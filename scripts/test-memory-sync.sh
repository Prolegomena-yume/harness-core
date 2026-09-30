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
