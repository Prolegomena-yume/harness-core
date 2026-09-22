#!/usr/bin/env bash
# claude-makabe.sh(Claude sonnet、codex weekly 逼迫時の実装代替経路)専用の PreToolUse hook。
#
# 真壁は `-C` に渡された作業ルート(worktree)の中では Write / Edit / NotebookEdit / Bash 経由の
# 書き込み・commit を自由にできる(実装者なので当然)。**禁じるのは作業ルートの外への書き込みだけ**
# ── `~/.codex-agents/**`(run_dir、贄川や柏木の checkpoint)・`~/canonical/**`(harness-core・tech)・
# `~/.claude/**`・`~/.codex/**`・`~/bin/**`。
#
# claude-kashiwagi の worktree-guard-claude.sh と違い、この hook は Write/Edit/NotebookEdit も見る
# (kashiwagi は --permission-mode acceptEdits の cwd スコープに任せていたが、makabe は
# --dangerously-skip-permissions で起動するため acceptEdits のスコープが掛からない。hook が唯一の担保)。
# root(作業ルート)の carve-out は常時有効 ── makabe の `-C` は贄川の run_dir 自身を指すことが無く、
# 常に実際の作業木のため、kashiwagi のゲート1のような「carve-out を切る」場面が無い。
#
# block の返し方は他の *-claude.sh hook と同じ実測(Claude Code は exit 2 + stderr でだけ block)。

set -u

stdin_json="$(cat 2>/dev/null || true)"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"

root="${CLAUDE_MAKABE_ROOT:-}"
[ -n "$root" ] || exit 0

block() {
  echo "作業木の外への書き込みを検出(claude-makabe): $1" >&2
  exit 2
}

check_path() {
  # $1 = 検査対象の生パス文字列(絶対・相対・~ 始まり)。作業ルートの外の禁止プレフィックス配下なら
  # violation の正規化パスを stdout へ、無ければ何も出さず終わる。
  python3 - "$root" "$1" <<'PY'
import os
import sys

root = os.path.realpath(os.path.expanduser(sys.argv[1]))
raw = sys.argv[2]
if not raw:
    sys.exit(1)

forbidden_prefixes = [
    os.path.realpath(os.path.expanduser("~/.codex-agents")),
    os.path.realpath(os.path.expanduser("~/canonical")),
    os.path.realpath(os.path.expanduser("~/.claude")),
    os.path.realpath(os.path.expanduser("~/.codex")),
    os.path.realpath(os.path.expanduser("~/bin")),
]

path = os.path.expanduser(raw)
if not os.path.isabs(path):
    # 相対パスは root からの相対として扱う(makabe の cwd は常に root)。
    path = os.path.join(root, path)
norm = os.path.normpath(path)

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
  Write|Edit)
    file_path="$(printf '%s' "$stdin_json" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    [ -n "$file_path" ] || exit 0
    violation="$(check_path "$file_path")"
    if [ -n "$violation" ]; then
      block "$violation(tool: $tool_name)"
    fi
    exit 0
    ;;
  NotebookEdit)
    file_path="$(printf '%s' "$stdin_json" | jq -r '.tool_input.notebook_path // empty' 2>/dev/null || true)"
    [ -n "$file_path" ] || exit 0
    violation="$(check_path "$file_path")"
    if [ -n "$violation" ]; then
      block "$violation(tool: NotebookEdit)"
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

# 書き込み系コマンドかどうかの判定(worktree-guard-claude.sh と同じロジック、P2/checkpoint の
# 自己 commit は書き込み扱いに含めない ── 対象パス次第で下の python チェックに掛かる)。
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

violation="$(python3 - "$root" "$command_str" <<'PY'
import os
import re
import sys

root = os.path.realpath(os.path.expanduser(sys.argv[1]))
cmd = sys.argv[2]

forbidden_prefixes = [
    os.path.realpath(os.path.expanduser("~/.codex-agents")),
    os.path.realpath(os.path.expanduser("~/canonical")),
    os.path.realpath(os.path.expanduser("~/.claude")),
    os.path.realpath(os.path.expanduser("~/.codex")),
    os.path.realpath(os.path.expanduser("~/bin")),
]

tokens = re.findall(r'(?:~|/)[^\s\'"|;&<>]+', cmd)
for tok in tokens:
    tok = tok.rstrip(").,;")
    path = os.path.expanduser(tok)
    if not os.path.isabs(path):
        continue
    norm = os.path.normpath(path)
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
