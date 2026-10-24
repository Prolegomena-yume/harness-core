#!/usr/bin/env bash
# claude-makabe.sh の後処理(変更ファイル数・changed-files.txt・makabe_commit_sha の footer)の test。
# claude と rates は偽物(PATH の先頭に置く)、git は実物。実 Claude・実ネットワークには出ない。
# 起点は 2026-10-03 の事故 ── 起動時に作業木が汚れていて、run の中で全部 commit して clean に戻ると
# `comm -3` が post 側の空行に tab だけの行を作り、`${line:3}` が空キーになって bash が落ちた。
# 使い方: bash scripts/test-claude-makabe.sh
set -uo pipefail
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${CLAUDE_MAKABE_UNDER_TEST:-$core/scripts/claude-makabe.sh}"
GAS="$core/scripts/git-as"
n=0; fail=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); echo "not ok $n - $1"; fail=1; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

sbx="$(mktemp -d)"; trap 'rm -rf "$sbx"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$sbx/bin"
cat >"$sbx/bin/claude" <<'S'
#!/usr/bin/env bash
# 偽の claude -p(stream-json 入出力)。最初の発言を 1 行読み、cwd(= 作業ルート)で FAKE_CLAUDE_SCENARIO を実行して
# result 行を返し、標準入力が閉じる(EOF)まで待って終わる(本物と同じ終わり方)。
IFS= read -r _first
bash "$FAKE_CLAUDE_SCENARIO" >&2
printf '{"type":"system","subtype":"init","session_id":"fake-session"}\n'
printf '{"type":"result","subtype":"success","session_id":"fake-session","is_error":false,"result":"fake done"}\n'
cat >/dev/null
S
printf '#!/bin/sh\nexit 1\n' >"$sbx/bin/rates"
chmod +x "$sbx/bin/claude" "$sbx/bin/rates"
export PATH="$sbx/bin:$PATH"

# new_case <name>: <sbx>/<name>/{base,wt,ext,state} を作る。wt は base から git worktree で切った impl/x(前 run の commit 1 本つき)。
# ext は作業木の外(-f の置き場)。BRIEF は既定で ext に置く(作業木は clean)。
new_case() {
  local d="$sbx/$1"; mkdir -p "$d/ext" "$d/state"
  git init -q -b main "$d/base"
  ( cd "$d/base" && echo base >README.md && git add -A && "$GAS" anno commit -q -m base \
      && git worktree add -q -b impl/x "$d/wt" \
      && cd "$d/wt" && echo prev >prev.txt && echo keep >keep.txt && git add -A && "$GAS" anno commit -q -m prev )
  echo "RESUME(作業木の外)" >"$d/ext/RESUME.md"
  echo "BRIEF" >"$d/ext/BRIEF.md"
  echo "$d"
}

# run_case <dir> [brief]: 偽 claude の台本は <dir>/scenario.sh。-f は RESUME(作業木の外)と BRIEF(既定は作業木の外)。
# launcher の stdout/stderr を <dir>/launcher.{out,err}、exit を <dir>/exit に残す
run_case() {
  local d="$1" brief="${2:-$1/ext/BRIEF.md}"
  ( cd "$d/ext" && env CODEX_AGENT_STATE_DIR="$d/state" FAKE_CLAUDE_SCENARIO="$d/scenario.sh" \
      bash "$LAUNCHER" -C "$d/wt" --log "$d/run.log" -f "$d/ext/RESUME.md" -f "$brief" \
      >"$d/launcher.out" 2>"$d/launcher.err"; echo $? >"$d/exit" )
}
run_dir_of() { ls -d "$1"/state/runs/makabe-* | head -1; }
cf_of() { cat "$(run_dir_of "$1")/changed-files.txt" 2>/dev/null; }
# 期待する path 集合(引数)と changed-files.txt が、順序を問わず完全一致する(先頭の欠け・空行・引用符・" -> " が混ざれば不一致)
same_set() { local d="$1"; shift; diff <(cf_of "$d" | LC_ALL=C sort) <(printf '%s\n' "$@" | LC_ALL=C sort) >"$d/set.diff"; }
exit_is() { [ "$(cat "$1/exit")" = "$2" ]; }
count_is() { grep -qx "変更ファイル数: $2" "$1/launcher.out"; }
sha_is_head() { grep -qx "makabe_commit_sha: $(git -C "$1/wt" rev-parse HEAD)" "$1/launcher.out"; }
sha_none() { grep -qx 'makabe_commit_sha: (無し)' "$1/launcher.out"; }
no_bash_error() { ! grep -q '誤った配列の添字\|ソートされていません' "$1/launcher.err" "$1/launcher.out"; }
cf_empty() { [ ! -s "$(run_dir_of "$1")/changed-files.txt" ]; }
cf_no_arrow() { ! grep -q ' -> ' "$(run_dir_of "$1")/changed-files.txt"; }

# ---- 1. 2026-10-03 の事故の形: 起動時に汚れ(tracked 変更・untracked・日本語名・空白名・作業木の中の BRIEF)、
#         run の中で全部 commit して clean に戻る。-f は作業木の外の RESUME と作業木の中の BRIEF の 2 本 ----
d="$(new_case dirty-then-clean)"
echo "BRIEF(作業木の中、untracked)" >"$d/wt/BRIEF.md"
( cd "$d/wt" && echo more >>prev.txt && echo left >leftover.txt && echo jp >"日本語 ファイル.txt" )
cat >"$d/scenario.sh" <<S
echo hello >hello.txt
git add -A
$GAS anno commit -q -m "run commit"
S
run_case "$d" "$d/wt/BRIEF.md"
chk "1a 汚れ → clean(commit)で exit 0" exit_is "$d" 0
chk "1b bash の配列添字エラーが出ない" no_bash_error "$d"
chk "1c changed-files.txt が実 path の完全一致(先頭欠け・空行なし)" \
  same_set "$d" prev.txt leftover.txt "日本語 ファイル.txt" hello.txt BRIEF.md
chk "1d footer の変更ファイル数が 5" count_is "$d" 5
chk "1e makabe_commit_sha が wt の HEAD" sha_is_head "$d"

# ---- 2. 起動時 clean、run が untracked を残して commit しない(HEAD 不動)。1 文字名・空白名・日本語名・子ディレクトリ ----
d="$(new_case clean-then-untracked)"
cat >"$d/scenario.sh" <<'S'
echo a >a
echo b >"b c.txt"
echo j >"日本.txt"
mkdir -p sub && echo s >sub/x.md
S
run_case "$d"
chk "2a clean → untracked で exit 0" exit_is "$d" 0
chk "2b 生の path で残る(ずれ・引用符なし)" same_set "$d" a "b c.txt" "日本.txt" sub/x.md
chk "2c footer: 4 件" count_is "$d" 4
chk "2d footer: sha は (無し)" sha_none "$d"

# ---- 3. 改名(staged の git mv)は新旧両方を実 path で拾う。" -> " 入りの 1 本にならない ----
d="$(new_case rename)"
cat >"$d/scenario.sh" <<'S'
git mv keep.txt moved.txt
git mv prev.txt "改名 後.txt"
S
run_case "$d"
chk "3a 改名で exit 0" exit_is "$d" 0
chk "3b 新旧とも実 path" same_set "$d" keep.txt moved.txt prev.txt "改名 後.txt"
chk "3c ' -> ' が path に混ざらない" cf_no_arrow "$d"

# ---- 4. squash(reset --soft + commit)で HEAD が動き、作業木は clean ----
d="$(new_case squash)"
cat >"$d/scenario.sh" <<S
echo 1 >one.txt; git add -A; $GAS anno commit -q -m cp1
echo 2 >two.txt; git add -A; $GAS anno commit -q -m cp2
git reset -q --soft HEAD~2
$GAS anno commit -q -m squashed
S
run_case "$d"
chk "4a squash で exit 0" exit_is "$d" 0
chk "4b HEAD 差分の path(one.txt two.txt)" same_set "$d" one.txt two.txt
chk "4c sha は HEAD" sha_is_head "$d"

# ---- 5. 何も変わらない: 0 件・空の changed-files.txt・(無し) ----
d="$(new_case nothing)"
: >"$d/scenario.sh"
run_case "$d"
chk "5a 何も無しで exit 0" exit_is "$d" 0
chk "5b 0 件" count_is "$d" 0
chk "5c changed-files.txt は空" cf_empty "$d"
chk "5d sha は (無し)" sha_none "$d"

# ---- 6. 汚れが run の後も残る(一部だけ commit) ----
d="$(new_case partial)"
( cd "$d/wt" && echo more >>prev.txt && echo left >leftover.txt )
cat >"$d/scenario.sh" <<S
echo n >new.txt
git add new.txt prev.txt
$GAS anno commit -q -m partial
echo late >late.txt
S
run_case "$d"
chk "6a 一部だけ commit で exit 0" exit_is "$d" 0
chk "6b prev.txt(pre 汚れ→commit)・new.txt(HEAD 差分)・late.txt(post 側だけ)。leftover.txt は pre・post とも同じで差なし" \
  same_set "$d" prev.txt new.txt late.txt

# ================================================================================================
# 案 A / 案 C(役員 人見 2026-10-03 の裁定): main/master の ref 変化は、launcher が真壁に与える committer 名義
# (launcher の GIT_COMMITTER_EMAIL)の reflog エントリがあるときだけ逸脱(exit 3)。別名義(別窓の鷹野・人見)の
# 移動は警告 1 行で exit 0。reflog が無い・pre が見つからないときは従来どおり「変化 = 逸脱」。
# 作業木の HEAD が main / master のとき起動を断る(kimi-makabe.sh と同じ)。
# ================================================================================================
other_env='GIT_COMMITTER_NAME=other GIT_COMMITTER_EMAIL=other@example.test GIT_AUTHOR_NAME=other GIT_AUTHOR_EMAIL=other@example.test'
warned() { grep -q "警告.*$2" "$1/launcher.err"; }
no_violation() { ! grep -q '権限逸脱' "$1/launcher.out"; }
has_violation() { grep -q '権限逸脱' "$1/launcher.out" && grep -q "ref 変化を検出: $2" "$1/launcher.out"; }
has_footer() { grep -q '^変更ファイル数: ' "$1/launcher.out" && grep -q '^makabe_commit_sha: ' "$1/launcher.out"; }
warn_lines_is() { [ "$(grep -c '警告.*refs/heads' "$1/launcher.err")" = "$2" ]; }

# ---- 7. 別名義が main に commit(別窓の鷹野の merge に当たる)→ exit 0 + 警告、footer は通常どおり ----
d="$(new_case a-foreign-main)"
cat >"$d/scenario.sh" <<S
echo hello >hello.txt
git add -A
$GAS anno commit -q -m "run commit"
env $other_env git -C "$d/base" commit -q --allow-empty -m "other window"
S
run_case "$d"
chk "7a 別名義の main の commit は exit 0" exit_is "$d" 0
chk "7b 警告 1 行(refs/heads/main)が stderr に出る" warned "$d" 'refs/heads/main'
chk "7c 権限逸脱を出さない" no_violation "$d"
chk "7d footer(変更ファイル数・makabe_commit_sha)が出る" has_footer "$d"
chk "7e 警告は 1 行だけ" warn_lines_is "$d" 1

# ---- 8. 真壁名義が main を動かす → exit 3 ----
d="$(new_case a-makabe-main)"
cat >"$d/scenario.sh" <<S
git -C "$d/base" commit -q --allow-empty -m "makabe moves main"
S
run_case "$d"
chk "8a 真壁名義の main の移動は exit 3" exit_is "$d" 3
chk "8b 権限逸脱: ref 変化を検出: refs/heads/main" has_violation "$d" refs/heads/main
chk "8c footer は出る" has_footer "$d"

# ---- 9. reflog が積まれない repo(core.logAllRefUpdates=false)→ 従来どおり「変化 = 逸脱」(別名義でも exit 3) ----
d="$(new_case a-no-reflog)"
git -C "$d/base" config core.logAllRefUpdates false
rm -f "$d/base/.git/logs/refs/heads/main"   # 既にある reflog には false でも追記されるので、無い状態にして始める
cat >"$d/scenario.sh" <<S
env $other_env git -C "$d/base" commit -q --allow-empty -m "other window"
S
run_case "$d"
chk "9a reflog が積まれない repo は従来どおり exit 3" exit_is "$d" 3
chk "9b 権限逸脱の表示" has_violation "$d" refs/heads/main

# ---- 10. reflog が run の間に消える(期限切れの代わり)→ pre が見つからず従来どおり exit 3 ----
d="$(new_case a-reflog-gone)"
cat >"$d/scenario.sh" <<S
rm -f "$d/base/.git/logs/refs/heads/main"
env $other_env git -C "$d/base" commit -q --allow-empty -m "other window"
S
run_case "$d"
chk "10a reflog が切り詰められたら従来どおり exit 3" exit_is "$d" 3
chk "10b 権限逸脱の表示" has_violation "$d" refs/heads/main

# ---- 11. 別窓の commit と真壁の移動が同じ run で混ざる → 真壁分が reflog にあるので exit 3 ----
d="$(new_case a-mixed)"
cat >"$d/scenario.sh" <<S
env $other_env git -C "$d/base" commit -q --allow-empty -m "other window 1"
git -C "$d/base" commit -q --allow-empty -m "makabe moves main"
env $other_env git -C "$d/base" commit -q --allow-empty -m "other window 2"
S
run_case "$d"
chk "11a 混ざっても真壁分があれば exit 3" exit_is "$d" 3
chk "11b 権限逸脱の表示" has_violation "$d" refs/heads/main

# ---- 12. master も同じ: 別名義の master 移動は exit 0 + 警告、真壁名義は exit 3 ----
d="$(new_case a-foreign-master)"
git -C "$d/base" branch master
"$GAS" anno -C "$d/base" commit -q --allow-empty -m ahead
cat >"$d/scenario.sh" <<S
env $other_env git -C "$d/base" update-ref refs/heads/master "\$(git -C "$d/base" rev-parse main)"
S
run_case "$d"
chk "12a 別名義の master の移動は exit 0" exit_is "$d" 0
chk "12b 警告(refs/heads/master)" warned "$d" 'refs/heads/master'
d="$(new_case a-makabe-master)"
git -C "$d/base" branch master
"$GAS" anno -C "$d/base" commit -q --allow-empty -m ahead
cat >"$d/scenario.sh" <<S
git -C "$d/base" update-ref refs/heads/master "\$(git -C "$d/base" rev-parse main)"
S
run_case "$d"
chk "12c 真壁名義の master の移動は exit 3" exit_is "$d" 3
chk "12d 権限逸脱: refs/heads/master" has_violation "$d" refs/heads/master

# ---- 13. 何も動かない run は警告も逸脱も無し ----
d="$(new_case a-quiet)"
: >"$d/scenario.sh"
run_case "$d"
chk "13a exit 0" exit_is "$d" 0
chk "13b 警告なし" warn_lines_is "$d" 0

# ---- 14(案 C). 作業木の HEAD が main / master のとき起動を断る(--dry-run でも)。detached・作業 branch は通る ----
mkrepo() { git init -q -b "$2" "$sbx/$1" && ( cd "$sbx/$1" && echo r >r && git add -A && "$GAS" anno commit -q -m init ); }
launch() { # <dir> [args...] ── stdout/err を $sbx/c.out / c.err、exit を $sbx/c.exit に
  local dir="$1"; shift
  ( cd "$sbx/ext-c" && env CODEX_AGENT_STATE_DIR="$sbx/c-state" FAKE_CLAUDE_SCENARIO=/dev/null \
      bash "$LAUNCHER" -C "$dir" -f "$sbx/ext-c/BRIEF.md" "$@" >"$sbx/c.out" 2>"$sbx/c.err"; echo $? >"$sbx/c.exit" )
}
exit_c_is() { [ "$(cat "$sbx/c.exit")" = "$1" ]; }
mkdir -p "$sbx/ext-c" "$sbx/c-state"; echo BRIEF >"$sbx/ext-c/BRIEF.md"
mkrepo c-main main; mkrepo c-master master
launch "$sbx/c-main"
chk "14a HEAD が main の作業木は exit 2" exit_c_is 2
chk "14b 文言は kimi-makabe と同じ(作業ルートが main の上にある)" grep -q '作業ルートが main の上にある' "$sbx/c.err"
chk "14c 断った run は claude を起動していない(last.json が無い)" test -z "$(ls "$sbx"/c-state/runs/*/last.json 2>/dev/null)"
launch "$sbx/c-main" --dry-run
chk "14d --dry-run でも断る(exit 2)" exit_c_is 2
launch "$sbx/c-master" --dry-run
chk "14e HEAD が master も断る" exit_c_is 2
git -C "$sbx/c-main" switch -q -c work/y
launch "$sbx/c-main" --dry-run
chk "14f 作業 branch は --dry-run が通る" exit_c_is 0
git -C "$sbx/c-main" checkout -q --detach
launch "$sbx/c-main" --dry-run
chk "14g detached HEAD は kimi-makabe と同じく通る" exit_c_is 0

# ---- 15. Claude Max 2 枚の選択(claude-acct.sh、親ゴール: a の枠が尽きても人見の手なしで b で起きる)----
# 偽 rates は CLAUDE_CONFIG_DIR の下の rates.json を返す。偽 claude が見た CLAUDE_CODE_OAUTH_TOKEN・_B・CLAUDE_CONFIG_DIR・account 情報を $FAKE_SEEN に書く。b は B の 1 年 token(偽 ymos の secret CLAUDE_CODE_OAUTH_TOKEN_B)を CLAUDE_CODE_OAUTH_TOKEN で受ける。
cat >"$sbx/bin/rates-acct" <<'S'
#!/usr/bin/env bash
cat "${CLAUDE_CONFIG_DIR:?}/rates.json"
S
chmod +x "$sbx/bin/rates-acct"
ACCT_SECRET="sk-ant-oat01-$(printf 'L%.0s' $(seq 1 80))"   # 偽の B の token(偽 ymos の store の中身)。run_dir・log・stdout・stderr に出てはいけない
cat >"$sbx/bin/ymos" <<'S'
#!/usr/bin/env bash
# 偽の ymos: `ymos secret exec -n NAME -- cmd...` を $YMOS_STORE/NAME の中身を env に入れて子として動かす
[ "$1 $2 $3" = "secret exec -n" ] || exit 64
name="$4"; shift 5; [ "$1" = "--" ] && shift
[ -f "${YMOS_STORE:?}/$name" ] || { echo "ymos: secret.not_found" >&2; exit 66; }
export "$name=$(cat "$YMOS_STORE/$name")"
"$@" <&0 &
wait $!
S
chmod +x "$sbx/bin/ymos"
acct_rates() { printf '{"email":"%s","remaining":{"5h":%s,"weekly":%s,"monthly":null}}\n' "$2" "$3" "$4" >"$1/rates.json"; }
# run_acct <name> <a_5h> <a_weekly> <b_5h> <b_weekly> [launcher args...]
run_acct() {
  local d; d="$(new_case "$1")"; local a5="$2" aw="$3" b5="$4" bw="$5"; shift 5
  mkdir -p "$d/acct-a" "$d/acct-b"; acct_rates "$d/acct-a" a@example.com "$a5" "$aw"; acct_rates "$d/acct-b" b@example.com "$b5" "$bw"
  mkdir -p "$d/ymos-store"; printf '%s\n' "$ACCT_SECRET" >"$d/ymos-store/CLAUDE_CODE_OAUTH_TOKEN_B"
  cat >"$d/scenario.sh" <<SC
printf '%s|%s|%s|%s' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}" "\${CLAUDE_CODE_OAUTH_TOKEN_B-unset}" "\${CLAUDE_CONFIG_DIR-unset}" "\${CLAUDE_CODE_USER_EMAIL-unset}" >"$d/seen.txt"
SC
  ( cd "$d/ext" && env CODEX_AGENT_STATE_DIR="$d/state" FAKE_CLAUDE_SCENARIO="$d/scenario.sh" CLAUDE_CODE_USER_EMAIL=gui@example.com \
      CLAUDE_ACCT_RATES="$sbx/bin/rates-acct" CLAUDE_ACCT_A_DIR="$d/acct-a" CLAUDE_ACCT_B_DIR="$d/acct-b" CLAUDE_ACCT_YMOS="$sbx/bin/ymos" YMOS_STORE="$d/ymos-store" \
      bash "$LAUNCHER" -C "$d/wt" --log "$d/run.log" -f "$d/ext/BRIEF.md" "$@" >"$d/launcher.out" 2>"$d/launcher.err"; echo $? >"$d/exit" )
  echo "$d"
}
acct_json() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/account.json"))[sys.argv[2]])' "$(run_dir_of "$1")" "$2"; }
no_token_in_run() { local f=("$(run_dir_of "$1")"); for x in run.log launcher.out launcher.err; do [ -e "$1/$x" ] && f+=("$1/$x"); done; ! grep -rqF -- "$ACCT_SECRET" "${f[@]}"; }

d="$(run_acct acct-a-ok 50 50 60 60)"
chk "15a a に余裕 → a で exit 0" exit_is "$d" 0
chk "15b account.json は label a・rates.json は a の dir の値" test "$(acct_json "$d" label)" = a -a "$(grep -c a@example.com "$(run_dir_of "$d")/rates.json")" = 1
chk "15c 偽 claude に token も CLAUDE_CONFIG_DIR も足されない(a は何も足さず、account 情報もそのまま)" test "$(cat "$d/seen.txt")" = "unset|unset|unset|gui@example.com"
chk "15d footer に account: a a@example.com" grep -qx 'account: a a@example.com' "$d/launcher.out"

d="$(run_acct acct-b 4 50 60 60)"
chk "15e a の 5h が 4 → b で exit 0" exit_is "$d" 0
chk "15f account.json は label b、rates.json は b の dir の値" test "$(acct_json "$d" label)" = b -a "$(grep -c b@example.com "$(run_dir_of "$d")/rates.json")" = 1
chk "15g 偽 claude は B の token を CLAUDE_CODE_OAUTH_TOKEN で受け、_B・CLAUDE_CONFIG_DIR・GUI の account 情報は持ち込まれない" test "$(cat "$d/seen.txt")" = "$ACCT_SECRET|unset|unset|unset"
chk "15h footer に account: b b@example.com" grep -qx 'account: b b@example.com' "$d/launcher.out"
chk "15i B の token の値は run_dir・log・stdout・stderr のどこにも無い" no_token_in_run "$d"

d="$(run_acct acct-none 4 50 2 60)"
chk "15j 両方尽きた → 起動せず exit 75" exit_is "$d" 75
chk "15k 枠切れの行が出て、claude は起動していない" bash -c 'grep -q "^枠切れ: 両方尽きた" "$1/launcher.out" && [ ! -e "$2/last.json" ] && [ ! -e "$1/seen.txt" ]' _ "$d" "$(run_dir_of "$d")"
chk "15l account.json は label null・reason both-exhausted" test "$(acct_json "$d" label)" = None -a "$(acct_json "$d" reason)" = both-exhausted

d="$(run_acct acct-dry 4 50 60 60 --dry-run)"
chk "15m --dry-run は pick の結果とコマンド前置きを出して exit 0・claude は起動しない" bash -c 'grep -q "account: b b@example.com" "$1/launcher.out" && grep -q "command prefix: .*claude-acct.sh exec b --" "$1/launcher.out" && [ ! -e "$1/seen.txt" ]' _ "$d"
chk "15n --dry-run で exit 0" exit_is "$d" 0
chk "15o dry-run の出力にも token の値は無い" no_token_in_run "$d"
d="$(run_acct acct-dry-none 4 50 2 60 --dry-run)"
chk "15p 両方尽きでも --dry-run は結果を出して exit 0" exit_is "$d" 0

echo "---"; echo "$n tests, fail=$fail"
if [ "$fail" -eq 0 ]; then echo "ALL OK"; else
  echo "FAILED"; for f in "$sbx"/*/set.diff; do [ -s "$f" ] && { echo "== $f"; cat "$f"; }; done; exit 1
fi
