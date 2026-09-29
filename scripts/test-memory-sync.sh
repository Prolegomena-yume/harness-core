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

# 「Forgejo」: seed 後に main へ memory 以外を含む push を弾く pre-receive(tech の unprotected_file_patterns の模し)を張る
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
  bad=$(printf '%s\n' "$files" | grep -v '^.claude/memory/' | head -1)
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
