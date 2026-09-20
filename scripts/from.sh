#!/usr/bin/env bash
# usage:
#   from-niekawa [--wait] [--cap <秒>=1800] [--after <N>] [--pid <pid>] \
#     (--wait の heartbeat は 300 秒ごと、環境 FROM_HEARTBEAT_INTERVAL で変えられる)
#                [--label <str>] [--inbox <path>] [-n N=20]
#   from-takano  [--after <N>] [--inbox <path>]
#
# 向きは $0 の basename (from-niekawa / from-takano の symlink) で決める。
# inbox-wait.sh / inbox-read.sh の統合(--wait 無しなら tail、--wait で見張り)。
#
# from-niekawa(鷹野が読む・待つ、箱は to-takano と同じ):
#   箱 = --inbox > env TAKANO_INBOX > exit 4
#   --wait なら見張り、新規行の種別で exit: 承認 0 / エスカレーション 2 /
#     異常終了・pid消滅 3、cap 到達で exit 1、引数不正 exit 4。
#     --pid の pid 消滅を検知した際は、exit 3 で返す前に受信箱をもう 1 回
#     読み直す(post 直後に exit するランチャとの隙間の誤診対策)。
#     一致行の行番号(after + 何行目)を LINES=N で stdout に出す。
#   --wait 無しなら -n N(既定20)の tail を列を揃えて表示(最小実装)。
# from-takano(贄川が読む、箱は to-niekawa と同じ):
#   箱 = --inbox > env NIEKAWA_INBOX > $CODEX_AGENT_RUN_DIR/to-niekawa.tsv > exit 4
#   tail だけ。--after N で未読だけを生の TSV で出し、最後に LINES=N(現在の
#   総行数)を出す。--wait は受け付けない(exit 4)。

if [ -z "${FROM_LINEBUF:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export FROM_LINEBUF=1
  exec stdbuf -oL bash "$0" "$@"
fi

set -u

prog=$(basename "$0")
case "$prog" in
  from-niekawa) role=niekawa ;;
  from-takano) role=takano ;;
  *)
    echo "[from] エラー: 不明な起動名 '$prog'(from-niekawa / from-takano の symlink 経由で呼ぶこと)" >&2
    exit 4
    ;;
esac

usage() {
  case "$role" in
    niekawa)
      echo "usage: from-niekawa [--wait] [--cap <秒>=1800] [--after <N>] [--pid <pid>] [--label <str>] [--inbox <path>] [-n N=20]" >&2
      ;;
    takano)
      echo "usage: from-takano [--after <N>] [--inbox <path>]" >&2
      ;;
  esac
}

wait_mode=0
cap=1800
after=0
pid=""
label="from-$role"
n=20
if [ "$role" = niekawa ]; then
  inbox="${TAKANO_INBOX:-}"
else
  inbox="${NIEKAWA_INBOX:-}"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait_mode=1; shift ;;
    --cap) cap="${2:-}"; shift 2 ;;
    --after) after="${2:-}"; shift 2 ;;
    --pid) pid="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --inbox) inbox="${2:-}"; shift 2 ;;
    -n) n="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 4 ;;
  esac
done

if [ "$role" = takano ] && [ "$wait_mode" -eq 1 ]; then
  echo "[from-takano] エラー: --wait は受け付けない(tail 専用)" >&2
  exit 4
fi

if [ "$role" = takano ] && [ -z "$inbox" ] && [ -n "${CODEX_AGENT_RUN_DIR:-}" ]; then
  inbox="${CODEX_AGENT_RUN_DIR}/to-niekawa.tsv"
fi

if [ -z "$inbox" ]; then
  echo "[$prog] エラー: --inbox / env が無い" >&2
  exit 4
fi

# --- tail 専用(--wait 無し) ---
if [ "$wait_mode" -eq 0 ]; then
  if [ "$role" = takano ]; then
    # 機械可読: --after N で未読だけを生 TSV で、最後に LINES= を出す
    cur=0
    if [ -f "$inbox" ]; then
      cur=$(wc -l < "$inbox" 2>/dev/null | tr -d ' ')
      [ -n "$cur" ] || cur=0
      if [ "$cur" -gt "$after" ]; then
        sed -n "$((after + 1)),${cur}p" "$inbox"
      fi
    fi
    echo "LINES=$cur"
    exit 0
  else
    # 人間向け: -n N の tail、column 整形(最小実装)
    if [ ! -f "$inbox" ]; then
      echo "[$prog] 受信箱が無い: $inbox" >&2
      exit 0
    fi
    {
      printf '時刻\t差出人\t種別\trun_dir\t要旨\n'
      tail -n "$n" "$inbox"
    } | column -t -s "$(printf '\t')"
    exit 0
  fi
fi

# --- --wait(ここに来るのは role=niekawa のときだけ、上で takano は弾いている) ---
ts() { date '+%H:%M:%S'; }

exit_for_kind() {
  case "$1" in
    承認) echo 0 ;;
    エスカレーション) echo 2 ;;
    異常終了) echo 3 ;;
    *) echo "" ;;
  esac
}

HEARTBEAT_INTERVAL="${FROM_HEARTBEAT_INTERVAL:-300}"  # 既定 300 秒(09-20_02「30 秒は過剰 → 既定 300」の実装漏れを 09-20 夜に訂正、鷹野)
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
