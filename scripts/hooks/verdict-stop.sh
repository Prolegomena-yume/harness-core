#!/usr/bin/env bash
# kimi 0.40.1 の Stop hook。契約は本ファイルの冒頭コメントに置く。
#
# 書式(実測、kimi 0.40.1 の agent-core-v2 バイナリ文字列から復元):
#   config.toml の `[[hooks]]` テーブル(HOOKS_SECTION="hooks"、HookDefSchema.strict()):
#     event   = "Stop" | "PreToolUse" | ... (HOOK_EVENT_TYPES、20 種)
#     matcher = 文字列・省略可(PreToolUse/PostToolUse では tool 名に対する正規表現)
#     command = 文字列・必須(shell:true で spawn される)
#     timeout = 1〜600 の整数・省略可(既定 30 秒)
#   起動: node child_process.spawn(command, {shell:true, env:{...process.env,...hook.env}})
#         stdin に JSON.stringify(inputData) を書いて end。inputData は camelCase → snake_case。
#         Stop の inputData: {hook_event_name:"Stop", session_id, cwd, stop_hook_active}
#   結果の解釈(resultFromExitCode):
#     exit 2                        → block、理由は stderr の trim
#     exit 0 + stdout が JSON で hookSpecificOutput.permissionDecision === "deny"
#                                    → block、理由は permissionDecisionReason
#     それ以外(exit 0 で上記以外、他の非 0 exit)→ allow
#   Stop hook の block は「セッションを終了させず、reason を assistant への
#   system_trigger メッセージとして差し込んで続行させる」効果(agent-core-v2 実装で確認)。
#
# この hook の中身: $CODEX_AGENT_RUN_DIR/verdict.md が無い・1 行目が
# 継続/承認/エスカレーション のどれでもなければ block(exit 2)。
# CODEX_AGENT_RUN_DIR が無い(人見の対話 kimi)なら素通し(exit 0)。
#
# 適用は鷹野が config.toml に足す(このスクリプト自体は config.toml を編集しない)。

set -u

# stdin の JSON は読み捨てる(この hook は中身を使わない)。
cat > /dev/null 2>&1 || true

if [ -z "${CODEX_AGENT_RUN_DIR:-}" ]; then
  # 人見の対話 kimi(ランチャ経由でない起動)には verdict.md の契約が無いので素通り。
  exit 0
fi

verdict_file="$CODEX_AGENT_RUN_DIR/verdict.md"

# block は「exit 0 + stdout の JSON({hookSpecificOutput:{permissionDecision:"deny",...}})」の形で返す
# (kimi 0.40.1 実測。exit 2 + stderr でも同じ効果だが、JSON 形式の方が hookSpecificOutput の
# 他フィールドと揃えやすいのでこちらを既定にする)。
block() {
  local reason="$1" escaped
  escaped="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$escaped"
  echo "$reason" >&2
  exit 0
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
