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

config_b64=""
if [ -z "$PY" ]; then
  echo "[session-install] no usable python; build and Codex bootstrap phases skipped" >&2
else
  config_b64="$("$PY" - "$REPO_ROOT/.harness.json" <<'PY'
import base64
import json
import sys

path = sys.argv[1]
defaults = {
    "buildTargets": [],
    "codex": {
        "enabled": False,
        "authEnvVar": "CODEX_AUTH_JSON",
        "workspaceWrite": True,
        "trustRepo": True,
    },
}

def emit(config):
    print(base64.b64encode(json.dumps(config).encode()).decode())

try:
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
except FileNotFoundError:
    print("WARN:.harness.json missing; using install defaults", file=sys.stderr)
    emit(defaults)
    sys.exit(0)
except Exception as exc:
    print(f"WARN:.harness.json parse error: {type(exc).__name__}: {exc}; using install defaults", file=sys.stderr)
    emit(defaults)
    sys.exit(0)

errors = []
if not isinstance(raw, dict):
    errors.append(".harness.json root must be an object")
    raw = {}

try:
    targets = raw.get("install", {}).get("buildTargets", [])
except AttributeError:
    errors.append("install must be an object")
    targets = defaults["buildTargets"]

if targets is None:
    targets = []
if not isinstance(targets, list) or not all(isinstance(item, str) for item in targets):
    errors.append("install.buildTargets must be a string array")
    targets = defaults["buildTargets"]

cloud = raw.get("cloud", {}) if isinstance(raw, dict) else {}
if cloud is None:
    cloud = {}
if not isinstance(cloud, dict):
    errors.append("cloud must be an object")
    cloud = {}

codex = cloud.get("codex", {})
if codex is None:
    codex = {}
if not isinstance(codex, dict):
    errors.append("cloud.codex must be an object")
    codex = {}

def bool_value(key):
    value = codex.get(key, defaults["codex"][key])
    if value is None:
        return defaults["codex"][key]
    if not isinstance(value, bool):
        errors.append(f"cloud.codex.{key} must be a boolean")
        return defaults["codex"][key]
    return value

auth_env_var = codex.get("authEnvVar", defaults["codex"]["authEnvVar"])
if auth_env_var is None:
    auth_env_var = defaults["codex"]["authEnvVar"]
if not isinstance(auth_env_var, str):
    errors.append("cloud.codex.authEnvVar must be a string")
    auth_env_var = defaults["codex"]["authEnvVar"]

config = {
    "buildTargets": targets,
    "codex": {
        "enabled": bool_value("enabled"),
        "authEnvVar": auth_env_var,
        "workspaceWrite": bool_value("workspaceWrite"),
        "trustRepo": bool_value("trustRepo"),
    },
}

if errors:
    print("WARN:" + "; ".join(errors) + "; invalid fields use defaults", file=sys.stderr)

emit(config)
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

build_targets=()
CODEX_ENABLED="false"
CODEX_AUTH_ENV_VAR="CODEX_AUTH_JSON"
CODEX_WORKSPACE_WRITE="true"
CODEX_TRUST_REPO="true"

if [ -z "$config_b64" ]; then
  echo "[session-install] no install.buildTargets configured; build phase skipped" >&2
else
  mapfile -t config_lines < <("$PY" - "$config_b64" <<'PY'
import base64
import json
import sys

cfg = json.loads(base64.b64decode(sys.argv[1]).decode())
targets = cfg["buildTargets"]
print(len(targets))
for item in targets:
    print(item)
codex = cfg["codex"]
print("true" if codex["enabled"] else "false")
print(codex["authEnvVar"])
print("true" if codex["workspaceWrite"] else "false")
print("true" if codex["trustRepo"] else "false")
PY
  )
  cr=$'\r'
  config_lines=("${config_lines[@]%$cr}")

  idx=0
  build_target_count="${config_lines[$idx]:-0}"
  idx=$((idx + 1))
  build_targets=()
  for _ in $(seq 1 "$build_target_count"); do
    build_targets+=("${config_lines[$idx]}")
    idx=$((idx + 1))
  done
  CODEX_ENABLED="${config_lines[$idx]:-false}"
  idx=$((idx + 1))
  CODEX_AUTH_ENV_VAR="${config_lines[$idx]:-CODEX_AUTH_JSON}"
  idx=$((idx + 1))
  CODEX_WORKSPACE_WRITE="${config_lines[$idx]:-true}"
  idx=$((idx + 1))
  CODEX_TRUST_REPO="${config_lines[$idx]:-true}"
fi

if [ "${#build_targets[@]}" -eq 0 ]; then
  echo "[session-install] install.buildTargets empty; build phase skipped" >&2
else
  echo "[session-install] building workspaces: ${build_targets[*]}" >&2
  build_args=(run build)
  for target in "${build_targets[@]}"; do
    build_args+=(-w "$target")
  done
  npm "${build_args[@]}" 2>&1 | tail -3 >&2
  echo "[session-install] workspace build done" >&2
fi

echo "[session-install] Codex auth bootstrap phase" >&2
if [ "$CODEX_ENABLED" != "true" ]; then
  echo "[session-install] cloud.codex.enabled is false or omitted; Codex bootstrap skipped" >&2
  exit 0
fi

if ! [[ "$CODEX_AUTH_ENV_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "[session-install] invalid cloud.codex.authEnvVar '$CODEX_AUTH_ENV_VAR'; Codex bootstrap skipped" >&2
  exit 0
fi

auth_value="${!CODEX_AUTH_ENV_VAR:-}"
if [ -z "$auth_value" ]; then
  echo "[session-install] $CODEX_AUTH_ENV_VAR not set; Codex bootstrap skipped" >&2
  exit 0
fi

CODEX_DIR="$HOME/.codex"
AUTH_FILE="$CODEX_DIR/auth.json"
CONFIG_FILE="$CODEX_DIR/config.toml"

mkdir -p "$CODEX_DIR"
chmod 0700 "$CODEX_DIR"

new_hash="$(printf '%s' "$auth_value" | sha256sum | awk '{print $1}')"
old_hash="$(sha256sum "$AUTH_FILE" 2>/dev/null | awk '{print $1}' || true)"

if [ "$new_hash" = "$old_hash" ]; then
  echo "[session-install] Codex auth.json unchanged (sha256=$new_hash, bytes=${#auth_value})" >&2
else
  printf '%s' "$auth_value" > "$AUTH_FILE"
  chmod 0600 "$AUTH_FILE"
  echo "[session-install] Codex auth.json written (sha256=$new_hash, bytes=${#auth_value})" >&2
fi

if [ -f "$CONFIG_FILE" ]; then
  echo "[session-install] Codex config.toml exists; leaving it unchanged" >&2
elif [ "$CODEX_WORKSPACE_WRITE" = "true" ] || [ "$CODEX_TRUST_REPO" = "true" ]; then
  {
    if [ "$CODEX_WORKSPACE_WRITE" = "true" ]; then
      echo 'sandbox_mode = "workspace-write"'
    fi
    if [ "$CODEX_TRUST_REPO" = "true" ]; then
      if [ "$CODEX_WORKSPACE_WRITE" = "true" ]; then
        echo ""
      fi
      echo "[projects.'$REPO_ROOT']"
      echo 'trust_level = "trusted"'
    fi
  } > "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
  echo "[session-install] Codex config.toml seeded" >&2
else
  echo "[session-install] Codex config.toml seed disabled by flags" >&2
fi

exit 0
