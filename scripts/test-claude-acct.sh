#!/usr/bin/env bash
# claude-acct.sh(pick / exec / is-limit)の test。rates は偽物(CLAUDE_ACCT_RATES)、実ネットワーク・実 claude には出ない。
# 偽 rates は CLAUDE_CONFIG_DIR の下の rates.json をそのまま返す(rates.fail があれば失敗、refresh.sh があれば実行 = 更新の再現)。
# 呼ばれた回数は <dir>/rates.calls に残る。token は偽の文字列で、どの出力にも現れないことを最後に縛る。
# 使い方: bash scripts/test-claude-acct.sh
set -uo pipefail
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCT="$core/scripts/claude-acct.sh"
n=0; fail=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); echo "not ok $n - $1"; fail=1; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

sbx="$(mktemp -d)"; trap 'rm -rf "$sbx"' EXIT
mkdir -p "$sbx/bin"
cat >"$sbx/bin/rates" <<'STUB'
#!/usr/bin/env bash
d="${CLAUDE_CONFIG_DIR:?}"
echo x >>"$d/rates.calls"
[ -f "$d/rates.fail" ] && { echo "fake rates failure" >&2; exit 1; }
[ -f "$d/refresh.sh" ] && bash "$d/refresh.sh" "$d"
cat "$d/rates.json"
STUB
chmod +x "$sbx/bin/rates"
export CLAUDE_ACCT_RATES="$sbx/bin/rates"
unset CLAUDE_ACCT_DISABLE CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_ACCT_SWITCH_AT CLAUDE_ACCT_STOP_AT \
      CLAUDE_ACCT_TOKEN_MARGIN_SEC

FILE_TOKEN="sk-ant-oat01-FILETOKENFILETOKENFILETOKEN"
CRED_TOKEN="sk-ant-oat01-CREDTOKENCREDTOKENCREDTOKEN"
NEW_TOKEN="sk-ant-oat01-REFRESHEDREFRESHEDREFRESHED"

# new_case <name>: a / b の設定ディレクトリと token_file の場所を env に出す($c = そのケースの dir)。
new_case() {
  c="$sbx/$1"; mkdir -p "$c/a" "$c/b"
  export CLAUDE_ACCT_A_DIR="$c/a" CLAUDE_ACCT_B_DIR="$c/b" CLAUDE_ACCT_B_TOKEN_FILE="$c/b.token"
}
# rates_json <dir> <5h> <weekly> [extra '"key":val']
rates_json() {
  local d="$1" h="$2" w="$3" extra="${4:-}"
  printf '{"email":"%s@example.com","remaining":{"5h":%s,"weekly":%s,"monthly":null%s}}\n' "$(basename "$d")" "$h" "$w" "${extra:+,$extra}" >"$d/rates.json"
}
file_token() { printf '%s\n' "$FILE_TOKEN" >"$c/b.token"; chmod 600 "$c/b.token"; }
# cred <expires_in_sec>: b の .credentials.json
cred() {
  python3 - "$c/b/.credentials.json" "$1" "$CRED_TOKEN" <<'PY'
import json, sys, time
json.dump({"claudeAiOauth": {"accessToken": sys.argv[3], "refreshToken": "r", "expiresAt": int((time.time() + float(sys.argv[2])) * 1000)}}, open(sys.argv[1], "w"))
PY
  chmod 600 "$c/b/.credentials.json"
}
# pick [args...]: stdout を $c/pick.out、stderr を $c/pick.err、exit を $c/pick.rc
pick() { "$ACCT" pick "$@" >"$c/pick.out" 2>"$c/pick.err"; echo $? >"$c/pick.rc"; }
label() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["label"])' "$c/pick.out"; }
reason() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reason"])' "$c/pick.out"; }
label_is() { [ "$(label)" = "$1" ] && [ "$(cat "$c/pick.rc")" = "${2:-0}" ]; }
calls() { if [ -f "$1/rates.calls" ]; then wc -l <"$1/rates.calls"; else echo 0; fi; }

# ---- 1. 規則の表(rates は偽物) ----
new_case t1; rates_json "$c/a" 50 50; rates_json "$c/b" 60 60; file_token
pick --model claude-sonnet-5
chk "1a A 50 → a" label_is a
chk "1b A が線より上なら b の rates は叩かない" test "$(calls "$c/b")" = 0

new_case t2; rates_json "$c/a" 4 50; rates_json "$c/b" 60 60; file_token
pick --model claude-sonnet-5
chk "2a A 4(5h)・B 60 → b" label_is b
chk "2b 理由が a-below-switch-line" test "$(reason)" = a-below-switch-line

new_case t2w; rates_json "$c/a" 50 5; rates_json "$c/b" 60 60; file_token
pick
chk "2c 線ちょうど(weekly 5)は割った扱い → b" label_is b

new_case t3; rates_json "$c/a" 4 50; rates_json "$c/b" 2 60; file_token
pick --model claude-sonnet-5
chk "3a A 4・B 2 → exit 75(label null)" label_is None 75
chk "3b 理由 both-exhausted" test "$(reason)" = both-exhausted

new_case t3b; rates_json "$c/a" 4 50; rates_json "$c/b" 60 3; file_token
pick
chk "3c B の weekly がちょうど 3(止める線)→ 尽きた扱いで 75" label_is None 75

new_case t4; touch "$c/a/rates.fail"; rates_json "$c/b" 60 60; file_token
pick
chk "4a A の rates 失敗 → a" label_is a
chk "4b 理由 a-rates-failed・b は見ない" test "$(reason)" = a-rates-failed -a "$(calls "$c/b")" = 0

new_case t5; rates_json "$c/a" 50 50 '"weekly_sonnet":2'; rates_json "$c/b" 60 60 '"weekly_sonnet":60'; file_token
pick --model claude-sonnet-5
chk "5a weekly_sonnet だけ 2 → b(model が sonnet)" label_is b
pick --model claude-haiku-5-5
chk "5b 同じ状態でも model が haiku なら sonnet の枠は見ない → a" label_is a
pick
chk "5c model 無しは 5h と weekly だけ → a" label_is a

new_case t5o; rates_json "$c/a" 50 50 '"weekly_opus":1'; rates_json "$c/b" 60 60 '"weekly_opus":2'; file_token
pick --model claude-opus-5-5
chk "5d opus の枠が a・b とも線以下 → 75" label_is None 75

# ---- 2. B の token の出どころ ----
new_case t6; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60
pick
chk "6a b.token も .credentials.json も無い → b を選ばない(a が止める線 3 より上なので a)" label_is a
chk "6b 理由 b-no-token-stay-a" test "$(reason)" = b-no-token-stay-a

new_case t6c; rates_json "$c/a" 50 2; rates_json "$c/b" 60 60
pick
chk "6c 出どころが無く、A も止める線以下 → 75" label_is None 75

new_case t6d; rates_json "$c/a" 50 4; touch "$c/b/rates.fail"; file_token
pick
chk "6d B の rates 失敗 → b を選ばない(a が止める線より上なので a)" label_is a

new_case t7; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60; cred 28800
pick
chk "7a b.token 無し + 期限に余裕のある accessToken → b" label_is b
chk "7b 余裕があれば更新の rates は叩かない(quota の 1 回だけ)" test "$(calls "$c/b")" = 1

new_case t8; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60; cred 3600
# 本物の rates は期限の 60 秒前まで更新しない ── quota を読む 1 回目では更新されず、2 回目(b_token の更新の依頼)で更新される形にする
cat >"$c/b/refresh.sh" <<RSH
[ "\$(wc -l <"\$1/rates.calls")" -ge 2 ] || exit 0
python3 - "\$1/.credentials.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["claudeAiOauth"]["accessToken"] = "$NEW_TOKEN"
d["claudeAiOauth"]["expiresAt"] = int((time.time() + 28800) * 1000)
json.dump(d, open(p, "w"))
PY
RSH
pick
chk "8a 期限まで 1 時間(2 時間を切る)→ 先に rates を叩いて更新させ、b を選ぶ" label_is b
chk "8b rates は quota と更新で 2 回以上" test "$(calls "$c/b")" -ge 2
tok_len="$("$ACCT" exec b -- sh -c 'printf "%s:%s" "${#CLAUDE_CODE_OAUTH_TOKEN}" "${CLAUDE_CODE_OAUTH_TOKEN#sk-ant-oat01-}"' 2>/dev/null)"
chk "8c exec b は更新後の token を env に入れる" test "$tok_len" = "${#NEW_TOKEN}:REFRESHEDREFRESHEDREFRESHED"

new_case t9; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60; cred 3600
pick
chk "9a 期限が近く、rates を叩いても更新されない → b を選ばない(a のまま)" label_is a
chk "9b 理由 b-no-token-stay-a" test "$(reason)" = b-no-token-stay-a
new_case t9b; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60; cred -100
pick
chk "9c 期限切れで更新されない → b を選ばない" label_is a

# ---- 3. exec ----
new_case t10; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60; file_token
out="$("$ACCT" exec b -- sh -c 'printf "%s" "${#CLAUDE_CODE_OAUTH_TOKEN}"' 2>"$c/exec.err")"
chk "10a exec b: token(b.token の値)が子の env に入る" test "$out" = "${#FILE_TOKEN}"
out="$(CLAUDE_CODE_USER_EMAIL=a@example.com CLAUDE_CODE_ACCOUNT_UUID=uuid "$ACCT" exec b -- sh -c 'printf "%s|%s" "${CLAUDE_CODE_USER_EMAIL-unset}" "${CLAUDE_CODE_ACCOUNT_UUID-unset}"' 2>/dev/null)"
chk "10b 親の env に account 情報があっても b の子には渡らない" test "$out" = "unset|unset"
out="$(CLAUDE_CODE_USER_EMAIL=a@example.com "$ACCT" exec a -- sh -c 'printf "%s|%s" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "${CLAUDE_CODE_USER_EMAIL-unset}"' 2>/dev/null)"
chk "10c exec a は何も足さず何も消さない" test "$out" = "unset|a@example.com"
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK; do
  env "$v=dummy" "$ACCT" exec b -- true >"$c/blk.out" 2>"$c/blk.err"; rc=$?
  chk "10d $v が env にあれば exec b は止まる(exit 2・理由を出す)" bash -c '[ "$1" = 2 ] && grep -q "$2" "$3"' _ "$rc" "$v" "$c/blk.err"
done
ANTHROPIC_API_KEY=dummy "$ACCT" pick >"$c/pick.out" 2>"$c/pick.err"; echo $? >"$c/pick.rc"
chk "10e ANTHROPIC_API_KEY があれば pick も b を選ばない(a のまま・理由 b-blocked-by-env)" \
  test "$(label)" = a -a "$(reason)" = b-blocked-by-env-stay-a
rm -f "$c/b.token" "$c/b/.credentials.json"
"$ACCT" exec b -- true >/dev/null 2>"$c/none.err"; rc=$?
chk "10f token の出どころが無ければ exec b は exit 3" test "$rc" = 3
file_token
"$ACCT" exec b -- /nonexistent/cmd >/dev/null 2>"$c/nx.err"; rc=$?
chk "10g コマンドが無ければ exit 127" test "$rc" = 127

# stdin が子まで通る(makabe-stream.py が claude の標準入力を持つため)
got="$(printf 'hello\n' | "$ACCT" exec b -- sh -c 'read x; printf "%s" "$x"' 2>/dev/null)"
chk "11 exec は stdin をそのまま子に渡す" test "$got" = hello

# ---- 4. a の資格を書かない ----
new_case t12; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60; file_token
printf '{"claudeAiOauth":{"accessToken":"A-ACCESS"}}' >"$c/a/.credentials.json"; chmod 600 "$c/a/.credentials.json"
before="$(stat -c '%Y %s' "$c/a/.credentials.json"; sha256sum <"$c/a/.credentials.json")"
pick; "$ACCT" exec b -- true >/dev/null 2>&1; "$ACCT" exec a -- true >/dev/null 2>&1
after="$(stat -c '%Y %s' "$c/a/.credentials.json"; sha256sum <"$c/a/.credentials.json")"
chk "12 pick と exec の前後で a の .credentials.json は変わらない" test "$before" = "$after"

# ---- 5. disable / 線の env ----
new_case t13; rates_json "$c/a" 1 1; rates_json "$c/b" 60 60; file_token
CLAUDE_ACCT_DISABLE=1 "$ACCT" pick >"$c/pick.out" 2>"$c/pick.err"; echo $? >"$c/pick.rc"
chk "13a CLAUDE_ACCT_DISABLE=1 は常に a" label_is a
chk "13b その pick は rates を叩かない" test "$(calls "$c/a")" = 0

new_case t14; rates_json "$c/a" 8 50; rates_json "$c/b" 60 60; file_token
CLAUDE_ACCT_SWITCH_AT=10 "$ACCT" pick >"$c/pick.out" 2>"$c/pick.err"; echo $? >"$c/pick.rc"
chk "14 CLAUDE_ACCT_SWITCH_AT=10 なら A 8 で b" label_is b

# ---- 6. is-limit ----
new_case t15
cat >"$c/r1.json" <<'J'
{"type":"result","subtype":"success","is_error":true,"result":"You've hit your weekly limit · resets Oct 28, 1pm"}
J
cat >"$c/r2.json" <<'J'
{"type":"result","subtype":"error_during_execution","is_error":true,"result":"some other error"}
J
cat >"$c/r3.json" <<'J'
{"type":"result","subtype":"success","is_error":false,"result":"You've hit your session limit (this text is an answer)"}
J
cat >"$c/s_retry.jsonl" <<'J'
{"type":"system","subtype":"init"}
{"type":"system","subtype":"api_retry","attempt":1,"error":"rate_limit","error_status":429}
J
cat >"$c/s_other.jsonl" <<'J'
{"type":"system","subtype":"api_retry","attempt":1,"error":"server_error","error_status":500}
J
: >"$c/empty.json"
chk "15a is_error + 'hit your ... limit' → 枠切れ" "$ACCT" is-limit "$c/r1.json"
chk "15b is_error だが別の失敗 → 枠切れでない" bash -c '! "$0" is-limit "$1"' "$ACCT" "$c/r2.json"
chk "15c is_error=false なら本文に limit があっても枠切れでない" bash -c '! "$0" is-limit "$1"' "$ACCT" "$c/r3.json"
chk "15d is_error + stream の api_retry error=rate_limit → 枠切れ" "$ACCT" is-limit "$c/r2.json" "$c/s_retry.jsonl"
chk "15e is_error + api_retry が server_error → 枠切れでない" bash -c '! "$0" is-limit "$1" "$2"' "$ACCT" "$c/r2.json" "$c/s_other.jsonl"
chk "15f 空の last.json(result が来なかった)は枠切れと決めない" bash -c '! "$0" is-limit "$1"' "$ACCT" "$c/empty.json"

# ---- 7. token の値はどの出力にも現れない ----
leak=0
for t in "$FILE_TOKEN" "$CRED_TOKEN" "$NEW_TOKEN"; do
  if grep -rqF --include='pick.out' --include='pick.err' --include='exec.err' --include='blk.err' --include='blk.out' \
       --include='none.err' --include='nx.err' -e "$t" "$sbx"; then leak=1; fi
done
# 陽性対照: 同じ grep が、値の出ている b.token は拾う(検査が空振りでないこと)
chk "16a 検査の陽性対照(b.token を拾える)" grep -rqF --include='b.token' -e "$FILE_TOKEN" "$sbx"
chk "16 pick の stdout・stderr と exec のエラー文に token の値が出ない" test "$leak" = 0

# ---- 8. claude-kashiwagi への差し込み(偽 claude・実 git、ゲート 2 の「便に 1 回」の記録を含む)----
GAS="$core/scripts/git-as"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
cat >"$sbx/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${#CLAUDE_CODE_OAUTH_TOKEN}" >"${FAKE_SEEN:?}"
printf '{"type":"result","subtype":"success","session_id":"fake","is_error":false,"result":"APPROVE"}\n'
STUB
chmod +x "$sbx/bin/claude"
# kashiwagi <name> <a_5h> <a_weekly> <b_5h> <b_weekly> [args]: <sbx>/<name>/ に wt・batch・state。exit は $d/exit
kashiwagi() {
  local d="$sbx/$1"; local a5="$2" aw="$3" b5="$4" bw="$5"; shift 5
  mkdir -p "$d/ext" "$d/state" "$d/batch" "$d/acct-a" "$d/acct-b"
  git init -q -b main "$d/base"
  ( cd "$d/base" && echo base >README.md && git add -A && "$GAS" anno commit -q -m base && git worktree add -q -b impl/x "$d/wt" )
  echo FINDINGS >"$d/ext/findings.md"; : >"$d/batch/inbox"
  rates_json "$d/acct-a" "$a5" "$aw"; rates_json "$d/acct-b" "$b5" "$bw"
  printf '%s\n' "$FILE_TOKEN" >"$d/b.token"; chmod 600 "$d/b.token"
  ( cd "$d/ext" && env CODEX_AGENT_STATE_DIR="$d/state" NIEKAWA_INBOX="$d/batch/inbox" FAKE_SEEN="$d/seen.txt" \
      CLAUDE_ACCT_A_DIR="$d/acct-a" CLAUDE_ACCT_B_DIR="$d/acct-b" CLAUDE_ACCT_B_TOKEN_FILE="$d/b.token" \
      PATH="$sbx/bin:$PATH" bash "$core/scripts/claude-kashiwagi.sh" --no-loop -C "$d/wt" --log "$d/run.log" -f "$d/ext/findings.md" "$@" \
      >"$d/launcher.out" 2>"$d/launcher.err" </dev/null; echo $? >"$d/exit" )
  echo "$d"
}
exit_is() { [ "$(cat "$1/exit")" = "$2" ]; }
d="$(kashiwagi k-b 4 50 60 60)"
chk "17a kashiwagi: a が 4 → b で exit 0、claude は b の token を受ける" bash -c '[ "$(cat "$1/exit")" = 0 ] && [ "$(cat "$1/seen.txt")" = "$2" ]' _ "$d" "${#FILE_TOKEN}"
chk "17b footer に account: b" grep -qx 'account: b acct-b@example.com' "$d/launcher.out"
chk "17c その run の gates.tsv にゲート 2 の記録が 1 件" test "$(wc -l <"$d/batch/gates.tsv")" = 1
d="$(kashiwagi k-none 4 50 2 60)"
chk "17d kashiwagi: 両方尽きた → exit 75・claude は起動しない" bash -c '[ "$(cat "$1/exit")" = 75 ] && [ ! -e "$1/seen.txt" ]' _ "$d"
chk "17e 起動しなかったゲートは gates.tsv に残らない(便に 1 回を使い切らない)" bash -c '! [ -s "$1/batch/gates.tsv" ]' _ "$d"
d="$(kashiwagi k-dry 4 50 60 60 --dry-run)"
chk "17f --dry-run は pick の行と前置きを出して exit 0" bash -c '[ "$(cat "$1/exit")" = 0 ] && grep -q "command prefix: .*claude-acct.sh exec b --" "$1/launcher.out" && [ ! -e "$1/seen.txt" ]' _ "$d"
d="$(kashiwagi k-a 50 50 60 60)"
chk "17g a に余裕 → a・token は渡らない" bash -c '[ "$(cat "$1/exit")" = 0 ] && [ "$(cat "$1/seen.txt")" = 0 ]' _ "$d"
leak=0; grep -rqF --include='*.out' --include='*.err' --include='*.log' --include='*.json' --include='*.md' -e "$FILE_TOKEN" "$sbx"/k-* && leak=1
chk "17h kashiwagi の run_dir・log・stdout・stderr に token の値が無い" test "$leak" = 0

echo "---"; echo "$n tests, fail=$fail"
exit "$fail"
