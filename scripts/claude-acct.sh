#!/usr/bin/env bash
# Claude Max 2 枚(a / b)のうち、便を起こす側を起動時に選ぶ道具 ── 本体は lib/claude-acct.py(使い方・env はその docstring)。
#   claude-acct.sh pick [--model <id>] [--policy primary]   JSON 1 行を stdout へ(token の値は出さない)。exit 75 = 両方尽きた
#   claude-acct.sh exec <a|b> -- <cmd...>                    b なら token を子の env にだけ入れて exec
#   claude-acct.sh is-limit <result.json> [stream.jsonl]      枠切れで終わった run か(exit 0 = 枠切れ)
# stdin はそのまま子に渡る(makabe-stream.py が claude の標準入力を持つため、python を stdin 読みにしない)。
# 親ゴール: claude-makabe / claude-kashiwagi の便が、1 枚目の枠が尽きても人見の手なしで 2 枚目で起きる。
set -euo pipefail
source_path="${BASH_SOURCE[0]}"
while [ -L "$source_path" ]; do
  d="$(cd -P "$(dirname "$source_path")" && pwd)"
  t="$(readlink "$source_path")"
  case "$t" in /*) source_path="$t" ;; *) source_path="$d/$t" ;; esac
done
here="$(cd -P "$(dirname "$source_path")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "エラー: python3 が見つからない" >&2; exit 2; }
exec python3 "$here/lib/claude-acct.py" "$@"
