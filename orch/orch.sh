#!/usr/bin/env bash
# orch.sh --task <task.md> --work <dir> [--rounds N] [--seed <dir>] [--no-launch]
#
# claude が叩くのはこれ1本。渡すのは task.md と作業域だけ。
# 段割り・setsid・resume・worker 刈り・通知・上限判定は全部この下に閉じる。
#
# ★ 宛先は「発進の直前」に引いて roster へ焼く。claude は割り込みや再起動で
#   pid も sessionId も name も振り直される(2026-08-16 実測)。起動時の値を
#   使い回すと戻り先を失う。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TASK=""; WORK=""; ROUNDS=""; SEED=""; NO_LAUNCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="$2"; shift 2;;
    --work) WORK="$2"; shift 2;;
    --rounds) ROUNDS="$2"; shift 2;;
    --seed) SEED="$2"; shift 2;;   # 既存の成果物を引き継ぐ場合
    --no-launch) NO_LAUNCH=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$TASK" ] && [ -n "$WORK" ] || { echo "usage: orch.sh --task <md> --work <dir> [--rounds N] [--seed <dir>] [--no-launch]" >&2; exit 2; }

PD="$WORK.prompts"
ROSTER="$PD/roster.json"
mkdir -p "$WORK" "$PD"
[ -n "$SEED" ] && cp -r "$SEED"/. "$WORK"/ 2>/dev/null || true
cp "$TASK" "$WORK/task.md"
: > "$WORK/trace.log"; : > "$WORK/exchange.md"
rm -f "$WORK/roster.json" "$WORK/last_msg.txt" "$WORK/done" "$WORK/result.md"

# ---- 設定: consumer の .harness.json を起動時に一度だけ解決して roster へ焼く ----
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
CONFIG=""
for dir in "$PROJECT_DIR" "$GIT_ROOT" "$PWD"; do
  [ -n "$dir" ] || continue
  if [ -f "$dir/.harness.json" ]; then CONFIG="$dir/.harness.json"; break; fi
done

CONFIG="$CONFIG" ROUNDS="$ROUNDS" ROSTER="$ROSTER" python3 - <<'PY' || exit $?
import json, os, re, sys

path = os.environ["CONFIG"]
try:
    data = json.load(open(path)) if path else {}
except (OSError, json.JSONDecodeError) as exc:
    print(f"orch: .harness.json を読めない: {exc}", file=sys.stderr)
    sys.exit(2)

orch = data.get("orch") or {}
implementer = orch.get("implementer") or {}
reviewer = orch.get("reviewer") or {}
token_file = implementer.get("tokenFile")
if not token_file:
    print("orch: orch.implementer.tokenFile が無い", file=sys.stderr)
    sys.exit(2)
token_file = os.path.expanduser(token_file)
if not os.path.isfile(token_file) or not os.access(token_file, os.R_OK):
    print(f"orch: tokenFile を読めない: {token_file}", file=sys.stderr)
    sys.exit(2)

token_env_var = implementer.get("tokenEnvVar", "CURSOR_API_KEY")
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token_env_var):
    print(f"orch: tokenEnvVar が不正: {token_env_var}", file=sys.stderr)
    sys.exit(2)
rounds = os.environ["ROUNDS"] or orch.get("defaultRounds", 3)
if not isinstance(rounds, int):
    try:
        rounds = int(rounds)
    except (TypeError, ValueError):
        print(f"orch: rounds が不正: {rounds}", file=sys.stderr)
        sys.exit(2)
if rounds < 1:
    print(f"orch: rounds が不正: {rounds}", file=sys.stderr)
    sys.exit(2)

roster = {
    "grok_chat_id": "",
    "codex_session_id": "",
    "rounds": rounds,
    "origin_session_id": "",
    "origin_name": "",
    "origin_pid": 0,
    "origin_started": 0,
    "origin_cwd": "",
    "implementer_command": implementer.get("command", "cursor-agent"),
    "implementer_model": implementer.get("model", "cursor-grok-4.6-high-fast"),
    "implementer_token_file": token_file,
    "implementer_token_env_var": token_env_var,
    "implementer_worker_pattern": implementer.get("workerPattern", "cursor-agent/versions/.*worker-server"),
    "reviewer_command": reviewer.get("command", "codex"),
    "reviewer_effort": reviewer.get("effort", "high"),
}
with open(os.environ["ROSTER"], "w") as f:
    json.dump(roster, f, ensure_ascii=False, indent=1)
PY

# ---- 宛先: 自分を「推測しない」。claude は自分の sessionId を環境で知っている ----
# 「同 cwd の最新 interactive」を自分と決めつけると別チャットへ誤爆する(2026-08-16 実測)。
: "${CLAUDE_CODE_SESSION_ID:?orch: CLAUDE_CODE_SESSION_ID が無い ── claude の中から起動すること}"
ORIGIN="$(claude agents --json 2>/dev/null | SID="$CLAUDE_CODE_SESSION_ID" python3 -c '
import json,sys,os
sid=os.environ["SID"]
for r in json.load(sys.stdin):
    if r.get("sessionId")==sid:
        print(json.dumps(r, ensure_ascii=False)); break
else:
    print("{}")')"
[ "$ORIGIN" = "{}" ] && { echo "orch: 自分($CLAUDE_CODE_SESSION_ID)が agents に見つからない" >&2; exit 1; }

ORIGIN="$ORIGIN" ROSTER="$ROSTER" python3 -c '
import json,os
o=json.loads(os.environ["ORIGIN"] or "{}")
p=os.environ["ROSTER"]; d=json.load(open(p))
d.update({"origin_session_id":o.get("sessionId",""), "origin_name":o.get("name",""),
 "origin_pid":o.get("pid",0), "origin_started":o.get("startedAt",0), "origin_cwd":o.get("cwd","")})
json.dump(d,open(p,"w"),ensure_ascii=False,indent=1)'

if [ "$NO_LAUNCH" -eq 1 ]; then
  echo "orch: work=$WORK  prompts=$WORK.prompts(作業域の外)"
  cat "$ROSTER"
  echo "orch: no-launch"
  exit 0
fi

# ---- 実装担当(grok)の chat を事前確保 ── claude が握り、roster に載せる ----
R() { python3 - "$ROSTER" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
PY
}
TOKEN_ENV_VAR="$(R implementer_token_env_var)"
printf -v "$TOKEN_ENV_VAR" '%s' "$(cat "$(R implementer_token_file)")"
export "$TOKEN_ENV_VAR"
IMPLEMENTER_COMMAND="$(R implementer_command)"
CID="$("$IMPLEMENTER_COMMAND" create-chat 2>/dev/null | tail -1 | tr -d '[:space:]')"
[ -n "$CID" ] || { echo "orch: create-chat 失敗" >&2; exit 1; }
CID="$CID" ROSTER="$ROSTER" python3 -c '
import json,os
p=os.environ["ROSTER"]; d=json.load(open(p)); d["grok_chat_id"]=os.environ["CID"]
json.dump(d,open(p,"w"),ensure_ascii=False,indent=1)'

echo "orch: work=$WORK  prompts=$WORK.prompts(作業域の外)"
cat "$ROSTER"
setsid bash "$HERE/run_turn.sh" --work "$WORK" --turn 1 </dev/null >/dev/null 2>&1 &
echo "orch: launched turn=1"
