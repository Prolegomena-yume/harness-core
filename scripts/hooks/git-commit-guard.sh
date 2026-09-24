#!/usr/bin/env bash
# Claude Code(claude -p / 対話 claude 両方)の PreToolUse hook。
# 「commit は役名(git-as <役>)、pax は人見本人だけ」(feedback-commit-as-role.md)を
# git hook ではなくこの hook で担保する ── git hook は人見本人の端末 commit まで塞いでしまうため
# 使わない(役員 人見 2026-09-25)。
#
# 対象は Bash tool の command に「plain `git` 経由の commit」が現れたときだけ。`git-as <役> commit …`
# は通す(git-as 自身が内部で `git -c user.name=... commit` を exec するが、typed command は
# "git-as" で始まるので判定にはかからない)。
#
# block の返し方は gate-guard-claude.sh / worktree-guard-claude.sh と同じ実測:
# Claude Code の PreToolUse は --dangerously-skip-permissions(bypass)下では
# exit 2 + stderr でだけ確実に block する(exit 0 + stdout の JSON deny は bypass 下で無視される)。
#
# 判定は python3(shlex でトークン化、`-C <path>` `-c k=v` 等フラグの値を安全にスキップしてから
# 実際のサブコマンドを取る。`--grep=commit` のような「commit という語を含むだけの引数」を
# 誤検知しない)。command 文字列は && / || / ; / | / 改行で区切った各セグメントを独立に見る
# (`cd foo && git commit …` のように前段に別コマンドが付く形に対応)。

set -u

stdin_json="$(cat 2>/dev/null || true)"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool_name" = "Bash" ] || exit 0

command_str="$(printf '%s' "$stdin_json" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_str" ] || exit 0

violation="$(python3 - "$command_str" <<'PY'
import re
import shlex
import sys

cmd = sys.argv[1]

# トップレベルの区切り(&& || ; | 改行)でセグメントに分ける。クォート内の区切りまで厳密には
# 見ないが、誤検知は「弾きすぎ」側に振れるだけで許容する(コメントの通り)。
segments = re.split(r'&&|\|\||;|\||\n', cmd)

ENV_ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=\S*$')

def strip_env_prefix(tokens):
    i = 0
    while i < len(tokens) and ENV_ASSIGN.match(tokens[i]):
        i += 1
    return tokens[i:]

VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}

def find_subcommand(tokens):
    i = 1  # tokens[0] == "git"
    while i < len(tokens):
        tok = tokens[i]
        if tok in VALUE_FLAGS:
            i += 2
            continue
        if tok.startswith("--") and "=" in tok:
            i += 1
            continue
        if tok.startswith("-"):
            i += 1
            continue
        return tok
    return None

for seg in segments:
    seg = seg.strip()
    if not seg:
        continue
    try:
        tokens = shlex.split(seg, posix=True)
    except ValueError:
        continue
    if not tokens:
        continue
    tokens = strip_env_prefix(tokens)
    if not tokens:
        continue
    if tokens[0] == "git-as":
        continue  # 正規経路、許可
    if tokens[0] != "git":
        continue
    sub = find_subcommand(tokens)
    if sub == "commit":
        print(seg)
        sys.exit(0)

sys.exit(1)
PY
)"
python_status=$?

if [ "$python_status" -eq 0 ] && [ -n "$violation" ]; then
  echo "commit は git-as <役> commit … を使う(plain git commit は block、役員 人見 2026-09-25)。該当コマンド: $violation" >&2
  exit 2
fi

exit 0
