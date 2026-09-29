#!/usr/bin/env bash
# kimi-makabe.sh(K3 直書き経路)専用の PreToolUse hook。gate-guard.sh が env KIMI_MAKABE_ROOT を見て
# ここへ exec で分岐する(config.toml の [[hooks]] は全 kimi 共通で run 単位に足せないため)。
#
# 真壁は `-C` に渡された作業ルート(worktree)の中では Write / Edit / Bash 経由の書き込み・commit を
# 自由にできる。**禁じるのは作業ルートの外への書き込みだけ** ── `~/.codex-agents/**`・`~/canonical/**`・
# `~/.claude/**`・`~/.codex/**`・`~/.kimi-code/**`・`~/bin/**`。ただし run_dir の停止理由ファイル
# (`$CODEX_AGENT_RUN_DIR/stuck.md`)だけは書ける(commit-stop-kimi-makabe.sh が読む終端の印)。
# worktree-guard-claude-makabe.sh の kimi 版。差は 3 つ: tool の path のキー(kimi は `path`、claude は
# `file_path`)、相対パスの基点(stdin の cwd)、禁止に ~/.kimi-code を足し stuck.md を carve-out した。
#
# kimi の PreToolUse は exit 2 + stderr で block(verdict-stop.sh の冒頭の実測と同じ)。
# tool_name / tool_input は 2026-09-29 に実測: Write {path,content} / Edit {path,old_string,new_string} /
# Bash {command}(Read / Glob / Grep は書かないので見ない)。

set -u

stdin_json="$(cat 2>/dev/null || true)"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

root="${KIMI_MAKABE_ROOT:-}"
[ -n "$root" ] || exit 0
allow_file="${CODEX_AGENT_RUN_DIR:+$CODEX_AGENT_RUN_DIR/stuck.md}"

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"
base_cwd="$(printf '%s' "$stdin_json" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$base_cwd" ] || base_cwd="$root"

block() {
  echo "作業木の外への書き込みを検出(kimi-makabe): $1" >&2
  exit 2
}

check_path() {
  # $1 = 検査対象の生パス(絶対・相対・~ 始まり)。作業ルートの外の禁止プレフィックス配下なら
  # 正規化パスを stdout へ出して exit 0、無ければ exit 1。
  python3 - "$root" "$base_cwd" "$allow_file" "$1" <<'PY'
import os
import sys

root = os.path.realpath(os.path.expanduser(sys.argv[1]))
base = os.path.realpath(os.path.expanduser(sys.argv[2]))
allow = sys.argv[3]
raw = sys.argv[4]
if not raw:
    sys.exit(1)

forbidden_prefixes = [
    os.path.realpath(os.path.expanduser(p))
    for p in ("~/.codex-agents", "~/canonical", "~/.claude", "~/.codex", "~/.kimi-code", "~/bin")
]

path = os.path.expanduser(raw)
if not os.path.isabs(path):
    path = os.path.join(base, path)
norm = os.path.realpath(os.path.normpath(path))

if allow and norm == os.path.realpath(allow):
    sys.exit(1)
if norm == root or norm.startswith(root + os.sep):
    sys.exit(1)
for prefix in forbidden_prefixes:
    if norm == prefix or norm.startswith(prefix + os.sep):
        print(norm)
        sys.exit(0)
sys.exit(1)
PY
}

case "$tool_name" in
  Write|Edit|MultiEdit|NotebookEdit)
    file_path="$(printf '%s' "$stdin_json" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)"
    [ -n "$file_path" ] || exit 0
    violation="$(check_path "$file_path")"
    if [ -n "$violation" ]; then
      block "$violation(tool: $tool_name)"
    fi
    exit 0
    ;;
  Bash)
    ;;
  *)
    exit 0
    ;;
esac

command_str="$(printf '%s' "$stdin_json" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_str" ] || exit 0

# 書き込み系コマンドかどうかの判定(worktree-guard-claude-makabe.sh と同じ)。
is_write=0
if printf '%s' "$command_str" | grep -Eq '(^|[^0-9&])>>?[^&]'; then
  if ! printf '%s' "$command_str" | grep -Eq '^\s*[^>]*>\s*/dev/null\s*$'; then
    is_write=1
  fi
fi
if printf '%s' "$command_str" | grep -Eq '\btee\b'; then
  case "$command_str" in
    *"tee /dev/null"*|*"tee -a /dev/null"*) ;;
    *) is_write=1 ;;
  esac
fi
if printf '%s' "$command_str" | grep -Eq '\b(rm|mv|cp|ln|mkdir|touch)[[:space:]]'; then
  is_write=1
fi
if printf '%s' "$command_str" | grep -Eq '\b(sed[[:space:]]+-i|truncate[[:space:]]|dd[[:space:]]+of=|chmod[[:space:]]+\+w|git[[:space:]]+(push|reset[[:space:]]+--hard|checkout[[:space:]]+--))'; then
  is_write=1
fi

[ "$is_write" -eq 1 ] || exit 0

violation="$(python3 - "$root" "$allow_file" "$command_str" <<'PY'
import os
import re
import sys

root = os.path.realpath(os.path.expanduser(sys.argv[1]))
allow = sys.argv[2]
cmd = sys.argv[3]

forbidden_prefixes = [
    os.path.realpath(os.path.expanduser(p))
    for p in ("~/.codex-agents", "~/canonical", "~/.claude", "~/.codex", "~/.kimi-code", "~/bin")
]

tokens = re.findall(r'(?:~|/)[^\s\'"|;&<>]+', cmd)
for tok in tokens:
    tok = tok.rstrip(").,;")
    path = os.path.expanduser(tok)
    if not os.path.isabs(path):
        continue
    norm = os.path.normpath(path)
    if allow and norm == os.path.normpath(allow):
        continue
    if norm == root or norm.startswith(root + os.sep):
        continue
    for prefix in forbidden_prefixes:
        if norm == prefix or norm.startswith(prefix + os.sep):
            print(norm)
            sys.exit(0)
sys.exit(1)
PY
)"
python_status=$?

if [ "$python_status" -eq 0 ] && [ -n "$violation" ]; then
  block "$violation(コマンド: $command_str)"
fi

exit 0
