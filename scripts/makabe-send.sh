#!/usr/bin/env bash
# 走っている claude-makabe に途中で発言(訂正・追加)を送る(庵野 2026-10-07)。
# claude-makabe.sh は claude -p を stream-json の入出力で起こし、<run_dir>/inbox.fifo を標準入力へ中継する。
# この道具はその FIFO へ 1 行 JSON(user message)を書く。
#
# 使い方: makabe-send <run_dir|最新> "<本文>"
#         makabe-send <run_dir|最新> -f <file>      本文をファイルから(- なら標準入力)
#   <run_dir>  フルパス、または run id(makabe-<ts>-<pid>-<rand>、${CODEX_AGENT_STATE_DIR:-~/.codex-agents}/runs 配下)
#   最新       走っている run のうち最新(無ければエラー)。送り先は stdout に必ず出す
#
# 走っていない run_dir(driver が居ない・result 済みで閉じ済み)には書かず exit 1。
# 送った本文は <run_dir>/sent/<時刻>-<n>.md に残す(送れたときだけ)。claude への届き方は既定の priority
# (turn の途中なら tool 呼び出しが終わったところで同じ turn の中で読まれる)。
set -euo pipefail

die() { echo "makabe-send: $*" >&2; exit "${2:-1}"; }

[ "$#" -ge 2 ] || die '使い方: makabe-send <run_dir|最新> "<本文>"(または -f <file>)' 2
target="$1"; shift
body=""
if [ "$1" = "-f" ]; then
  [ "$#" -ge 2 ] || die "-f には path が必要" 2
  if [ "$2" = "-" ]; then body="$(cat)"; else [ -r "$2" ] || die "読めない: $2" 2; body="$(cat "$2")"; fi
else
  body="$*"
fi
LC_ALL=C grep -q '[^[:space:]]' <<<"$body" || die "本文が空白のみ" 2

state_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}"
runs="$state_dir/runs"

is_running() { # <run_dir>
  local d="$1" pid
  [ -f "$d/driver.pid" ] || return 1
  pid="$(cat "$d/driver.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # pid の使い回しを避ける: 駆動役の cmdline であること
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'makabe-stream' || return 1
  [ ! -e "$d/closed" ] || return 1
  [ -p "$d/inbox.fifo" ] || return 1
}

if [ "$target" = "最新" ] || [ "$target" = "latest" ]; then
  run_dir=""
  newest=""
  while IFS= read -r d; do
    [ -n "$newest" ] || newest="$d"
    if is_running "$d"; then run_dir="$d"; break; fi
  done < <(ls -1d "$runs"/makabe-* 2>/dev/null | sort -r)
  [ -n "$run_dir" ] || die "走っている claude-makabe の run が無い(最新の run: ${newest:-無し})"
else
  case "$target" in
    /*|./*|../*) run_dir="$target" ;;
    *) run_dir="$runs/$target" ;;
  esac
  [ -d "$run_dir" ] || die "run_dir が見つからない: $run_dir"
  run_dir="$(cd -P "$run_dir" && pwd)"
fi
echo "makabe-send: 送り先 $run_dir"

is_running "$run_dir" || die "走っていない(driver が居ない・result 済み・FIFO が無い): $run_dir"

line="$(printf '%s' "$body" | python3 -c '
import json, sys
text = sys.stdin.read()
print(json.dumps({"type": "user", "message": {"role": "user", "content": text}, "parent_tool_use_id": None}, ensure_ascii=False))
')"

# 駆動役の終端処理と同じ flock で直列化する(閉じる瞬間の送り損ねを防ぐ)
exec 9>"$run_dir/inbox.lock"
flock -x 9
is_running "$run_dir" || die "走っていない(送る直前に終わった): $run_dir"
# 駆動役が O_RDWR で読み側を持っているので非 blocking の open は通る(居なければ ENXIO で失敗)
printf '%s\n' "$line" | python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
data = sys.stdin.buffer.read()
os.set_blocking(fd, True)
view = memoryview(data)
while view:
    n = os.write(fd, view)
    view = view[n:]
os.close(fd)
' "$run_dir/inbox.fifo" || die "FIFO に書けない(駆動役が読んでいない): $run_dir"

mkdir -p "$run_dir/sent"
n=$(( $(ls -1 "$run_dir/sent" 2>/dev/null | wc -l) + 1 ))
stamp="$(date '+%Y%m%d-%H%M%S')"
printf '%s\n' "$body" > "$run_dir/sent/$stamp-$n.md"
echo "makabe-send: 送った($run_dir/sent/$stamp-$n.md)"
