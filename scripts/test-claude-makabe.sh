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
# 偽の claude -p。cwd(= 作業ルート)で FAKE_CLAUDE_SCENARIO を実行して JSON を返すだけ。
bash "$FAKE_CLAUDE_SCENARIO" >&2
printf '{"session_id":"fake-session","is_error":false,"result":"fake done"}'
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

echo "---"; echo "$n tests, fail=$fail"
if [ "$fail" -eq 0 ]; then echo "ALL OK"; else
  echo "FAILED"; for f in "$sbx"/*/set.diff; do [ -s "$f" ] && { echo "== $f"; cat "$f"; }; done; exit 1
fi
