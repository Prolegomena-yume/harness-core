#!/usr/bin/env bash
# .claude/hooks/session-init.sh
#
# Claude Code SessionStart hook.
# Emits a JSON document on stdout matching the SessionStart hookSpecificOutput
# contract so the additionalContext is injected into the new session's context.
#
# Responsibilities:
#   1. git: current branch / recent commits / working-tree summary
#   2. session: latest docs/_sessions/<date>/ + daily_summary path
#   3. mirror: head of MIRROR_STATE.txt (Drive code mirror freshness)
#   4. Linear: open issues for team=Prolegomena (Personal API Key, GraphQL)
#   5. reminders: which canonical docs to consult
#
# Linear token contract (env-first, file fallback for backward compat):
#   1. $LINEAR_TOKEN env var (cloud: Claude Code on the web の env vars UI)
#   2. ${CLAUDE_PROJECT_DIR}/.claude/.linear-token  (local: plain text, gitignored)
#   Personal API Key from https://linear.app/settings/api (lin_api_*).
#   Missing / empty / unreachable -> graceful fallback (reminder only).
#
# Env contract:
#   CLAUDE_PROJECT_DIR is set by Claude Code when the hook fires. If absent
#   (manual invocation), fall back to $PWD.
#   CLAUDE_CODE_REMOTE=true → cloud session (Claude Code on the web,
#   Ubuntu 24.04 LTS container). Triggers cloud-mode branches:
#   skip MIRROR_STATE / simpler python lookup / env identification line.
#
# Output contract (https://docs.claude.com/en/docs/claude-code/hooks):
#   {
#     "hookSpecificOutput": {
#       "hookEventName": "SessionStart",
#       "additionalContext": "<markdown>"
#     }
#   }

set -uo pipefail

# Cloud session 検出(Claude Code on the web では CLAUDE_CODE_REMOTE=true)
IS_CLOUD="${CLAUDE_CODE_REMOTE:-false}"

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$REPO_ROOT" 2>/dev/null || {
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"session-init.sh: failed to cd to %s"}}\n' "$REPO_ROOT"
  exit 0
}

# Force UTF-8 on git output. On Windows git defaults to writing commit
# subjects in the system code page (CP932 / SJIS for ja-JP installs); piping
# that into our UTF-8 JSON breaks the additionalContext payload. The
# i18n.* config keys override the per-repo defaults without persisting.
GIT_OPTS=(-c i18n.logOutputEncoding=UTF-8 -c i18n.commitEncoding=UTF-8 -c core.quotePath=false)

git_branch=$(git "${GIT_OPTS[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(unknown)")
git_log=$(git "${GIT_OPTS[@]}" log -5 --oneline --no-decorate 2>/dev/null || echo "(git log unavailable)")
git_status=$(git "${GIT_OPTS[@]}" status --short 2>/dev/null || echo "(git status unavailable)")
if [ -z "$git_status" ]; then
  git_status="(clean working tree)"
fi

latest_session_dir=""
if [ -d docs/_sessions ]; then
  latest_session_dir=$(ls -1d docs/_sessions/*/ 2>/dev/null | sort -r | head -n 1 | sed 's:/$::' || true)
fi
daily_summary_status=""
if [ -n "${latest_session_dir:-}" ]; then
  ds_path="${latest_session_dir}/daily_summary.md"
  if [ -f "$ds_path" ]; then
    daily_summary_status="$ds_path"
  else
    daily_summary_status="$latest_session_dir (daily_summary.md not yet)"
  fi
else
  latest_session_dir="(none)"
  daily_summary_status="(none)"
fi

mirror_state="(MIRROR_STATE.txt not found)"
if [ "$IS_CLOUD" = "true" ]; then
  mirror_state="(cloud では skip ── Drive mirror は local PowerShell 専用)"
elif [ -f MIRROR_STATE.txt ]; then
  mirror_state=$(head -n 5 MIRROR_STATE.txt 2>/dev/null || echo "(MIRROR_STATE.txt unreadable)")
fi

# Environment identification line (cloud / local)
if [ "$IS_CLOUD" = "true" ]; then
  env_mode_md=$(cat <<'EOF'
### environment
- mode: **cloud**(Claude Code on the web、CLAUDE_CODE_REMOTE=true)
- 主実装層 cloud override = Claude 内サブエージェント(Codex 不可)
- Drive mirror skip / agmsg 退役(別 issue Phase 1+)
EOF
)
else
  env_mode_md="### environment
- mode: local(Windows / WSL / Linux)"
fi

# Compose the base markdown context (git / session / mirror / reminders).
# Linear section is appended by the python stage below.
context_md=$(cat <<EOF
## SessionStart context (auto-injected by .claude/hooks/session-init.sh)

${env_mode_md}

### git
- branch: \`${git_branch}\`
- recent commits:
\`\`\`
${git_log}
\`\`\`
- working tree:
\`\`\`
${git_status}
\`\`\`

### session
- latest session dir: \`${latest_session_dir}\`
- daily_summary: \`${daily_summary_status}\`

### mirror state (Drive code mirror, scripts/mirror.ps1)
\`\`\`
${mirror_state}
\`\`\`

### 起動チェックリマインダ
- 進行中 issue 詳細 → Linear MCP \`get_issue PRL-N\`(本 hook は team open issue 一覧を自動取得、詳細取得は手動)
- 主要 canonical:
  - [CLAUDE.md](CLAUDE.md)
  - [AGENTS.md](AGENTS.md)
  - [docs/operations/harness_redesign_step1_2026-06-26.md](docs/operations/harness_redesign_step1_2026-06-26.md)
- close-session 時:[CLAUDE.md](CLAUDE.md) §「セッションサマリ git canonical 化」+ \`scripts/mirror.ps1\`
EOF
)

# Encode as JSON for the SessionStart hookSpecificOutput contract.
#
# On Windows the WindowsApps shim `python3` is a Store stub that prints "Python"
# and exits 49 when invoked non-interactively, so we prefer `python` (real
# CPython on PATH) first and only fall back to `python3` when that points at a
# real interpreter -- confirmed by a `--version` probe. On cloud (Linux
# container) there's no WindowsApps stub, so a simple lookup suffices.
PY=""
if [ "$IS_CLOUD" = "true" ]; then
  PY="$(command -v python3 || command -v python || true)"
else
  if command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
    PY=python
  elif command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    PY=python3
  fi
fi
if [ -z "$PY" ]; then
  # Last-ditch fallback: emit a JSON envelope with a notice instead of failing.
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"session-init.sh: no usable python on PATH; skipped enrichment"}}\n'
  exit 0
fi

# Round-trip the markdown through base64 to keep it byte-exact across the
# bash -> MSYS -> Win32 python argv boundary (otherwise UTF-8 JP characters
# get mangled to CP932). And write the JSON to stdout via the binary buffer
# so python doesn't re-encode it through the console code page.
ctx_b64=$(printf '%s' "$context_md" | base64 -w 0)

# Linear token: env var 優先(cloud) → file fallback(local、後方互換)
LINEAR_TOKEN="${LINEAR_TOKEN:-}"
LINEAR_TOKEN_SOURCE="env(LINEAR_TOKEN)"
if [ -z "$LINEAR_TOKEN" ] && [ -f "${REPO_ROOT}/.claude/.linear-token" ]; then
  LINEAR_TOKEN="$(tr -d '[:space:]' < "${REPO_ROOT}/.claude/.linear-token")"
  LINEAR_TOKEN_SOURCE="file(.claude/.linear-token)"
fi
if [ -z "$LINEAR_TOKEN" ]; then
  LINEAR_TOKEN_SOURCE="(none)"
fi
# base64 round-trip the token too, to keep it byte-exact across the argv boundary
token_b64=$(printf '%s' "$LINEAR_TOKEN" | base64 -w 0)

"$PY" - "$ctx_b64" "$token_b64" "$LINEAR_TOKEN_SOURCE" <<'PY'
import base64, json, sys
import urllib.request, urllib.error

ctx = base64.b64decode(sys.argv[1]).decode("utf-8")
token = base64.b64decode(sys.argv[2]).decode("utf-8").strip()
token_source = sys.argv[3]

PRIORITY = {0: "None", 1: "Urgent", 2: "High", 3: "Medium", 4: "Low"}

def sanitize(s):
    # Linear can store strings containing lone UTF-16 surrogates (e.g. \udc8X
    # without a matching high surrogate). Python keeps them in str but
    # str.encode("utf-8") in strict mode raises UnicodeEncodeError, which
    # would crash the JSON envelope. Round-trip through utf-8 with replace
    # so any lone surrogate becomes U+FFFD instead of taking down the hook.
    if s is None:
        return ""
    return s.encode("utf-8", errors="replace").decode("utf-8", errors="replace")

def fetch_linear():
    if not token:
        return None, "token not set (env LINEAR_TOKEN or .claude/.linear-token)"

    query = (
        "query {\n"
        "  issues(\n"
        "    filter: {\n"
        '      team: { name: { eq: "Prolegomena" } }\n'
        '      state: { type: { in: ["backlog", "unstarted", "started"] } }\n'
        "    }\n"
        "    first: 30\n"
        "    orderBy: updatedAt\n"
        "  ) {\n"
        "    nodes {\n"
        "      identifier\n"
        "      title\n"
        "      priority\n"
        "      state { name type }\n"
        "      assignee { name }\n"
        "    }\n"
        "  }\n"
        "}"
    )
    payload = json.dumps({"query": query}).encode("utf-8")
    req = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=payload,
        method="POST",
        headers={
            "Authorization": token,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        return None, "HTTP %d: %s" % (e.code, e.reason)
    except urllib.error.URLError as e:
        return None, "network: %s" % e.reason
    except Exception as e:
        return None, "unexpected: %s: %s" % (type(e).__name__, e)

    if "errors" in data:
        return None, "graphql: %s" % json.dumps(data["errors"], ensure_ascii=False)
    nodes = data.get("data", {}).get("issues", {}).get("nodes", [])
    return nodes, None

def fmt_linear(nodes, err):
    lines = ["", "### Linear open issues (team=Prolegomena)"]
    if err:
        lines.append("- 取得失敗: %s" % err)
        lines.append("- fallback: MCP `list_issues` を手動で")
        return "\n".join(lines)
    if not nodes:
        lines.append("- (open issue なし)")
        return "\n".join(lines)
    for n in nodes:
        ident = sanitize(n.get("identifier") or "?")
        title = sanitize((n.get("title") or "").strip())
        state = sanitize((n.get("state") or {}).get("name") or "?")
        pri = PRIORITY.get(n.get("priority", 0), "?")
        assignee_obj = n.get("assignee") or {}
        assignee = sanitize(assignee_obj.get("name") or "(unassigned)")
        lines.append("- **%s** [%s] (P:%s, @%s) ─ %s" % (ident, state, pri, assignee, title))
    return "\n".join(lines)

nodes, err = fetch_linear()
linear_md = fmt_linear(nodes, err)
ctx_full = ctx + "\n" + linear_md + "\n"

out = json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx_full,
    }
}, ensure_ascii=False) + "\n"
sys.stdout.buffer.write(out.encode("utf-8"))
PY
