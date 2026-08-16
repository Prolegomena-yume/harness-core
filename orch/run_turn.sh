#!/usr/bin/env bash
# run_turn.sh --work <dir> --turn <n>
# 1段 = 1プロセス。実行 → 次段を setsid で起こす → 自分は死ぬ。
#
# ★ 段ごとの枠を被せない。役割はその実行体の初回にだけ焼き、以降は相手の出力を
#   そのまま垂れ流す。理由は2つ。
#   1. 段ごとに枠を組むと、タスクが変わるたびにラッパを書き直す羽目になる
#   2. 枠には相手の立場が漏れる。実装担当がレビュー基準を知ると、基準に合わせて
#      書くようになり、ゲートの検出力が落ちる
#   したがってプロンプトは作業域に置かない($WORK.prompts へ退避する)。
#
# 奇数段 = 実装担当(grok) / 偶数段 = レビュワー(codex)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=""; turn=""
while [ $# -gt 0 ]; do
  case "$1" in
    --work) WORK="$2"; shift 2;;
    --turn) turn="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$WORK" ] && [ -n "$turn" ] || { echo "usage: run_turn.sh --work <dir> --turn <n>" >&2; exit 2; }
W="$(cd "$WORK" && pwd)"
PD="$W.prompts"; mkdir -p "$PD"

R() { python3 - "$PD/roster.json" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
PY
}
ROUNDS="$(R rounds)"; LAST=$((ROUNDS * 2))
CID="$(R grok_chat_id)"
TOKEN_ENV_VAR="$(R implementer_token_env_var)"
printf -v "$TOKEN_ENV_VAR" '%s' "$(cat "$(R implementer_token_file)")"
export "$TOKEN_ENV_VAR"
IMPLEMENTER_COMMAND="$(R implementer_command)"
IMPLEMENTER_MODEL="$(R implementer_model)"
WORKER_PATTERN="$(R implementer_worker_pattern)"
REVIEWER_COMMAND="$(R reviewer_command)"
REVIEWER_EFFORT="$(R reviewer_effort)"

log() { echo "$(date +%H:%M:%S.%3N) turn=$turn pid=$$ ppid=$PPID $*" >> "$W/trace.log"; }
put_sid() { SID="$1" python3 -c "
import json,os
p='$PD/roster.json'; d=json.load(open(p)); d['codex_session_id']=os.environ['SID']
json.dump(d,open(p,'w'),ensure_ascii=False,indent=1)"; }

finish() { # <state> <本文>
  { echo "state=$1 turn=$turn rounds=$ROUNDS work=$W"; echo; cat "$W/last_msg.txt" 2>/dev/null; } > "$W/result.md"
  touch "$W/done"
  # ★ 必ず戻す。socket に ACK は無く、claude は落ちて別プロセスで立ち直る(実測18秒)。
  #   宛先を毎回引き直しながら粘る。それでも届かなければ UNDELIVERED を残す。
  local body="orch [$1] $2
結果: $W/result.md / 全往復: $W/exchange.md"
  local ok=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ORCH_SENDER_LABEL="orch:$1:turn$turn" \
      bash "$HERE/notify-session.sh" "$PD/roster.json" "$body" >> "$W/notify.log" 2>&1; then
      ok=1; log "notify ok (try=$i)"; break
    fi
    sleep 15
  done
  [ "$ok" -eq 1 ] || { touch "$W/UNDELIVERED"; log "notify UNDELIVERED ── 結果は result.md に在り"; }
  log "chain end state=$1"
}

if [ $((turn % 2)) -eq 1 ]; then who=grok; else who=codex; fi
SID="$(R codex_session_id)"
log "start who=$who last=$LAST"

# ---- プロンプト: 役割はその実行体の初回のみ。以降は垂れ流し ----
PREFIX=""
if [ "$who" = grok ] && [ "$turn" -eq 1 ]; then
  PREFIX="$(cat "$HERE/roles/implementer.md")

## 仕様

$(cat "$W/task.md")

"
elif [ "$who" = codex ] && [ -z "$SID" ]; then
  PREFIX="$(cat "$HERE/roles/reviewer.md")

## 仕様

$(cat "$W/task.md")

"
fi
PROMPT="$PREFIX$(cat "$W/last_msg.txt" 2>/dev/null || true)"
printf '%s\n' "$PROMPT" > "$PD/turn$turn.txt"   # 控えは作業域の外

# ---- 実行 ----
if [ "$who" = grok ]; then
  ( cd "$W" && "$IMPLEMENTER_COMMAND" --resume "$CID" -p "$PROMPT" --output-format text --force \
      --model "$IMPLEMENTER_MODEL" ) > "$PD/turn$turn.log" 2>&1 || log "grok exit=$?"
  cp "$PD/turn$turn.log" "$PD/turn$turn.out"
  pkill -f "$WORKER_PATTERN" 2>/dev/null && log "worker killed" || true
else
  COMMON=(--dangerously-bypass-approvals-and-sandbox
          -c model_reasoning_effort="$REVIEWER_EFFORT"
          -c mcp_servers.node_repl.enabled=false
          -c mcp_servers.blender.enabled=false
          -C "$W" -o "$PD/turn$turn.out")
  if [ -z "$SID" ]; then
    "$REVIEWER_COMMAND" exec "${COMMON[@]}" "$PROMPT" > "$PD/turn$turn.log" 2>&1 || log "codex exit=$?"
    NEW="$(grep -m1 -oP 'session id:\s*\K[0-9a-f-]+' "$PD/turn$turn.log" || true)"
    [ -n "$NEW" ] && { put_sid "$NEW"; log "codex sid=$NEW"; }
  else
    "$REVIEWER_COMMAND" exec "${COMMON[@]}" resume "$SID" "$PROMPT" > "$PD/turn$turn.log" 2>&1 || log "codex exit=$?"
  fi
fi

if [ ! -s "$PD/turn$turn.out" ]; then
  log "EMPTY OUTPUT"; finish ABORT "turn$turn ($who) が空出力"; exit 1
fi
cp "$PD/turn$turn.out" "$W/last_msg.txt"
{ echo "## turn$turn ($who)"; cat "$PD/turn$turn.out"; echo; } >> "$W/exchange.md"
log "done bytes=$(stat -c%s "$PD/turn$turn.out")"

# ---- 制御: 判定だけ読む(内容は再構成しない)----
if [ "$who" = codex ]; then
  V="$(grep -m1 -oP '\[VERDICT\]\s*\K(APPROVE|REJECT|IMPOSSIBLE)' "$PD/turn$turn.out" || echo UNKNOWN)"
  log "verdict=$V"
  case "$V" in
    APPROVE)    finish APPROVED "レビュワーが承認"; exit 0;;
    IMPOSSIBLE) finish IMPOSSIBLE "レビュワーが仕様側の矛盾を申告 ── 人見の裁定が要る"; exit 0;;
  esac
  # 上限に達しても承認が出ない = 暴走。止めて上へ上げる。
  if [ "$turn" -ge "$LAST" ]; then
    finish ESCALATED "${ROUNDS}往復で承認に至らず(最終 verdict=$V)── 強制エスカレーション"; exit 0
  fi
fi
[ "$turn" -ge "$LAST" ] && { finish ESCALATED "上限到達"; exit 0; }

setsid bash "$HERE/run_turn.sh" --work "$W" --turn $((turn + 1)) </dev/null >/dev/null 2>&1 &
log "launched next=$((turn+1)) then_exit"
