#!/usr/bin/env bash

set -euo pipefail

bin_dir="$HOME/bin"
mkdir -p "$bin_dir"

write_wrapper() {
  local persona="$1"
  local target="$bin_dir/codex-$persona"

  cat > "$target" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

if [ -n "\${CODEX_AGENT_CORE:-}" ]; then
  launcher="\$CODEX_AGENT_CORE/scripts/codex-agent.sh"
elif repo_root="\$(git rev-parse --show-toplevel 2>/dev/null)" && [ -f "\$repo_root/.claude/_core/scripts/codex-agent.sh" ]; then
  launcher="\$repo_root/.claude/_core/scripts/codex-agent.sh"
else
  launcher="\$HOME/canonical/tech/.claude/_core/scripts/codex-agent.sh"
fi

if [ ! -x "\$launcher" ]; then
  echo "エラー: codex-agent.sh が見つからないか実行できない: \$launcher" >&2
  exit 2
fi

exec "\$launcher" $persona "\$@"
WRAPPER
  chmod +x "$target"
  printf '%s\n' "$target"
}

echo "Codex 委譲人格の wrapper を配置:"
write_wrapper minase
write_wrapper makabe
write_wrapper kashiwagi
