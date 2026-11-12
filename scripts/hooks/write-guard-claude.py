#!/usr/bin/env python3
"""契約モード(claude-makabe / claude-kashiwagi の --contract)専用の PreToolUse hook。

Write / Edit / NotebookEdit の書き先が作業ルート(-C の worktree)の外なら block する。
禁止プレフィックスの一覧ではなく「ルートの中だけ許可」── 契約の置き場(tech の _contract/)は MCP だけが
知っていて、モデルは path を持たない。だから worktree の外は一律に塞いでよい。

使い方: write-guard-claude.py <作業ルート>(launcher が settings.json の command に引数で埋める。
env に頼らない ── 無いと素通しになる型を避けるため)。

- 判定は realpath(symlink と .. を解く)。書き先がまだ無いファイルは、在る所までの親を解いて残りを足す
- 相対パスは hook 入力の cwd(無ければ作業ルート)から解く
- **読めない入力・path の無い入力・ルート引数の欠けは block する**(fail-closed。jq にも頼らない)
- 対象外の tool(Read・Bash など)は素通し。Bash の書き込みは worktree-guard-claude*.sh の持ち場
- block は exit 2 + stderr(Claude Code は --dangerously-skip-permissions の下でもこれで止まる。実測は test-contract-mcp.sh)
"""
import json
import os
import sys

WRITE_TOOLS = {"Write": "file_path", "Edit": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path"}


def block(msg: str) -> None:
    sys.stderr.write(f"作業木の外への書き込みを断った(契約モード): {msg}\n"
                     "brief・result・gate は契約の MCP の道具(brief_get・result_put・gate_put など)で読み書きする。"
                     "path は持たなくてよい\n")
    sys.exit(2)


def resolve(path: str, base: str) -> str:
    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        p = os.path.join(base, p)
    return os.path.realpath(p)  # 無いファイルは、在る所までの親を解いて残りを足してくれる


def main() -> None:
    if len(sys.argv) < 2 or not sys.argv[1]:
        block("作業ルートが hook に渡っていない")
    root = os.path.realpath(os.path.expanduser(sys.argv[1]))
    try:
        data = json.load(sys.stdin)
    except Exception:
        block("hook の入力を読めない")
    if not isinstance(data, dict):
        block("hook の入力の形が違う")
    tool = data.get("tool_name") or ""
    if tool not in WRITE_TOOLS:
        sys.exit(0)
    ti = data.get("tool_input")
    raw = ti.get(WRITE_TOOLS[tool]) if isinstance(ti, dict) else None
    if not isinstance(raw, str) or not raw:
        block(f"{tool} の書き先が読めない")
    cwd = data.get("cwd")
    base = cwd if isinstance(cwd, str) and os.path.isabs(cwd) else root
    target = resolve(raw, base)
    if target == root or target.startswith(root + os.sep):
        sys.exit(0)
    block(f"{target}(tool: {tool}、作業ルート: {root})")


if __name__ == "__main__":
    main()
