#!/usr/bin/env bash
# cloud の SessionStart で、session-init.sh の JSON に tech / keiei の MEMORY.md を additionalContext として足す。
# 母艦では使わない(tech の settings.json は cloud のときだけこれを呼び、母艦は今までどおり session-init.sh 直)。
#
# なぜ別の hook でなく session-init.sh のラッパか ── 同じ matcher の hook は並列に走るので、
# 「cloud-bootstrap.sh(keiei の clone)の後」を保てるのは 1 本の command の中だけ。session-init.sh 自体には
# cloud の事情を入れない(他の consumer と母艦を汚さない)。
# なぜ additionalContext か ── cloud では auto memory も CLAUDE.md の @import も SessionStart hook より先に解決され、
# symlink が張られる前なので載らない(役員 人見の実測 2026-09-30)。hook の出力は読み込み順に依存しない。
#
# 出力は JSON 1 個。どこが落ちても session-init.sh の出力はそのまま通す。
# test 用の上書き: CTX_TECH_MEM CTX_KEIEI_MEM CTX_MAX_BYTES

core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
proj="${CLAUDE_PROJECT_DIR:-$(cd -P "$core/../.." && pwd)}"
export CTX_TECH_MEM="${CTX_TECH_MEM:-$proj/.claude/memory}"
export CTX_KEIEI_MEM="${CTX_KEIEI_MEM:-$HOME/canonical/keiei/.claude/memory}"
base="$(bash "$core/hooks/session-init.sh" 2>/dev/null)"
command -v python3 >/dev/null 2>&1 || { printf '%s\n' "$base"; exit 0; }
BASE_JSON="$base" python3 - <<'PY'
import json, os
base = os.environ.get("BASE_JSON", "")
try:
    out = json.loads(base) if base.strip() else {}
except Exception:
    print(base); raise SystemExit(0)
limit = int(os.environ.get("CTX_MAX_BYTES", "25000"))

def read(path):
    try:
        with open(path, encoding="utf-8") as f: return f.read()
    except OSError:
        return None

def clip(text):
    b = text.encode("utf-8")
    if len(b) <= limit: return text
    return b[:limit].decode("utf-8", "ignore") + "\n…(%d バイトで切った。続きは MEMORY.md を直接読む)" % limit

parts = []
t = read(os.path.join(os.environ["CTX_TECH_MEM"], "MEMORY.md"))
k = read(os.path.join(os.environ["CTX_KEIEI_MEM"], "MEMORY.md"))
if t is not None:
    parts.append("### tech の memory(~/canonical/tech/.claude/memory/)\n"
                 "cloud では auto memory が自動で載らないので、その索引を hook が入れた。各項目の本文は上の dir の <file>.md。"
                 "**書くのもこの dir(tech 側の symlink 経由)。書けば Stop hook が Forgejo の main に memory だけ送る。**\n\n" + clip(t))
if k is not None:
    parts.append("### keiei の memory 索引(~/canonical/keiei/.claude/memory/、読むだけ)\n"
                 "tech の CLAUDE.md の @import が cloud では展開されないので、その索引を hook が入れた。本文は上の dir の <file>.md。\n\n" + clip(k))
if not parts:
    print(base); raise SystemExit(0)
hso = out.setdefault("hookSpecificOutput", {"hookEventName": "SessionStart"})
prev = hso.get("additionalContext", "")
hso["additionalContext"] = (prev + "\n\n" if prev else "") + "## memory(cloud、hooks/cloud-session-start.sh が注入)\n\n" + "\n\n".join(parts)
print(json.dumps(out, ensure_ascii=False))
PY
exit 0
