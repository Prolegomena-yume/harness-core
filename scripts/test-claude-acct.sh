#!/usr/bin/env bash
# claude-acct.sh(pick / exec / is-limit)の test。rates は偽物(CLAUDE_ACCT_RATES)、実ネットワーク・実 claude には出ない。
# 偽 rates は CLAUDE_CONFIG_DIR の下の rates.json をそのまま返す(rates.fail があれば失敗、refresh.sh があれば実行 = 更新の再現)。
# 呼ばれた回数は <dir>/rates.calls に残る。a・b の .credentials.json は中身が偽の秘密の文字列で、開かれず(mtime・sha 不変)どの出力にも現れないことを縛る。
# b は env の token ではなく CLAUDE_CONFIG_DIR=<b の dir> で渡す形(b の資格の更新は Claude Code 自身に任せる)。
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
unset CLAUDE_ACCT_DISABLE CLAUDE_CONFIG_DIR CLAUDE_ACCT_B_TOKEN_FILE ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_ACCT_SWITCH_AT CLAUDE_ACCT_STOP_AT \

SECRET="SECRET-IN-CRED-$(date +%s)-ZZZ"   # 資格ファイルの中身の代わり。出力に出てはいけない

# new_case <name>: a / b の設定ディレクトリを env に出す($c = そのケースの dir)。資格ファイルは中身が秘密の偽物(開かれないことを縛る)。
new_case() {
  c="$sbx/$1"; mkdir -p "$c/a" "$c/b"
  export CLAUDE_ACCT_A_DIR="$c/a" CLAUDE_ACCT_B_DIR="$c/b"
  printf '{"claudeAiOauth":{"accessToken":"%s-A","refreshToken":"%s-A"}}' "$SECRET" "$SECRET" >"$c/a/.credentials.json"
  printf '{"claudeAiOauth":{"accessToken":"%s-B","refreshToken":"%s-B"}}' "$SECRET" "$SECRET" >"$c/b/.credentials.json"
  chmod 600 "$c/a/.credentials.json" "$c/b/.credentials.json"
}
# rates_json <dir> <5h> <weekly> [extra '"key":val']
rates_json() {
  local d="$1" h="$2" w="$3" extra="${4:-}"
  printf '{"email":"%s@example.com","remaining":{"5h":%s,"weekly":%s,"monthly":null%s}}\n' "$(basename "$d")" "$h" "$w" "${extra:+,$extra}" >"$d/rates.json"
}
# pick [args...]: stdout を $c/pick.out、stderr を $c/pick.err、exit を $c/pick.rc
pick() { "$ACCT" pick "$@" >"$c/pick.out" 2>"$c/pick.err"; echo $? >"$c/pick.rc"; }
label() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["label"])' "$c/pick.out"; }
reason() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reason"])' "$c/pick.out"; }
label_is() { [ "$(label)" = "$1" ] && [ "$(cat "$c/pick.rc")" = "${2:-0}" ]; }
calls() { if [ -f "$1/rates.calls" ]; then wc -l <"$1/rates.calls"; else echo 0; fi; }

# ---- 1. 規則の表(rates は偽物) ----
new_case t1; rates_json "$c/a" 50 50; rates_json "$c/b" 60 60
pick --model claude-sonnet-5
chk "1a A 50 → a" label_is a
chk "1b A が線より上なら b の rates は叩かない" test "$(calls "$c/b")" = 0

new_case t2; rates_json "$c/a" 4 50; rates_json "$c/b" 60 60
pick --model claude-sonnet-5
chk "2a A 4(5h)・B 60 → b" label_is b
chk "2b 理由が a-below-switch-line" test "$(reason)" = a-below-switch-line

new_case t2w; rates_json "$c/a" 50 5; rates_json "$c/b" 60 60
pick
chk "2c 線ちょうど(weekly 5)は割った扱い → b" label_is b

new_case t3; rates_json "$c/a" 4 50; rates_json "$c/b" 2 60
pick --model claude-sonnet-5
chk "3a A 4・B 2 → exit 75(label null)" label_is None 75
chk "3b 理由 both-exhausted" test "$(reason)" = both-exhausted

new_case t3b; rates_json "$c/a" 4 50; rates_json "$c/b" 60 3
pick
chk "3c B の weekly がちょうど 3(止める線)→ 尽きた扱いで 75" label_is None 75

new_case t4; touch "$c/a/rates.fail"; rates_json "$c/b" 60 60
pick
chk "4a A の rates 失敗 → a" label_is a
chk "4b 理由 a-rates-failed・b は見ない" test "$(reason)" = a-rates-failed -a "$(calls "$c/b")" = 0

new_case t5; rates_json "$c/a" 50 50 '"weekly_sonnet":2'; rates_json "$c/b" 60 60 '"weekly_sonnet":60'
pick --model claude-sonnet-5
chk "5a weekly_sonnet だけ 2 → b(model が sonnet)" label_is b
pick --model claude-haiku-5-5
chk "5b 同じ状態でも model が haiku なら sonnet の枠は見ない → a" label_is a
pick
chk "5c model 無しは 5h と weekly だけ → a" label_is a

new_case t5o; rates_json "$c/a" 50 50 '"weekly_opus":1'; rates_json "$c/b" 60 60 '"weekly_opus":2'
pick --model claude-opus-5-5
chk "5d opus の枠が a・b とも線以下 → 75" label_is None 75

# ---- 2. b を選べる条件 = b の dir の rates が読めること(資格・期限の判定は持たない)----
new_case t6; rates_json "$c/a" 50 4; touch "$c/b/rates.fail"
pick
chk "6a B の rates が失敗 → b を選ばない(a が止める線 3 より上なので a)" label_is a
chk "6b 理由 b-rates-failed-stay-a" test "$(reason)" = b-rates-failed-stay-a

new_case t6c; rates_json "$c/a" 50 2; touch "$c/b/rates.fail"
pick
chk "6c B の rates が失敗で A も止める線以下 → 75" label_is None 75

new_case t7; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60; rm -f "$c/b/.credentials.json"
pick
chk "7a B の rates が読めれば b(資格ファイルの有無・期限は pick では見ない)" label_is b
chk "7b b の rates は 1 回だけ" test "$(calls "$c/b")" = 1

new_case t7b; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60
ANTHROPIC_API_KEY=dummy "$ACCT" pick >"$c/pick.out" 2>"$c/pick.err"; echo $? >"$c/pick.rc"
chk "7c ANTHROPIC_API_KEY が env にあれば b を選ばない(a のまま・理由 b-blocked-by-env)" \
  test "$(label)" = a -a "$(reason)" = b-blocked-by-env-stay-a

# ---- 3. exec ----
new_case t10; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60
out="$(CLAUDE_CODE_OAUTH_TOKEN=preset-token CLAUDE_CODE_USER_EMAIL=gui@example.com CLAUDE_CODE_ACCOUNT_UUID=u CLAUDE_CODE_ORGANIZATION_UUID=o \
  "$ACCT" exec b -- sh -c 'printf "%s|%s|%s|%s|%s" "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "${CLAUDE_CODE_USER_EMAIL-unset}" "${CLAUDE_CODE_ACCOUNT_UUID-unset}" "${CLAUDE_CODE_ORGANIZATION_UUID-unset}"' 2>"$c/exec.err")"
chk "10a exec b: 子の CLAUDE_CONFIG_DIR は b の dir・CLAUDE_CODE_OAUTH_TOKEN は無い・GUI 由来の account 情報も無い" test "$out" = "$c/b|unset|unset|unset|unset"
out="$(CLAUDE_CONFIG_DIR=/somewhere/else CLAUDE_CODE_OAUTH_TOKEN=preset-token CLAUDE_CODE_USER_EMAIL=gui@example.com \
  "$ACCT" exec a -- sh -c 'printf "%s|%s|%s" "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "${CLAUDE_CODE_USER_EMAIL-unset}"' 2>/dev/null)"
chk "10b exec a: CLAUDE_CONFIG_DIR だけ外し、ほかは足しも消しもしない" test "$out" = "unset|preset-token|gui@example.com"
out="$("$ACCT" exec a -- sh -c 'printf "%s" "${CLAUDE_CONFIG_DIR-unset}"' 2>/dev/null)"
chk "10c exec a: 元から無ければ無いまま" test "$out" = unset
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK; do
  env "$v=dummy" "$ACCT" exec b -- true >"$c/blk.out" 2>"$c/blk.err"; rc=$?
  chk "10d $v が env にあれば exec b は止まる(exit 2・理由を出す)" bash -c '[ "$1" = 2 ] && grep -q "$2" "$3"' _ "$rc" "$v" "$c/blk.err"
done
rm -f "$c/b/.credentials.json"
"$ACCT" exec b -- true >/dev/null 2>"$c/none.err"; rc=$?
chk "10e b の資格ファイルが無ければ exec b は exit 3" test "$rc" = 3
printf '{}' >"$c/b/.credentials.json"
"$ACCT" exec b -- /nonexistent/cmd >/dev/null 2>"$c/nx.err"; rc=$?
chk "10f コマンドが無ければ exit 127" test "$rc" = 127

# stdin が子まで通る(makabe-stream.py が claude の標準入力を持つため)
got="$(printf 'hello\n' | "$ACCT" exec b -- sh -c 'read x; printf "%s" "$x"' 2>/dev/null)"
chk "11 exec は stdin をそのまま子に渡す" test "$got" = hello

# ---- 4. a・b の資格を開かない・書かない ----
new_case t12; rates_json "$c/a" 50 4; rates_json "$c/b" 60 60
snap() { for x in a b; do stat -c '%Y %s' "$c/$x/.credentials.json"; sha256sum <"$c/$x/.credentials.json"; done; }
before="$(snap)"
pick; "$ACCT" exec b -- true >/dev/null 2>&1; "$ACCT" exec a -- true >/dev/null 2>&1
after="$(snap)"
chk "12 pick と exec の前後で a・b の .credentials.json は変わらない(rates は stub なので claude-acct が書いていないことの確認)" test "$before" = "$after"

# ---- 5. disable / 線の env ----
new_case t13; rates_json "$c/a" 1 1; rates_json "$c/b" 60 60
CLAUDE_ACCT_DISABLE=1 "$ACCT" pick >"$c/pick.out" 2>"$c/pick.err"; echo $? >"$c/pick.rc"
chk "13a CLAUDE_ACCT_DISABLE=1 は常に a" label_is a
chk "13b その pick は rates を叩かない" test "$(calls "$c/a")" = 0

new_case t14; rates_json "$c/a" 8 50; rates_json "$c/b" 60 60
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

# ---- 7. 資格ファイルの中身(偽の秘密)はどの出力にも現れない ----
leak=0
grep -rqF --include='pick.out' --include='pick.err' --include='exec.err' --include='blk.err' --include='blk.out' \
     --include='none.err' --include='nx.err' -e "$SECRET" "$sbx" && leak=1
# 陽性対照: 同じ grep が、秘密の入っている資格ファイルは拾う(検査が空振りでないこと)
chk "16a 検査の陽性対照(資格ファイルの秘密を拾える)" grep -rqF --include='.credentials.json' -e "$SECRET" "$sbx"
chk "16 pick の stdout・stderr と exec のエラー文に資格の中身が出ない" test "$leak" = 0

# ---- 8. claude-kashiwagi への差し込み(偽 claude・実 git、ゲート 2 の「便に 1 回」の記録を含む)----
GAS="$core/scripts/git-as"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
cat >"$sbx/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s' "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" >"${FAKE_SEEN:?}"
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
  printf '{"claudeAiOauth":{"accessToken":"%s"}}' "$SECRET" >"$d/acct-b/.credentials.json"; chmod 600 "$d/acct-b/.credentials.json"
  ( cd "$d/ext" && env CODEX_AGENT_STATE_DIR="$d/state" NIEKAWA_INBOX="$d/batch/inbox" FAKE_SEEN="$d/seen.txt" \
      CLAUDE_ACCT_A_DIR="$d/acct-a" CLAUDE_ACCT_B_DIR="$d/acct-b" \
      PATH="$sbx/bin:$PATH" bash "$core/scripts/claude-kashiwagi.sh" --no-loop -C "$d/wt" --log "$d/run.log" -f "$d/ext/findings.md" "$@" \
      >"$d/launcher.out" 2>"$d/launcher.err" </dev/null; echo $? >"$d/exit" )
  echo "$d"
}
exit_is() { [ "$(cat "$1/exit")" = "$2" ]; }
d="$(kashiwagi k-b 4 50 60 60)"
chk "17a kashiwagi: a が 4 → b で exit 0、claude は CLAUDE_CONFIG_DIR=b の dir・OAUTH_TOKEN 無しで起動する" bash -c '[ "$(cat "$1/exit")" = 0 ] && [ "$(cat "$1/seen.txt")" = "$1/acct-b|unset" ]' _ "$d"
chk "17b footer に account: b" grep -qx 'account: b acct-b@example.com' "$d/launcher.out"
chk "17c その run の gates.tsv にゲート 2 の記録が 1 件" test "$(wc -l <"$d/batch/gates.tsv")" = 1
d="$(kashiwagi k-none 4 50 2 60)"
chk "17d kashiwagi: 両方尽きた → exit 75・claude は起動しない" bash -c '[ "$(cat "$1/exit")" = 75 ] && [ ! -e "$1/seen.txt" ]' _ "$d"
chk "17e 起動しなかったゲートは gates.tsv に残らない(便に 1 回を使い切らない)" bash -c '! [ -s "$1/batch/gates.tsv" ]' _ "$d"
d="$(kashiwagi k-dry 4 50 60 60 --dry-run)"
chk "17f --dry-run は pick の行と前置きを出して exit 0" bash -c '[ "$(cat "$1/exit")" = 0 ] && grep -q "command prefix: .*claude-acct.sh exec b --" "$1/launcher.out" && [ ! -e "$1/seen.txt" ]' _ "$d"
d="$(kashiwagi k-a 50 50 60 60)"
chk "17g a に余裕 → a・CLAUDE_CONFIG_DIR も token も足されない" bash -c '[ "$(cat "$1/exit")" = 0 ] && [ "$(cat "$1/seen.txt")" = "unset|unset" ]' _ "$d"
leak=0; grep -rqF --include='*.out' --include='*.err' --include='*.log' --include='*.json' --include='*.md' --exclude='.credentials.json' -e "$SECRET" "$sbx"/k-* && leak=1
chk "17h kashiwagi の run_dir・log・stdout・stderr に資格の中身が無い" test "$leak" = 0

echo "---"; echo "$n tests, fail=$fail"
exit "$fail"
