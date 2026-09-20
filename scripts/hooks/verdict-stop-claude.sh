#!/usr/bin/env bash
# Claude Code(claude -p)の Stop hook。verdict-stop.sh(kimi 0.40.1 版)と判定ロジックは同一、
# block の返し方だけが違う(庵野 実測、2026-09-21、claude-code 2.1.246)。
#
# 実測で分かったこと:
#   Claude Code の Stop イベントは exit 2(理由は stderr)でだけ block する。
#   exit 0 + stdout JSON({"hookSpecificOutput":{"permissionDecision":"deny",...}})の形式は
#   kimi 0.40.1 では block になるが、Claude Code の Stop では無視される(num_turns が増えない、
#   実測 2 本: JSON-deny → num_turns 1 のまま/exit 2 → num_turns 2)。
#   さらに `--dangerously-skip-permissions`(bypassPermissions)下でも exit 2 の Stop block は効く
#   ── permission decision の経路とは別物のため(PreToolUse の JSON deny は bypass 下で無視されるが
#   exit 2 は無視されない、gate-guard-claude.sh のコメントと同じ実測)。
#
# 適用は claude-niekawa.sh が起動のたびに書く run_dir 内 settings.json から(--settings)。
# ~/.claude/settings.json は触らない(ハーネスは Claude だけが触る、母艦の設定は汚さない)。
#
# 契約は verdict-stop.sh と同じ: $CODEX_AGENT_RUN_DIR/verdict.md が無い・1 行目が
# 継続/承認/エスカレーション のどれでもなければ block。CODEX_AGENT_RUN_DIR が無ければ素通し。

set -u

# stdin の JSON は読み捨てる(この hook は中身を使わない)。
cat > /dev/null 2>&1 || true

if [ -z "${CODEX_AGENT_RUN_DIR:-}" ]; then
  exit 0
fi

verdict_file="$CODEX_AGENT_RUN_DIR/verdict.md"

block() {
  # exit 2 + stderr の理由が Claude Code の Stop block の形(実測、上記コメント参照)。
  echo "$1" >&2
  exit 2
}

if [ ! -s "$verdict_file" ]; then
  block "verdict.md を書いてから終わる"
fi

first_line="$(head -n 1 "$verdict_file" | tr -d '\r')"
case "$first_line" in
  'verdict: 継続'|'verdict:継続'|'verdict: 承認'|'verdict:承認'|'verdict: エスカレーション'|'verdict:エスカレーション')
    exit 0
    ;;
  *)
    block "verdict.md を書いてから終わる"
    ;;
esac
