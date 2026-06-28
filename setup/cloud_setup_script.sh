#!/usr/bin/env bash
# Generic harness cloud setup script.
# Reads .harness.json cloud.* settings when present. Config problems degrade
# to defaults and never fail the setup script by themselves.

set -euo pipefail

trap 'echo "ERROR: Setup failed at line $LINENO"; exit 1' ERR

echo "=== Harness Cloud Setup: START ==="
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

if [ "${CLAUDE_CODE_REMOTE:-false}" != "true" ]; then
  echo "Not a cloud session (CLAUDE_CODE_REMOTE != 'true'), exiting"
  exit 0
fi

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

find_python() {
  if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    printf '%s\n' python3
  elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
    printf '%s\n' python
  fi
}

PY="$(find_python)"
if [ -z "$PY" ]; then
  echo "[cloud-setup] WARNING: no usable python; using cloud defaults" >&2
  config_b64=""
else
  config_b64="$("$PY" - "$REPO_ROOT/.harness.json" <<'PY'
import base64
import json
import sys

path = sys.argv[1]
defaults = {
    "aptPackages": [],
    "nodeMinVersion": 20,
    "requiredEnvVars": [],
    "optionalEnvVars": [],
}

def emit(config):
    print(base64.b64encode(json.dumps(config).encode()).decode())

try:
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
except FileNotFoundError:
    print("[cloud-setup] WARNING: .harness.json missing; using cloud defaults", file=sys.stderr)
    emit(defaults)
    sys.exit(0)
except Exception as exc:
    print(f"[cloud-setup] WARNING: .harness.json parse error: {type(exc).__name__}: {exc}; using cloud defaults", file=sys.stderr)
    emit(defaults)
    sys.exit(0)

errors = []
cloud = raw.get("cloud", {}) if isinstance(raw, dict) else {}
if not isinstance(cloud, dict):
    errors.append("cloud must be an object")
    cloud = {}

def string_list(key):
    value = cloud.get(key, defaults[key])
    if value is None:
        return defaults[key]
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        errors.append(f"cloud.{key} must be a string array")
        return defaults[key]
    return value

node_min = cloud.get("nodeMinVersion", defaults["nodeMinVersion"])
if node_min is None:
    node_min = defaults["nodeMinVersion"]
if not isinstance(node_min, (int, float)) or isinstance(node_min, bool):
    errors.append("cloud.nodeMinVersion must be a number")
    node_min = defaults["nodeMinVersion"]

if errors:
    print("[cloud-setup] WARNING: " + "; ".join(errors) + "; using cloud defaults", file=sys.stderr)
    emit(defaults)
else:
    emit({
        "aptPackages": string_list("aptPackages"),
        "nodeMinVersion": int(node_min),
        "requiredEnvVars": string_list("requiredEnvVars"),
        "optionalEnvVars": string_list("optionalEnvVars"),
    })
PY
)"
fi

if [ -z "$config_b64" ]; then
  config_b64="eyJhcHRQYWNrYWdlcyI6IFtdLCAibm9kZU1pblZlcnNpb24iOiAyMCwgInJlcXVpcmVkRW52VmFycyI6IFtdLCAib3B0aW9uYWxFbnZWYXJzIjogW119"
fi

if [ -z "$PY" ]; then
  NODE_MIN_VERSION="20"
  APT_PACKAGES=()
  REQUIRED_ENV_VARS=()
  OPTIONAL_ENV_VARS=()
else
  mapfile -t config_lines < <("$PY" - "$config_b64" <<'PY'
import base64
import json
import sys

cfg = json.loads(base64.b64decode(sys.argv[1]).decode())
print(cfg["nodeMinVersion"])
for key in ("aptPackages", "requiredEnvVars", "optionalEnvVars"):
    values = cfg[key]
    print(len(values))
    for value in values:
        print(value)
PY
)

  idx=0
  NODE_MIN_VERSION="${config_lines[$idx]}"
  idx=$((idx + 1))

  apt_count="${config_lines[$idx]:-0}"
  idx=$((idx + 1))
  APT_PACKAGES=()
  for _ in $(seq 1 "$apt_count"); do
    APT_PACKAGES+=("${config_lines[$idx]}")
    idx=$((idx + 1))
  done

  required_count="${config_lines[$idx]:-0}"
  idx=$((idx + 1))
  REQUIRED_ENV_VARS=()
  for _ in $(seq 1 "$required_count"); do
    REQUIRED_ENV_VARS+=("${config_lines[$idx]}")
    idx=$((idx + 1))
  done

  optional_count="${config_lines[$idx]:-0}"
  idx=$((idx + 1))
  OPTIONAL_ENV_VARS=()
  for _ in $(seq 1 "$optional_count"); do
    OPTIONAL_ENV_VARS+=("${config_lines[$idx]}")
    idx=$((idx + 1))
  done
fi

echo ""
echo "--- [Phase 1] apt packages ---"
if [ "${#APT_PACKAGES[@]}" -eq 0 ] || [ -z "${APT_PACKAGES[0]:-}" ]; then
  echo "No apt packages configured; skipping Phase 1"
else
  apt-get update -qq
  apt-get install -y "${APT_PACKAGES[@]}"
  echo "OK: installed apt packages: ${APT_PACKAGES[*]}"
fi

echo ""
echo "--- [Phase 2] Node version ---"
NODE_RAW="$(node --version 2>/dev/null || echo '')"
NODE_MAJOR="$(echo "$NODE_RAW" | sed 's/^v//' | cut -d. -f1)"
echo "Current Node: ${NODE_RAW:-none}"

if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt "$NODE_MIN_VERSION" ]; then
  echo ""
  echo "ERROR: Node ${NODE_MIN_VERSION}+ required but found '${NODE_RAW:-none}'"
  echo "Manual upgrade required:"
  echo "  curl -fsSL https://deb.nodesource.com/setup_${NODE_MIN_VERSION}.x | bash -"
  echo "  apt-get install -y nodejs"
  exit 1
fi
echo "OK: Node ${NODE_RAW}, npm $(npm --version)"

check_required() {
  if [ -z "${!1:-}" ]; then
    echo "  [X] $1 NOT SET (REQUIRED)"
    return 1
  fi
  echo "  [v] $1 set"
  return 0
}

check_optional() {
  if [ -z "${!1:-}" ]; then
    echo "  [-] $1 unset (optional)"
  else
    echo "  [v] $1 set"
  fi
}

echo ""
echo "--- [Phase 3] Environment vars check ---"
if [ "${#REQUIRED_ENV_VARS[@]}" -eq 0 ] || [ -z "${REQUIRED_ENV_VARS[0]:-}" ]; then
  echo "No required env vars configured; skipping required check"
else
  echo "Required:"
  for name in "${REQUIRED_ENV_VARS[@]}"; do
    check_required "$name" || true
  done
fi

if [ "${#OPTIONAL_ENV_VARS[@]}" -eq 0 ] || [ -z "${OPTIONAL_ENV_VARS[0]:-}" ]; then
  echo "No optional env vars configured; skipping optional check"
else
  echo ""
  echo "Optional:"
  for name in "${OPTIONAL_ENV_VARS[@]}"; do
    check_optional "$name"
  done
fi

echo ""
echo "=== Setup complete: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""
echo "Next: launch Claude Code so SessionStart hooks can run:"
echo "  - hooks/session-init.sh     context injection"
echo "  - hooks/session-install.sh  npm ci and configured workspace builds"
echo ""

exit 0
