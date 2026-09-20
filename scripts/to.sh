#!/usr/bin/env bash
# usage:
#   to-takano  --from <差出人> --kind <承認|エスカレーション|異常終了> \
#              [--run-dir <path>] [--inbox <path>] [--] [要旨...]
#   to-niekawa [--from <差出人>=鷹野] --kind <裁定|指示|停止> \
#              [--inbox <path>] [--] [要旨...]
#
# 向きは $0 の basename (to-takano / to-niekawa の symlink) で決める。
# TSV 1 行: 時刻(ISO8601秒,ローカルTZ) \t 差出人 \t 種別 \t run_dir \t 要旨
#
# to-takano(贄川 → 鷹野の箱 to-takano.tsv):
#   箱 = --inbox > env TAKANO_INBOX > exit 4
#   種別は 承認/エスカレーション/異常終了 の3値だけ(それ以外 exit 4)
#   --from 必須。verdict ガードあり(下記)。
# to-niekawa(鷹野 → 贄川の箱 to-niekawa.tsv):
#   箱 = --inbox > env NIEKAWA_INBOX > $CODEX_AGENT_RUN_DIR/to-niekawa.tsv > exit 4
#   種別は 裁定/指示/停止 の3値だけ(それ以外 exit 4)
#   ガード無し。--from 省略時の既定は「鷹野」。
#
# 種別の集合は向きで排他(to-takano に裁定、to-niekawa に承認、は exit 4)。
#
# 差出人・run_dir・要旨は改行/TAB を空白に潰す(列がズレないよう全列で行う)。
# 行全体は PIPE_BUF(4096 バイト)を超えない ── ロック無しで複数 writer が
# `printf '%s\n' >>` 1 回だけの原子的 append を行うための不変条件で、これは落とさない。
# 要旨は上限まで丸ごと入れる(1024 バイト固定切り詰めは廃止、BRIEF-inbox-limits)。
# 行が 4096 バイトを超える場合だけ、要旨を切って末尾に
# `…[切れた N 字、全文は <path>]`(N は元の全文字数)を付け、元の全文(改行/TAB を
# 潰す前のもの)を便ディレクトリの messages/<時刻>-<pid>.md に残す。読み手は
# その path を辿れば裁定文を取りこぼさない。
#
# verdict ガード(to-takano のみ): run_dir が "-" 以外かつ種別が
# 承認/エスカレーション のとき、"<run_dir>/verdict.md" が存在し 1 行目が
# "verdict: <種別>"(空白無し可)と一致しなければ exit 4。
# 異常終了は検証しない。run_dir が "-" なら検証しない。
#
# 書いた行を stdout に出して exit 0。

set -u

prog=$(basename "$0")
case "$prog" in
  to-takano) role=takano ;;
  to-niekawa) role=niekawa ;;
  *)
    echo "[to] エラー: 不明な起動名 '$prog'(to-takano / to-niekawa の symlink 経由で呼ぶこと)" >&2
    exit 4
    ;;
esac

usage() {
  case "$role" in
    takano)
      echo "usage: to-takano --from <差出人> --kind <承認|エスカレーション|異常終了> [--run-dir <path>] [--inbox <path>] [--] [要旨...]" >&2
      ;;
    niekawa)
      echo "usage: to-niekawa [--from <差出人>=鷹野] --kind <裁定|指示|停止> [--inbox <path>] [--] [要旨...]" >&2
      ;;
  esac
}

from=""
kind=""
rundir="${CODEX_AGENT_RUN_DIR:-}"
if [ "$role" = takano ]; then
  inbox="${TAKANO_INBOX:-}"
else
  inbox="${NIEKAWA_INBOX:-}"
fi
summary_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --from) from="${2:-}"; shift 2 ;;
    --kind) kind="${2:-}"; shift 2 ;;
    --run-dir) rundir="${2:-}"; shift 2 ;;
    --inbox) inbox="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; summary_args=("$@"); break ;;
    *) summary_args+=("$1"); shift ;;
  esac
done

if [ "$role" = niekawa ] && [ -z "$inbox" ] && [ -n "${CODEX_AGENT_RUN_DIR:-}" ]; then
  inbox="${CODEX_AGENT_RUN_DIR}/to-niekawa.tsv"
fi

if [ -z "$inbox" ]; then
  echo "[$prog] エラー: --inbox / env が無い" >&2
  exit 4
fi

if [ "$role" = niekawa ]; then
  [ -n "$from" ] || from="鷹野"
fi

if [ -z "$from" ]; then
  echo "[$prog] エラー: --from が無い" >&2
  exit 4
fi

case "$role" in
  takano)
    case "$kind" in
      承認|エスカレーション|異常終了) ;;
      *)
        echo "[$prog] エラー: --kind は 承認/エスカレーション/異常終了 の3値以外不可(受領: '${kind}')" >&2
        exit 4
        ;;
    esac
    ;;
  niekawa)
    case "$kind" in
      裁定|指示|停止) ;;
      *)
        echo "[$prog] エラー: --kind は 裁定/指示/停止 の3値以外不可(受領: '${kind}')" >&2
        exit 4
        ;;
    esac
    ;;
esac

[ -n "$rundir" ] || rundir="-"

# 差出人・run_dir も改行/TAB を空白へ潰す(列がズレないように)
from=$(printf '%s' "$from" | tr '\n\t' '  ')
rundir=$(printf '%s' "$rundir" | tr '\n\t' '  ')

# verdict ガード(to-takano のみ): run_dir が実指定("-" 以外)で
# 種別が 承認/エスカレーション のときだけ、run_dir/verdict.md の
# 1 行目と種別の一致を確認する
if [ "$role" = takano ] && [ "$rundir" != "-" ] && { [ "$kind" = "承認" ] || [ "$kind" = "エスカレーション" ]; }; then
  vfile="$rundir/verdict.md"
  if [ ! -f "$vfile" ]; then
    echo "[$prog] エラー: verdict.md が無い ($vfile)" >&2
    exit 4
  fi
  vline1=$(head -n 1 "$vfile")
  if ! printf '%s' "$vline1" | grep -qE "^verdict:[[:space:]]*${kind}\$"; then
    echo "[$prog] エラー: verdict.md の1行目が不一致('${vline1}')" >&2
    exit 4
  fi
fi

if [ "${#summary_args[@]}" -gt 0 ]; then
  raw_summary="${summary_args[*]}"
else
  raw_summary="$(cat -)"
fi

# 改行/TAB を空白へ潰す
flat_summary=$(printf '%s' "$raw_summary" | tr '\n\t' '  ')

# UTF-8 の文字境界を壊さずバイト数で切る(先頭 max バイトを取り、末尾の
# 不完全なマルチバイトシーケンスは iconv -c で捨てる)
truncate_utf8() {
  local s="$1" max="$2"
  [ "$max" -le 0 ] && { printf ''; return; }
  printf '%s' "$s" | head -c "$max" | iconv -f utf-8 -t utf-8 -c 2>/dev/null
}

ts=$(date '+%Y-%m-%dT%H:%M:%S%:z')
mkdir -p "$(dirname "$inbox")"

# 要旨列以外(時刻・差出人・種別・run_dir・列区切りタブ4本・末尾改行1)のバイト数を
# 引いた残りが要旨の予算。ここまでは丸ごと入れ、1024 バイト固定切り詰めはしない。
prefix_bytes=$(printf '%s\t%s\t%s\t%s\t' "$ts" "$from" "$kind" "$rundir" | wc -c)
budget=$((4096 - prefix_bytes - 1))
[ "$budget" -lt 0 ] && budget=0

flat_bytes=$(printf '%s' "$flat_summary" | wc -c)
if [ "$flat_bytes" -le "$budget" ]; then
  summary="$flat_summary"
else
  # 便ディレクトリ(inbox と同階層)の messages/ に全文(改行/TAB を潰す前の原文)を残す。
  msg_dir="$(dirname "$inbox")/messages"
  mkdir -p "$msg_dir"
  msg_file="$msg_dir/$(date '+%Y%m%d-%H%M%S')-$$.md"
  printf '%s\n' "$raw_summary" > "$msg_file"
  orig_chars=$(printf '%s' "$flat_summary" | wc -m)
  marker=$(printf '…[切れた %s 字、全文は %s]' "$orig_chars" "$msg_file")
  marker_bytes=$(printf '%s' "$marker" | wc -c)
  body_budget=$((budget - marker_bytes))
  [ "$body_budget" -lt 0 ] && body_budget=0
  body=$(truncate_utf8 "$flat_summary" "$body_budget")
  summary="${body}${marker}"
fi

line=$(printf '%s\t%s\t%s\t%s\t%s' "$ts" "$from" "$kind" "$rundir" "$summary")
printf '%s\n' "$line" >> "$inbox"
printf '%s\n' "$line"
exit 0
