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

# ---- 不変の作法を ~/.codex/AGENTS.md へ配置 ----
# codex はリポ配下の .codex/ を読まない(実測)。ホーム側だけが唯一の
# codex 専用の口なので、正典を core に置いてここから配る。
core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$core_dir/codex/AGENTS.home.md"
dst="${CODEX_HOME:-$HOME/.codex}/AGENTS.md"

if [ ! -f "$src" ]; then
  echo "警告: $src が無い ── 不変の作法を配置しない" >&2
elif [ -s "$dst" ] && ! cmp -s "$src" "$dst"; then
  echo "警告: $dst に core と異なる内容がある ── 上書きしない" >&2
  echo "  差分を確認して、寄せるなら手で cp する: cp \"$src\" \"$dst\"" >&2
else
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "不変の作法を配置: $dst"
fi
