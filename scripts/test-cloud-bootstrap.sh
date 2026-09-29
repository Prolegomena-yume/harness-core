#!/usr/bin/env bash
# cloud 起動処理・guard の test。母艦で走らせて、(A)母艦では何も起きない (D)母艦の SessionStart の出力が
# 変わらない を確かめ、(B)cloud を sandbox で模して起動処理が通る (C)guard が期待どおり止める を確かめる。
#   使い方: bash scripts/test-cloud-bootstrap.sh
#   env: TECH_MAIN(既定 ~/canonical/tech、settings の「前」= その HEAD)  TECH_NEW(既定 TECH_MAIN/.claude/worktrees/cloud-1、「後」)
# 実ネットワークには出ない(musearch の clone は sandbox の bare repo)。D は session-init.sh を実際に走らせる(Neon を読むので母艦だけ)。
set -uo pipefail
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TECH_MAIN="${TECH_MAIN:-$HOME/canonical/tech}"
TECH_NEW="${TECH_NEW:-$TECH_MAIN/.claude/worktrees/cloud-1}"
n=0; fail=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); echo "not ok $n - $1"; fail=1; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }
sbx="$(mktemp -d)"; trap 'rm -rf "$sbx"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

echo "# A. 母艦(CLAUDE_CODE_REMOTE 未設定)では何もしない"
mkdir -p "$sbx/homeA"
out="$(env -u CLAUDE_CODE_REMOTE HOME="$sbx/homeA" CLAUDE_PROJECT_DIR="$sbx/projA" bash "$core/hooks/cloud-bootstrap.sh" 2>"$sbx/errA")"; rc=$?
chk "A1 exit 0 / 標準出力も標準エラーも空" test "$rc" = 0 -a -z "$out" -a ! -s "$sbx/errA"
chk "A2 HOME に何も作らない" test -z "$(find "$sbx/homeA" -mindepth 1 | head -1)"
env -u CLAUDE_CODE_REMOTE bash "$core/scripts/cloud-pr.sh" tech x -t t >/dev/null 2>&1; rc=$?
chk "A3 cloud-pr は母艦で exit 2" test "$rc" = 2

echo "# B. cloud を sandbox で模す(HOME=sandbox、musearch は sandbox の bare repo)"
H="$sbx/homeB"; mkdir -p "$H" "$sbx/projB" "$sbx/src"
git -C "$sbx/src" init -q -b main && "$core/scripts/git-as" anno -C "$sbx/src" commit -q --allow-empty -m init
git clone -q --bare "$sbx/src" "$sbx/musearch.git"
runB() { env CLAUDE_CODE_REMOTE=true HOME="$H" CLAUDE_PROJECT_DIR="$sbx/projB" CLOUD_BIN_DIR="$sbx/bin" CLOUD_MUSEARCH_URL="$1" bash "$core/hooks/cloud-bootstrap.sh" 2>"$sbx/errB"; }
out="$(runB "file://$sbx/musearch.git")"; rc=$?
chk "B1 exit 0 / 標準出力は空(session-init の JSON を壊さない)" test "$rc" = 0 -a -z "$out"
chk "B2 git-as が PATH 側に張られ、動く" bash -c "'$sbx/bin/git-as' --help >/dev/null"
chk "B3 ~/canonical/tech が clone を指す" test "$(readlink "$H/canonical/tech")" = "$sbx/projB"
chk "B4 ~/.claude/agents に makabe / kashiwagi が張られ、読める" test -r "$H/.claude/agents/makabe.md" -a -r "$H/.claude/agents/kashiwagi.md"
chk "B5 musearch が ~/yumemism_repo/musearch に clone された" test -d "$H/yumemism_repo/musearch/.git"
sn1="$(cd "$H" && find . -printf '%p %l\n' | grep -v '\.cache' | sort | md5sum)"
runB "file://$sbx/musearch.git" >/dev/null; rc=$?
sn2="$(cd "$H" && find . -printf '%p %l\n' | grep -v '\.cache' | sort | md5sum)"
chk "B6 2 回目は冪等(exit 0、構成が同じ)" test "$rc" = 0 -a "$sn1" = "$sn2"
rm -rf "$H/yumemism_repo"; runB "file://$sbx/nonexistent.git" >/dev/null; rc=$?
chk "B7 clone が落ちても exit 0(cloud の起動を止めない)、記録に FAILED" bash -c "test $rc = 0 && grep -q 'musearch clone FAILED' '$H/.cache/harness-cloud/bootstrap.log'"
chk "B8 記録・標準エラーに資格情報の形(Basic / Bearer / user:pass@)が出ない" bash -c "! cat '$sbx/errB' '$H/.cache/harness-cloud/bootstrap.log' | grep -Eqi 'basic |bearer |://[^/ ]+:[^/ ]+@'"

echo "# C. guard"
AG="$core/scripts/hooks/cloud-agent-guard.sh"; SG="$core/scripts/hooks/cloud-subagent-guard.sh"
ag() { local remote="$1" json="$2"; if [ "$remote" = 1 ]; then env CLAUDE_CODE_REMOTE=true CLOUD_GATES_FILE="$sbx/gates.tsv" bash "$AG" <<<"$json" 2>/dev/null; else env -u CLAUDE_CODE_REMOTE CLOUD_GATES_FILE="$sbx/gates.tsv" bash "$AG" <<<"$json" 2>/dev/null; fi; echo $?; }
mk() { jq -nc --arg t "$1" --arg p "$2" '{tool_name:"Agent",tool_input:{subagent_type:$t,prompt:$p}}'; }
chk "C1 母艦で makabe → 止める" test "$(ag 0 "$(mk makabe 'x')")" = 2
chk "C2 母艦で kashiwagi → 止める" test "$(ag 0 "$(mk kashiwagi '便: t-1')")" = 2
chk "C3 母艦で anno / minase / general-purpose は素通り" test "$(ag 0 "$(mk anno x)")$(ag 0 "$(mk minase x)")$(ag 0 "$(mk general-purpose x)")" = 000
chk "C4 cloud で makabe は通る" test "$(ag 1 "$(mk makabe x)")" = 0
chk "C5 cloud の kashiwagi は 1 行目に便が無ければ止める" test "$(ag 1 "$(mk kashiwagi 'レビューして')")" = 2
chk "C6 cloud の kashiwagi は 1 回目通り、同じ便の 2 回目は止める、別の便は通る" test "$(ag 1 "$(mk kashiwagi $'便: cloud-1\n本文')")$(ag 1 "$(mk kashiwagi $'便: cloud-1\n本文')")$(ag 1 "$(mk kashiwagi $'便: cloud-2\n本文')")" = 020
sg() { local mode="$1" tool="$2" arg="$3" j; case "$tool" in Bash) j="$(jq -nc --arg c "$arg" '{tool_name:"Bash",tool_input:{command:$c}}')";; *) j="$(jq -nc --arg c "$arg" --arg t "$tool" '{tool_name:$t,tool_input:{file_path:$c}}')";; esac; env HOME="$H" bash "$SG" "$mode" <<<"$j" 2>/dev/null; echo $?; }
for c in 'git push origin x' 'cd a && git -C b push -f' 'git-as makabe push'; do chk "C7 makabe は push 不可: $c" test "$(sg makabe Bash "$c")" = 2; done
for c in 'git-as makabe commit -m x' 'npm test' 'ls > out.txt' 'git status'; do chk "C8 makabe は通常の作業を止めない: $c" test "$(sg makabe Bash "$c")" = 0; done
chk "C9 makabe の Write ~/.claude は止め、/tmp は通る" test "$(sg makabe Write "$H/.claude/x")$(sg makabe Write "/tmp/w/x")" = 20
mkdir -p "$H/.cache/harness-cloud"; echo "$sbx/wt" >"$H/.cache/harness-cloud/makabe-root"
chk "C10 makabe-root があれば配下だけ書ける(外は止める)" test "$(sg makabe Edit "$sbx/wt/a.ts")$(sg makabe Edit /var/lib/other/a.ts)" = 02
for c in 'rm -rf x' 'echo a > f' 'echo a >> f' 'cat x | tee f' 'sed -i s/a/b/ f' 'git commit -m x' 'git-as kashiwagi commit -m x' 'git checkout main' 'git push' 'cp a b' 'curl -X POST http://x' 'npm install'; do chk "C11 kashiwagi は書き込み不可: $c" test "$(sg kashiwagi Bash "$c")" = 2; done
for c in 'git diff --stat' 'git -C /x log --oneline -3' 'rg -n foo src' 'sed -n 1,5p f' 'cat f 2>/dev/null' 'ls 2>&1' 'npm test' 'echo "a > b"' 'curl -s https://git.yumemism.com/api/v1/version'; do chk "C12 kashiwagi は読み・検証を止めない: $c" test "$(sg kashiwagi Bash "$c")" = 0; done
chk "C13 kashiwagi の Edit / Write は止める" test "$(sg kashiwagi Edit /tmp/x)$(sg kashiwagi Write /tmp/x)" = 22

echo "# D. 母艦の SessionStart は前後で変わらない(session-init.sh を settings の command 文字列のまま実走)"
old="$(git -C "$TECH_MAIN" show HEAD:.claude/settings.json | jq -r '.hooks.SessionStart[0].hooks[0].command')"
new="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$TECH_NEW/.claude/settings.json")"
runD() { env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$TECH_MAIN" bash -c "$1" 2>"$sbx/errD.$2"; }
o1="$(runD "$old" old)"; r1=$?; o2="$(runD "$new" new)"; r2=$?
norm() { sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.+Z-]+//g'; }
same='[.hooks.SessionStart[0].hooks[1], .hooks.Stop, .hooks.PreToolUse[0], .autoMemoryDirectory, .outputStyle]'
chk "D1 command 文字列以外の SessionStart(session-install)・Stop・commit guard・autoMemoryDirectory・outputStyle が同じ" test "$(git -C "$TECH_MAIN" show HEAD:.claude/settings.json | jq -c "$same")" = "$(jq -c "$same" "$TECH_NEW/.claude/settings.json")"
chk "D2 exit code が同じ($r1 / $r2)" test "$r1" = "$r2"
chk "D3 標準出力が同じ(日時の揺れは除く、$(printf %s "$o1" | wc -c) バイト)" test -n "$o1" -a "$(printf %s "$o1" | norm)" = "$(printf %s "$o2" | norm)"
chk "D4 標準エラーが同じ" test "$(norm <"$sbx/errD.old")" = "$(norm <"$sbx/errD.new")"
tm() { local s e; s=$(date +%s%N); env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$TECH_MAIN" bash -c "$1" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }
so=0; sn=0; for _ in 1 2 3 4; do so=$((so+$(tm "$old"))); sn=$((sn+$(tm "$new"))); done
echo "# D5 所要(ms、交互 4 回平均): 前 $((so/4)) / 後 $((sn/4))  ※ session-init が Neon を読むので揺れる。差は誤差の範囲かを見る"
tn=$(date +%s%N); for _ in $(seq 1 20); do env -u CLAUDE_CODE_REMOTE bash -c 'if [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then :; fi; :'; done; te=$(date +%s%N)
echo "# D6 追加した if 節だけの所要: $(( (te-tn)/20000000 )) ms / 回(bash 起動込み。session-init は元から bash を起こす)"

echo "1..$n"; [ "$fail" = 0 ] && echo "ALL OK" || echo "FAILED"
exit "$fail"
