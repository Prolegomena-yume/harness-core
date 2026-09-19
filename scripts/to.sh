#!/usr/bin/env bash
# usage: inbox-post.sh --from <差出人> --kind <承認|エスカレーション|異常終了> \
#                       [--run-dir <path>] [--inbox <path>] [--] [要旨...]
#
# 鷹野の受信箱(session ごと 1 ファイル、TSV、追記だけ)に 1 行足す。
# TSV 1 行: 時刻(ISO8601秒,ローカルTZ) \t 差出人 \t 種別 \t run_dir \t 要旨
#
# パス解決: --inbox > env TAKANO_INBOX > exit 4
# run_dir 解決: --run-dir > env CODEX_AGENT_RUN_DIR > "-"
# 種別は 承認 / エスカレーション / 異常終了 の 3 値だけ(それ以外 exit 4)
# 要旨は "--" 以降の引数(空白区切りで連結)か、無ければ stdin から読む。
# 差出人・run_dir・要旨は改行/TAB を空白に潰す(列がズレないよう全列で行う)。
# 要旨はさらに UTF-8 の文字境界を壊さず 1024 バイトで切る。
# 行全体は PIPE_BUF(4096 バイト)を超えない(超過時は要旨をさらに削る)。
# append は `printf '%s\n' >>` 1 回だけ(原子的、ロック無し)。
#
# verdict ガード: run_dir が "-" 以外かつ種別が 承認/エスカレーション のとき、
# "<run_dir>/verdict.md" が存在し 1 行目が "verdict: <種別>"(空白無し可)と
# 一致しなければ exit 4。異常終了は検証しない。run_dir が "-" なら検証しない。
#
# 書いた行を stdout に出して exit 0。

set -u

usage() {
  echo "usage: inbox-post --from <差出人> --kind <承認|エスカレーション|異常終了> [--run-dir <path>] [--inbox <path>] [--] [要旨...]" >&2
}

from=""
kind=""
rundir="${CODEX_AGENT_RUN_DIR:-}"
inbox="${TAKANO_INBOX:-}"
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

if [ -z "$inbox" ]; then
  echo "[inbox-post] エラー: --inbox も TAKANO_INBOX も無い" >&2
  exit 4
fi
if [ -z "$from" ]; then
  echo "[inbox-post] エラー: --from が無い" >&2
  exit 4
fi
case "$kind" in
  承認|エスカレーション|異常終了) ;;
  *)
    echo "[inbox-post] エラー: --kind は 承認/エスカレーション/異常終了 の3値以外不可(受領: '${kind}')" >&2
    exit 4
    ;;
esac
[ -n "$rundir" ] || rundir="-"

# 差出人・run_dir も改行/TAB を空白へ潰す(列がズレないように)
from=$(printf '%s' "$from" | tr '\n\t' '  ')
rundir=$(printf '%s' "$rundir" | tr '\n\t' '  ')

# verdict ガード: run_dir が実指定("-" 以外)で種別が 承認/エスカレーション
# のときだけ、run_dir/verdict.md の 1 行目と種別の一致を確認する
if [ "$rundir" != "-" ] && { [ "$kind" = "承認" ] || [ "$kind" = "エスカレーション" ]; }; then
  vfile="$rundir/verdict.md"
  if [ ! -f "$vfile" ]; then
    echo "[inbox-post] エラー: verdict.md が無い ($vfile)" >&2
    exit 4
  fi
  vline1=$(head -n 1 "$vfile")
  if ! printf '%s' "$vline1" | grep -qE "^verdict:[[:space:]]*${kind}\$"; then
    echo "[inbox-post] エラー: verdict.md の1行目が不一致('${vline1}')" >&2
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

summary=$(truncate_utf8 "$flat_summary" 1024)

ts=$(date '+%Y-%m-%dT%H:%M:%S%:z')
mkdir -p "$(dirname "$inbox")"

line=$(printf '%s\t%s\t%s\t%s\t%s' "$ts" "$from" "$kind" "$rundir" "$summary")
line_bytes=$(printf '%s' "$line" | wc -c)
if [ "$line_bytes" -gt 4096 ]; then
  overflow=$((line_bytes - 4096))
  new_max=$((1024 - overflow))
  [ "$new_max" -lt 0 ] && new_max=0
  summary=$(truncate_utf8 "$summary" "$new_max")
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$ts" "$from" "$kind" "$rundir" "$summary")
fi

printf '%s\n' "$line" >> "$inbox"
printf '%s\n' "$line"
exit 0
