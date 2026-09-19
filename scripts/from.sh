#!/usr/bin/env bash
# usage: inbox-wait.sh [--cap <秒>=1800] [--after <N>] [--pid <pid>] \
#                       [--label <str>] [--inbox <path>]
#
# 鷹野の受信箱(TSV、追記だけ)を見張り、新規行が届いたら種別で exit する。
#   承認 0 / エスカレーション 2 / 異常終了 3
# cap 到達で exit 1。--pid の pid が消えたら exit 3(ランチャ改修前の
# 走行中プロセスに今回限り使う想定。pid 直指定なので pgrep の誤診は無い)。
# 起動時点で --after N より後ろに対象行が既にあれば即返す(取りこぼし無し)。
# 受信箱がまだ無いのはエラーでなく待つ(inbox-post が mkdir -p する)。
# 1 秒 poll、heartbeat 30 秒、stdbuf -oL。一致行と、一致した行の行番号
# (after + 何行目、次回の --after 用、LINES=N の形)を stdout に出す。
# --pid の pid 消滅を検知した際は、exit 3 で返す前に受信箱をもう 1 回
# 読み直す(post 直後に exit するランチャと 1 秒 poll の隙間で、行が
# 届いているのに exit 3 と誤診するのを防ぐ)。行があれば種別の code で返す。

if [ -z "${INBOX_WAIT_LINEBUF:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export INBOX_WAIT_LINEBUF=1
  exec stdbuf -oL bash "$0" "$@"
fi

set -u

usage() {
  echo "usage: inbox-wait [--cap <秒>=1800] [--after <N>] [--pid <pid>] [--label <str>] [--inbox <path>]" >&2
}

cap=1800
after=0
pid=""
label="inbox-wait"
inbox="${TAKANO_INBOX:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cap) cap="${2:-}"; shift 2 ;;
    --after) after="${2:-}"; shift 2 ;;
    --pid) pid="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --inbox) inbox="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 4 ;;
  esac
done

if [ -z "$inbox" ]; then
  echo "[inbox-wait] エラー: --inbox も TAKANO_INBOX も無い" >&2
  exit 4
fi

ts() { date '+%H:%M:%S'; }

exit_for_kind() {
  case "$1" in
    承認) echo 0 ;;
    エスカレーション) echo 2 ;;
    異常終了) echo 3 ;;
    *) echo "" ;;
  esac
}

HEARTBEAT_INTERVAL=30
start_epoch=$(date +%s)
last_heartbeat=$start_epoch
cur=0
matched_code=""
matched_line=""
matched_kind=""
matched_lineno=0

# 受信箱を読み、新規行に一致(承認/エスカレーション/異常終了)があれば
# matched_* をセットして戻り値 0。無ければ after を cur まで進めて戻り値 1。
check_new() {
  matched_code=""
  matched_line=""
  matched_kind=""
  matched_lineno=0
  [ -f "$inbox" ] || return 1
  cur=$(wc -l < "$inbox" 2>/dev/null | tr -d ' ')
  [ -n "$cur" ] || cur=0
  [ "$cur" -gt "$after" ] || return 1
  local new_lines lineno=$after code
  new_lines=$(sed -n "$((after + 1)),${cur}p" "$inbox")
  while IFS=$'\t' read -r f_ts f_from f_kind f_rundir f_summary; do
    lineno=$((lineno + 1))
    [ -n "${f_kind:-}" ] || continue
    code=$(exit_for_kind "$f_kind")
    if [ -n "$code" ]; then
      matched_code="$code"
      matched_kind="$f_kind"
      matched_line=$(printf '%s\t%s\t%s\t%s\t%s' "$f_ts" "$f_from" "$f_kind" "$f_rundir" "$f_summary")
      matched_lineno="$lineno"
      return 0
    fi
  done <<< "$new_lines"
  after="$cur"
  return 1
}

emit_match_and_exit() {
  echo "[$label] [$(ts)] 一致行検知 種別=$matched_kind"
  printf '%s\n' "$matched_line"
  echo "LINES=$matched_lineno"
  exit "$matched_code"
}

echo "[$label] [$(ts)] 受信箱監視開始 inbox=$inbox after=$after cap=${cap}秒${pid:+ pid=$pid}"

while :; do
  now_epoch=$(date +%s)
  elapsed=$((now_epoch - start_epoch))

  if check_new; then
    emit_match_and_exit
  fi

  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    # exit 3 で返す前に受信箱をもう 1 回読み直す(post 直後に exit する
    # ランチャと 1 秒 poll の隙間の誤診対策)。行があれば種別の code で返す。
    if check_new; then
      emit_match_and_exit
    fi
    echo "[$label] [$(ts)] pid=$pid 消滅を検知"
    echo "LINES=$cur"
    exit 3
  fi

  if [ "$elapsed" -ge "$cap" ]; then
    echo "[$label] [$(ts)] cap 到達 経過=${elapsed}秒"
    echo "LINES=$cur"
    exit 1
  fi

  if [ $((now_epoch - last_heartbeat)) -ge "$HEARTBEAT_INTERVAL" ]; then
    echo "[$label] [$(ts)] 監視中 経過=${elapsed}秒 残=$((cap - elapsed))秒"
    last_heartbeat=$now_epoch
  fi

  sleep 1
done
