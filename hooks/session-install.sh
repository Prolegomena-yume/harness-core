#!/usr/bin/env bash
# Cloud SessionStart install hook.
# Local sessions are no-op. Cloud sessions run npm ci idempotently and build
# workspaces listed in .harness.json install.buildTargets.

set -eu

if [ "${CLAUDE_CODE_REMOTE:-false}" != "true" ]; then
  exit 0
fi

REPO_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$REPO_ROOT" ] || [ ! -f "$REPO_ROOT/package.json" ]; then
  echo "[session-install] CLAUDE_PROJECT_DIR not set or package.json missing, skip" >&2
  exit 0
fi

cd "$REPO_ROOT"

find_python() {
  if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    printf '%s\n' python3
  elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
    printf '%s\n' python
  fi
}

PY="$(find_python)"

build_targets_b64=""
if [ -z "$PY" ]; then
  echo "[session-install] no usable python; build phase skipped" >&2
else
  build_targets_b64="$("$PY" - "$REPO_ROOT/.harness.json" <<'PY'
import base64
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
except FileNotFoundError:
    print("WARN:.harness.json missing; build phase skipped", file=sys.stderr)
    print("")
    sys.exit(0)
except Exception as exc:
    print(f"WARN:.harness.json parse error: {type(exc).__name__}: {exc}; build phase skipped", file=sys.stderr)
    print("")
    sys.exit(0)

try:
    targets = raw.get("install", {}).get("buildTargets", [])
except AttributeError:
    print("WARN:.harness.json root/install must be objects; build phase skipped", file=sys.stderr)
    print("")
    sys.exit(0)

if targets is None:
    targets = []
if not isinstance(targets, list) or not all(isinstance(item, str) for item in targets):
    print("WARN:install.buildTargets must be a string array; build phase skipped", file=sys.stderr)
    print("")
    sys.exit(0)

print(base64.b64encode(json.dumps(targets).encode()).decode())
PY
)"
fi

HASH_FILE=".claude/.npm-install-hash"
LOCK_HASH="$(sha256sum package-lock.json 2>/dev/null | awk '{print $1}')"
LAST_HASH="$(cat "$HASH_FILE" 2>/dev/null || echo '')"

if [ -d node_modules ] && [ -n "$LOCK_HASH" ] && [ "$LOCK_HASH" = "$LAST_HASH" ]; then
  echo "[session-install] node_modules + lock hash unchanged, skip npm ci" >&2
else
  echo "[session-install] npm ci start (lock hash changed or first run)" >&2
  npm ci --loglevel=warn
  mkdir -p "$(dirname "$HASH_FILE")"
  echo "$LOCK_HASH" > "$HASH_FILE"
  echo "[session-install] npm ci complete, hash saved" >&2
fi

if [ -z "$build_targets_b64" ]; then
  echo "[session-install] no install.buildTargets configured; build phase skipped" >&2
  exit 0
fi

mapfile -t build_targets < <("$PY" - "$build_targets_b64" <<'PY'
import base64
import json
import sys

for item in json.loads(base64.b64decode(sys.argv[1]).decode()):
    print(item)
PY
)

if [ "${#build_targets[@]}" -eq 0 ]; then
  echo "[session-install] install.buildTargets empty; build phase skipped" >&2
  exit 0
fi

echo "[session-install] building workspaces: ${build_targets[*]}" >&2
build_args=(run build)
for target in "${build_targets[@]}"; do
  build_args+=(-w "$target")
done
npm "${build_args[@]}" 2>&1 | tail -3 >&2
echo "[session-install] workspace build done" >&2

exit 0
