#!/usr/bin/env bash

set -euo pipefail

usage() { echo '使い方: install-codex-agents.sh [--consumer <repo>]'; }
consumer=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --consumer)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo 'エラー: --consumer には repo が必要' >&2; exit 2
      fi
      consumer="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "エラー: 不明な option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ -n "$consumer" ]; then
  [ -d "$consumer" ] || { echo "エラー: consumer が見つからない: $consumer" >&2; exit 2; }
  consumer="$(cd "$consumer" && pwd -P)"
  python3 - "$core_dir" "$consumer" <<'PYTHON'
from pathlib import Path
import sys
import tomllib
core, consumer = map(Path, sys.argv[1:])
instructions = (core / 'roles/makabe.md').read_text() + '\n\n' + (core / 'codex/makabe.md').read_text()
if "'" * 3 in instructions:
    sys.exit("エラー: developer_instructions に TOML の三連単引用符が含まれる")
if any(ord(c) < 32 and c not in '\n\t' or ord(c) == 127 for c in instructions):
    sys.exit('エラー: developer_instructions に制御文字が含まれる')
template = (core / 'codex/agents/makabe.toml.tmpl').read_text()
marker = '@@DEVELOPER_INSTRUCTIONS@@'
if template.count(marker) != 1:
    sys.exit('エラー: makabe template の置換箇所が不正')
rendered = template.replace(marker, instructions)
tomllib.loads(rendered)
target = consumer / '.codex/agents/makabe.toml'
if target.exists() and target.read_bytes() == rendered.encode():
    print(f'変更なし: {target}')
else:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(rendered)
    print(f'役定義を生成: {target}')
with target.open('rb') as stream:
    tomllib.load(stream)
PYTHON
fi

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

write_kimi_niekawa_wrapper() {
  local target="$bin_dir/kimi-niekawa"

  cat > "$target" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

if [ -n "\${CODEX_AGENT_CORE:-}" ]; then
  launcher="\$CODEX_AGENT_CORE/scripts/kimi-niekawa.sh"
elif repo_root="\$(git rev-parse --show-toplevel 2>/dev/null)" && [ -f "\$repo_root/.claude/_core/scripts/kimi-niekawa.sh" ]; then
  launcher="\$repo_root/.claude/_core/scripts/kimi-niekawa.sh"
else
  launcher="\$HOME/canonical/tech/.claude/_core/scripts/kimi-niekawa.sh"
fi

if [ ! -x "\$launcher" ]; then
  echo "エラー: kimi-niekawa.sh が見つからないか実行できない: \$launcher" >&2
  exit 2
fi

exec "\$launcher" "\$@"
WRAPPER
  chmod +x "$target"
  printf '%s\n' "$target"
}

echo "Codex 委譲人格の wrapper を配置:"
write_wrapper minase
write_wrapper makabe
write_wrapper kashiwagi
write_wrapper niekawa
write_kimi_niekawa_wrapper
ln -sfn "$core_dir/scripts/git-as" "$bin_dir/git-as"
ln -sfn "$core_dir/scripts/claude-minase.sh" "$bin_dir/claude-minase"
ln -sfn "$core_dir/scripts/genai.sh" "$bin_dir/genai"
ln -sfn "$core_dir/scripts/harness-route.sh" "$bin_dir/harness-route"
printf '%s\n' "$bin_dir/git-as" "$bin_dir/claude-minase" "$bin_dir/genai" "$bin_dir/harness-route"

# ---- 不変の作法を ~/.codex/AGENTS.md へ配置 ----
# ホーム共通指示を正典から配る。repo 固有の役定義は --consumer で別途生成する。
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
