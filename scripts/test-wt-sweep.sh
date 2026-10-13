#!/usr/bin/env bash
# scripts/wt-sweep.sh の test。一時ディレクトリに git リポと linked worktree を作り、
# 4 条件それぞれで「残す」になること、submodule 付きが --force で消えること、dry-run で何も消えないことを縛る。
# 実リポ・~/yumemism_repo・~/old-pc には触らない(WT_SWEEP_ROOT / WT_SWEEP_EXCLUDE を一時ディレクトリへ向ける)。
# 使い方: bash scripts/test-wt-sweep.sh
set -uo pipefail
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$core/scripts/wt-sweep.sh"; GAS="$core/scripts/git-as"
n=0; fail=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); echo "not ok $n - $1"; fail=1; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

sbx="$(cd -P "$(mktemp -d)" && pwd)"
pids=()
cleanup() { for p in "${pids[@]+"${pids[@]}"}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$sbx"; }   # 子(sleep)は親 pid 指名で止める
trap cleanup EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always   # file:// の submodule を許す(test 内だけ)

ROOT="$sbx/root"; OLDPC="$sbx/old-pc"; mkdir -p "$ROOT" "$OLDPC" "$sbx/home/.codex/worktrees" "$sbx/outside"
export HOME="$sbx/home"   # ~/.codex の対象外を、実 HOME に触れずに試す
export WT_SWEEP_ROOT="$ROOT" WT_SWEEP_EXCLUDE="$OLDPC"
R="$ROOT/r"
g() { "$GAS" anno -C "$R" "$@"; }                 # r(リポ本体)に対する git
gw() { local w="$1"; shift; "$GAS" anno -C "$w" "$@"; }

# ---- 材料: submodule の remote、リポ r、別リポ q(worktree 無し) ----
git init -q --bare -b main "$sbx/sub.git"
git init -q -b main "$sbx/subwork"; echo s1 >"$sbx/subwork/f"
git -C "$sbx/subwork" add -A; "$GAS" anno -C "$sbx/subwork" commit -q -m s1
git -C "$sbx/subwork" push -q "$sbx/sub.git" main

git init -q -b main "$R"; echo a >"$R/a.txt"
git -C "$R" add -A; g commit -q -m init
g submodule add -q "$sbx/sub.git" .claude/_core >/dev/null 2>&1
g commit -q -m "add _core"
git init -q -b main "$ROOT/q"; echo q >"$ROOT/q/q.txt"; git -C "$ROOT/q" add -A; "$GAS" anno -C "$ROOT/q" commit -q -m q

old() { touch -d '2 days ago' "$(git -C "$1" rev-parse --absolute-git-dir)/HEAD"; }   # HEAD ファイルを古くする
mk() { # <name> : main と同じ commit の枝で worktree(HEAD ファイルは古い)
  g worktree add -q -b "br-$1" "$ROOT/$1" main 2>/dev/null; old "$ROOT/$1"
}

mk wt-ok                       # 全条件を満たす → 消す
mk wt-ok-p                     # 消す(--only 用)
mk wt-ok-q                     # 消す(--only dry-run 用)
mk wt-unmerged; echo u >"$ROOT/wt-unmerged/u.txt"; gw "$ROOT/wt-unmerged" add -A; gw "$ROOT/wt-unmerged" commit -q -m u   # [1]
mk wt-dirty; echo x >>"$ROOT/wt-dirty/a.txt"                                   # [2] tracked の変更
mk wt-untracked; echo x >"$ROOT/wt-untracked/new.txt"                          # [2] untracked
mk wt-untracked5; for i in 1 2 3 4 5; do echo x >"$ROOT/wt-untracked5/f$i.txt"; done
mk wt-mixed; echo x >"$ROOT/wt-mixed/new.txt"; echo y >>"$ROOT/wt-mixed/a.txt"
mk wt-cwd                                                                      # [3] cwd
mk wt-arg                                                                      # [3] cmdline
mk wt-arg2                                                                     # 後ろに文字が続く別名の引数 → 巻き込まない
mk wt-ancestor                                                                 # 呼び出し元の cmdline は数えない
mk wt-anc-cwd                                                                  # 呼び出し元の cwd は数える
g worktree add -q -b br-wt-new "$ROOT/wt-new" main 2>/dev/null                 # [4] HEAD ファイルが新しい(old しない)
mk wt-locked; g worktree lock "$ROOT/wt-locked"
mk wt-sub;       gw "$ROOT/wt-sub" submodule update --init -q >/dev/null 2>&1; old "$ROOT/wt-sub"
mk wt-sub-dirty; gw "$ROOT/wt-sub-dirty" submodule update --init -q >/dev/null 2>&1; echo z >"$ROOT/wt-sub-dirty/.claude/_core/untracked"; old "$ROOT/wt-sub-dirty"
mk wt-sub-unpushed; gw "$ROOT/wt-sub-unpushed" submodule update --init -q >/dev/null 2>&1
( cd "$ROOT/wt-sub-unpushed/.claude/_core" && echo s2 >f2 && git add f2 && "$GAS" anno commit -q -m s2 )   # remote に無い commit
gw "$ROOT/wt-sub-unpushed" add .claude/_core; gw "$ROOT/wt-sub-unpushed" commit -q -m "bump _core"
git -C "$R" update-ref refs/heads/main "$(git -C "$ROOT/wt-sub-unpushed" rev-parse HEAD)"                   # 親は main に入った → [1] は通る
old "$ROOT/wt-sub-unpushed"
# origin/main だけに入っている枝(base 列が origin/main になる)
mk wt-origin
echo o >"$ROOT/wt-origin/o.txt"; gw "$ROOT/wt-origin" add -A; gw "$ROOT/wt-origin" commit -q -m o
git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$ROOT/wt-origin" rev-parse HEAD)"; old "$ROOT/wt-origin"
# $WT_SWEEP_EXCLUDE の下
g worktree add -q -b br-oldpc "$OLDPC/wt-oldpc" main 2>/dev/null; old "$OLDPC/wt-oldpc"

# main の動かした後で wt-ok などは main の祖先でなくなる可能性があるので、main を進めた分を取り込んだ形に直す
# (wt-sub-unpushed の commit が main に入った → 他の worktree の HEAD(init)は main の祖先のまま。問題なし)

g worktree add -q -b br-codex "$HOME/.codex/worktrees/wt-codex" main 2>/dev/null; old "$HOME/.codex/worktrees/wt-codex"   # ~/.codex の下(対象外・出力にも出ない)
g worktree add -q -b br-outside "$sbx/outside/wt-outside" main 2>/dev/null; old "$sbx/outside/wt-outside"            # ROOT の外(全条件を満たしても「残す」)

# プロセス
( cd "$ROOT/wt-cwd" && exec sleep 600 ) >/dev/null 2>&1 & pids+=($!)
bash -c 'sleep 600; :' _ "$ROOT/wt-arg/some/file" >/dev/null 2>&1 & pids+=($!)
bash -c 'sleep 600; :' _ "$ROOT/wt-arg2-extra/file" >/dev/null 2>&1 & pids+=($!)
sleep 0.3

has()  { grep -qP -- "$1" <<<"$out"; }                       # out に正規表現が 1 行でも当たる
nhas() { ! has "$1"; }
col()  { grep -P "\t$ROOT/$1\t" <<<"$out" | head -1 | cut -f"$2"; }   # <wt 名> <列>
verdict() { col "$1" 1; }
gone() { local d; for d in "$@"; do [ ! -e "$ROOT/$d" ] || { echo "残ってる $d" >&2; return 1; }; done; }
kept() { local d; for d in "$@"; do [ -d "$ROOT/$d" ] || { echo "消えてる $d" >&2; return 1; }; done; }

# ---- dry-run ----
out="$("$SWEEP" 2>&1)"; rc=$?
chk "D0 dry-run は exit 0" test "$rc" = 0
chk "D1 dry-run で何も消えない(全 worktree が残る、管理領域も)" bash -c "$(declare -f kept); ROOT='$ROOT'; kept wt-ok wt-ok-p wt-sub wt-sub-dirty wt-unmerged wt-dirty wt-cwd wt-locked wt-new wt-origin && [ -d '$R/.git/worktrees/wt-ok' ] && [ -d '$R/.git/worktrees/wt-sub/modules' ]"
chk "D2 全条件を満たす wt-ok は「消す」" test "$(verdict wt-ok)" = 消す
chk "D3 [1] 未 merge は残す" has "^残す\t.*\t$ROOT/wt-unmerged\t.*\[1\]"
chk "D4 [2] tracked の変更は残す(理由は「変更あり」)" has "^残す\t.*\t$ROOT/wt-dirty\t.*\[2\] 変更あり"
chk "D5 [2] untracked だけでも残す(理由は「未追跡のみ」+ ファイル名)" has "^残す\t.*\t$ROOT/wt-untracked\t.*\[2\] 未追跡のみ 1 件: new.txt"
chk "D5b 未追跡 5 件なら名前は 3 つまで + ほか" has "^残す\t.*\t$ROOT/wt-untracked5\t.*\[2\] 未追跡のみ 5 件: [^,]+, [^,]+, [^,ほ]+ ほか"
chk "D5c 未追跡と追跡の変更が混じれば「変更あり」" has "^残す\t.*\t$ROOT/wt-mixed\t.*\[2\] 変更あり"
d5d() { has "^#   [0-9]+\t\[2\] 未追跡のみ" && has "^#   [0-9]+\t\[2\] 変更あり"; }
chk "D5d 内訳も 2 つに分かれる" d5d
chk "D6 [3] cwd が中にあるプロセスがあれば残す(pid を出す)" has "^残す\t.*\t$ROOT/wt-cwd\t.*\[3\] 使用中 pid=${pids[0]}\(sleep\):cwd"
chk "D7 [3] 引数にパスを含むプロセスがあれば残す" has "^残す\t.*\t$ROOT/wt-arg\t.*\[3\] 使用中 .*:cmdline"
chk "D8 別名(wt-arg2-extra)を引数に持つプロセスは wt-arg2 を止めない" test "$(verdict wt-arg2)" = 消す
chk "D9 [4] HEAD ファイルが新しければ残す" has "^残す\t.*\t$ROOT/wt-new\t.*\[4\]"
chk "D10 locked は残す" has "^残す\t.*\t$ROOT/wt-locked\t.*locked"
chk "D11 submodule 付きで clean・HEAD が remote にある wt-sub は「消す」" test "$(verdict wt-sub)" = 消す
chk "D12 submodule が dirty なら残す" has "^残す\t.*\t$ROOT/wt-sub-dirty\t.*\[2\]"
chk "D13 submodule の HEAD が remote に無ければ残す" has "^残す\t.*\t$ROOT/wt-sub-unpushed\t.*remote に無い"
chk "D14 base 列: main に入っていれば main、origin/main だけなら origin/main(それでも消す)" test "$(col wt-ok 6)/$(col wt-origin 6)/$(verdict wt-origin)" = main/origin/main/消す
d15() { nhas "^(消す|残す)\t.*wt-oldpc" && has '^# 対象外.*2 本' && nhas 'wt-codex'; }
chk "D15 WT_SWEEP_EXCLUDE の下は行に出ない(末尾で数だけ書く)" d15
chk "D16 リポ本体と worktree の無いリポ q は行に出ない" nhas "(消す|残す)\t.*\t($ROOT/r|$ROOT/q)\t"
d17() { has '^# 消す [0-9]+ 本、合計 .*残す [0-9]+ 本' && has '^# 残す理由の内訳'; }
chk "D17 末尾に「消す N 本、合計 …」と残す理由の内訳" d17
chk "D18 サイズ列が入る(wt-ok は数字+K/M/G)" bash -c "[[ \"\$0\" =~ ^[0-9.]+[KMG]\$ ]]" "$(col wt-ok 2)"
chk "D20 ROOT の外の worktree は全条件を満たしても「残す」(理由に出る)" has "^残す\\t.*\\t$sbx/outside/wt-outside\\t.*対象外"
want_del="wt-ok wt-ok-p wt-ok-q wt-arg2 wt-ancestor wt-anc-cwd wt-sub wt-origin"
got_del="$(awk -F'\t' '$1=="消す"{n=split($4,a,"/"); print a[n]}' <<<"$out" | sort | paste -sd' ')"
chk "D19 消す行の集合が想定どおり($want_del)" test "$got_del" = "$(tr ' ' '\n' <<<"$want_del" | sort | paste -sd' ')"

# ---- --only(dry-run と apply) ----
o="$("$SWEEP" --only "$ROOT/wt-ok-q" 2>&1)"; rc=$?
chk "O1 --only の dry-run: 消すなら exit 0 で実体は残る" bash -c "[ $rc = 0 ] && [ -d '$ROOT/wt-ok-q' ] && grep -q '消す(dry-run' <<<\"\$0\"" "$o"
o="$("$SWEEP" --only "$ROOT/wt-dirty" --apply 2>&1)"; rc=$?
chk "O2 --only --apply でも条件を満たさなければ exit 3 で消さない" bash -c "[ $rc = 3 ] && [ -d '$ROOT/wt-dirty' ] && grep -q '\[2\]' <<<\"\$0\"" "$o"
o="$("$SWEEP" --only "$R" 2>&1)"; rc=$?
chk "O3 --only でリポ本体を指すと exit 3(対象外)" bash -c "[ $rc = 3 ] && grep -q 'main worktree' <<<\"\$0\"" "$o"
o="$("$SWEEP" --only "$ROOT/wt-ok-p" --apply 2>&1)"; rc=$?
chk "O4 --only --apply で 1 本だけ消える(枝は残り、他は触らない)" bash -c "[ $rc = 0 ] && [ ! -d '$ROOT/wt-ok-p' ] && [ -d '$ROOT/wt-ok' ] && git -C '$R' rev-parse --verify -q refs/heads/br-wt-ok-p >/dev/null && ! git -C '$R' worktree list | grep -q wt-ok-p"
o="$("$SWEEP" --only "$OLDPC/wt-oldpc" --apply 2>&1)"; rc=$?
chk "O5 --only で WT_SWEEP_EXCLUDE の下を指すと exit 2 で消さない" bash -c "[ $rc = 2 ] && [ -d '$OLDPC/wt-oldpc' ]"
o="$(bash -c 'bash "$1" --only "$2" 2>&1; true' _ "$SWEEP" "$ROOT/wt-ancestor")"
chk "O6 呼び出し元の cmdline にパスがあっても止まらない(祖先の cmdline は数えない)" bash -c "grep -q '消す(dry-run' <<<\"\$0\"" "$o"
o="$(bash -c 'cd "$2"; bash "$1" --only "$2" 2>&1; true' _ "$SWEEP" "$ROOT/wt-anc-cwd")"
chk "O7 呼び出し元の cwd が中にあれば止まる(祖先の cwd は数える)" bash -c "grep -q '^残す' <<<\"\$0\" && grep -q '\[3\].*:cwd' <<<\"\$0\"" "$o"

o="$("$SWEEP" --only "$HOME/.codex/worktrees/wt-codex" --apply 2>&1)"; rc=$?
chk "O8 --only で ~/.codex の下を指すと exit 2 で消さない" bash -c "[ $rc = 2 ] && [ -d '$HOME/.codex/worktrees/wt-codex' ]"
o2="$("$SWEEP" --exclude '*/wt-ok-q' 2>&1)"
chk "O9 --exclude GLOB に一致する worktree は残す(理由に --exclude)" grep -qP "^残す\t.*\t$ROOT/wt-ok-q\t.*--exclude" <<<"$o2"

# ---- --apply(全体) ----
out="$("$SWEEP" --apply 2>&1)"; rc=$?
chk "A0 --apply は exit 0" test "$rc" = 0
chk "A1 消す行は実体が無くなる(submodule 付きも --force で)" bash -c "$(declare -f gone); ROOT='$ROOT'; gone wt-ok wt-arg2 wt-ancestor wt-anc-cwd wt-sub wt-origin wt-ok-q"
chk "A2 残す行は全部そのまま(未 merge・dirty・使用中・新しい・locked・submodule 絡み・EXCLUDE の下)" bash -c "$(declare -f kept); ROOT='$ROOT'; kept wt-unmerged wt-dirty wt-untracked wt-cwd wt-arg wt-new wt-locked wt-sub-dirty wt-sub-unpushed && [ -d '$OLDPC/wt-oldpc' ] && [ -d '$HOME/.codex/worktrees/wt-codex' ] && [ -d '$sbx/outside/wt-outside' ]"
chk "A3 枝は消えない" bash -c "git -C '$R' rev-parse --verify -q refs/heads/br-wt-ok >/dev/null && git -C '$R' rev-parse --verify -q refs/heads/br-wt-sub >/dev/null"
chk "A4 消した分の管理領域は prune されている" bash -c "! ls '$R/.git/worktrees' | grep -qE '^(wt-ok|wt-sub|wt-origin)\$'"
chk "A5 末尾に「削除した N 本」" has '^# 削除した [0-9]+ 本'
chk "A6 二度目の dry-run は消す 0 本(冪等)" bash -c "'$SWEEP' 2>&1 | grep -qP '^# 消す 0 本'"

echo "---"
echo "$n tests, $([ "$fail" = 0 ] && echo 'all ok' || echo 'FAILED')"
exit "$fail"
