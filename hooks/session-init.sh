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
    "linear_team": "Prolegomena",
    "linear_token_env": "LINEAR_TOKEN",
    "linear_token_file": ".claude/.linear-token",
    "linear_issue_states": ["backlog", "unstarted", "started"],
    "linear_limit": 30,
    "sessions_dir": "docs/_sessions",
    "daily_summary_filename": "daily_summary.md",
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
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        errors.append(f"{path_name} must be a number")
        return default
    return int(value)

def string_list_at(container, key, path_name, default):
    value = container.get(key, default)
    if value is None:
        return default
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        errors.append(f"{path_name} must be a string array")
        return default
    return value

project = obj("project")
linear = obj("linear")
token_source = linear.get("tokenSource", {})
if token_source is None:
    token_source = {}
if not isinstance(token_source, dict):
    errors.append("linear.tokenSource must be an object")
    token_source = {}
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

if errors:
    fail("; ".join(errors))

cfg = {
    "config_status": "ok",
    "config_message": "",
    "project_name": string_at(project, "name", "project.name", SESSION_DEFAULTS["project_name"]),
    "linear_team": string_at(linear, "teamName", "linear.teamName", ""),
    "linear_token_env": string_at(token_source, "envVar", "linear.tokenSource.envVar", "LINEAR_TOKEN"),
    "linear_token_file": string_at(token_source, "fileFallback", "linear.tokenSource.fileFallback", ".claude/.linear-token"),
    "linear_issue_states": string_list_at(linear, "issueStates", "linear.issueStates", ["backlog", "unstarted", "started"]),
    "linear_limit": number_at(linear, "limit", "linear.limit", 30),
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
import subprocess
import sys
import urllib.error
import urllib.request

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

sessions_dir = cfg["sessions_dir"]
daily_name = cfg["daily_summary_filename"]
latest_session_dir = "(none)"
daily_summary_status = "(none)"
session_abs = os.path.join(repo_root, sessions_dir)
if os.path.isdir(session_abs):
    children = [
        os.path.join(sessions_dir, name).replace("\\", "/")
        for name in os.listdir(session_abs)
        if os.path.isdir(os.path.join(session_abs, name))
    ]
    if children:
        latest_session_dir = sorted(children, reverse=True)[0]
        ds_path = f"{latest_session_dir}/{daily_name}"
        if os.path.isfile(os.path.join(repo_root, ds_path)):
            daily_summary_status = ds_path
        else:
            daily_summary_status = f"{latest_session_dir} ({daily_name} not yet)"

mirror_md = ""
if is_cloud:
    mirror_md = "### mirror state\n(cloud mode: skipped)\n"
elif not cfg["mirror_enabled"]:
    mirror_md = "### mirror state\n(mirror disabled)\n"
else:
    state_file = cfg["mirror_state_file"]
    state_abs = os.path.join(repo_root, state_file)
    if os.path.isfile(state_abs):
        try:
            with open(state_abs, encoding="utf-8", errors="replace") as f:
                state = "".join(f.readlines()[:5]).rstrip() or "(empty)"
        except Exception as exc:
            state = f"({state_file} unreadable: {exc})"
    else:
        state = f"({state_file} not found)"
    mirror_md = f"### mirror state ({state_file})\n```\n{state}\n```\n"

if is_cloud:
    env_mode_md = "\n".join([
        "### environment",
        "- mode: **cloud** (CLAUDE_CODE_REMOTE=true)",
        "- implementation layer: Claude subagent/workflow",
        "- Drive mirror skipped",
    ])
else:
    env_mode_md = "### environment\n- mode: local"

config_section = ""
if cfg["config_status"] == "missing":
    config_section = "\n### .harness.json missing\n- warning: .harness.json not found; using compatibility defaults\n"
elif cfg["config_status"] == "error":
    config_section = f"\n### .harness.json error\n- warning: {cfg['config_message']}\n- fallback: using compatibility defaults\n"

canonical_lines = []
for link in cfg["canonical_links"]:
    canonical_lines.append(f"- [{link['label']}]({link['path']})")
close_reminder = cfg["close_session_reminder"]
if close_reminder:
    canonical_lines.append(f"- {close_reminder}")
canonical_md = "\n".join(canonical_lines) if canonical_lines else "- (no canonical links configured)"

ctx = f"""## SessionStart context (auto-injected by hooks/session-init.sh)
{config_section}
{env_mode_md}

### git
- branch: `{git_branch}`
- recent commits:
```
{git_log}
```
- working tree:
```
{git_status}
```

### session
- sessions dir: `{sessions_dir}`
- daily_summary filename: `{daily_name}`
- latest session dir: `{latest_session_dir}`
- daily_summary: `{daily_summary_status}`

{mirror_md}
### startup reminders
{canonical_md}
"""

PRIORITY = {0: "None", 1: "Urgent", 2: "High", 3: "Medium", 4: "Low"}

def sanitize(value):
    if value is None:
        return ""
    return str(value).encode("utf-8", errors="replace").decode("utf-8", errors="replace")

def fetch_linear():
    team = cfg["linear_team"]
    if not team:
        return ""
    env_var = cfg["linear_token_env"] or "LINEAR_TOKEN"
    token_file = cfg["linear_token_file"] or ".claude/.linear-token"
    token = os.environ.get(env_var, "").strip()
    token_source = f"env({env_var})"
    if not token:
        token_path = os.path.join(repo_root, token_file)
        if os.path.isfile(token_path):
            with open(token_path, encoding="utf-8", errors="replace") as f:
                token = "".join(f.read().split())
            token_source = f"file({token_file})"
    if not token:
        err = f"token not set (env {env_var} or {token_file})"
        return f"\n### Linear open issues (team={team})\n- fetch failed: {err}\n- fallback: use Linear MCP manually\n"

    states = cfg["linear_issue_states"] or ["backlog", "unstarted", "started"]
    limit = cfg["linear_limit"] or 30
    query = """
query($teamName: String!, $states: [String!], $limit: Int!) {
  issues(
    filter: {
      team: { name: { eq: $teamName } }
      state: { type: { in: $states } }
    }
    first: $limit
    orderBy: updatedAt
  ) {
    nodes {
      identifier
      title
      priority
      state { name type }
      assignee { name }
    }
  }
}
"""
    payload = json.dumps({"query": query, "variables": {"teamName": team, "states": states, "limit": limit}}).encode("utf-8")
    req = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=payload,
        method="POST",
        headers={"Authorization": token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        err = f"HTTP {exc.code}: {exc.reason}"
        return f"\n### Linear open issues (team={team})\n- fetch failed: {err}\n- token source: {token_source}\n"
    except urllib.error.URLError as exc:
        err = f"network: {exc.reason}"
        return f"\n### Linear open issues (team={team})\n- fetch failed: {err}\n- token source: {token_source}\n"
    except Exception as exc:
        err = f"{type(exc).__name__}: {exc}"
        return f"\n### Linear open issues (team={team})\n- fetch failed: {err}\n- token source: {token_source}\n"
    if "errors" in data:
        err = json.dumps(data["errors"], ensure_ascii=False)
        return f"\n### Linear open issues (team={team})\n- fetch failed: graphql: {err}\n- token source: {token_source}\n"
    nodes = data.get("data", {}).get("issues", {}).get("nodes", [])
    lines = [f"", f"### Linear open issues (team={team})"]
    if not nodes:
        lines.append("- (open issue none)")
    for item in nodes:
        ident = sanitize(item.get("identifier") or "?")
        title = sanitize((item.get("title") or "").strip())
        state = sanitize((item.get("state") or {}).get("name") or "?")
        priority = PRIORITY.get(item.get("priority", 0), "?")
        assignee = sanitize((item.get("assignee") or {}).get("name") or "(unassigned)")
        lines.append(f"- **{ident}** [{state}] (P:{priority}, @{assignee}) - {title}")
    return "\n".join(lines) + "\n"

ctx += fetch_linear()
out = {
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}
sys.stdout.buffer.write((json.dumps(out, ensure_ascii=False) + "\n").encode("utf-8"))
PY

exit 0
