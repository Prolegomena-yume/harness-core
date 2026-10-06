#!/usr/bin/env bash
# hooks/memory-sync.sh の test。sandbox の bare repo を Forgejo に見立て、母艦の作業木・cloud の clone を模す。
# 実ネットワークには出ない。使い方: bash scripts/test-memory-sync.sh
set -uo pipefail
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$core/hooks/memory-sync.sh"; GAS="$core/scripts/git-as"
n=0; fail=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); echo "not ok $n - $1"; fail=1; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }
sbx="$(mktemp -d)"; trap 'rm -rf "$sbx"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# 「Forgejo」: seed 後に main へ memory・_sessions 以外を含む push を弾く pre-receive(tech の unprotected_file_patterns `.claude/memory/**;_sessions/**` の模し)を張る
git init -q --bare -b main "$sbx/forgejo.git"
seed="$sbx/seed"; git init -q -b main "$seed"
mkdir -p "$seed/.claude/memory"; echo "- [a](a.md) — first" >"$seed/.claude/memory/MEMORY.md"; echo "A0" >"$seed/.claude/memory/a.md"; echo code >"$seed/code.txt"
git -C "$seed" add -A; "$GAS" anno -C "$seed" commit -q -m init
git -C "$seed" push -q "$sbx/forgejo.git" main

host="$sbx/host"; git clone -q "$sbx/forgejo.git" "$host"
cloud="$sbx/cloud"; git clone -q "$sbx/forgejo.git" "$cloud"
git -C "$cloud" update-ref refs/memory-sync/base HEAD   # cloud-bootstrap が SessionStart で置く
# hook を後から張る(seed の push は hook 無しで通した)
cat >"$sbx/forgejo.git/hooks/pre-receive" <<'H'
#!/bin/bash
z=0000000000000000000000000000000000000000
while read old new ref; do
  [ "$new" = $z ] && continue
  files=$(git diff --name-only "$old" "$new")
  bad=$(printf '%s\n' "$files" | grep -v -e '^.claude/memory/' -e '^_sessions/' | head -1)
  [ -n "$bad" ] && { echo "protected: $bad" >&2; exit 1; }
done
exit 0
H
chmod +x "$sbx/forgejo.git/hooks/pre-receive"

hs() { env -u CLAUDE_CODE_REMOTE MEMSYNC_REMOTE_MODE=host MEMSYNC_REPO="$host" MEMSYNC_STATE="$sbx/st-host" MEMSYNC_FOREGROUND=1 MEMSYNC_FETCH_EVERY=0 bash "$HOOK" </dev/null; echo $?; }
cs() { env CLAUDE_CODE_REMOTE=true MEMSYNC_REPO="$cloud" MEMSYNC_URL="$sbx/forgejo.git" MEMSYNC_STATE="$sbx/st-cloud" MEMSYNC_FETCH_EVERY=0 bash "$HOOK" </dev/null; echo $?; }
rmem() { git -C "$sbx/forgejo.git" show "main:.claude/memory/$1" 2>/dev/null; }
rfiles() { git -C "$sbx/forgejo.git" diff --name-only "$1" main; }
H="$host/.claude/memory"; C="$cloud/.claude/memory"

echo "# 母艦"
chk "H1 出発点: 母艦の HEAD = Forgejo の main" test "$(git -C "$sbx/forgejo.git" rev-parse main)" = "$(git -C "$host" rev-parse HEAD)"
r0="$(git -C "$sbx/forgejo.git" rev-parse main)"
out="$(hs)"; chk "H2 差分なし: exit 0、Forgejo の main は動かない" test "$out" = 0 -a "$(git -C "$sbx/forgejo.git" rev-parse main)" = "$r0"

# 他セッションの書きかけ: 追跡 file の未 commit の変更・staged・untracked
echo "wip" >>"$host/code.txt"; echo staged >"$host/staged.txt"; git -C "$host" add staged.txt; echo untr >"$host/untr.txt"
echo "B0" >"$H/b.md"; echo "- [b](b.md) — second" >>"$H/MEMORY.md"; echo "A1" >"$H/a.md"
sleep 1
out="$(hs)"
chk "H3 exit 0" test "$out" = 0
chk "H4 Forgejo の main が進み、差分は memory だけ" bash -c "[ \"\$(git -C '$sbx/forgejo.git' diff --name-only $r0 main | grep -vc '^.claude/memory/')\" = 0 ] && [ \"\$(git -C '$sbx/forgejo.git' rev-parse main)\" != $r0 ]"
chk "H5 Forgejo の memory が手元と同じ(b.md 新規、a.md 更新、MEMORY.md)" test "$(rmem b.md)" = B0 -a "$(rmem a.md)" = A1 -a "$(rmem MEMORY.md | wc -l)" = 2
chk "H6 他セッションの書きかけ(code.txt の変更・staged.txt・untr.txt)は触られない" bash -c "cd '$host' && git status --porcelain | sort | tr '\n' ',' | grep -qxF ' M code.txt,?? untr.txt,A  staged.txt,'"
chk "H7 HEAD が Forgejo の main に進み、memory は clean" bash -c "[ \"\$(git -C '$host' rev-parse HEAD)\" = \"\$(git -C '$sbx/forgejo.git' rev-parse main)\" ] && [ -z \"\$(git -C '$host' status --porcelain -- .claude/memory)\" ]"
chk "H8 author が鷹野(git-as)" test "$(git -C "$host" log -1 --format=%an)" = 鷹野

echo "# cloud → 母艦"
echo "C0" >"$C/c.md"; echo "- [c](c.md) — from cloud" >>"$C/MEMORY.md"; sleep 1
out="$(cs)"; chk "K1 cloud の Stop: exit 0" test "$out" = 0
chk "K2 Forgejo に c.md が入り、母艦で書いた b.md・a.md=A1 も消えない(memory の置き換えでなく差分の重ね)" test "$(rmem c.md)" = C0 -a "$(rmem b.md)" = B0 -a "$(rmem a.md)" = A1
chk "K3 MEMORY.md は両方の行を持つ(和集合。cloud は母艦の追加を知らなかった)" bash -c "m=\"\$(git -C '$sbx/forgejo.git' show main:.claude/memory/MEMORY.md)\"; echo \"\$m\" | grep -q first && echo \"\$m\" | grep -q second && echo \"\$m\" | grep -q 'from cloud'"
chk "K4 cloud の手元にも母艦の b.md が降りてきた" test "$(cat "$C/b.md" 2>/dev/null)" = B0
sleep 1; out="$(hs)"; chk "H9 母艦の次の Stop で c.md が手元に降り、HEAD が進み、clean" bash -c "[ '$out' = 0 ] && [ \"\$(cat '$H/c.md')\" = C0 ] && [ \"\$(git -C '$host' rev-parse HEAD)\" = \"\$(git -C '$sbx/forgejo.git' rev-parse main)\" ] && [ -z \"\$(git -C '$host' status --porcelain -- .claude/memory)\" ]"

echo "# 衝突"
echo "HOST" >"$H/a.md"; echo "CLOUD" >"$C/a.md"; sleep 1
cs >/dev/null; sleep 1; hs >/dev/null
chk "X1 同じ topic file: 先に打った cloud の版が Forgejo に入り、母艦は(同期前に書いた自分の版で)後勝ち" bash -c "[ \"\$(git -C '$sbx/forgejo.git' show main:.claude/memory/a.md)\" = HOST ]"
chk "X2 負けた版(CLOUD)は Forgejo の履歴に残る" bash -c "git -C '$sbx/forgejo.git' log --format=%H main -- .claude/memory/a.md | while read c; do git -C '$sbx/forgejo.git' show \$c:.claude/memory/a.md; done | grep -qx CLOUD"
chk "X3 衝突した path が commit message に出る" bash -c "git -C '$sbx/forgejo.git' log --format=%B main | grep -q '衝突(a.md'"

echo "# 保護・失敗"
# cloud が memory 以外を巻き込む: worker は memory しか commit に載せないので通る(session の branch の他の変更は載らない)
echo "cloudcode" >"$cloud/code.txt"; git -C "$cloud" add code.txt; "$GAS" anno -C "$cloud" commit -q -m "cloud branch change"
echo "D0" >"$C/d.md"; sleep 1; out="$(cs)"
chk "P1 session の branch に memory 以外の commit があっても、Forgejo に載るのは memory だけ" bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$sbx/forgejo.git' show main:.claude/memory/d.md)\" = D0 ] && [ \"\$(git -C '$sbx/forgejo.git' show main:code.txt)\" = code ]"
# 保護が弾く: memory 以外を含む push を手で打つ
chk "P2 保護(模し)は memory 以外を含む push を弾く" bash -c "echo x >'$cloud/code.txt'; git -C '$cloud' add code.txt; $GAS anno -C '$cloud' commit -q -m x; ! git -C '$cloud' push -q '$sbx/forgejo.git' HEAD:refs/heads/main 2>/dev/null"
git -C "$cloud" reset -q --hard HEAD~1
# 母艦: 未 push の commit があるなら push しない
echo u >"$host/unpushed.txt"; git -C "$host" add unpushed.txt; "$GAS" anno -C "$host" commit -q -m unpushed; echo "E0" >"$H/e.md"; sleep 1
r1="$(git -C "$sbx/forgejo.git" rev-parse main)"; out="$(hs)"
chk "P3 母艦に未 push の commit があれば push せず、作業木も動かさない(exit 0)" test "$out" = 0 -a "$(git -C "$sbx/forgejo.git" rev-parse main)" = "$r1" -a "$(cat "$H/e.md")" = E0
git -C "$host" reset -q --hard origin/main 2>/dev/null; git -C "$host" fetch -q origin; git -C "$host" reset -q --hard origin/main; echo "E0" >"$H/e.md"
# index.lock を握られていても落ちない(push は通り、HEAD は次回)
touch "$host/.git/index.lock"; echo "F0" >"$H/f.md"; sleep 1; out="$(hs)"; rm -f "$host/.git/index.lock"
chk "P4 index.lock 中でも exit 0、Forgejo には入る" test "$out" = 0 -a "$(rmem f.md)" = F0
# 母艦が main 以外の branch
git -C "$host" checkout -q -b other; echo "G0" >"$H/g.md"; sleep 1; out="$(hs)"
chk "P5 母艦の作業木が main でなければ何もしない" test "$out" = 0 -a -z "$(rmem g.md)"
git -C "$host" checkout -q main
# 同時実行
( flock -n 9 || exit 1; sleep 3 ) 9>"$sbx/st-host/lock" & sleep 0.3
echo "H0" >"$H/h.md"; sleep 1; out="$(hs)"; wait
chk "P6 lock が取れなければ黙って次回(exit 0、push しない)" test "$out" = 0 -a -z "$(rmem h.md)"
sleep 1; hs >/dev/null; chk "P7 次回の Stop で追いつく" test "$(rmem h.md)" = H0
# fetch 失敗(URL が壊れている)
out="$(env -u CLAUDE_CODE_REMOTE MEMSYNC_REMOTE_MODE=host MEMSYNC_REPO="$host" MEMSYNC_URL="$sbx/none.git" MEMSYNC_STATE="$sbx/st-host" MEMSYNC_FOREGROUND=1 MEMSYNC_FETCH_EVERY=0 bash "$HOOK" </dev/null; echo $?)"
chk "P8 Forgejo に届かなくても exit 0・標準出力なし" test "$out" = 0

echo "# cloud: サマリ(_sessions)と memory を Forgejo の main へ直接上げ、Anthropic の Stop 検査の要求(commit して origin の branch に push)に応える"
# Anthropic が VM に入れる ~/.claude/stop-hook-git-check.sh の模し(鷹野が cloud の VM で読んだ実物の条件):
#   stop_hook_active=true なら素通り / git 管理外・remote 無しも素通り / exit 2 で止める: 未 commit の差分(git diff・--cached)・未追跡ファイル・
#   origin/<branch>(無ければ origin/HEAD)に対する未 push の commit(署名の検査は gpgsign=true の VM だけで、ここでは模さない)
cat >"$sbx/stopcheck.sh" <<'SC'
#!/usr/bin/env bash
cd "$1" || exit 0
[ "${2:-}" = active ] && exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0
git diff --quiet && git diff --cached --quiet || { echo "uncommitted" >&2; exit 2; }
[ -z "$(git ls-files --others --exclude-standard)" ] || { echo "untracked" >&2; exit 2; }
br="$(git branch --show-current)"; if git rev-parse "origin/$br" >/dev/null 2>&1; then up="origin/$br"; else up=origin/HEAD; fi
[ "$(git rev-list --count "$up..HEAD" 2>/dev/null)" = 0 ] || { echo "unpushed vs $up" >&2; exit 2; }
exit 0
SC
stopcheck() { bash "$sbx/stopcheck.sh" "$@" 2>/dev/null; echo $?; }
# 「GitHub の写し」= cloud の clone の origin(bare)。session の branch claude/x はここに在り、origin/claude/x を追跡する(実機と同じ)
git clone -q --bare "$sbx/forgejo.git" "$sbx/github.git"
# 他のセッションが Forgejo の main を先へ進めておく(サマリ old.md と memory の更新。写しは知らない)
oth="$sbx/oth"; git clone -q "$sbx/forgejo.git" "$oth"; mkdir -p "$oth/_sessions"; echo OLD >"$oth/_sessions/old.md"; echo "M1" >"$oth/.claude/memory/m1.md"
git -C "$oth" add -A; "$GAS" anno -C "$oth" commit -q -m "other session"; git -C "$oth" push -q "$sbx/forgejo.git" main
cl() { rm -rf "$sbx/cl2" "$sbx/st-cl2"; git -C "$sbx/github.git" branch -q -f claude/x main; git clone -q -b claude/x "$sbx/github.git" "$sbx/cl2"; mkdir -p "$sbx/cl2/_sessions"
  git -C "$sbx/cl2" update-ref refs/memory-sync/base HEAD; git -C "$sbx/cl2" remote add forgejo "$sbx/forgejo.git"; }
c2() { sleep 1; env CLAUDE_CODE_REMOTE=true "$@" MEMSYNC_REPO="$sbx/cl2" MEMSYNC_URL="$sbx/forgejo.git" MEMSYNC_STATE="$sbx/st-cl2" MEMSYNC_FETCH_EVERY=0 bash "$HOOK" </dev/null >/dev/null 2>&1; echo $?; }
fmain() { git -C "$sbx/forgejo.git" rev-parse main; }
fshow() { git -C "$sbx/forgejo.git" show "main:$1" 2>/dev/null; }
gtip() { git -C "$sbx/github.git" rev-parse claude/x; }
L2="$sbx/cl2"; ss="2026-10-01_01.md"
slog() { cat "$sbx/st-cl2/sync.log" 2>/dev/null; }

# R1: サマリは commit せず、memory も書き換わった(close-session の cloud の形)
cl; printf 'SUMMARY1\n' >"$L2/_sessions/$ss"; echo "N0" >"$L2/.claude/memory/n.md"; echo "- [n](n.md) — new" >>"$L2/.claude/memory/MEMORY.md"
r0="$(fmain)"; g0="$(gtip)"; h0="$(git -C "$L2" rev-parse HEAD)"
chk "R0 対照: 何もしなければ Anthropic の検査が止める(未追跡・未 commit)" test "$(stopcheck "$L2")" = 2
chk "R0b 模した検査は stop_hook_active=true なら素通り" test "$(stopcheck "$L2" active)" = 0
out="$(c2)"
chk "R1 Forgejo の main に直接載るのはサマリ・n.md・MEMORY.md だけ(m1.md・old.md は他セッションの分で手元に降りる)" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$sbx/forgejo.git' show main:_sessions/$ss)\" = SUMMARY1 ] && [ \"\$(git -C '$sbx/forgejo.git' diff --name-only $r0 main | sort | tr '\n' ' ')\" = '.claude/memory/MEMORY.md .claude/memory/n.md _sessions/$ss ' ]"
chk "R2 session の branch に対象の path だけを git-as 鷹野で commit し(message は Forgejo と同じ形)、origin の claude/x に push した(force でなく fast-forward)" \
  bash -c "[ \"\$(git -C '$L2' rev-parse HEAD~1)\" = $h0 ] && [ \"\$(git -C '$L2' log -1 --format=%an)\" = 鷹野 ] && git -C '$L2' log -1 --format=%s | grep -q '^sessions: cloud から' && [ \"\$(git -C '$L2' diff --name-only HEAD~1 HEAD | grep -vc -e '^.claude/memory/' -e '^_sessions/')\" = 0 ] && [ \"\$(git -C '$sbx/github.git' rev-parse claude/x)\" = \"\$(git -C '$L2' rev-parse HEAD)\" ] && git -C '$sbx/github.git' merge-base --is-ancestor $g0 claude/x"
chk "R3 検査が静かに通る(exit 0)。Forgejo の main には session の branch の commit が載らない" bash -c "[ \"\$(bash $sbx/stopcheck.sh $L2 >/dev/null 2>&1; echo \$?)\" = 0 ] && ! git -C '$sbx/forgejo.git' cat-file -e \$(git -C '$L2' rev-parse HEAD) 2>/dev/null"
# R4: 続けて 2 本目(また commit・push される)
printf 'SUMMARY2\n' >"$L2/_sessions/2026-10-01_02.md"; out="$(c2)"
chk "R4 2 本目のサマリも Forgejo に上がり、branch にも commit・push されて、また検査が通る" test "$out" = 0 -a "$(fshow _sessions/2026-10-01_02.md)" = SUMMARY2 -a "$(stopcheck "$L2")" = 0 -a "$(gtip)" = "$(git -C "$L2" rev-parse HEAD)"

# R5: サマリを git-as で commit してあった(他ロールの形)+ memory は未 commit
ss="2026-10-01_05.md"; cl; printf 'SUMMARY1c\n' >"$L2/_sessions/$ss"; git -C "$L2" add "_sessions/$ss"; "$GAS" anno -C "$L2" commit -q -m "summary"; echo "N1" >"$L2/.claude/memory/n1.md"
r0="$(fmain)"; out="$(c2)"
chk "R5 commit 済みのサマリ(未 push)も対象の path だけなので、memory と一緒に origin の branch へ上がり、検査が通る" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$sbx/forgejo.git' show main:_sessions/$ss)\" = SUMMARY1c ] && [ \"\$(git -C '$sbx/forgejo.git' diff --name-only $r0 main | sort | tr '\n' ' ')\" = '.claude/memory/n1.md _sessions/$ss ' ] && [ \"\$(git -C '$sbx/github.git' rev-parse claude/x)\" = \"\$(git -C '$L2' rev-parse HEAD)\" ] && [ \"\$(bash $sbx/stopcheck.sh $L2 >/dev/null 2>&1; echo \$?)\" = 0 ]"

# R6: 本物の作業(tech の変更)が残っている ── Forgejo に載るのはサマリだけ、branch には何もせず、警告は残る
ss="2026-10-01_06.md"; cl; printf 'SUMMARY1w\n' >"$L2/_sessions/$ss"; echo "real work" >>"$L2/code.txt"; echo "untracked real" >"$L2/newfile.txt"
r0="$(fmain)"; h0="$(git -C "$L2" rev-parse HEAD)"; g0="$(gtip)"; out="$(c2)"
chk "R6 uncommitted の本物の作業があっても、Forgejo に載るのはサマリだけ" bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$sbx/forgejo.git' diff --name-only $r0 main | tr '\n' ' ')\" = '_sessions/$ss ' ] && [ \"\$(git -C '$sbx/forgejo.git' show main:code.txt)\" = code ]"
chk "R7 対象外が 1 つでもあれば、branch に commit も push もせず(HEAD・origin の claude/x 不変)、作業木もそのまま、検査は止め続ける(本物の未保存を隠さない)" \
  bash -c "[ \"\$(git -C '$L2' rev-parse HEAD)\" = $h0 ] && [ \"\$(git -C '$sbx/github.git' rev-parse claude/x)\" = $g0 ] && grep -q 'real work' '$L2/code.txt' && [ -f '$L2/newfile.txt' ] && [ -f '$L2/_sessions/$ss' ] && [ \"\$(bash $sbx/stopcheck.sh $L2 >/dev/null 2>&1; echo \$?)\" = 2 ] && grep -q 'branch: uncommitted/untracked .* (real work; nothing done)' '$sbx/st-cl2/sync.log'"
ss="2026-10-01_08.md"; cl; printf 'SUMMARY1r\n' >"$L2/_sessions/$ss"; echo "real commit" >>"$L2/code.txt"; git -C "$L2" add code.txt; "$GAS" anno -C "$L2" commit -q -m "real work"
h0="$(git -C "$L2" rev-parse HEAD)"; g0="$(gtip)"; out="$(c2)"
chk "R8 push していない本物の commit があれば、サマリは Forgejo に上がるが、branch には何もせず(commit も push も無し)、検査は止め続ける" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$sbx/forgejo.git' show main:_sessions/$ss)\" = SUMMARY1r ] && [ \"\$(git -C '$L2' rev-parse HEAD)\" = $h0 ] && [ \"\$(git -C '$sbx/github.git' rev-parse claude/x)\" = $g0 ] && grep -q 'unpushed commit touches code.txt' '$sbx/st-cl2/sync.log' && [ \"\$(bash $sbx/stopcheck.sh $L2 >/dev/null 2>&1; echo \$?)\" = 2 ]"

# R9: non-FF ── origin の claude/x が先へ進んでいる。force せず、手元の commit は残し、記録して止める(exit 0)
ss="2026-10-01_09.md"; cl; printf 'S9\n' >"$L2/_sessions/$ss"
oth3="$sbx/oth3"; rm -rf "$oth3"; git clone -q -b claude/x "$sbx/github.git" "$oth3"; echo other >"$oth3/other.txt"; git -C "$oth3" add -A; "$GAS" anno -C "$oth3" commit -q -m "other pushed to the branch"; git -C "$oth3" push -q origin claude/x
g0="$(gtip)"; out="$(c2)"
chk "R9 non-FF なら push は通らず(origin の claude/x は他の commit のまま、force しない)、手元には commit が残り、記録に failed を残し、検査は止まる" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$sbx/github.git' rev-parse claude/x)\" = $g0 ] && grep -q 'push to origin/claude/x failed' '$sbx/st-cl2/sync.log' && [ \"\$(git -C '$L2' log -1 --format=%s | cut -c1-9)\" = 'sessions:' ] && [ \"\$(bash $sbx/stopcheck.sh $L2 >/dev/null 2>&1; echo \$?)\" = 2 ]"
# R10: commit が失敗する(署名・hook の模し)── 記録して止め、差分はそのまま。直った次の Stop で拾う
ss="2026-10-01_10.md"; cl; printf 'S10\n' >"$L2/_sessions/$ss"; printf '#!/bin/sh\nexit 1\n' >"$L2/.git/hooks/pre-commit"; chmod +x "$L2/.git/hooks/pre-commit"; h0="$(git -C "$L2" rev-parse HEAD)"; g0="$(gtip)"; out="$(c2)"
chk "R10 commit が失敗したら、記録に commit failed を残し、HEAD・origin・作業木の差分はそのまま(index に積み残さない)" \
  bash -c "[ '$out' = 0 ] && grep -q 'branch: commit failed' '$sbx/st-cl2/sync.log' && [ \"\$(git -C '$L2' rev-parse HEAD)\" = $h0 ] && [ \"\$(git -C '$sbx/github.git' rev-parse claude/x)\" = $g0 ] && [ -z \"\$(git -C '$L2' diff --cached --name-only)\" ] && [ -f '$L2/_sessions/$ss' ]"
rm -f "$L2/.git/hooks/pre-commit"; out="$(c2)"
chk "R10b 原因が直った次の Stop で commit・push され、検査が通る" test "$out" = 0 -a "$(gtip)" = "$(git -C "$L2" rev-parse HEAD)" -a "$(stopcheck "$L2")" = 0

# R11: 連番の衝突 ── Forgejo の版も手元の版も上書きしない。手元の版は session の branch には載る
cl; printf 'MINE\n' >"$L2/_sessions/2026-10-01_11.md"
oth2="$sbx/oth2"; rm -rf "$oth2"; git clone -q "$sbx/forgejo.git" "$oth2"; printf 'THEIRS\n' >"$oth2/_sessions/2026-10-01_11.md"; git -C "$oth2" add -A; "$GAS" anno -C "$oth2" commit -q -m "theirs"; git -C "$oth2" push -q "$sbx/forgejo.git" main
out="$(c2)"
chk "R11 同じ名前を別の中身で先に上げられていたら、Forgejo の版も手元の版も上書きせず、記録に conflict を残す(手元の版は session の branch に commit・push される)" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$sbx/forgejo.git' show main:_sessions/2026-10-01_11.md)\" = THEIRS ] && [ \"\$(cat '$L2/_sessions/2026-10-01_11.md')\" = MINE ] && grep -q 'conflict: _sessions/2026-10-01_11.md' '$sbx/st-cl2/sync.log' && [ \"\$(git -C '$sbx/github.git' show claude/x:_sessions/2026-10-01_11.md)\" = MINE ]"
# R12: 手元で消した _sessions のファイルは Forgejo から消えない(足すだけ)。branch には削除として載る
cl; rm -f "$L2/_sessions/old.md" 2>/dev/null; git -C "$L2" fetch -q "$sbx/forgejo.git" main; printf 'S12\n' >"$L2/_sessions/2026-10-01_12.md"; out="$(c2)"
chk "R12 手元に無い _sessions のファイル(old.md)の削除は Forgejo へ流さない" test "$out" = 0 -a "$(fshow _sessions/old.md)" = OLD -a "$(fshow _sessions/2026-10-01_12.md)" = S12
# R13: 母艦は _sessions を対象にしない(母艦の分岐は変えない)。cloud が上げたサマリが main に入ると、母艦は pull するまで memory も
# 上げない(HEAD..main に memory 以外の path が入るため。母艦の既存の条件のまま)。pull(ff)した後は今までどおり memory だけ上げる
echo "HM0" >"$H/hm0.md"; sleep 1; out="$(hs)"
chk "R13a 母艦は cloud のサマリが入った main に追いつく前は push しない(既存の条件: HEAD..main に memory 以外の path)" test "$out" = 0 -a -z "$(rmem hm0.md)"
git -C "$host" fetch -q origin && git -C "$host" merge -q --ff-only origin/main 2>/dev/null
mkdir -p "$host/_sessions"; printf 'HOSTSUM\n' >"$host/_sessions/h.md"; echo "HM" >"$H/hm.md"; sleep 1; out="$(hs)"
chk "R13 pull した母艦の Stop は memory だけ上げ(hm0.md・hm.md)、_sessions のサマリは上げず、origin の branch への commit・push もしない(母艦の分岐は変えない)" test "$out" = 0 -a "$(rmem hm.md)" = HM -a "$(rmem hm0.md)" = HM0 -a -z "$(fshow _sessions/h.md)" -a "$(git -C "$host" log -1 --format=%s | cut -c1-7)" = 'memory:'
# R14: Forgejo に届かなければ branch にも触らない(Forgejo への push が済んだ後の段)
cl; printf 'S14\n' >"$L2/_sessions/2026-10-01_14.md"; h0="$(git -C "$L2" rev-parse HEAD)"; g0="$(gtip)"; sleep 1
env CLAUDE_CODE_REMOTE=true MEMSYNC_REPO="$L2" MEMSYNC_URL="$sbx/none.git" MEMSYNC_STATE="$sbx/st-cl2" MEMSYNC_FETCH_EVERY=0 bash "$HOOK" </dev/null >/dev/null 2>&1
chk "R14 Forgejo に届かなければ branch に commit も push もしない(サマリは手元に残る)" bash -c "[ \"\$(git -C '$L2' rev-parse HEAD)\" = $h0 ] && [ \"\$(git -C '$sbx/github.git' rev-parse claude/x)\" = $g0 ] && [ -f '$L2/_sessions/2026-10-01_14.md' ]"
# R15: 起動時の取り込み(MEMSYNC_NO_BRANCH=1)は branch に触らない。降りた memory は、差分が無い次の Stop(fetch 間隔内)でも拾って commit・push する
cl; h0="$(git -C "$L2" rev-parse HEAD)"; g0="$(gtip)"; out="$(c2 MEMSYNC_NO_BRANCH=1)"
chk "R15 起動時の取り込みは Forgejo の memory(m1.md・old.md)を作業木に降ろすだけで、branch に commit も push もしない(M / ?? が残る)" test "$out" = 0 -a "$(git -C "$L2" rev-parse HEAD)" = "$h0" -a "$(gtip)" = "$g0" -a "$(stopcheck "$L2")" = 2
sleep 1; out="$(env CLAUDE_CODE_REMOTE=true MEMSYNC_REPO="$L2" MEMSYNC_URL="$sbx/forgejo.git" MEMSYNC_STATE="$sbx/st-cl2" MEMSYNC_FETCH_EVERY=600 bash "$HOOK" </dev/null >/dev/null 2>&1; echo $?)"
chk "R15b 次の Stop は memory の差分も fetch 間隔も無くても、対象の path の未 commit があれば worker を走らせ、commit・push して検査が通る" test "$out" = 0 -a "$(gtip)" = "$(git -C "$L2" rev-parse HEAD)" -a "$(stopcheck "$L2")" = 0
# R16: 差分が何も無い Stop は何もしない / main に居るときは push しない
cl; h0="$(git -C "$L2" rev-parse HEAD)"; git -C "$L2" fetch -q "$sbx/forgejo.git" main && git -C "$L2" reset -q --hard FETCH_HEAD && git -C "$L2" update-ref refs/memory-sync/base HEAD; h0="$(git -C "$L2" rev-parse HEAD)"; g0="$(gtip)"; out="$(c2)"
chk "R16 差分も未 push も無ければ commit も push もしない" test "$out" = 0 -a "$(git -C "$L2" rev-parse HEAD)" = "$h0"
cl; git -C "$L2" checkout -q -B main; echo "N16" >"$L2/.claude/memory/n16.md"; gm="$(git -C "$sbx/github.git" rev-parse main)"; out="$(c2)"
chk "R16b branch が main のときは origin へ push しない(写しの main を進めない)" test "$out" = 0 -a "$(git -C "$sbx/github.git" rev-parse main)" = "$gm" -a "$(fshow .claude/memory/n16.md)" = N16

echo "# 母艦: 他の窓が Forgejo の main に push した memory 以外の変更を、作業木・index・HEAD ごと降ろす(advance_host)"
# 別の sandbox(Forgejo は pre-receive 無し: 他の窓の push は memory 以外も通る)。host2 = 母艦、oth2 = 他の窓
w_mk() {
  rm -rf "$sbx/w" "$sbx/st-w"; mkdir -p "$sbx/w"
  git init -q --bare -b main "$sbx/w/f.git"
  local sd="$sbx/w/seed"; git init -q -b main "$sd"; mkdir -p "$sd/.claude/memory" "$sd/_sessions"
  echo "- [a](a.md) — first" >"$sd/.claude/memory/MEMORY.md"; echo A0 >"$sd/.claude/memory/a.md"; echo code >"$sd/code.txt"; echo other >"$sd/other.txt"
  echo old >"$sd/old.txt"; echo ev0 >"$sd/_sessions/s0.md"; printf 'ign.txt\n' >"$sd/.gitignore"
  git -C "$sd" add -A; "$GAS" anno -C "$sd" commit -q -m init; git -C "$sd" push -q "$sbx/w/f.git" main
  git clone -q "$sbx/w/f.git" "$sbx/w/host"; git clone -q "$sbx/w/f.git" "$sbx/w/oth"
  W="$sbx/w/host"; WF="$sbx/w/f.git"; WO="$sbx/w/oth"; WH="$W/.claude/memory"
}
whs() { sleep 1; env -u CLAUDE_CODE_REMOTE MEMSYNC_REMOTE_MODE=host MEMSYNC_REPO="$W" MEMSYNC_STATE="$sbx/st-w" MEMSYNC_FOREGROUND=1 MEMSYNC_FETCH_EVERY=0 bash "$HOOK" </dev/null >/dev/null 2>&1; echo $?; }
wlog() { cat "$sbx/st-w/sync.log" 2>/dev/null; }
w_other() {   # 他の窓が memory 以外(code.txt 変更・docs/new.md 新規・old.txt 削除)を commit して Forgejo の main に push
  git -C "$WO" pull -q --ff-only origin main 2>/dev/null; echo "code2" >"$WO/code.txt"; mkdir -p "$WO/docs"; echo NEW >"$WO/docs/new.md"; git -C "$WO" rm -q old.txt
  git -C "$WO" add -A; "$GAS" anno -C "$WO" commit -q -m "other window"; git -C "$WO" push -q origin main
}
w_aligned() { [ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$WF" rev-parse main)" ] && [ -z "$(git -C "$W" status --porcelain)" ]; }
w_fmain() { git -C "$WF" rev-parse main; }

# W1: 他の窓の push だけ(母艦に手元の変更なし)
w_mk; w_other; out="$(whs)"
chk "W1 他の窓が memory 以外(変更・新規・削除)を push → 母艦の Stop で HEAD・index・作業木が揃い、git status に取り消しの差分が無い" \
  bash -c "[ '$out' = 0 ] && cd '$W' && [ \"\$(git rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ] && [ -z \"\$(git status --porcelain)\" ] && [ \"\$(cat code.txt)\" = code2 ] && [ \"\$(cat docs/new.md)\" = NEW ] && [ ! -e old.txt ]"
# W1b: memory も一緒に変わった push(他の窓が memory と code を 1 commit で)
w_mk; echo "AX" >"$WO/.claude/memory/a.md"; echo "BX" >"$WO/.claude/memory/b.md"; w_other; out="$(whs)"
chk "W1b memory も一緒に変わった他の窓の push も、作業木・index・HEAD が揃う(memory の新規・更新も降りる)" \
  bash -c "[ '$out' = 0 ] && cd '$W' && [ \"\$(git rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ] && [ -z \"\$(git status --porcelain)\" ] && [ \"\$(cat .claude/memory/a.md)\" = AX ] && [ \"\$(cat .claude/memory/b.md)\" = BX ] && [ \"\$(cat code.txt)\" = code2 ]"

# W2: 他の窓が変えた path を母艦が手元で編集中 → HEAD は進まず、編集は残り、記録に残る。編集を消した次の Stop で揃う
w_mk; echo "my wip" >>"$W/code.txt"; h0="$(git -C "$W" rev-parse HEAD)"; w_other; out="$(whs)"
chk "W2 他の窓が変えた path を手元で編集中なら、HEAD は進まず、編集は残り、新しいファイルも降ろさず、記録に refused を残す" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && grep -q 'my wip' '$W/code.txt' && [ ! -e '$W/docs/new.md' ] && [ -e '$W/old.txt' ] && grep -q 'read-tree refused' '$sbx/st-w/sync.log' && grep -q 'code.txt' '$sbx/st-w/sync.log' && [ \"\$(git -C '$W' status --porcelain)\" = ' M code.txt' ]"
git -C "$W" checkout -q -- code.txt; out="$(whs)"
chk "W2b 編集を消した次の Stop で揃う" test "$out" = 0 && chk "W2c(揃った後の git status が空)" w_aligned
# W2d: stage 済みの手元変更でも同じ
w_mk; echo "staged wip" >>"$W/code.txt"; git -C "$W" add code.txt; h0="$(git -C "$W" rev-parse HEAD)"; w_other; whs >/dev/null
chk "W2d stage 済みの手元変更がある path が変わっていても HEAD は進まず、stage は残る" bash -c "[ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && [ \"\$(git -C '$W' status --porcelain)\" = 'M  code.txt' ]"

# W3: 母艦の main に push 前の commit がある → HEAD は動かず、その commit は main に残る
w_mk; echo u >"$W/unpushed.txt"; git -C "$W" add unpushed.txt; "$GAS" anno -C "$W" commit -q -m unpushed; u="$(git -C "$W" rev-parse HEAD)"; w_other; out="$(whs)"
chk "W3 push 前の commit がある母艦は、他の窓の push があっても HEAD が動かず(その commit が main に残り)、作業木も壊れない" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $u ] && [ \"\$(git -C '$W' rev-parse main)\" = $u ] && [ -z \"\$(git -C '$W' status --porcelain)\" ] && grep -q 'not a fast-forward' '$sbx/st-w/sync.log' && [ \"\$(cat '$W/code.txt')\" = code ]"
# W3b: 母艦に push 前の commit があり memory も書き換わった → push しない(今の挙動)、commit は残る
echo "M3" >"$WH/m3.md"; f0="$(w_fmain)"; out="$(whs)"
chk "W3b push 前の commit があって memory も書いたとき: Forgejo の main は動かず、HEAD も動かない(今の挙動)" test "$out" = 0 -a "$(w_fmain)" = "$f0" -a "$(git -C "$W" rev-parse HEAD)" = "$u"

# W4: 他の窓が足したファイルと同名の追跡外ファイルが母艦にある → 上書きしない、HEAD は進まない。どかすと進む
w_mk; mkdir -p "$W/docs"; echo "mine" >"$W/docs/new.md"; h0="$(git -C "$W" rev-parse HEAD)"; w_other; out="$(whs)"
chk "W4 同名の追跡外ファイルがあれば上書きせず、HEAD も進まず、記録に残る" \
  bash -c "[ '$out' = 0 ] && [ \"\$(cat '$W/docs/new.md')\" = mine ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && [ \"\$(cat '$W/code.txt')\" = code ] && grep -q 'docs/new.md' '$sbx/st-w/sync.log'"
rm -f "$W/docs/new.md"; rmdir "$W/docs" 2>/dev/null; out="$(whs)"
chk "W4b どかした次の Stop で揃う" bash -c "[ '$out' = 0 ]" && chk "W4c(揃った後の git status が空)" w_aligned
# W4d: .gitignore に載る追跡外ファイルでも上書きしない(read-tree -u は無視される追跡外を黙って上書きするので、hook 側で止める)
w_mk; git -C "$WO" pull -q --ff-only origin main; echo "ign" >"$WO/ign.txt"; git -C "$WO" add -f ign.txt; "$GAS" anno -C "$WO" commit -q -m "add ign.txt"; git -C "$WO" push -q origin main
echo "my secret" >"$W/ign.txt"; h0="$(git -C "$W" rev-parse HEAD)"; out="$(whs)"
chk "W4d .gitignore された同名の追跡外ファイルも上書きせず、HEAD は進まない" bash -c "[ '$out' = 0 ] && [ \"\$(cat '$W/ign.txt')\" = 'my secret' ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && grep -q 'ign.txt' '$sbx/st-w/sync.log'"

# W4r: 他の窓が old.txt を ign.txt へ rename(R100)し、移動先の名前が母艦では .gitignore 済みの追跡外ファイル(鍵のような)→ 上書きせず、HEAD も進まない
# (git diff は rename を既定で検出し --diff-filter=A に出ないので、事前検査は --no-renames で見る。tech の .hex-token がこの形)
w_mk; git -C "$WO" pull -q --ff-only origin main; git -C "$WO" mv old.txt ign.txt; "$GAS" anno -C "$WO" commit -q -m "rename old.txt to ign.txt"; git -C "$WO" push -q origin main
chk "W4r0 対照: 他の窓の commit は old.txt → ign.txt の rename(100%)" test "$(git -C "$WO" diff -M --name-status HEAD~1 HEAD | cut -c1-4)" = R100
echo "MINE" >"$W/ign.txt"; h0="$(git -C "$W" rev-parse HEAD)"; out="$(whs)"
chk "W4r rename の移動先が .gitignore 済みの追跡外ファイルなら、上書きせず(中身 MINE が残る)、HEAD も進まず、記録に残る" \
  bash -c "[ '$out' = 0 ] && [ \"\$(cat '$W/ign.txt')\" = MINE ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && [ -e '$W/old.txt' ] && grep -q 'ign.txt' '$sbx/st-w/sync.log'"
rm -f "$W/ign.txt"; out="$(whs)"
chk "W4r2 どかした次の Stop で rename が降りて揃う(old.txt が消え ign.txt が現れる)" bash -c "[ '$out' = 0 ] && [ ! -e '$W/old.txt' ] && [ \"\$(cat '$W/ign.txt')\" = old ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ]"

# W11: submodule(gitlink)。tech の .claude/_core がこの形。他の窓が pointer を進める commit は頻繁に来る
sg() { git -c protocol.file.allow=always "$@"; }
sm_mk() {
  w_mk; local sb="$sbx/w/sub" i; rm -rf "$sb"; git init -q -b main "$sb"
  for i in 1 2 3; do echo "s$i" >"$sb/f.txt"; git -C "$sb" add -A; "$GAS" anno -C "$sb" commit -q -m "s$i"; eval "SM$i=$(git -C "$sb" rev-parse HEAD)"; done
  sg -C "$WO" pull -q --ff-only origin main; sg -C "$WO" submodule add -q "$sb" .claude/_core 2>/dev/null; git -C "$WO/.claude/_core" checkout -q "$SM1"
  git -C "$WO" add -A; "$GAS" anno -C "$WO" commit -q -m "add submodule at s1"; git -C "$WO" push -q origin main
  sg -C "$W" pull -q --ff-only origin main; sg -C "$W" submodule update -q --init 2>/dev/null
  # 他の窓: submodule の pointer を s2 へ + code.txt も変える
  git -C "$WO/.claude/_core" checkout -q "$SM2"; echo code2 >"$WO/code.txt"; git -C "$WO" add -A; "$GAS" anno -C "$WO" commit -q -m "bump submodule to s2"; git -C "$WO" push -q origin main
  SMW="$W/.claude/_core"
}
sm_mk; h0="$(git -C "$W" rev-parse HEAD)"; out="$(whs)"
chk "W11a 母艦の submodule が H0 の pointer のまま clean: HEAD・index の gitlink が N(s2)になり、code.txt も降り、submodule の作業木は古い s1 のまま(checkout しない)で、git status は ' M .claude/_core' だけ" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ] && [ \"\$(git -C '$W' ls-files -s .claude/_core | cut -d' ' -f2)\" = $SM2 ] && [ \"\$(git -C '$SMW' rev-parse HEAD)\" = $SM1 ] && [ \"\$(cat '$W/code.txt')\" = code2 ] && [ \"\$(git -C '$W' status --porcelain)\" = ' M .claude/_core' ]"
chk "W11a2 記録に「submodule の pointer が進んだ ... git submodule update が要る」が 1 行残る" bash -c "[ \"\$(grep -c 'submodule の pointer が進んだ: .claude/_core' '$sbx/st-w/sync.log')\" = 1 ] && grep 'submodule の pointer' '$sbx/st-w/sync.log' | grep -q 'git submodule update'"
sg -C "$W" submodule update -q 2>/dev/null
chk "W11a3 git submodule update をすれば git status が空になる" bash -c "[ -z \"\$(git -C '$W' status --porcelain)\" ] && [ \"\$(git -C '$SMW' rev-parse HEAD)\" = $SM2 ]"
# W11b: 母艦が submodule を手元で進めている(pointer は stage していない)→ read-tree は通る。手元の submodule は巻き戻さず、stage に取り消しの差分も出ない
sm_mk; git -C "$SMW" checkout -q "$SM3"; out="$(whs)"
chk "W11b 手元で submodule を s3 に進めただけ(未 stage): HEAD は進み、submodule は s3 のまま、stage の差分は無く' M .claude/_core' が出る" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ] && [ \"\$(git -C '$SMW' rev-parse HEAD)\" = $SM3 ] && [ -z \"\$(git -C '$W' diff --cached --name-only)\" ] && [ \"\$(git -C '$W' status --porcelain)\" = ' M .claude/_core' ] && [ \"\$(git -C '$W' ls-files -s .claude/_core | cut -d' ' -f2)\" = $SM2 ]"
# W11c: pointer を stage 済み(index の gitlink が H0 とも N とも違う)→ read-tree が拒む。HEAD は進まず、stage は残る
sm_mk; git -C "$SMW" checkout -q "$SM3"; git -C "$W" add .claude/_core; h0="$(git -C "$W" rev-parse HEAD)"; out="$(whs)"
chk "W11c pointer を stage 済み(s3)なら read-tree が拒み、HEAD は進まず、stage は残り、code.txt も降ろさず、記録に refused を残す" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && [ \"\$(git -C '$W' ls-files -s .claude/_core | cut -d' ' -f2)\" = $SM3 ] && [ \"\$(cat '$W/code.txt')\" = code ] && grep -q 'read-tree refused' '$sbx/st-w/sync.log' && grep -q '_core' '$sbx/st-w/sync.log'"
# W11d: submodule の中身を編集中 → 中身は触らない
sm_mk; echo wip >>"$SMW/f.txt"; out="$(whs)"
chk "W11d submodule の中を編集中でも HEAD は進み、その編集は残る" bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ] && grep -q wip '$SMW/f.txt'"

# W5: 手元の memory 変更と、他の窓の memory 以外の push が同時 → push しない(今の挙動)。作業木・index は壊れず、pull(ff)した次の Stop で memory が上がる
w_mk; echo "AL" >"$WH/a.md"; echo "BL" >"$WH/b.md"; h0="$(git -C "$W" rev-parse HEAD)"; f0="$(git -C "$WF" rev-parse main)"; w_other; f1="$(w_fmain)"; out="$(whs)"
chk "W5 手元の memory 変更と他の窓の memory 以外の push が同時なら、Forgejo へ push せず(main 不変)、HEAD も動かず、作業木・index は memory の変更だけが残る" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$WF' rev-parse main)\" = $f1 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && [ \"\$(cat '$WH/a.md')\" = AL ] && [ \"\$(cat '$W/code.txt')\" = code ] && [ \"\$(git -C '$W' status --porcelain | sort | tr '\n' ',')\" = ' M .claude/memory/a.md,?? .claude/memory/b.md,' ] && grep -q 'HEAD..new has non-memory paths' '$sbx/st-w/sync.log'"
git -C "$W" pull -q --ff-only origin main 2>/dev/null; out="$(whs)"
chk "W5b pull(ff)した次の Stop で memory(a.md・b.md)が Forgejo に上がり、揃う" bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$WF' show main:.claude/memory/a.md)\" = AL ] && [ \"\$(git -C '$WF' show main:.claude/memory/b.md)\" = BL ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ] && [ -z \"\$(git -C '$W' status --porcelain)\" ]"

# W6: HEAD..N で変わらない path の手元の変更(他の窓の書きかけ)は残る
w_mk; echo wip >>"$W/other.txt"; echo staged >"$W/staged.txt"; git -C "$W" add staged.txt; echo untr >"$W/untr.txt"; w_other; out="$(whs)"
chk "W6 HEAD..N で変わらない path の手元の変更(未 commit・staged・追跡外)は残り、HEAD は進む" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = \"\$(git -C '$WF' rev-parse main)\" ] && [ \"\$(git -C '$W' status --porcelain | sort | tr '\n' ',')\" = ' M other.txt,?? untr.txt,A  staged.txt,' ] && [ \"\$(cat '$W/code.txt')\" = code2 ]"

# W7: update-ref が失敗する(ref lock)→ index・作業木だけ進んだ形を残さず、取り返す。lock を外した次の Stop で揃う
w_mk; w_other; touch "$W/.git/refs/heads/main.lock"; h0="$(git -C "$W" rev-parse HEAD)"; out="$(whs)"
chk "W7 update-ref が失敗(ref lock)しても、index・作業木は HEAD のまま戻り(git status が空)、記録に残る" \
  bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && [ -z \"\$(git -C '$W' status --porcelain)\" ] && [ \"\$(cat '$W/code.txt')\" = code ] && [ -e '$W/old.txt' ] && grep -q 'put back' '$sbx/st-w/sync.log'"
rm -f "$W/.git/refs/heads/main.lock"; out="$(whs)"
chk "W7b lock を外した次の Stop で揃う" bash -c "[ '$out' = 0 ]" && chk "W7c(揃った後の git status が空)" w_aligned
# W7d: memory も降りる push のとき、取り返しても memory の作業木は N の中身のまま(memory の同期は止めない)
w_mk; echo "AX" >"$WO/.claude/memory/a.md"; echo "BX" >"$WO/.claude/memory/b.md"; w_other; touch "$W/.git/refs/heads/main.lock"; out="$(whs)"
chk "W7d ref lock で HEAD が進まなくても、memory の降ろし(a.md・b.md)は作業木に残り、memory 以外は HEAD のまま" \
  bash -c "[ '$out' = 0 ] && [ \"\$(cat '$WH/a.md')\" = AX ] && [ \"\$(cat '$WH/b.md')\" = BX ] && [ \"\$(cat '$W/code.txt')\" = code ] && [ -z \"\$(git -C '$W' diff --cached --name-only)\" ]"
rm -f "$W/.git/refs/heads/main.lock"; out="$(whs)"
chk "W7e lock を外した次の Stop で揃う" bash -c "[ '$out' = 0 ]" && chk "W7f(揃った後の git status が空)" w_aligned

# W7g: read-tree の終わりから update-ref までの間に、他の窓が HEAD を動かした(PATH の git の薄い包みで、read-tree -m -u の直後に 1 回だけ
# 別の commit へ main を進める)→ 取り返す先は「いまの HEAD の木」。HEAD は他の窓の commit のまま、作業木・index はそれに揃う
mkdir -p "$sbx/shim"; realgit="$(command -v git)"
cat >"$sbx/shim/git" <<SH
#!/bin/bash
"$realgit" "\$@"; rc=\$?
case " \$* " in *" read-tree -m -u "*) if [ -n "\${SHIM_AFTER:-}" ] && [ ! -e "\$SHIM_FLAG" ]; then : >"\$SHIM_FLAG"; ( eval "\$SHIM_AFTER" ) >/dev/null 2>&1; fi ;; esac
exit \$rc
SH
chmod +x "$sbx/shim/git"
w_mk; echo "AX" >"$WO/.claude/memory/a.md"; w_other; h0="$(git -C "$W" rev-parse HEAD)"; rm -f "$sbx/shim.flag"
SHIM_AFTER="c=\$($realgit -c user.name=x -c user.email=x@x -C '$W' commit-tree \"\$($realgit -C '$W' rev-parse HEAD^{tree})\" -p $h0 -m other-window-commit) && $realgit -C '$W' update-ref refs/heads/main \$c"
out="$(PATH="$sbx/shim:$PATH" SHIM_FLAG="$sbx/shim.flag" SHIM_AFTER="$SHIM_AFTER" whs)"; h1="$(git -C "$W" rev-parse HEAD)"
chk "W7g update-ref の前に他の窓が HEAD を動かしても、HEAD はその commit のまま、index・作業木は(memory の降ろしを除いて)その HEAD に揃い、記録に残る" \
  bash -c "[ '$out' = 0 ] && [ -e '$sbx/shim.flag' ] && [ '$h1' != $h0 ] && [ \"\$(git -C '$W' log -1 --format=%s)\" = other-window-commit ] && [ \"\$(cat '$W/code.txt')\" = code ] && [ -e '$W/old.txt' ] && [ ! -e '$W/docs/new.md' ] && [ -z \"\$(git -C '$W' diff --cached --name-only)\" ] && [ \"\$(cat '$WH/a.md')\" = AX ] && [ \"\$(git -C '$W' status --porcelain)\" = ' M .claude/memory/a.md' ] && grep -q 'put back' '$sbx/st-w/sync.log'"

# W8: merge の途中は何もしない
w_mk; w_other; git -C "$W" rev-parse HEAD >"$W/.git/MERGE_HEAD"; h0="$(git -C "$W" rev-parse HEAD)"; out="$(whs)"
chk "W8 merge の途中(MERGE_HEAD)は HEAD も作業木も動かさず、記録に残る" bash -c "[ '$out' = 0 ] && [ \"\$(git -C '$W' rev-parse HEAD)\" = $h0 ] && [ \"\$(cat '$W/code.txt')\" = code ] && grep -q 'in progress' '$sbx/st-w/sync.log'"
rm -f "$W/.git/MERGE_HEAD"; out="$(whs)"; chk "W8b 途中でなくなった次の Stop で揃う" bash -c "[ '$out' = 0 ]" && chk "W8c(揃った後の git status が空)" w_aligned

# W9: stat だけ変わった(touch)追跡 file は、中身が同じなら進められる
w_mk; touch "$W/code.txt"; sleep 1; touch "$W/code.txt"; w_other; out="$(whs)"
chk "W9 touch しただけ(中身は同じ)の追跡 file が HEAD..N で変わる path でも、誤って拒まず揃う" bash -c "[ '$out' = 0 ]" && chk "W9b(揃った後の git status が空)" w_aligned
# W10: 2 回目以降(HEAD == N)は何もしない
h1="$(git -C "$W" rev-parse HEAD)"; out="$(whs)"; chk "W10 揃った後の Stop は何も変えない" test "$out" = 0 -a "$(git -C "$W" rev-parse HEAD)" = "$h1" -a -z "$(git -C "$W" status --porcelain)"

echo "# 速度"
ms() { local s e; s=$(date +%s%N); "$@" >/dev/null; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }
export MEMSYNC_FETCH_EVERY=600
sleep 1; hs >/dev/null   # 追いつかせる
env -u CLAUDE_CODE_REMOTE MEMSYNC_REPO="$host" MEMSYNC_STATE="$sbx/st-host" bash "$HOOK" </dev/null; touch "$sbx/st-host/last-run" "$sbx/st-host/last-fetch"
t_idle=$(ms env -u CLAUDE_CODE_REMOTE MEMSYNC_REPO="$host" MEMSYNC_STATE="$sbx/st-host" bash "$HOOK" </dev/null)
echo "# S1 差分なし・fetch 間隔内の Stop の所要: ${t_idle} ms(前景。find と stamp だけ)"
echo x >"$H/s.md"
t_dirty=$(ms env -u CLAUDE_CODE_REMOTE MEMSYNC_REPO="$host" MEMSYNC_STATE="$sbx/st-host" bash "$HOOK" </dev/null)
echo "# S2 memory が書き換わった Stop の前景の所要: ${t_dirty} ms(worker は切り離す)"
chk "S3 差分なしの Stop は 100 ms 未満(前景)" test "$t_idle" -lt 100
sleep 2
echo "1..$n"; [ "$fail" = 0 ] && echo "ALL OK" || echo "FAILED"
exit "$fail"
