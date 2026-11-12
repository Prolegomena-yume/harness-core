#!/usr/bin/env bash
# hooks/turn-end-guard.sh のテスト(2026-11-13)。
# 偽の claude(bash への symlink、comm が claude になる)の下で hook を起こし、
# 本物のプロセスの木(祖先に claude、子孫に timer.sh)と fixture の transcript で判定を見る。
# exit code(2=弾く / 0=通す)を表で確かめる。壊した版(常に通す)で弾く期待の件が落ちることも見る。
# 走っているほかのセッションのプロセスには触らない(kill するのはこのテストが起こした timer だけ)。
#
# usage: bash scripts/test-turn-end-guard.sh

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$script_dir/../hooks/turn-end-guard.sh"
timer="$script_dir/timer.sh"
[ -f "$hook" ] || { echo "hook not found: $hook" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ln -s "$(command -v bash)" "$work/claude"   # comm が "claude" になる偽のセッション

# ---- fixture の transcript(実物の形: isMeta / origin.kind / tool_result) ----
python3 - "$work" <<'PY'
import json, sys, os
w = sys.argv[1]

def user(text, **kw):
    r = {"type": "user", "origin": {"kind": "human"}, "turnOrigin": "human",
         "message": {"role": "user", "content": text}}
    r.update(kw); return r
def asst_text(t):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": t}]}}
def asst_skill(name):
    return {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t1", "name": "Skill", "input": {"skill": name}}]}}
def tool_result(body="ok"):
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": body}]}}
def skill_body():
    return {"type": "user", "isMeta": True, "sourceToolUseID": "t1",
            "message": {"role": "user", "content": [{"type": "text", "text": "Base directory for this skill: /x\n# close-session"}]}}
def notification():
    return {"type": "user", "origin": {"kind": "task-notification"}, "turnOrigin": "task_notification",
            "message": {"role": "user", "content": "<task-notification>\n<task-id>x</task-id>\n</task-notification>"}}
def stop_feedback():
    return {"type": "user", "isMeta": True,
            "message": {"role": "user", "content": "Stop hook feedback:\n[x.sh]: msg"}}

def w_(name, rows, big=0):
    with open(os.path.join(w, name), "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
        if big:  # 巨大な tool_result 行を大量に(末尾から読んで parse しない確認)
            pass

conv = [user("調べて"), asst_text("調べました")]
w_("conv.jsonl", conv)
w_("close_this_turn.jsonl", [user("締めて"), asst_text("締めます"), asst_skill("close-session"),
                             tool_result(), skill_body(), asst_text("締めました")])
w_("close_prev_turn.jsonl", [user("締めて"), asst_skill("close-session"), tool_result(), skill_body(),
                             asst_text("締めました"), user("やっぱり続き"), asst_text("はい")])
w_("close_ns.jsonl", [user("締めて"), asst_skill("anthropic-skills:close-session"), tool_result(), skill_body()])
w_("close_then_notification.jsonl", [user("締めて"), asst_skill("close-session"), tool_result(), skill_body(),
                                     notification(), asst_text("通知を見た")])
w_("close_then_stop_feedback.jsonl", [user("締めて"), asst_skill("close-session"), tool_result(), skill_body(),
                                      stop_feedback(), asst_text("直した")])
w_("typed_close.jsonl", [user("<command-name>/close-session</command-name>\n<command-args></command-args>"),
                         skill_body(), asst_text("締めました")])
w_("other_skill.jsonl", [user("x"), asst_skill("takano-handover"), tool_result(), skill_body(), asst_text("done")])
w_("empty.jsonl", [])

# 大きい transcript: 前の turn に 2MB の tool_result 行 x 40(=80MB)、末尾の turn は会話だけ
big = [user("古い")]
for i in range(40):
    big.append(asst_text("a"))
    big.append(tool_result("x" * 2_000_000))
big += [user("今の話"), asst_text("答えた")]
w_("big_conv.jsonl", big)
PY

mk_in() { # <transcript> <stop_hook_active true|false> -> stdin json file
  jq -n --arg t "$work/$1" --argjson a "$2" '{transcript_path:$t,stop_hook_active:$a,hook_event_name:"Stop"}' > "$work/in.$1.$2.json"
  echo "$work/in.$1.$2.json"
}

# run <hook> <transcript> <active> <mode: plain|timer|headless|orphan> -> exit code
run() {
  local h="$1" tr="$2" act="$3" mode="$4" in rc=0
  in="$(mk_in "$tr" "$act")"
  case "$mode" in
    plain)
      "$work/claude" -c "bash '$h' < '$in' >/dev/null 2>'$work/err'" || rc=$? ;;
    timer)  # 子孫に生きた timer.sh(実物)を張る。起こしたものだけ最後に落とす
      "$work/claude" -c "bash '$timer' 20 test-timer >/dev/null & tp=\$!; sleep 0.5; bash '$h' < '$in' >/dev/null 2>'$work/err'; r=\$?; pkill -P \$tp 2>/dev/null; kill \$tp 2>/dev/null; wait \$tp 2>/dev/null; exit \$r" || rc=$? ;;
    deadtimer)  # timer.sh が終わった後(子孫に居ない)
      "$work/claude" -c "bash '$timer' 1 test-timer >/dev/null; bash '$h' < '$in' >/dev/null 2>'$work/err'" || rc=$? ;;
    fakeonly)  # timer.sh という語を含むだけの別プロセス(grep / tail)は数えない
      "$work/claude" -c "sleep 5 & sp=\$!; tail -f '$timer' >/dev/null 2>&1 & tp=\$!; sleep 0.3; bash '$h' < '$in' >/dev/null 2>'$work/err'; r=\$?; kill \$sp \$tp 2>/dev/null; exit \$r" || rc=$? ;;
    headless)  # claude -p
      "$work/claude" -p -c "bash '$h' < '$in' >/dev/null 2>'$work/err'" || rc=$? ;;
    orphan)  # 祖先に claude が居ない(setsid -f で親が消え subreaper の下に入る)
      rm -f "$work/orphan.rc"
      setsid -f bash -c "bash '$h' < '$in' >/dev/null 2>'$work/err'; echo \$? > '$work/orphan.rc'" >/dev/null 2>&1
      for _ in $(seq 50); do [ -f "$work/orphan.rc" ] && break; sleep 0.1; done
      rc="$(cat "$work/orphan.rc" 2>/dev/null || echo none)" ;;
  esac
  echo "$rc"
}

total=0; bad=0
check() { # <label> <hook> <block|pass> <transcript> <active> <mode>
  local label="$1" h="$2" want="$3" want_rc got
  [ "$want" = block ] && want_rc=2 || want_rc=0
  got="$(run "$h" "$4" "$5" "$6")"
  total=$((total + 1))
  if [ "$got" = "$want_rc" ]; then printf '○ %-5s %s\n' "$want" "$label"
  else bad=$((bad + 1)); printf '× %-5s %s   (exit %s, 期待 %s)\n' "$want" "$label" "$got" "$want_rc"; fi
}

echo "== 本体 =="
# 依頼の 6 件
check "1 会話だけで timer も close も無い"                    "$hook" block conv.jsonl false plain
check "2 子孫に timer.sh が生きている"                         "$hook" pass  conv.jsonl false timer
check "3 この turn に Skill close-session がある"              "$hook" pass  close_this_turn.jsonl false plain
check "4 前の turn に close-session、この turn には無い"       "$hook" block close_prev_turn.jsonl false plain
check "5 stop_hook_active: true"                               "$hook" pass  conv.jsonl true plain
check "6 祖先が claude -p"                                     "$hook" pass  conv.jsonl false headless
# 境界
check "7 timer.sh が終わった後(子孫に居ない)"                "$hook" block conv.jsonl false deadtimer
check "8 timer.sh の語だけ持つ別プロセス(tail -f)は数えない" "$hook" block conv.jsonl false fakeonly
check "9 名前空間付き close-session(anthropic-skills:)"        "$hook" pass  close_ns.jsonl false plain
check "10 close 後に task-notification(timer の鳴り)は境にしない" "$hook" pass close_then_notification.jsonl false plain
check "11 close 後の Stop hook 返し文(isMeta)は境にしない"    "$hook" pass  close_then_stop_feedback.jsonl false plain
check "12 user が打った /close-session"                        "$hook" pass  typed_close.jsonl false plain
check "13 別の Skill は close にならない"                      "$hook" block other_skill.jsonl false plain
check "14 空の transcript(turn の始まりまで close 無し)"      "$hook" block empty.jsonl false plain
check "15 祖先に claude が無い(fail open)"                    "$hook" pass  conv.jsonl false orphan

echo "== 速さ(80MB の transcript、会話だけの末尾 turn) =="
t0=$(date +%s.%N)
check "16 巨大 transcript でも弾く" "$hook" block big_conv.jsonl false plain
t1=$(date +%s.%N)
el=$(python3 -c "print(round($t1-$t0,2))")
printf '   経過 %s 秒(基準 2 秒)\n' "$el"
total=$((total + 1))
if python3 -c "import sys; sys.exit(0 if $t1-$t0 < 2.0 else 1)"; then echo "○ 速さ 2 秒以内"; else bad=$((bad + 1)); echo "× 速さ 2 秒超"; fi

echo "== 壊した版(判定を常に通す)で、弾く期待の件が落ちること =="
broken="$work/turn-end-guard.broken.sh"
python3 - "$hook" "$broken" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert "sys.exit(2)\nPY" in s
open(sys.argv[2], "w").write(s.replace("sys.exit(2)\nPY", "sys.exit(0)\nPY"))
PY
# 壊した版は弾かない。弾く期待の件(1・4)が「通ってしまう」=本体の期待と食い違う=落ちる、を確かめる
for spec in "1 conv.jsonl" "4 close_prev_turn.jsonl"; do
  set -- $spec
  got="$(run "$broken" "$2" false plain)"
  total=$((total + 1))
  if [ "$got" = 0 ]; then printf '○ 壊した版は件%s で弾かない(exit 0)=本体の「弾く」期待を満たせず落ちる\n' "$1"
  else bad=$((bad + 1)); printf '× 壊した版が件%s で exit %s(壊せていない)\n' "$1" "$got"; fi
done

echo
echo "total=$total bad=$bad"
[ "$bad" -eq 0 ]
