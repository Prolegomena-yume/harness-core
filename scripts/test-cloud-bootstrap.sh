#!/usr/bin/env bash
# cloud 起動処理・guard の test。母艦で走らせて、(A)母艦では何も起きない (D)母艦の SessionStart の出力が
# 変わらない を確かめ、(B)cloud を sandbox で模して起動処理が通る (C)guard が期待どおり止める を確かめる。
#   使い方: bash scripts/test-cloud-bootstrap.sh
#   env: TECH_MAIN(既定 ~/canonical/tech、settings の「前」= その HEAD)  TECH_NEW(既定 TECH_MAIN/.claude/worktrees/cloud-3、「後」)
# 実ネットワークには出ない(musearch・yumemi・ymos の clone は sandbox の bare repo、npm は偽物)。D は session-init.sh を実際に走らせる(Neon を読むので母艦だけ)。
set -uo pipefail
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TECH_MAIN="${TECH_MAIN:-$HOME/canonical/tech}"
TECH_NEW="${TECH_NEW:-$TECH_MAIN/.claude/worktrees/cloud-3}"
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

mkdir -p "$sbx/binA"
env -u CLAUDE_CODE_REMOTE HOME="$sbx/homeA" CLOUD_BIN_DIR="$sbx/binA" CLOUD_SETUP_SKIP_TOOLS=1 CLOUD_SETUP_SETTINGS="$sbx/homeA-settings.json" CLOUD_YMOS_URL="file:///nonexistent" bash "$core/cloud/setup.sh" >/dev/null 2>&1
chk "A4 母艦(CLAUDE_CODE_REMOTE 未設定)で setup.sh を走らせても ymos の clone も wrapper も作らない(~/yumemism_repo・bin が空)" test ! -e "$sbx/homeA/yumemism_repo" -a -z "$(ls -A "$sbx/binA")"

echo "# B. cloud を sandbox で模す(HOME=sandbox、musearch は sandbox の bare repo)"
H="$sbx/homeB"; mkdir -p "$H" "$sbx/src" "$sbx/kei"
git -C "$sbx/src" init -q -b main; mkdir -p "$sbx/src/.claude/memory"; echo "- [t](t.md) — tech memory" >"$sbx/src/.claude/memory/MEMORY.md"; git -C "$sbx/src" add -A
"$core/scripts/git-as" anno -C "$sbx/src" commit -q -m init
git -C "$sbx/kei" init -q -b main; mkdir -p "$sbx/kei/.claude/memory"; echo "- [k](k.md) — keiei memory" >"$sbx/kei/.claude/memory/MEMORY.md"; git -C "$sbx/kei" add -A
"$core/scripts/git-as" anno -C "$sbx/kei" commit -q -m init
git clone -q "$sbx/src" "$sbx/projB"
git clone -q --bare "$sbx/src" "$sbx/musearch.git"
# ymos: sandbox の bare repo(cli/ に package.json と lock)と偽の npm(ci は記録、run build は dist/index.js を作る)
mkdir -p "$sbx/ymos-src/cli" "$sbx/fakenpm"
git -C "$sbx/ymos-src" init -q -b main
echo '{"name":"ymos-cli","scripts":{"build":"x"}}' >"$sbx/ymos-src/cli/package.json"; echo '{"lockfileVersion":3}' >"$sbx/ymos-src/cli/package-lock.json"
git -C "$sbx/ymos-src" add -A; "$core/scripts/git-as" anno -C "$sbx/ymos-src" commit -q -m init
git clone -q --bare "$sbx/ymos-src" "$sbx/ymos.git"
cat >"$sbx/fakenpm/npm" <<'EOS'
#!/usr/bin/env bash
echo "npm $* (cwd=$PWD)" >>"$FAKE_NPM_LOG"
[ "${FAKE_NPM_FAIL:-}" = 1 ] && exit 1
if [ "$1" = run ] && [ "$2" = build ]; then
  mkdir -p dist; echo 'console.log(JSON.stringify({cred: process.env.YMOS_CREDENTIAL, args: process.argv.slice(2)}))' >dist/index.js
fi
exit 0
EOS
chmod +x "$sbx/fakenpm/npm"; export FAKE_NPM_LOG="$sbx/npm.log"; : >"$FAKE_NPM_LOG"
runB() { env CLAUDE_CODE_REMOTE=true PATH="$sbx/fakenpm:$PATH" CLOUD_YMOS_URL="file://$sbx/ymos.git" HOME="$H" CLAUDE_PROJECT_DIR="$sbx/projB" CLOUD_BIN_DIR="$sbx/bin" CLOUD_MUSEARCH_URL="$1" CLOUD_KEIEI_URL="$sbx/kei" CLOUD_YUMEMI_URL="file://$sbx/musearch.git" CLOUD_SETUP_SKIP_TOOLS=1 MEMSYNC_URL="$sbx/src" bash "$core/hooks/cloud-bootstrap.sh" 2>"$sbx/errB"; }
out="$(runB "file://$sbx/musearch.git")"; rc=$?
chk "B1 exit 0 / 標準出力は空(session-init の JSON を壊さない)" test "$rc" = 0 -a -z "$out"
chk "B1b bootstrap-done の印が置かれた(注入 hook が待つ印)" test -e "$H/.cache/harness-cloud/bootstrap-done"
chk "B2 git-as が PATH 側に張られ、動く" bash -c "'$sbx/bin/git-as' --help >/dev/null"
chk "B3 ~/canonical/tech が clone を指す" test "$(readlink "$H/canonical/tech")" = "$sbx/projB"
chk "B4 ~/.claude/agents に makabe / kashiwagi が張られ、読める" test -r "$H/.claude/agents/makabe.md" -a -r "$H/.claude/agents/kashiwagi.md"
chk "B5 musearch が ~/yumemism_repo/musearch に clone された" test -d "$H/yumemism_repo/musearch/.git"
chk "B5b keiei が ~/canonical/keiei に clone され、MEMORY.md がある" test -r "$H/canonical/keiei/.claude/memory/MEMORY.md"
chk "B5c memory 同期の起点 refs/memory-sync/base が clone に置かれ、同期が走った(前景 stamp)" bash -c "git -C '$sbx/projB' rev-parse -q --verify refs/memory-sync/base >/dev/null && test -e '$H/.cache/harness-memory-sync/last-run'"
chk "B5d yumemi が ~/yumemism_repo/yumemi に clone された" test -d "$H/yumemism_repo/yumemi/.git"
chk "B5e ~/.claude/settings.json の autoMode.environment が \$defaults と自社の source control を持つ" \
  bash -c "jq -e '.autoMode.environment[0] == \"\$defaults\" and any(.autoMode.environment[]; test(\"git.yumemism.com\"))' '$H/.claude/settings.json' >/dev/null"
chk "B5f ymos が ~/yumemism_repo/yumemism-os に clone され、cli/ が npm ci → build され、PATH 側に wrapper がある" \
  bash -c "test -d '$H/yumemism_repo/yumemism-os/.git' && grep -q 'npm ci' '$FAKE_NPM_LOG' && grep -q 'npm run build' '$FAKE_NPM_LOG' && test -x '$sbx/bin/ymos'"
chk "B5g ymos wrapper は YMOS_CREDENTIAL=proxy を export して dist/index.js に引数をそのまま渡す" \
  test "$("$sbx/bin/ymos" discord takano post s x)" = '{"cred":"proxy","args":["discord","takano","post","s","x"]}'
chk "B5g2 wrapper は NODE_USE_ENV_PROXY=1 を立て、UNDICI-EHPA の警告だけを消し(--no-warnings にしない)、NODE_OPTIONS は触らない" \
  bash -c "grep -q '^export NODE_USE_ENV_PROXY=1\$' '$sbx/bin/ymos' && grep -q -- '--disable-warning=UNDICI-EHPA' '$sbx/bin/ymos' && ! grep -v '^#' '$sbx/bin/ymos' | grep -q -e '--no-warnings' -e NODE_OPTIONS"
chk "B5g3 wrapper 越しに NODE_USE_ENV_PROXY=1 が node の環境に届き、母艦の node で --disable-warning=UNDICI-EHPA が通る" \
  bash -c "printf 'console.log(process.env.NODE_USE_ENV_PROXY)' >'$H/yumemism_repo/yumemism-os/cli/dist/index.js' && test \"\$('$sbx/bin/ymos')\" = 1 && node --disable-warning=UNDICI-EHPA -e 0 2>&1 | wc -c | grep -qx 0"
chk "B5g4 古い wrapper(NODE_USE_ENV_PROXY 無し)があっても、build の印が一致したままの次回で書き直される" \
  bash -c "printf '#!/bin/sh\\nexit 9\\n' >'$sbx/bin/ymos' && env CLAUDE_CODE_REMOTE=true PATH='$sbx/fakenpm:$PATH' CLOUD_YMOS_URL='file://$sbx/ymos.git' CLOUD_BIN_DIR='$sbx/bin' HOME='$H' CLOUD_SETUP_SKIP_TOOLS=1 CLOUD_SETUP_SETTINGS='$sbx/h3.json' bash '$core/cloud/setup.sh' >/dev/null 2>&1; grep -q NODE_USE_ENV_PROXY '$sbx/bin/ymos' && test \$(grep -c 'npm ci' '$FAKE_NPM_LOG') = 1"
chk "B5h autoMode.environment に ymos の 1 行(dispatch.yumemism.com・proxy)がある" \
  bash -c "jq -e 'any(.autoMode.environment[]; test(\"ymos\") and test(\"dispatch.yumemism.com\") and test(\"proxy\"))' '$H/.claude/settings.json' >/dev/null"
sn1="$(cd "$H" && find . -printf '%p %l\n' | grep -v -e '\.cache' -e 'FETCH_HEAD' -e 'ORIG_HEAD' | sort | md5sum)"
runB "file://$sbx/musearch.git" >/dev/null; rc=$?
sn2="$(cd "$H" && find . -printf '%p %l\n' | grep -v -e '\.cache' -e 'FETCH_HEAD' -e 'ORIG_HEAD' | sort | md5sum)"
chk "B6 2 回目は冪等(exit 0、構成が同じ)" test "$rc" = 0 -a "$sn1" = "$sn2"
chk "B6b 2 回目は同じ rev なので npm ci / build を走らせない(印 .git/cloud-built-rev で抜ける)" test "$(grep -c 'npm ci' "$FAKE_NPM_LOG")" = 1
"$core/scripts/git-as" anno -C "$sbx/ymos-src" commit -q --allow-empty -m next; git -C "$sbx/ymos-src" push -q "$sbx/ymos.git" main 2>/dev/null
runB "file://$sbx/musearch.git" >/dev/null
chk "B6c 取り先が進んだら pull して build し直す(npm ci 2 回目、印が新しい rev)" test "$(grep -c 'npm ci' "$FAKE_NPM_LOG")" = 2 -a "$(cat "$H/yumemism_repo/yumemism-os/.git/cloud-built-rev")" = "$(git -C "$sbx/ymos.git" rev-parse main)"
rm -rf "$H/yumemism_repo" "$sbx/bin/ymos"; FAKE_NPM_FAIL=1 runB "file://$sbx/musearch.git" >/dev/null; rc=$?
chk "B6d npm が落ちても bootstrap は exit 0、wrapper は作らず、記録に ymos build FAILED" bash -c "test $rc = 0 && test ! -e '$sbx/bin/ymos' && grep -q 'ymos build FAILED' '$H/.cache/harness-cloud/bootstrap.log'"
rm -rf "$H/yumemism_repo"; env CLAUDE_CODE_REMOTE=true PATH="$sbx/fakenpm:$PATH" CLOUD_YMOS_URL="file://$sbx/nonexistent.git" CLOUD_BIN_DIR="$sbx/bin" HOME="$H" CLOUD_SETUP_SKIP_TOOLS=1 CLOUD_SETUP_SETTINGS="$sbx/h2.json" bash "$core/cloud/setup.sh" >/dev/null 2>"$sbx/y.err"; rc=$?
chk "B6e ymos の clone が落ちても setup.sh は exit 0、wrapper は作らない(setup script の入口 = API credential が無い形)" bash -c "test $rc = 0 && test ! -e '$sbx/bin/ymos' && grep -q 'ymos clone FAILED' '$sbx/y.err'"
rm -rf "$H/yumemism_repo"; runB "file://$sbx/nonexistent.git" >/dev/null; rc=$?
chk "B7 clone が落ちても exit 0(cloud の起動を止めない)、記録に FAILED" bash -c "test $rc = 0 && grep -q 'musearch clone FAILED' '$H/.cache/harness-cloud/bootstrap.log'"
chk "B8 記録・標準エラーに資格情報の形(Basic / Bearer / user:pass@)が出ない" bash -c "! cat '$sbx/errB' '$H/.cache/harness-cloud/bootstrap.log' | grep -Eqi 'basic |bearer |://[^/ ]+:[^/ ]+@'"

S="$sbx/set.json"; echo '{"model":"x","autoMode":{"environment":["Trusted cloud buckets: s3://keep"],"allow":["$defaults"]}}' >"$S"
env CLOUD_SETUP_SKIP_TOOLS=1 CLOUD_SETUP_SETTINGS="$S" bash "$core/cloud/setup.sh" 2>/dev/null; h1="$(md5sum <"$S")"
env CLOUD_SETUP_SKIP_TOOLS=1 CLOUD_SETUP_SETTINGS="$S" bash "$core/cloud/setup.sh" 2>/dev/null; h2="$(md5sum <"$S")"
chk "B9 setup.sh は他の key と他の environment 行を残し、2 回目は書き換えない" \
  bash -c "jq -e '.model == \"x\" and .autoMode.allow == [\"\$defaults\"] and any(.autoMode.environment[]; . == \"Trusted cloud buckets: s3://keep\")' '$S' >/dev/null && test '$h1' = '$h2'"
out="$(env CLOUD_SETUP_SKIP_TOOLS=1 CLOUD_SETUP_SETTINGS="$S" bash "$core/cloud/setup.sh" 2>/dev/null)"
chk "B10 setup.sh は標準出力に何も出さない" test -z "$out"

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

echo "# E. cloud の SessionStart に memory を注入する(hooks/cloud-memory-inject.sh、tech-1 / tech-2 / keiei の 3 本)"
INJ="$core/hooks/cloud-memory-inject.sh"
cat >"$sbx/jc.py" <<'PYEOF'
import json, sys
# 使い方: jc.py <file> → additionalContext の UTF-16 字数を出す。空なら EMPTY。JSON でなければ BAD。
t = open(sys.argv[1], encoding="utf-8").read()
if not t.strip(): print("EMPTY"); raise SystemExit
try: c = json.loads(t)["hookSpecificOutput"]["additionalContext"]
except Exception: print("BAD"); raise SystemExit
if len(sys.argv) > 2: open(sys.argv[2], "w", encoding="utf-8").write(c)
print(len(c.encode("utf-16-le")) // 2)
PYEOF
mkdir -p "$sbx/tm" "$sbx/km" "$sbx/state"; echo "- [x](x.md) — TECHIDX" >"$sbx/tm/MEMORY.md"; echo "- [y](y.md) — KEIEIIDX" >"$sbx/km/MEMORY.md"
touch "$sbx/state/bootstrap-done"
inj() { local part="$1"; shift; env CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$sbx/projB" HOME="$H" CLOUD_STATE_DIR="$sbx/state" CLOUD_HOOK_T0=1 CTX_TECH_MEM="$sbx/tm" CTX_KEIEI_MEM="$sbx/km" CTX_WAIT_SEC=2 "$@" bash "$INJ" "$part" 2>/dev/null </dev/null; }
for p in tech-1 tech-2 keiei; do inj $p >"$sbx/e.$p"; done
chk "E1 小さい索引: tech-1 に TECHIDX が入り、tech-2 は空、keiei に KEIEIIDX(JSON 1 個ずつ)" test "$(python3 "$sbx/jc.py" "$sbx/e.tech-1" | grep -c '^[0-9]')" = 1 -a "$(python3 "$sbx/jc.py" "$sbx/e.tech-2")" = EMPTY -a "$(python3 "$sbx/jc.py" "$sbx/e.keiei" | grep -c '^[0-9]')" = 1 && grep -q TECHIDX "$sbx/e.tech-1" && grep -q KEIEIIDX "$sbx/e.keiei" && ! grep -q KEIEIIDX "$sbx/e.tech-1"
real="$TECH_MAIN/.claude/memory/MEMORY.md"; realk="$HOME/canonical/keiei/.claude/memory/MEMORY.md"
if [ -r "$real" ]; then
  mkdir -p "$sbx/rt" "$sbx/rk"; cp "$real" "$sbx/rt/MEMORY.md"; [ -r "$realk" ] && cp "$realk" "$sbx/rk/MEMORY.md"
  for p in tech-1 tech-2 keiei; do inj $p CTX_TECH_MEM="$sbx/rt" CTX_KEIEI_MEM="$sbx/rk" >"$sbx/r.$p"; done
  c1="$(python3 "$sbx/jc.py" "$sbx/r.tech-1" "$sbx/r1.txt")"; c2="$(python3 "$sbx/jc.py" "$sbx/r.tech-2" "$sbx/r2.txt")"; ck="$(python3 "$sbx/jc.py" "$sbx/r.keiei" "$sbx/rk.txt")"
  chk "E2 実物の索引($(python3 -c 'import sys;print(len(open(sys.argv[1],encoding="utf-8").read()))' "$real") 字): 3 本とも 9,500 字以下(tech-1 $c1 / tech-2 $c2 / keiei $ck)" bash -c "[ '$c1' -le 9500 ] && [ '$c2' -le 9500 ] && [ '$ck' -le 9500 ]"
  chk "E2b 前半と後半を足すと原本の全行が 1 度ずつ、後半は '## ' 見出しから始まる" python3 - "$real" "$sbx/r1.txt" "$sbx/r2.txt" <<'PYEOF'
import sys
orig = open(sys.argv[1], encoding="utf-8").read().splitlines(keepends=True)
def body(p):
    t = open(p, encoding="utf-8").read().split("\n\n", 1)[1]   # 見出し + 注記の後の空行から本文
    return t.splitlines(keepends=True)
a, b = body(sys.argv[2]), body(sys.argv[3])
assert a + b == orig, "行が欠けた/重複した"
assert b and b[0].startswith("## "), "後半が見出しで始まらない"
PYEOF
  if [ -r "$realk" ]; then chk "E2c keiei の実物が原本のまま入る" bash -c "grep -qF -- \"\$(sed -n 1p '$sbx/rk/MEMORY.md')\" '$sbx/rk.txt'"; fi
fi
# 大きい索引の合成: 見出しなし(行で割る)・3 本目が要る大きさ(警告 + 切る)
python3 - "$sbx" <<'PYEOF'
import sys, os
d = sys.argv[1]
def mk(name, secs, per, heads=True):
    os.makedirs(f"{d}/{name}", exist_ok=True)
    out = ["# MEMORY\n\n"]
    for s in range(secs):
        if heads: out.append(f"## セクション{s}\n")
        for i in range(per): out.append(f"- [項目{s}-{i}](f{s}-{i}.md) — " + "あ" * 60 + "\n")
    open(f"{d}/{name}/MEMORY.md", "w", encoding="utf-8").write("".join(out))
mk("bigA", 4, 40)                 # 約 4×40×~80 字 ≒ 12,800 字、見出しあり
mk("bigB", 1, 200, heads=False)   # 約 16,000 字、見出しなし
mk("bigC", 6, 60)                 # 約 29,000 字 → 3 本目が要る
PYEOF
for nm in bigA bigB bigC; do
  for p in tech-1 tech-2; do inj $p CTX_TECH_MEM="$sbx/$nm" >"$sbx/$nm.$p"; done
  eval "$nm"1="$(python3 "$sbx/jc.py" "$sbx/$nm.tech-1" "$sbx/$nm.1.txt")"; eval "$nm"2="$(python3 "$sbx/jc.py" "$sbx/$nm.tech-2" "$sbx/$nm.2.txt")"
done
chk "E3 見出しありの大きい索引(bigA): 2 本とも 9,500 字以下、見出しで割れ、警告なし($bigA1 / $bigA2)" bash -c "[ '$bigA1' -le 9500 ] && [ '$bigA2' -le 9500 ] && grep -q '^## セクション' '$sbx/bigA.2.txt' && ! grep -q '整理が要る' '$sbx/bigA.1.txt' && [ \"\$(sed -n '/^## セクション/{p;q}' '$sbx/bigA.2.txt')\" != '' ]"
chk "E4 見出しなしの大きい索引(bigB): 行で割って 2 本とも 9,500 字以下、行が欠けない($bigB1 / $bigB2)" bash -c "[ '$bigB1' -le 9500 ] && [ '$bigB2' -le 9500 ] && [ \$(( \$(grep -c '^- \[' '$sbx/bigB.1.txt') + \$(grep -c '^- \[' '$sbx/bigB.2.txt') )) = 200 ]"
chk "E5 3 本目が要る大きさ(bigC): 両方に「索引が大きすぎる、整理が要る」を出し、それでも 9,500 字以下($bigC1 / $bigC2)" bash -c "[ '$bigC1' -le 9500 ] && [ '$bigC2' -le 9500 ] && grep -q '索引が大きすぎる' '$sbx/bigC.1.txt' && grep -q '索引が大きすぎる' '$sbx/bigC.2.txt' && grep -q '行を載せていない' '$sbx/bigC.2.txt'"
inj keiei CTX_MAX_CHARS=300 >"$sbx/e.k300"; ek="$(python3 "$sbx/jc.py" "$sbx/e.k300")"
chk "E6 上限(CTX_MAX_CHARS)を下げても出力はそれ以下($ek ≤ 300)" test "$ek" -le 300
# 待ち
echo "# E-wait. keiei / bootstrap の完了待ち"
rm -rf "$sbx/wk" "$sbx/wstate"; mkdir -p "$sbx/wk" "$sbx/wstate"
t_start=$(date +%s)
( sleep 1.5; echo "- [w](w.md) — WAITED-KEIEI" >"$sbx/wk/MEMORY.md"; touch "$sbx/wstate/bootstrap-done" ) &
inj keiei CTX_KEIEI_MEM="$sbx/wk" CLOUD_STATE_DIR="$sbx/wstate" CLOUD_HOOK_T0="$(date +%s)" CTX_WAIT_SEC=10 >"$sbx/w1"; t_el=$(( $(date +%s) - t_start )); wait
chk "E7 印が後から現れるまで待ち、keiei の中身が入る(待ち ${t_el}s、上限 10s)" bash -c "grep -q WAITED-KEIEI '$sbx/w1' && [ $t_el -ge 1 ] && [ $t_el -lt 8 ]"
rm -rf "$sbx/wk" "$sbx/wstate"; mkdir -p "$sbx/wk" "$sbx/wstate"; touch -d '2020-01-01' "$sbx/wstate/bootstrap-done"
t_start=$(date +%s); inj keiei CTX_KEIEI_MEM="$sbx/wk" CLOUD_STATE_DIR="$sbx/wstate" CLOUD_HOOK_T0="$(date +%s)" CTX_WAIT_SEC=2 >"$sbx/w2"; t_el=$(( $(date +%s) - t_start ))
chk "E8 前回の古い印は今回の完了と読まない: 上限まで待って(${t_el}s)、clone が間に合わなかった旨を出し exit 0" bash -c "[ $t_el -ge 2 ] && [ $t_el -lt 6 ] && grep -q '間に合わなかった' '$sbx/w2' && [ \"\$(python3 '$sbx/jc.py' '$sbx/w2')\" -le 9500 ]"
rm -rf "$sbx/wk"; mkdir -p "$sbx/wk"; echo "- [w](w.md) — LATE" >"$sbx/wk/MEMORY.md"
inj tech-1 CTX_TECH_MEM="$sbx/wk" CLOUD_STATE_DIR="$sbx/wstate" CLOUD_HOOK_T0="$(date +%s)" CTX_WAIT_SEC=1 >"$sbx/w3"
chk "E9 tech 側は待ちきれなくても手元の索引を出し、取り込み未了かもしれない旨を添える" bash -c "grep -q LATE '$sbx/w3' && grep -q '完了を' '$sbx/w3'"
# settings の command 文字列で、_core が後から現れる(submodule 取得が遅い)cloud を模す
echo "# E-chain. settings.json の command を実走(_core は 1.5 秒後に現れ、書きかけの版が先にある)"
rm -rf "$sbx/px" "$sbx/xstate"; mkdir -p "$sbx/px/.claude/_core/hooks" "$sbx/xstate" "$sbx/xh"
head -c 200 "$INJ" >"$sbx/px/.claude/_core/hooks/cloud-memory-inject.sh"
( sleep 1.5; cp "$INJ" "$sbx/px/.claude/_core/hooks/cloud-memory-inject.sh.new"; mv "$sbx/px/.claude/_core/hooks/cloud-memory-inject.sh.new" "$sbx/px/.claude/_core/hooks/cloud-memory-inject.sh"; sleep 0.5; touch "$sbx/xstate/bootstrap-done" ) &
mkdir -p "$sbx/pxmem"; cp "$sbx/bigA/MEMORY.md" "$sbx/pxmem/MEMORY.md"
t_start=$(date +%s)
for i in 2 3 4; do
  cmd="$(jq -r ".hooks.SessionStart[0].hooks[$i].command" "$TECH_NEW/.claude/settings.json")"
  env CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$sbx/px" HOME="$sbx/xh" CLOUD_STATE_DIR="$sbx/xstate" CTX_TECH_MEM="$sbx/pxmem" CTX_KEIEI_MEM="$sbx/km" bash -c "$cmd" >"$sbx/x.$i" 2>"$sbx/x.$i.err" </dev/null &
done
wait; t_el=$(( $(date +%s) - t_start ))
chk "E10 3 本の command が _core の出現と印を待って、それぞれ JSON 1 個を返す(${t_el}s: tech-1 $(python3 "$sbx/jc.py" "$sbx/x.2") / tech-2 $(python3 "$sbx/jc.py" "$sbx/x.3") / keiei $(python3 "$sbx/jc.py" "$sbx/x.4"))" bash -c "grep -q 'セクション0' '$sbx/x.2' && grep -q 'セクション3' '$sbx/x.3' && grep -q KEIEIIDX '$sbx/x.4' && [ $t_el -ge 2 ]"
env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$sbx/none" bash "$INJ" tech-1 >"$sbx/m1" 2>&1; rc=$?
chk "E11 母艦ではスクリプト自体も何も出さず exit 0" test "$rc" = 0 -a ! -s "$sbx/m1"

echo "# D. 母艦の SessionStart は前後で変わらない(session-init.sh を settings の command 文字列のまま実走)"
old="$(git -C "$TECH_MAIN" show HEAD:.claude/settings.json | jq -r '.hooks.SessionStart[0].hooks[0].command')"
new="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$TECH_NEW/.claude/settings.json")"
runD() { env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$TECH_MAIN" bash -c "$1" 2>"$sbx/errD.$2"; }
o1="$(runD "$old" old)"; r1=$?; o2="$(runD "$new" new)"; r2=$?
norm() { sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.+Z-]+//g'; }
same='[.hooks.SessionStart[0].hooks[1], .hooks.Stop[0].hooks[0], .hooks.PreToolUse[0], .autoMemoryDirectory, .outputStyle]'
chk "D1 command 文字列以外の SessionStart(session-install)・Stop・commit guard・autoMemoryDirectory・outputStyle が同じ" test "$(git -C "$TECH_MAIN" show HEAD:.claude/settings.json | jq -c "$same")" = "$(jq -c "$same" "$TECH_NEW/.claude/settings.json")"
chk "D1b Stop に memory-sync が足され、guard の後ろで、常に exit 0" test "$(jq -r '.hooks.Stop[0].hooks[1].command' "$TECH_NEW/.claude/settings.json" | grep -c 'memory-sync.sh.*exit 0')" = 1
chk "D2 exit code が同じ($r1 / $r2)" test "$r1" = "$r2"
chk "D3 標準出力が同じ(日時の揺れは除く、$(printf %s "$o1" | wc -c) バイト)" test -n "$o1" -a "$(printf %s "$o1" | norm)" = "$(printf %s "$o2" | norm)"
chk "D4 標準エラーが同じ" test "$(norm <"$sbx/errD.old")" = "$(norm <"$sbx/errD.new")"
for i in 2 3 4; do
  cmd="$(jq -r ".hooks.SessionStart[0].hooks[$i].command" "$TECH_NEW/.claude/settings.json")"
  oi="$(env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$TECH_MAIN" bash -c "$cmd" 2>"$sbx/errI.$i")"; ri=$?
  s0=$(date +%s%N); for _ in 1 2 3 4 5; do env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$TECH_MAIN" bash -c "$cmd" >/dev/null 2>&1; done; e0=$(date +%s%N)
  chk "D7.$i 母艦で注入 hook[$i] は何も出さず(標準出力・標準エラーとも空)exit 0、所要 $(( (e0-s0)/5000000 )) ms/回" test "$ri" = 0 -a -z "$oi" -a ! -s "$sbx/errI.$i"
done
chk "D8 母艦の SessionStart は hook 5 本(init / install / 注入 3 本)で、cloud-session-start.sh はもう呼ばれない" bash -c "test \$(jq '.hooks.SessionStart[0].hooks|length' '$TECH_NEW/.claude/settings.json') = 5 && ! grep -q cloud-session-start '$TECH_NEW/.claude/settings.json'"
tm() { local s e; s=$(date +%s%N); env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$TECH_MAIN" bash -c "$1" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }
so=0; sn=0; for _ in 1 2 3 4; do so=$((so+$(tm "$old"))); sn=$((sn+$(tm "$new"))); done
echo "# D5 所要(ms、交互 4 回平均): 前 $((so/4)) / 後 $((sn/4))  ※ session-init が Neon を読むので揺れる。差は誤差の範囲かを見る"
tn=$(date +%s%N); for _ in $(seq 1 20); do env -u CLAUDE_CODE_REMOTE bash -c 'if [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then :; fi; :'; done; te=$(date +%s%N)
echo "# D6 追加した if 節だけの所要: $(( (te-tn)/20000000 )) ms / 回(bash 起動込み。session-init は元から bash を起こす)"

echo "1..$n"; [ "$fail" = 0 ] && echo "ALL OK" || echo "FAILED"
exit "$fail"
