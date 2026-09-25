#!/usr/bin/env bash
# Claude Code の Stop hook。close-session を使ったのに #session へ流していなければ
# 終わるのを拒否する(役員 人見 2026-09-26、形は鷹野が決定、実装は庵野)。
#
# 判定は stdin の transcript_path(JSONL)だけを読む。他の道具の判定ロジックを
# ここに重複させない(session-post 自体の二重防止=posted.tsv とは別物)。
#
#   (a) close-session を使ったイベント
#       - Skill の tool_use で skill が close-session
#         (名前空間の接頭辞を許す。例 anthropic-skills:close-session)
#       - user が打った `/close-session`(`<command-name>/close-session</command-name>`
#         の形で transcript に残る)
#   (b) session-post を実行した Bash の tool_use。`--dry-run` を含むものは数えない
#       (投稿を試みたかどうかを見るだけで、成功したかは問わない)
#
# transcript は書かれた順の JSONL なので、行の出現順=時系列として最後の (a) の
# インデックスと最後の (b) のインデックスを比べる。(a) が (b) より後ろにあれば block。
# (a) が一度も無ければ(このターンで締めていない)そのまま通す。
#
# stop_hook_active の特別扱いはしない。一度 session-post を打てば (b) が
# transcript に残るので、次の Stop では通る ── 無限ループにはならない。
#
# block は exit 2 + stderr で返す。Claude Code の Stop は JSON の {"decision":"block",...}
# を無視し、exit 2 でだけ block した(庵野 2026-09-21 実測、claude-code 2.1.246、
# scripts/hooks/verdict-stop-claude.sh のコメント)。

set -u

stdin_json="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$stdin_json" <<'PY'
import json
import sys

stdin_json = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    hook_input = json.loads(stdin_json)
except Exception:
    sys.exit(0)

transcript_path = hook_input.get("transcript_path") or ""
if not transcript_path:
    sys.exit(0)

try:
    with open(transcript_path, encoding="utf-8") as f:
        lines = f.readlines()
except OSError:
    sys.exit(0)

CLOSE_TAG = "<command-name>/close-session</command-name>"

last_close_idx = None
last_post_idx = None

for idx, raw_line in enumerate(lines):
    raw_line = raw_line.strip()
    if not raw_line:
        continue
    try:
        row = json.loads(raw_line)
    except json.JSONDecodeError:
        continue

    row_type = row.get("type")
    message = row.get("message") or {}
    content = message.get("content")

    if row_type == "user":
        texts = []
        if isinstance(content, str):
            texts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and isinstance(block.get("text"), str):
                    texts.append(block["text"])
        if any(CLOSE_TAG in t for t in texts):
            last_close_idx = idx

    elif row_type == "assistant" and isinstance(content, list):
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name = block.get("name")
            tool_input = block.get("input") or {}
            if name == "Skill":
                skill = str(tool_input.get("skill") or "")
                if skill.split(":")[-1] == "close-session":
                    last_close_idx = idx
            elif name == "Bash":
                command = str(tool_input.get("command") or "")
                if "session-post" in command and "--dry-run" not in command:
                    last_post_idx = idx

if last_close_idx is None:
    # このターンで close-session を使っていない ── 締めていないので通す
    sys.exit(0)

if last_post_idx is not None and last_post_idx > last_close_idx:
    # 最後の締めより後に session-post を試している(失敗していてもここでは問わない)
    sys.exit(0)

reason = (
    "close-session を使ったが、session-post をまだ実行していない。"
    "流すサマリは今のリポの `_sessions/` でこのターンに書いた/直した "
    "YYYY-MM-DD_NN.md(たいてい一番新しい1本)。"
    "打つ: discord/session-post <そのサマリの path>"
    "(company/tech の外なら $HOME/canonical/tech/discord/session-post <path>)"
)
print(reason, file=sys.stderr)
sys.exit(2)
PY
