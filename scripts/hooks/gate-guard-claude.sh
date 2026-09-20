#!/usr/bin/env bash
# Claude Code(claude -p)の PreToolUse hook。gate-guard.sh(kimi 0.40.1 版)と判定ロジックは同一、
# block の返し方だけが違う(庵野 実測、2026-09-21、claude-code 2.1.246)。
#
# 実測で分かったこと:
#   Claude Code の PreToolUse は exit 2(理由は stderr)でだけ確実に block する。
#   exit 0 + stdout JSON の permissionDecision:"deny" は `--dangerously-skip-permissions`
#   (bypassPermissions)下では無視される(実測: hook は正しく起動され tool_input.command も
#   読めているが、deny を返しても Bash は実行された。exit 2 に替えると同条件で実行前に block された)。
#   このランチャ群は全 persona が `--dangerously-skip-permissions` 固定のため、JSON deny 版の
#   gate-guard.sh をそのまま Claude へ載せても効かない。exit 2 版が必須。
#
# 適用は claude-niekawa.sh が起動のたびに書く run_dir 内 settings.json から(--settings、
# matcher は "Bash" を明示。kimi と違い Claude Code は matcher を使わないと効かない訳ではないが、
# ここでは Bash だけに絞って kimi 版と同じ判定に揃える)。
#
# 契約は gate-guard.sh と同じ: Bash の command に codex-kashiwagi を含み、-f / --file の指す
# ファイル名が findings.md(ゲート2)または plan.md(ゲート1)のとき、便ディレクトリの gates.tsv に
# そのゲート番号の行が既に 1 本あれば block。append はしない(書き手は codex-agent.sh だけ)。
# NIEKAWA_INBOX が無い・jq が無いなら素通し。

set -u

stdin_json="$(cat 2>/dev/null || true)"

if [ -z "${NIEKAWA_INBOX:-}" ]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

command_str="$(printf '%s' "$stdin_json" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
case "$command_str" in
  *codex-kashiwagi*) ;;
  *) exit 0 ;;
esac

fpath="$(printf '%s' "$command_str" \
  | grep -oE '(^|[[:space:]])(-f|--file)[=[:space:]]+[^[:space:]]+' \
  | tail -1 \
  | sed -E 's/^[[:space:]]*(-f|--file)[=[:space:]]+//')"
fpath="${fpath%\"}"
fpath="${fpath#\"}"
fpath="${fpath%\'}"
fpath="${fpath#\'}"
base=""
[ -n "$fpath" ] && base="$(basename -- "$fpath")"

gate_check=""
case "$base" in
  findings.md) gate_check=2 ;;
  plan.md) gate_check=1 ;;
  *) exit 0 ;;
esac

batch_dir="$(dirname -- "$NIEKAWA_INBOX")"
gates_tsv="$batch_dir/gates.tsv"

block() {
  # exit 2 + stderr の理由が Claude Code の PreToolUse block の形(実測、上記コメント参照)。
  echo "$1" >&2
  exit 2
}

if [ -f "$gates_tsv" ] && awk -F'\t' -v g="$gate_check" '$3==g{found=1} END{exit !found}' "$gates_tsv"; then
  block "ゲート ${gate_check} は便に 1 回、直った巡は自分の検収で閉じる"
fi

exit 0
