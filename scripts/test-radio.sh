#!/usr/bin/env bash
# scripts/radio と hooks/radio.sh のテスト(庵野 2026-11-22)。性質で縛る。
# 置き場は一時 dir(RADIO_HOME)。本物の ~/.local/state/harness-radio は触らない。時計は RADIO_NOW で固定。
# usage: bash scripts/test-radio.sh
set -u
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
radio="$here/radio"; hook="$here/../hooks/radio.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export RADIO_HOME="$work/home"; mkdir -p "$RADIO_HOME"
export HOME_REAL="$HOME"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
ng()  { fail=$((fail+1)); echo "  FAIL $1 ${2:-}"; }
T0=1795000000
setnow() { export RADIO_NOW="$1"; }
setnow $T0

# hook を叩く: ev sid [json 追加の python 辞書 update]。stdout の additionalContext を返す(無ければ空)。
H() { # H <event> <sid> [extra-json]
  python3 - "$1" "$2" "${3:-{\}}" <<'PY' | bash "$hook"
import json,sys
ev,sid,extra=sys.argv[1:4]
d={"hook_event_name":ev,"session_id":sid,"cwd":"/nonexistent"}
d.update(json.loads(extra)); print(json.dumps(d))
PY
}
ctx() { python3 -c 'import json,sys
t=sys.stdin.read()
print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t.strip() else "",end="")'; }
HC() { H "$@" | ctx; }
SA=aaaaaaaa-1111; SB=bbbbbbbb-2222; SC=cccccccc-3333

# fixture のリポ(origin は URL だけ、網は使わない)
mkrepo() { # mkrepo <dir> <name>
  git init -q -b main "$1" && git -C "$1" config user.email t@t && git -C "$1" config user.name tester
  git -C "$1" remote add origin "ssh://git@git.example.test/company/$2.git"
  echo base > "$1/a.txt"; git -C "$1" add -A && git -C "$1" commit -qm init
}
mkrepo "$work/r1" foo
ch="company__foo"

echo "== 流す口"
"$radio" post --from 鷹野 --kind 裁定 --ref canon/x.md "X を採る" >/dev/null && ok "post 裁定が流れる" || ng "post"
"$radio" post --from 鷹野 --kind 工事 "x" 2>/dev/null; [ $? = 4 ] && ok "post は 工事 を打てない(exit 4)" || ng "工事 post"
"$radio" post --from 鷹野 --kind 凍結 "x" 2>/dev/null; [ $? = 4 ] && ok "post は 凍結 を打てない" || ng "凍結 post"
"$radio" post --from 鷹野 --kind 判決 "x" 2>/dev/null; [ $? = 4 ] && ok "閉じた種別の外は exit 4" || ng "種別集合"
"$radio" post --from 鷹野 "sk-abcdefghijklmnopqrstuv" 2>/dev/null; [ $? = 4 ] && ok "秘密に見える字面は断る" || ng "秘密"
"$radio" post --kind 告知 "x" 2>/dev/null; [ $? = 2 ] && ok "--from 必須" || ng "--from"
"$radio" post --from 鷹野 --kind 告知 --target "a	b" "tab
nl" >/dev/null; n=$(wc -l < "$RADIO_HOME/harness.tsv"); [ "$n" = 2 ] && ok "改行・TAB は潰され 1 行" || ng "改行潰し" "$n"
big=$(python3 -c 'print("あ"*3000)')
"$radio" post --from 鷹野 --kind 告知 "$big" >/dev/null
last=$(tail -1 "$RADIO_HOME/harness.tsv"); bytes=$(printf '%s\n' "$last" | wc -c)
[ "$bytes" -le 4096 ] && grep -q '切れた 3000 字、全文は' <<<"$last" && ls "$RADIO_HOME/messages"/*.md >/dev/null 2>&1 && ok "4096 バイト超は要旨を切り全文を messages/ に残す($bytes B)" || ng "4096" "$bytes"
# 並行 post で行が壊れない
for i in $(seq 20); do "$radio" post --from t$i --kind 告知 "並行 $i" >/dev/null & done; wait
bad=$(awk -F'\t' 'NF!=6' "$RADIO_HOME/harness.tsv" | wc -l); [ "$bad" = 0 ] && ok "並行 20 post でも 6 列の行のまま" || ng "並行" "$bad"
rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"

echo "== 読む口: 二度出さない・自分の行を出さない・初回は末尾から"
"$radio" post --from 鷹野 --kind 告知 --session $SB "古い流れ" >/dev/null
HC UserPromptSubmit $SB >/dev/null
out=$(HC UserPromptSubmit $SA); [ -z "$out" ] && ok "初回は流れを今の末尾から(昔の告知を浴びない)" || ng "初回" "$out"
setnow $((T0+10)); "$radio" post --from 真壁 --kind 告知 --session $SB "新しい 1" >/dev/null
out=$(HC UserPromptSubmit $SA)
grep -q '新しい 1' <<<"$out" && grep -q '^無線。' <<<"$out" && ok "新しい行を頭の 1 行つきで出す" || ng "新行" "$out"
out=$(HC UserPromptSubmit $SA); [ -z "$out" ] && ok "二度出さない" || ng "二度目" "$out"
out=$(HC PostToolBatch $SA '{"tool_calls":[]}'); [ -z "$out" ] && ok "PostToolBatch でも二度出さない" || ng "batch 二度目"
"$radio" post --from 鷹野 --kind 告知 --session $SA "自分の放送" >/dev/null
out=$(HC UserPromptSubmit $SA); [ -z "$out" ] && ok "自分の行を出さない" || ng "自分" "$out"
out=$(HC UserPromptSubmit $SB); grep -q '自分の放送' <<<"$out" && ok "他のセッションには出る(自分の行は B から見れば他人)" || ng "他人" "$out"

echo "== 上限で畳む"
for i in $(seq 20); do "$radio" post --from 真壁 --kind 告知 --session $SB "行 $i $(python3 -c 'print("字"*60)')" >/dev/null; done
out=$(HC UserPromptSubmit $SA)
nl=$(grep -c '^行 \|^\[告知\]' <<<"$out"); chars=${#out}
grep -q 'ほか [0-9]* 行は `radio tail`' <<<"$out" && [ "$nl" -le 8 ] && [ "$chars" -le 1500 ] && ok "20 行 → 8 行以下・1,500 字以下に畳み『ほか N 行』($nl 行 $chars 字)" || ng "上限" "$nl $chars"
python3 - <<'PY' "$RADIO_HOME" || exit 1
PY
"$radio" post --from 真壁 --kind 告知 --session $SB "$(python3 -c 'print("長"*900)')" >/dev/null
out=$(HC UserPromptSubmit $SA); [ "$(grep -c . <<<"$out")" -ge 2 ] && ! awk '{ if (length($0)>201) exit 1 }' <<<"$(sed 1d <<<"$out")" 2>/dev/null; l=$(sed 1d <<<"$out" | python3 -c 'import sys;print(max(len(x.rstrip("\n")) for x in sys.stdin))'); [ "${l:-0}" -le 200 ] && ok "1 行は 200 字まで($l)" || ng "行長" "$l"

echo "== rotate の後に読み落とさず、二度出さない"
rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; setnow $T0
HC UserPromptSubmit $SA >/dev/null; "$radio" post --from 鷹野 --session $SB "月内 1" >/dev/null
setnow $((T0+60)); HC UserPromptSubmit $SA >/dev/null   # 月内 1 を読んだ
"$radio" post --from 鷹野 --session $SB "rotate 前の未読" >/dev/null
setnow $((T0+40*86400)); "$radio" rotate >/dev/null
"$radio" post --from 鷹野 --session $SB "rotate 後の新行" >/dev/null
ls "$RADIO_HOME"/harness.tsv.* >/dev/null 2>&1 && ok "rotate が旧 file を退避した" || ng "rotate なし"
out=$(HC UserPromptSubmit $SA)
grep -q 'rotate 前の未読' <<<"$out" && grep -q 'rotate 後の新行' <<<"$out" && ! grep -q '月内 1' <<<"$out" && ok "rotate をまたいで未読は読み落とさず、読んだ分は再掲しない" || ng "rotate 読み" "$out"
out=$(HC UserPromptSubmit $SA); [ -z "$out" ] && ok "rotate 後も二度出さない" || ng "rotate 二度" "$out"

echo "== 壊れた入力で exit 0 ・何も出さない"
rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; setnow $T0
out=$(echo 'not json{' | bash "$hook"); rc=$?; [ $rc = 0 ] && [ -z "$out" ] && ok "壊れた stdin" || ng "壊れた stdin" "$rc $out"
out=$(: | bash "$hook"); rc=$?; [ $rc = 0 ] && [ -z "$out" ] && ok "空の stdin" || ng "空 stdin"
out=$(echo '{"hook_event_name":"PostToolBatch"}' | bash "$hook"); rc=$?; [ $rc = 0 ] && [ -z "$out" ] && ok "session_id 無し" || ng "sid 無し"
HC UserPromptSubmit $SA >/dev/null; echo '{{{' > "$RADIO_HOME/cursor/$SA"
"$radio" post --from 鷹野 --session $SB "壊れ位置の後" >/dev/null
out=$(H UserPromptSubmit $SA | cat); rc=$?; [ $rc = 0 ] && ok "壊れた位置の file でも exit 0($(echo "$out" | head -c 40))" || ng "壊れ位置"
out=$(HC UserPromptSubmit $SA); [ -z "$out" ] && ok "壊れた位置は作り直され、以後は静か(初回扱い)" || ng "位置の復旧" "$out"
RADIO_HOME="$work/none" bash "$hook" <<<'{"hook_event_name":"UserPromptSubmit","session_id":"x"}' >"$work/o"; rc=$?; [ $rc = 0 ] && [ ! -s "$work/o" ] && [ ! -e "$work/none" ] && ok "置き場が無い: exit 0・何も出さず・作らない" || ng "置き場無し"
mkdir -p "$work/ro/cursor"; chmod 555 "$work/ro/cursor"
RADIO_HOME="$work/ro" bash "$hook" <<<'{"hook_event_name":"UserPromptSubmit","session_id":"x"}' >"$work/o"; rc=$?; chmod 755 "$work/ro/cursor"; [ $rc = 0 ] && ok "書けない置き場でも exit 0" || ng "書けない置き場"
printf '{"hook_event_name":"PostToolBatch","session_id":"x","tool_calls":"oops"}' | bash "$hook" >/dev/null; [ $? = 0 ] && ok "tool_calls が壊れていても exit 0" || ng "tool_calls 壊れ"

echo "== 札"
rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; setnow $T0
"$radio" board set dleam --from 鷹野 --session $SB --until +60m --match dleam.yumemism.com "A→B の切り替え中" >/dev/null
out=$(HC UserPromptSubmit $SA); grep -q '札 dleam(鷹野@bbbbbbbb' <<<"$out" && grep -q 'A→B の切り替え中' <<<"$out" && ok "加入(初回)で立っている札を出す" || ng "札 初回" "$out"
setnow $((T0+30)); out=$(HC UserPromptSubmit $SA); [ -z "$out" ] && ok "札は二度目の prompt では出さない" || ng "札 二度" "$out"
tc='{"tool_calls":[{"tool_name":"Bash","tool_input":{"command":"curl https://x.dleam.yumemism.com/api"},"tool_response":"HTTP 503"}]}'
out=$(HC PostToolBatch $SA "$tc"); [ -z "$out" ] && ok "踏んだ直後でも 15 分以内の再掲はしない(初回で出した)" || ng "再掲抑止" "$out"
setnow $((T0+16*60)); out=$(HC PostToolBatch $SA "$tc"); grep -q '札 dleam' <<<"$out" && ok "合言葉を踏んだら 15 分後に札を出し直す" || ng "踏んだ再掲" "$out"
out=$(HC PostToolBatch $SA "$tc"); [ -z "$out" ] && ok "出し直しは 15 分に 1 回まで" || ng "15 分" "$out"
setnow $((T0+40*60)); out=$(HC PostToolBatch $SA '{"tool_calls":[{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":"x"}]}'); [ -z "$out" ] && ok "触れていない束には出さない" || ng "無関係" "$out"
# サブエージェント: 踏んだときだけ
setnow $((T0+60*60-30)); out=$(HC PostToolBatch $SA "$(python3 -c "import json;d=json.loads('$tc');d['agent_id']='sub1';print(json.dumps(d))")"); grep -q '札 dleam' <<<"$out" && ok "サブエージェントにも踏んだときの 1 行は出る" || ng "サブ踏んだ" "$out"
setnow $((T0+10)); "$radio" post --from 鷹野 --kind 告知 --session $SB "流れ" >/dev/null
out=$(HC UserPromptSubmit $SA '{"agent_id":"sub2"}'); [ -z "$out" ] && ok "サブエージェントには流れを出さない" || ng "サブ流れ" "$out"
# 期限切れ
setnow $((T0+3*3600))
out=$(HC SessionStart cccccccc-3 '{"source":"startup"}'); grep -q '期限切れ、終わりの報が無い' <<<"$out" && ok "期限切れの札を『終わりの報が無い』と出す" || ng "期限切れ" "$out"
out=$(HC PostToolBatch $SA "$tc"); ! grep -q '札 dleam' <<<"$out" && ok "期限切れの札は踏んだときの再掲に使わない" || ng "期限切れ再掲" "$out"
"$radio" board set dleam --from 庵野 --force --session $SB "x" >/dev/null; "$radio" board clear dleam --from 鷹野 "完了" >/dev/null
[ -z "$("$radio" board)" ] && ok "clear で札が消える" || ng "clear"
"$radio" board set dleam --from 鷹野 --until +5m "a" >/dev/null; "$radio" board set dleam --from 庵野 --until +5m "b" >/dev/null 2>&1; [ $? = 3 ] && ok "同じ台に 2 人目は exit 3 で断る" || ng "二枚目"
"$radio" board set dleam --from 庵野 --until +5m --force "b" >/dev/null; grep -q '上書き' "$RADIO_HOME/harness.tsv" && ok "--force の上書きは流れに出る" || ng "force echo"
echo "-- resume は札だけ"
rm -rf "$RADIO_HOME/cursor"; setnow $T0; "$radio" board clear dleam --from 鷹野 >/dev/null; "$radio" board set dleam --from 鷹野 --until +60m "札" >/dev/null
HC UserPromptSubmit $SA >/dev/null; "$radio" post --from 鷹野 --kind 告知 --session $SB "未読の告知" >/dev/null
out=$(HC SessionStart $SA '{"source":"resume"}'); grep -q '札 dleam' <<<"$out" && ! grep -q '未読の告知' <<<"$out" && ok "resume/compact の SessionStart は札だけ(流れは動かさない)" || ng "resume" "$out"
out=$(HC UserPromptSubmit $SA); grep -q '未読の告知' <<<"$out" && ok "resume で流れを食わなかったので次の prompt で読める" || ng "resume 後" "$out"

echo "== 初回の裁定 24 時間"
rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; setnow $T0
"$radio" post --from 鷹野 --kind 裁定 --session $SB "古い裁定" >/dev/null
setnow $((T0+30*3600)); "$radio" post --from 大橋 --kind 裁定 --session $SB "新しい裁定" >/dev/null
setnow $((T0+31*3600)); out=$(HC UserPromptSubmit $SA)
grep -q '新しい裁定' <<<"$out" && ! grep -q '古い裁定' <<<"$out" && grep -q '関係があれば今の手に反映する' <<<"$out" && ok "初回は 24 時間以内の裁定を出し、裁定の行があれば強い扱いを足す" || ng "初回裁定" "$out"

echo "== base の進みと重なり"
rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; setnow $T0
git -C "$work/r1" worktree add -q -b work "$work/w1"; echo wip >> "$work/w1/a.txt"   # 作業木 w1: a.txt を触っている
TC="{\"cwd\":\"$work/w1\",\"tool_calls\":[]}"
HC UserPromptSubmit $SA "$TC" >/dev/null     # 加入(base=main の今の値が基準)。w1 は r1 の worktree で同じチャンネルに乗る
[ -f "$RADIO_HOME/cursor/$SA" ] && ok "cwd の worktree からそのリポのチャンネルに乗った" || ng "加入"
setnow $((T0+100)); out=$(HC UserPromptSubmit $SA "$TC"); [ -z "$out" ] && ok "base が動かなければ静か" || ng "base 静か" "$out"
echo m >> "$work/r1/a.txt"; git -C "$work/r1" commit -qam "main を進める"
setnow $((T0+200)); out=$(HC UserPromptSubmit $SA "$TC")
grep -q 'main が 1 commit 進んだ' <<<"$out" && grep -q '重なり: a.txt' <<<"$out" && grep -q 'main を進める' <<<"$out" && ok "base が進んだら 1 行に畳み、触っている file との重なりを出す" || ng "base 進み" "$out"
out=$(HC UserPromptSubmit $SA "$TC"); [ -z "$out" ] && ok "base の進みも二度出さない" || ng "base 二度" "$out"
echo n > "$work/r1/c.txt"; git -C "$work/r1" add -A; git -C "$work/r1" commit -qm "c だけ"
out=$(HC UserPromptSubmit $SA "$TC"); grep -q '重なりなし' <<<"$out" && ok "重ならない進みは『重なりなし』" || ng "重なりなし" "$out"
echo o > "$work/r1/d.txt"; git -C "$work/r1" add -A; git -C "$work/r1" commit -qm "自分の merge"
out=$(HC PostToolBatch $SA "{\"cwd\":\"$work/w1\",\"tool_calls\":[{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $work/r1 merge x\"},\"tool_response\":\"\"}]}"); [ -z "$out" ] && ok "自分の束が merge なら、その進みは出さない" || ng "自分 merge" "$out"
echo "-- 自分の push・merge・commit を黙る(cwd が別のリポ、cd・git -C・相対 cd・git-as・subshell)"
mkrepo "$work/r2" bar
mkdir -p "$work/r1/sub"; JF="$work/r1/a.txt"   # 加入に使う file(subdir 経由だと cd 先の dir は未知になる)
quiet_case() { # quiet_case <説明> <cwd> <command> : r1 の main を 1 commit 進め、その束で黙るか
  rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; setnow $T0
  # r1 は file_path で、r2 は cwd で乗る。2 回目以降の prompt は 60 秒以内(加入の走査は due でない)
  HC PostToolBatch $SA "{\"cwd\":\"$work/r2\",\"tool_calls\":[{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$JF\"}}]}" >/dev/null
  echo q >> "$work/r1/a.txt"; git -C "$work/r1" commit -qam "q $RANDOM"
  setnow $((T0+10))
  local ev; ev=$(python3 -c 'import json,sys;print(json.dumps({"cwd":sys.argv[1],"tool_calls":[{"tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":""}]}))' "$2" "$3")
  local out; out=$(HC PostToolBatch $SA "$ev")
  [ -z "$out" ] && ok "$1" || ng "$1" "$out"
}
JF="$work/r1/sub/x.txt"
quiet_case "cd <dir>(加入時と別の dir 表記)&& git-as .. commit && git push で黙る(外れの形)" "$work/r2" "cd $work/r1 && git-as 鷹野 commit -qm x; git push -q origin main"
JF="$work/r1/a.txt"
quiet_case "git -C <dir> push で黙る" "$work/r2" "git -C $work/r1 push -q origin main"
quiet_case "cwd のリポで git push(cd なし)も黙る" "$work/r1" "git push -q origin main"
quiet_case "git-as 鷹野 -C <dir> push で黙る" "$work/r2" "git-as 鷹野 -C $work/r1 push"
quiet_case "(cd <dir>; git push) の subshell で黙る" "$work/r2" "(cd $work/r1; git push)"
quiet_case "相対 cd(cwd からの相対)で黙る" "$work" "cd r1 && git push"
quiet_case "bash -c の中の cd && git push で黙る" "$work/r2" "bash -c 'cd $work/r1 && git push'"
quiet_case "FOO=1 git -C <dir> merge で黙る" "$work/r2" "FOO=1 git -C $work/r1 merge x"
# 黙ってはいけない側(他人の進みを隠さない)
loud_case() { # loud_case <説明> <cwd> <command>
  rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; setnow $T0
  HC PostToolBatch $SA "{\"cwd\":\"$work/r2\",\"tool_calls\":[{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$JF\"}}]}" >/dev/null
  echo q >> "$work/r1/a.txt"; git -C "$work/r1" commit -qam "他人の進み $RANDOM"
  setnow $((T0+10))
  local ev; ev=$(python3 -c 'import json,sys;print(json.dumps({"cwd":sys.argv[1],"tool_calls":[{"tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":""}]}))' "$2" "$3")
  local out; out=$(HC PostToolBatch $SA "$ev")
  grep -q '進んだ' <<<"$out" && ok "$1" || ng "$1" "$out"
}
loud_case "別のリポの push では r1 の進みを隠さない" "$work/r2" "git push -q origin main"
loud_case "echo の中の git push 文字列では黙らない" "$work/r2" "cd $work/r1 && echo 'git push'"
loud_case "(cd <dir>) を抜けた後の git push は cwd 側(r2)" "$work/r2" "(cd $work/r1); git push"
loud_case "cd <dir> で ls だけなら黙らない" "$work/r2" "cd $work/r1 && git log -1 && git status"
git -C "$work/r1" branch -q staging main
rm -rf "$RADIO_HOME/cursor"; HC UserPromptSubmit $SC "$TC" >/dev/null
git -C "$work/r1" checkout -q staging; echo s > "$work/r1/s.txt"; git -C "$work/r1" add -A; git -C "$work/r1" commit -qm "staging 側"; git -C "$work/r1" checkout -q main
out=$(HC UserPromptSubmit $SC "$TC"); grep -q 'staging が 1 commit' <<<"$out" && ok "base は staging があれば staging" || ng "staging 優先" "$out"
echo "-- 真壁・柏木(RADIO_ROLE)は base の進みを受けない"
rm -rf "$RADIO_HOME/cursor"; RADIO_ROLE=makabe HC UserPromptSubmit $SA "$TC" >/dev/null; git -C "$work/r1" checkout -q staging; echo t > "$work/r1/t.txt"; git -C "$work/r1" add -A; git -C "$work/r1" commit -qm "また進む"; git -C "$work/r1" checkout -q main
out=$(RADIO_ROLE=makabe HC UserPromptSubmit $SA "$TC"); [ -z "$out" ] && ok "RADIO_ROLE=makabe には base の進みを出さない" || ng "role" "$out"
"$radio" post --from 鷹野 --kind 裁定 --session $SB "真壁にも裁定は届く" >/dev/null; "$radio" post --from 鷹野 --kind 告知 --session $SB "真壁には要らない告知" >/dev/null
out=$(RADIO_ROLE=makabe HC UserPromptSubmit $SA "$TC"); grep -q '真壁にも裁定' <<<"$out" && ! grep -q '要らない告知' <<<"$out" && ok "RADIO_ROLE=makabe は裁定・工事だけ" || ng "role 種別" "$out"
echo "-- 6 時間触らなければ降りる"
rm -rf "$RADIO_HOME/cursor"; setnow $T0; HC UserPromptSubmit $SA "$TC" >/dev/null
setnow $((T0+7*3600)); HC UserPromptSubmit $SA '{"cwd":"/nonexistent","tool_calls":[]}' >/dev/null
python3 -c "import json;d=json.load(open('$RADIO_HOME/cursor/$SA'));print(len(d['repos']))" | grep -qx 0 && ok "6 時間触れないリポから降りる" || ng "降りる"

echo "== 後始末"
rm -rf "$RADIO_HOME/cursor"; mkdir -p "$RADIO_HOME/cursor"; echo '{}' > "$RADIO_HOME/cursor/old"; touch -d '10 days ago' "$RADIO_HOME/cursor/old"; echo '{}' > "$RADIO_HOME/cursor/new"
setnow $(date +%s); "$radio" rotate >/dev/null; [ ! -e "$RADIO_HOME/cursor/old" ] && [ -e "$RADIO_HOME/cursor/new" ] && ok "rotate が 7 日触られていない位置 file だけ消す" || ng "cursor 掃除"

echo "== 所要(測るだけ、合否に掛けない)"
rm -rf "$RADIO_HOME"; mkdir -p "$RADIO_HOME"; unset RADIO_NOW
HC UserPromptSubmit $SA "$TC" >/dev/null
payload=$(python3 -c "import json;print(json.dumps({'hook_event_name':'PostToolBatch','session_id':'$SA','cwd':'$work/r1','tool_calls':[{'tool_name':'Bash','tool_input':{'command':'ls'},'tool_response':'x'*100}]}))")
s=$(date +%s%N); for i in $(seq 20); do echo "$payload" | bash "$hook" >/dev/null; done; e=$(date +%s%N)
echo "  静かなとき PostToolBatch 1 回 ≒ $(( (e-s)/20000000 )) ms(20 回平均、bash 起動と python 起動を含む)"
"$radio" board set dleam --from t --until +60m "x" >/dev/null
s=$(date +%s%N); for i in $(seq 20); do echo "$payload" | bash "$hook" >/dev/null; done; e=$(date +%s%N)
echo "  札が 1 枚あるとき ≒ $(( (e-s)/20000000 )) ms"

echo
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
