#!/usr/bin/env bash
# 贄川(claude 経路)が真壁・柏木を待つときに使う道具(案 A、役員 人見 2026-09-25「claude 経路は 590 でよい」)。
#
# kimi 経路の「280 秒の切片で必ず返る sleep」(kimi/niekawa.md・docs/delegation.md、契約の数字、
# K3 の tool 上限 300 秒に合わせている)とは前提が違う ── claude の cache は 1h TTL で、
# 待っても cold にならない。Bash tool の timeout は 600 秒が上限なので、1 回の待ちはこれより長くできない。
#
# 真壁/柏木の `.out` の `^変更ファイル数:`(終端の印)か、鷹野からの新着(`from-takano --after <LINES>`)
# のどちらかが先に出た時点で即座に返る。何も無ければ --timeout 秒(既定 590 = 600 - 10 秒の余白)で返る。
# 10 秒ごと(--poll)に両方を見る。返すのは短い要約(tail 3 行・footer・新着)だけ ── 全文脈を読み直させない。
#
# K3(kimi 経路)には触らない。kimi-niekawa.sh・kimi/niekawa.md の 280 秒の切片はこのファイルの外。
#
# usage: niekawa-wait-claude.sh --out <真壁/柏木の .out> [--after <N>] [--inbox <path>]
#                                [--timeout <秒>=590] [--poll <秒>=10]
#
# --inbox は from-takano と同じ省略時解決(env NIEKAWA_INBOX > $CODEX_AGENT_RUN_DIR/to-niekawa.tsv)に
# 任せる ── 贄川は自分の便の箱の path を知らなくてよい(from-takano --after <N> をそのまま呼ぶのと同じ)。
#
# exit: 0 = 終端(footer)検知 / 1 = 鷹野からの新着検知 / 2 = timeout(何も無いまま)/ 4 = 引数不正
#
# NIEKAWA_WAIT_TIMEOUT / NIEKAWA_WAIT_POLL で既定を上書きできる(test 用、610 を超えて Bash tool の
# 上限を超える値を渡さないこと)。

set -u

die() {
  echo "エラー: $*" >&2
  exit 4
}

usage() {
  cat <<'USAGE'
使い方: niekawa-wait-claude.sh --out <path> [--inbox <path>] [--after <N>] [--timeout <秒>=590] [--poll <秒>=10]
USAGE
}

out_path=""
inbox_path=""
inbox_after=""
timeout="${NIEKAWA_WAIT_TIMEOUT:-590}"
poll="${NIEKAWA_WAIT_POLL:-10}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || die "--out には path が要る"; out_path="$2"; shift 2 ;;
    --inbox) [ $# -ge 2 ] || die "--inbox には path が要る"; inbox_path="$2"; shift 2 ;;
    --after) [ $# -ge 2 ] || die "--after には N が要る"; inbox_after="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die "--timeout には秒が要る"; timeout="$2"; shift 2 ;;
    --poll) [ $# -ge 2 ] || die "--poll には秒が要る"; poll="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done

[ -n "$out_path" ] || die "--out が要る(真壁 / 柏木の .out のパス)"
[[ "$timeout" =~ ^[0-9]+$ ]] || die "--timeout は整数: $timeout"
[[ "$poll" =~ ^[0-9]+$ ]] || die "--poll は整数: $poll"
[ "$poll" -ge 1 ] || die "--poll は 1 以上"

inbox_watch=0
if [ -n "$inbox_path" ] || [ -n "$inbox_after" ]; then
  inbox_watch=1
  [ -n "$inbox_after" ] || inbox_after=0
  [[ "$inbox_after" =~ ^[0-9]+$ ]] || die "--after は整数: $inbox_after"
  command -v from-takano >/dev/null 2>&1 || die "from-takano が見つからない(PATH を確認)"
fi

check_footer() {
  [ -f "$out_path" ] && LC_ALL=C grep -q '^変更ファイル数:' "$out_path" 2>/dev/null
}

inbox_new=""
inbox_lines="${inbox_after:-0}"

check_inbox() {
  local raw cur new_lines
  [ "$inbox_watch" -eq 1 ] || return 1
  if [ -n "$inbox_path" ]; then
    raw="$(from-takano --after "$inbox_after" --inbox "$inbox_path" 2>/dev/null)" || return 1
  else
    raw="$(from-takano --after "$inbox_after" 2>/dev/null)" || return 1
  fi
  cur="$(printf '%s\n' "$raw" | LC_ALL=C sed -n 's/^LINES=//p' | tail -n1)"
  [ -n "$cur" ] || return 1
  new_lines="$(printf '%s\n' "$raw" | LC_ALL=C grep -v '^LINES=' | sed '/^$/d')"
  if [ "$cur" -gt "$inbox_after" ] 2>/dev/null && [ -n "$new_lines" ]; then
    inbox_new="$new_lines"
    inbox_lines="$cur"
    return 0
  fi
  inbox_lines="$cur"
  return 1
}

start_epoch=$(date +%s)
reason="timeout"

while :; do
  if check_footer; then
    reason="footer"
    break
  fi
  if check_inbox; then
    reason="inbox"
    break
  fi
  now_epoch=$(date +%s)
  elapsed=$((now_epoch - start_epoch))
  if [ "$elapsed" -ge "$timeout" ]; then
    reason="timeout"
    break
  fi
  remain=$((timeout - elapsed))
  sleep_for="$poll"
  [ "$sleep_for" -le "$remain" ] || sleep_for="$remain"
  [ "$sleep_for" -ge 1 ] || sleep_for=1
  sleep "$sleep_for"
done

echo "REASON=$reason"
echo "--- tail 3 ---"
if [ -f "$out_path" ]; then
  tail -n 3 "$out_path"
else
  echo "(まだ出力ファイルが無い: $out_path)"
fi
echo "--- footer ---"
if [ -f "$out_path" ] && LC_ALL=C grep -q '^変更ファイル数:' "$out_path" 2>/dev/null; then
  LC_ALL=C grep '^変更ファイル数:' "$out_path"
else
  echo "まだ"
fi
echo "--- from-takano 新着 ---"
if [ -n "$inbox_new" ]; then
  printf '%s\n' "$inbox_new"
else
  echo "無し"
fi
echo "LINES=$inbox_lines"

case "$reason" in
  footer) exit 0 ;;
  inbox) exit 1 ;;
  timeout) exit 2 ;;
esac
