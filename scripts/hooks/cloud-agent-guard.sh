#!/usr/bin/env bash
# PreToolUse(matcher: Agent)。cloud 専用の真壁・柏木サブエージェントの呼び出しを見る。
#  - 母艦(CLAUDE_CODE_REMOTE != true)で subagent_type が makabe / kashiwagi なら止める(exit 2)
#  - cloud の kashiwagi: プロンプト 1 行目が `便: <id>` でなければ止める。同じ便の 2 回目も止める
#    (ゲートは便に 1 回。記録は VM の中のファイルなので、VM が回収されると消える)
# それ以外の Agent 呼び出しは何もせず exit 0(母艦の既存の呼び出しに影響しない)。
# 速さのため、対象外は grep 1 回で抜ける(jq / python を起こさない)。
set -u
in="$(cat 2>/dev/null || true)"
printf '%s' "$in" | grep -q '"subagent_type"[[:space:]]*:[[:space:]]*"\(makabe\|kashiwagi\)"' || exit 0
kind="$(printf '%s' "$in" | grep -o '"subagent_type"[[:space:]]*:[[:space:]]*"[a-z]*"' | head -1 | sed 's/.*"\([a-z]*\)"$/\1/')"
if [ "${CLAUDE_CODE_REMOTE:-}" != true ]; then
  echo "$kind は cloud セッション専用(母艦では呼ばない。真壁は codex-makabe / kimi-makabe / claude-makabe、柏木は claude-kashiwagi / codex-kashiwagi)" >&2
  exit 2
fi
[ "$kind" = kashiwagi ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
first="$(printf '%s' "$in" | jq -r '.tool_input.prompt // ""' | head -1)"
id="$(printf '%s' "$first" | sed -n 's/^便:[[:space:]]*\([A-Za-z0-9._-]\{1,\}\)[[:space:]]*$/\1/p')"
[ -n "$id" ] || { echo "kashiwagi のプロンプト 1 行目は「便: <id>」にする(ゲートは便に 1 回、記録に使う)" >&2; exit 2; }
f="${CLOUD_GATES_FILE:-$HOME/.cache/harness-cloud/gates.tsv}"
mkdir -p "$(dirname "$f")"
if grep -q "^$id	" "$f" 2>/dev/null; then
  echo "便 $id のゲートは実施済み(便に 1 回、柏木は呼び直さない)" >&2
  exit 2
fi
printf '%s\t%s\n' "$id" "$(date -u +%FT%TZ)" >>"$f"
exit 0
