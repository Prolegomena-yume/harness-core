#!/usr/bin/env bash
# claude-kashiwagi.sh(Opus 柏木、実行経路C)専用の PreToolUse hook。
#
# 役員 人見 2026-09-22 00:0x の訂正: 「レビュアーは書き込み無し」は締めすぎ。
# **柏木は作業木(cwd = 贄川が渡す -C の先)の中では Write / Edit / git commit ができる**
# (P2 の自己 commit は残す、delegation.md:147 のまま)。**禁じるのは作業木の外への書き込みだけ**
# ── 例: ~/.codex-agents/runs/**(自分の run_dir も他の run_dir も)、~/canonical/**、~/.claude/**、
# ~/.codex/**、~/bin/**。
#
# Write/Edit/NotebookEdit は `--permission-mode acceptEdits` が「cwd 内は自動承認、cwd 外は拒否」を
# 素の挙動として持つ(実測、庵野 2026-09-22。--disallowedTools の path 付き rule は
# --dangerously-skip-permissions 下で完全に無視されるため使わない。acceptEdits は skip-permissions では
# ないので disallowedTools 自体は効くはずだが、そもそも acceptEdits の cwd スコープだけで十分だった)。
#
# **Bash は acceptEdits でもスコープが掛からない**(実測: cwd 外へのリダイレクト書き込み・rm が
# 無条件で成功した)。この hook はその Bash 経路を塞ぐ ── 書き込み系コマンドで、対象パスが
# 上記の禁止プレフィックスに該当するときだけ block する。
#
# **root 配下を常に許可する例外(carve-out)は env CLAUDE_KASHIWAGI_GATE=2 のときだけ有効**
# (役員 人見 2026-09-22 の指摘)。ゲート1(`-f plan.md`)は `-C` が贄川の run_dir 自身(=
# `~/.codex-agents/runs/**` の中)なので、carve-out を効かせると「作業木の外は禁止」のはずが
# 「run_dir(plan.md・他ゲートの所見)への書き込み許可」になってしまう ── PoC の事故
# (閉じた run の gate2.md 上書き)と同じ穴。ゲート1・ゲート番号不明の呼び出しは carve-out 無し
# (root 自身が禁止プレフィックス配下なら、root 配下への書き込みも block される)。ゲート2
# (`-f findings.md`、`-C` は作業木)だけ root 配下を許可する。
#
# block の返し方は gate-guard-claude.sh と同じ実測(Claude Code は exit 2 + stderr でだけ block)。

set -u

stdin_json="$(cat 2>/dev/null || true)"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool_name" = "Bash" ] || exit 0

command_str="$(printf '%s' "$stdin_json" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_str" ] || exit 0

root="${CLAUDE_KASHIWAGI_ROOT:-}"
[ -n "$root" ] || exit 0
gate="${CLAUDE_KASHIWAGI_GATE:-}"

block() {
  echo "作業木の外への書き込みを検出(claude-kashiwagi): $1" >&2
  exit 2
}

# 書き込み系コマンドかどうかの判定(P2 の自己 commit は許すので git commit/add 単体は書き込み扱いに含めない
# ── 対象パス次第で下の python チェックに掛かる。push/reset --hard/checkout -- は不可逆側なので含める)。
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
if printf '%s' "$command_str" | grep -Eq '\b(sed[[:space:]]+-i|truncate[[:space:]]|dd[[:space:]]+of=|chmod[[:space:]]+\+w|git[[:space:]]+(commit|add|push|reset[[:space:]]+--hard|checkout[[:space:]]+--))'; then
  is_write=1
fi

[ "$is_write" -eq 1 ] || exit 0

violation="$(python3 - "$root" "$command_str" "$gate" <<'PY'
import os
import re
import sys

root = os.path.realpath(os.path.expanduser(sys.argv[1]))
cmd = sys.argv[2]
gate = sys.argv[3]
root_carve_out = (gate == "2")

forbidden_prefixes = [
    os.path.realpath(os.path.expanduser("~/.codex-agents")),
    os.path.realpath(os.path.expanduser("~/canonical")),
    os.path.realpath(os.path.expanduser("~/.claude")),
    os.path.realpath(os.path.expanduser("~/.codex")),
    os.path.realpath(os.path.expanduser("~/bin")),
]

# 絶対パス・~ 始まりのトークンを抽出(空白・引用符・パイプ・リダイレクト記号で区切る簡易抽出)。
tokens = re.findall(r'(?:~|/)[^\s\'"|;&<>]+', cmd)
for tok in tokens:
    tok = tok.rstrip(").,;")
    path = os.path.expanduser(tok)
    if not os.path.isabs(path):
        continue
    norm = os.path.normpath(path)
    if root_carve_out and (norm == root or norm.startswith(root + os.sep)):
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
