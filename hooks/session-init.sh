#!/usr/bin/env bash
# Claude Code SessionStart hook.
# Reads .harness.json from the consumer repository root and emits a single
# SessionStart hookSpecificOutput JSON object on stdout. Config errors are
# reported in additionalContext and never make the hook fail.

set -uo pipefail

IS_CLOUD="${CLAUDE_CODE_REMOTE:-false}"
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

cd "$REPO_ROOT" 2>/dev/null || {
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"session-init.sh: failed to cd to %s"}}\n' "$REPO_ROOT"
  exit 0
}

find_python() {
  if [ "$IS_CLOUD" = "true" ]; then
    command -v python3 || command -v python || true
    return
  fi
  if command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
    printf '%s\n' python
  elif command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    printf '%s\n' python3
  fi
}

PY="$(find_python)"
if [ -z "$PY" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"session-init.sh: no usable python on PATH; skipped enrichment"}}\n'
  exit 0
fi
export PYTHONIOENCODING=UTF-8

config_b64="$("$PY" - "$REPO_ROOT/.harness.json" <<'PY'
import base64
import json
import sys

path = sys.argv[1]

SESSION_DEFAULTS = {
    "project_name": "prolegomena",
    "neon_url_file": "",
    "neon_limit": 5,
    "sessions_dir": "docs/_sessions",
    "daily_summary_filename": "daily_summary.md",  # deprecated 2026-09-24: session-v1 は _sessions/YYYY-MM-DD_NN.md の1本、daily_summary は廃止済み(keiei/_sessions/README.md)。値は互換のため受理するだけで未使用
    "mirror_enabled": True,
    "mirror_state_file": "MIRROR_STATE.txt",
    "canonical_links": [
        {"label": "CLAUDE.md", "path": "CLAUDE.md"},
        {"label": "AGENTS.md", "path": "AGENTS.md"},
        {
            "label": "docs/operations/harness_redesign_step1_2026-06-26.md",
            "path": "docs/operations/harness_redesign_step1_2026-06-26.md",
        },
    ],
    "close_session_reminder": "close-session 時:[CLAUDE.md](CLAUDE.md) §「セッションサマリ git canonical 化」+ `scripts/mirror.ps1`",
}

def fail(message):
    cfg = dict(SESSION_DEFAULTS)
    cfg["config_status"] = "error" if message != "missing" else "missing"
    cfg["config_message"] = message
    print(base64.b64encode(json.dumps(cfg, ensure_ascii=False).encode()).decode())
    sys.exit(0)

try:
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
except FileNotFoundError:
    fail("missing")
except Exception as exc:
    fail(f"{type(exc).__name__}: {exc}")

errors = []
if not isinstance(raw, dict):
    errors.append("root must be an object")

def obj(name):
    value = raw.get(name, {}) if isinstance(raw, dict) else {}
    if value is None:
        return {}
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return {}
    return value

def string_at(container, key, path_name, default=None):
    value = container.get(key, default)
    if value is None:
        return default
    if not isinstance(value, str):
        errors.append(f"{path_name} must be a string")
        return default
    return value

def bool_at(container, key, path_name, default=False):
    value = container.get(key, default)
    if value is None:
        return default
    if not isinstance(value, bool):
        errors.append(f"{path_name} must be a boolean")
        return default
    return value

def number_at(container, key, path_name, default):
    value = container.get(key, default)
    if value is None:
        return default
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        errors.append(f"{path_name} must be a positive integer")
        return default
    return value

project = obj("project")
neon = obj("neon")
sessions = obj("sessions")
mirror = obj("mirror")
canonical = obj("canonical")

links = canonical.get("links", [])
if links is None:
    links = []
if not isinstance(links, list):
    errors.append("canonical.links must be an array")
    links = []
else:
    normalized = []
    for idx, item in enumerate(links):
        if not isinstance(item, dict):
            errors.append(f"canonical.links[{idx}] must be an object")
            continue
        label = item.get("label")
        path_value = item.get("path")
        if not isinstance(label, str) or not isinstance(path_value, str):
            errors.append(f"canonical.links[{idx}] requires string label and path")
            continue
        normalized.append({"label": label, "path": path_value})
    links = normalized

if "project" in raw and "name" not in project:
    errors.append("project.name is required when project is set")

neon_url_file = string_at(neon, "urlFile", "neon.urlFile", "")
neon_limit = number_at(neon, "limit", "neon.limit", 5)
if errors:
    fail("; ".join(errors))

cfg = {
    "config_status": "ok",
    "config_message": "",
    "project_name": string_at(project, "name", "project.name", SESSION_DEFAULTS["project_name"]),
    "neon_url_file": neon_url_file,
    "neon_limit": neon_limit,
    "sessions_dir": string_at(sessions, "dir", "sessions.dir", "docs/_sessions"),
    "daily_summary_filename": string_at(sessions, "dailySummaryFilename", "sessions.dailySummaryFilename", "daily_summary.md"),
    "mirror_enabled": bool_at(mirror, "enabled", "mirror.enabled", False),
    "mirror_state_file": string_at(mirror, "stateFile", "mirror.stateFile", "MIRROR_STATE.txt"),
    "canonical_links": links,
    "close_session_reminder": string_at(canonical, "closeSessionReminder", "canonical.closeSessionReminder", ""),
}
print(base64.b64encode(json.dumps(cfg, ensure_ascii=False).encode()).decode())
PY
)"

GIT_OPTS=(-c i18n.logOutputEncoding=UTF-8 -c i18n.commitEncoding=UTF-8 -c core.quotePath=false)

git_branch=$(git "${GIT_OPTS[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(unknown)")
git_log=$(git "${GIT_OPTS[@]}" log -5 --oneline --no-decorate 2>/dev/null || echo "(git log unavailable)")
git_status=$(git "${GIT_OPTS[@]}" status --short 2>/dev/null || echo "(git status unavailable)")
if [ -z "$git_status" ]; then
  git_status="(clean working tree)"
fi

"$PY" - "$config_b64" "$IS_CLOUD" "$REPO_ROOT" "$git_branch" <<'PY'
import base64
import json
import os
import shutil
import subprocess
import sys

cfg = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
is_cloud = sys.argv[2] == "true"
repo_root = sys.argv[3]
git_branch = sys.argv[4]

def run_git(args, fallback):
    try:
        return subprocess.check_output(
            ["git", "-c", "i18n.logOutputEncoding=UTF-8", "-c", "i18n.commitEncoding=UTF-8", "-c", "core.quotePath=false"] + args,
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
        ).decode("utf-8", errors="replace").rstrip() or fallback
    except Exception:
        return fallback

git_log = run_git(["log", "-5", "--oneline", "--no-decorate"], "(git log unavailable)")
git_status = run_git(["status", "--short"], "(clean working tree)")

import re

# session-v1 (keiei/_sessions/README.md 正典): サマリは `_sessions/YYYY-MM-DD_NN.md` の
# 1本。日付ディレクトリは作らない。旧形式(日付ディレクトリ + daily_summary.md)は
# 2026-08-09 の session-v1 移行以前の消えた consumer だけが残しており、いま追随している
# 全 consumer(tech / keiei / hanabi)は flat file なので後方互換は持たない。
SESSION_FILE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d+\.md$")
sessions_dir = cfg["sessions_dir"]
latest_session_line = ""
session_abs = os.path.join(repo_root, sessions_dir)
if os.path.isdir(session_abs):
    candidates = sorted(
        (name for name in os.listdir(session_abs) if SESSION_FILE_RE.match(name)),
        reverse=True,
    )
    if candidates:
        rel_path = os.path.join(sessions_dir, candidates[0]).replace("\\", "/")
        try:
            with open(os.path.join(session_abs, candidates[0]), encoding="utf-8", errors="replace") as f:
                title = f.readline().strip().lstrip("#").strip() or candidates[0]
        except Exception:
            title = candidates[0]
        latest_session_line = f"- latest session summary: `{rel_path}` ── {title}\n"

if is_cloud:
    mirror_line = "- mirror: skipped (cloud mode)\n"
elif not cfg["mirror_enabled"]:
    mirror_line = "- mirror: disabled\n"
else:
    state_file = cfg["mirror_state_file"]
    state_abs = os.path.join(repo_root, state_file)
    if os.path.isfile(state_abs):
        try:
            with open(state_abs, encoding="utf-8", errors="replace") as f:
                state = f.readline().strip() or "(empty)"
        except Exception as exc:
            state = f"unreadable: {exc}"
    else:
        state = f"{state_file} not found"
    mirror_line = f"- mirror ({state_file}): {state}\n"

if is_cloud:
    mode_desc = "**cloud** (CLAUDE_CODE_REMOTE=true, impl layer: subagent, Drive mirror skipped)"
else:
    mode_desc = "local"

config_section = ""
if cfg["config_status"] == "missing":
    config_section = "\n### .harness.json missing\n- warning: .harness.json not found; using compatibility defaults\n"
elif cfg["config_status"] == "error":
    config_section = f"\n### .harness.json error\n- warning: {cfg['config_message']}\n- fallback: using compatibility defaults\n"

link_parts = [
    link["label"] if link["label"] == link["path"] else f"{link['label']}({link['path']})"
    for link in cfg["canonical_links"]
]
canonical_md = ", ".join(link_parts) if link_parts else "(no canonical links configured)"
close_reminder = cfg["close_session_reminder"]
if close_reminder:
    canonical_md += f" / {close_reminder}"

ctx = f"""## SessionStart context (auto-injected by hooks/session-init.sh)
{config_section}
### status
- mode: {mode_desc}; branch: `{git_branch}`; working tree: {"clean" if git_status == "(clean working tree)" else git_status.replace(chr(10), "; ")}
- recent commits:
```
{git_log}
```
{latest_session_line}{mirror_line}
### startup reminders
- {canonical_md}
"""

def fetch_neon():
    url_file = cfg["neon_url_file"]
    if not url_file:
        return ""
    heading = "\n### Neon recent documents (harness_index_db, JST)"
    url_path = os.path.expanduser(url_file)
    if not os.path.isfile(url_path):
        return f"{heading}\n- fetch failed: urlFile not found: {url_file}\n"
    if shutil.which("psql") is None:
        return f"{heading}\n- fetch failed: psql not found on PATH\n"
    try:
        with open(url_path, encoding="utf-8", errors="replace") as f:
            url = f.readline().strip()
    except Exception as exc:
        return f"{heading}\n- fetch failed: urlFile unreadable: {exc}\n"
    if not url:
        return f"{heading}\n- fetch failed: urlFile is empty: {url_file}\n"
    limit = cfg["neon_limit"] or 5
    query = (
        "SELECT path, coalesce(title,''), "
        "to_char(updated_at AT TIME ZONE 'Asia/Tokyo', 'MM-DD HH24:MI') "
        f"FROM documents ORDER BY updated_at DESC LIMIT {limit};"
    )
    try:
        result = subprocess.run(
            ["psql", url, "-X", "-tA", "-F", "\t", "-c", query],
            cwd=repo_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            check=True,
        )
    except subprocess.TimeoutExpired:
        return f"{heading}\n- fetch failed: timed out after 10 seconds\n"
    except subprocess.CalledProcessError as exc:
        reason = (exc.stderr or "").strip().splitlines()
        reason = reason[-1] if reason else f"psql exited with status {exc.returncode}"
        return f"{heading}\n- fetch failed: {reason}\n"
    except Exception as exc:
        return f"{heading}\n- fetch failed: {type(exc).__name__}: {exc}\n"
    lines = ["", "### Neon recent documents (harness_index_db, JST)"]
    for row in result.stdout.splitlines():
        fields = row.split("\t", 2)
        if len(fields) == 3:
            path_value, title, updated = fields
            lines.append(f"- {updated} {path_value} ── {title}")
    if len(lines) == 2:
        lines.append("- (documents none)")
    lines.append('- semantic 検索: bash scripts/search-docs.sh "<query>" [N]')
    return "\n".join(lines) + "\n"

ctx += fetch_neon()
out = {
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}
sys.stdout.buffer.write((json.dumps(out, ensure_ascii=False) + "\n").encode("utf-8"))
PY

exit 0
