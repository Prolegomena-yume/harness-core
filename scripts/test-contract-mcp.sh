#!/usr/bin/env bash
# 契約モード(--contract / --batch)の test。実 Claude は使わない(偽の claude を PATH の先頭に置く)。
#   A. 契約の MCP の単体(test-contract-mcp.py)
#   B. 書きの塞ぎ hook(hooks/write-guard-claude.py)の判定
#   C. ランチャ(claude-makabe.sh / claude-kashiwagi.sh)の契約モードと、-f の今の形が変わっていないこと
# 実 Claude で hook と MCP を通す確かめは scripts/e2e/contract-mcp-e2e.sh(Sonnet を使うので手で回す)。
# 差し替え: WRITE_GUARD_UNDER_TEST=<hook の path>(壊した版で B が落ちることの確認用)
# 使い方: bash scripts/test-contract-mcp.sh
set -uo pipefail
# 契約なしの起動を断る規則(役員 人見 2026-11-19)の抜け道。test のためだけに開ける(運用では使わない)。
export HARNESS_ALLOW_NO_CONTRACT=1
# ランチャは既定で systemd の unit に載る(fa0d0b9)。unit には FAKE_CLAUDE_LOG などの test 用 env が届かず、cwd も変わるので、退避口で in-process にする。
export NIEKAWA_NO_UNIT=1
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${WRITE_GUARD_UNDER_TEST:-$core/scripts/hooks/write-guard-claude.py}"
GAS="$core/scripts/git-as"
n=0; fail=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); echo "not ok $n - $1"; fail=1; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

sbx="$(mktemp -d)"; trap 'rm -rf "$sbx"' EXIT
sbx="$(cd -P "$sbx" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# ---- A. MCP 単体 ----
if python3 "$core/scripts/test-contract-mcp.py" >"$sbx/mcp.out" 2>&1; then
  ok "A MCP 単体($(grep -c '^ok ' "$sbx/mcp.out") 件、すべて ok)"
else
  nok "A MCP 単体(落ち: $(grep -c '^not ok' "$sbx/mcp.out") 件)"; grep '^not ok' "$sbx/mcp.out" | head -5
fi

# ---- B. 書きの塞ぎ hook ----
wt="$sbx/hk/wt"; mkdir -p "$wt/sub" "$sbx/hk/outside" "$sbx/hk/wt2"
ln -s "$sbx/hk/outside" "$wt/linkout"
tech_like="$HOME/canonical/tech/_contract-hook-test-never-written.md"
# hook_rc <tool> <path-key> <path> [cwd]: hook を呼んで exit code を返す(hook は書かない。判定だけ)
hook_rc() {
  local tool="$1" key="$2" path="$3" cwd="${4:-$wt}"
  python3 - "$tool" "$key" "$path" "$cwd" <<'PY' | python3 "$HOOK" "$wt" >/dev/null 2>"$sbx/hook.err"
import json, sys
tool, key, path, cwd = sys.argv[1:5]
print(json.dumps({"tool_name": tool, "tool_input": {key: path, "content": "x"}, "cwd": cwd}))
PY
  echo "${PIPESTATUS[1]}"
}
is() { [ "$1" = "$2" ]; }
chk "B1 worktree の中への Write は通る(exit 0)" is "$(hook_rc Write file_path "$wt/a.md")" 0
chk "B2 worktree の中の、まだ無いサブフォルダへの Write は通る" is "$(hook_rc Write file_path "$wt/new/deep/a.md")" 0
chk "B3 相対 path は cwd(worktree)から解いて通る" is "$(hook_rc Edit file_path "sub/a.md")" 0
chk "B4 tech の _contract の外(~/canonical/tech/x.md)への Write は弾く(exit 2)" is "$(hook_rc Write file_path "$tech_like")" 2
chk "B5 弾いた文は stderr に出る(MCP の道具の案内つき)" grep -q 'brief_get' "$sbx/hook.err"
chk "B6 Edit も外を弾く" is "$(hook_rc Edit file_path "$sbx/hk/outside/x.md")" 2
chk "B7 NotebookEdit は notebook_path で見て外を弾く" is "$(hook_rc NotebookEdit notebook_path "$sbx/hk/outside/x.ipynb")" 2
chk "B8 NotebookEdit の中は通る" is "$(hook_rc NotebookEdit notebook_path "$wt/x.ipynb")" 0
chk "B9 .. で外へ出る path は弾く" is "$(hook_rc Write file_path "$wt/../outside/x.md")" 2
chk "B10 相対の .. も弾く" is "$(hook_rc Write file_path "../outside/x.md")" 2
chk "B11 worktree 内の symlink が外を指すなら弾く" is "$(hook_rc Write file_path "$wt/linkout/x.md")" 2
chk "B12 root と前方一致する兄弟フォルダ(wt2)は弾く" is "$(hook_rc Write file_path "$sbx/hk/wt2/x.md")" 2
chk "B13 ~ 始まりの path(~/x.md)は弾く" is "$(hook_rc Write file_path "~/x.md")" 2
chk "B14 /tmp への Write も弾く(外は一律)" is "$(hook_rc Write file_path "/tmp/x-contract-hook.md")" 2
chk "B15 Read・Bash など対象外の tool は素通し" is "$(hook_rc Read file_path "$tech_like")" 0
chk "B16 path が空の Write は弾く(fail-closed)" is "$(hook_rc Write file_path "")" 2
echo 'not json' | python3 "$HOOK" "$wt" >/dev/null 2>&1; chk "B17 壊れた入力は弾く(fail-closed)" is "$?" 2
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$wt"'/a"}}' | python3 "$HOOK" >/dev/null 2>&1
chk "B18 作業ルートの引数が無ければ弾く(env に頼らない)" is "$?" 2
echo '{"tool_name":"Write","tool_input":{"file_path":"a.md"}}' | python3 "$HOOK" "$wt" >/dev/null 2>&1
chk "B19 cwd が入力に無ければ作業ルートから解く(中なので通る)" is "$?" 0

# ---- C. ランチャ ----
mkdir -p "$sbx/bin"
cat >"$sbx/bin/claude" <<'S'
#!/usr/bin/env bash
# 偽の claude。argv と cwd を FAKE_CLAUDE_LOG に残す。makabe の stream-json 入力なら最初の 1 行を読んで result 行を返し、
# kashiwagi の --output-format json なら単一 JSON を返す。
printf '%s\n' "$@" >"$FAKE_CLAUDE_LOG.argv"
pwd >"$FAKE_CLAUDE_LOG.cwd"
env | grep -E '^(CONTRACT_DIR|BATCH|CONTRACT_TOOLS)=' >"$FAKE_CLAUDE_LOG.env"
if printf '%s\n' "$@" | grep -qx 'stream-json'; then
  IFS= read -r _first
  printf '{"type":"result","subtype":"success","session_id":"fake","is_error":false,"result":"fake done"}\n'
  cat >/dev/null
else
  printf '{"session_id":"fake","is_error":false,"result":"P0 無し"}\n'
fi
[ -z "${FAKE_CLAUDE_RC:-}" ] || exit "$FAKE_CLAUDE_RC"
S
printf '#!/bin/sh\nexit 1\n' >"$sbx/bin/rates"
chmod +x "$sbx/bin/claude" "$sbx/bin/rates"
export PATH="$sbx/bin:$PATH" CLAUDE_ACCT_DISABLE=1

lc="$sbx/lc"; mkdir -p "$lc/contract/b1" "$lc/state"
echo "# GOAL" >"$lc/contract/GOAL.md"; echo "brief 本文" >"$lc/contract/b1/brief.md"
git init -q -b main "$lc/base"
( cd "$lc/base" && echo base >README.md && git add -A && "$GAS" anno commit -q -m base && git worktree add -q -b impl/x "$lc/wt" )
echo "FBRIEF" >"$lc/f.md"
export CODEX_AGENT_STATE_DIR="$lc/state"
runs() { ls -d "$lc"/state/runs/"$1"-* 2>/dev/null | tail -1; }

# C1. makabe の契約モード(偽 claude で実際に起動)
FAKE_CLAUDE_LOG="$lc/m" bash "$core/scripts/claude-makabe.sh" -C "$lc/wt" --contract "$lc/contract" --batch b1 --log "$lc/m.log" >"$lc/m.out" 2>&1
rd="$(runs makabe)"
chk "C1a makabe 契約モードが起動して終わる(-f 無しでよい)" grep -q '^persona: makabe' "$lc/m.out"
chk "C1b claude に --mcp-config と --strict-mcp-config が渡る" bash -c "grep -qx -- '--mcp-config' '$lc/m.argv' && grep -qx -- '--strict-mcp-config' '$lc/m.argv'"
chk "C1c mcp.json は contract サーバ(CONTRACT_DIR・BATCH・真壁の 4 道具)" python3 - "$rd/mcp.json" "$lc/contract" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["mcpServers"]["contract"]
e = c["env"]
sys.exit(0 if e["CONTRACT_DIR"] == sys.argv[2] and e["BATCH"] == "b1" and e["CONTRACT_TOOLS"] == "brief_get,result_get,result_put,result_append" and c["type"] == "stdio" else 1)
PY
chk "C1d settings.json に write-guard(Write|Edit|MultiEdit|NotebookEdit、root を引数で)" python3 - "$rd/settings.json" "$lc/wt" <<'PY'
import json, sys
pre = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
m = [p for p in pre if "NotebookEdit" in p["matcher"]]
sys.exit(0 if m and m[0]["hooks"][0]["command"].endswith("write-guard-claude.py " + sys.argv[2]) else 1)
PY
chk "C1e 最初の指示は brief_get / result_put で、brief の path も本文も入っていない" bash -c "grep -q 'brief_get' '$rd/prompt.md' && grep -q 'result_put' '$rd/prompt.md' && ! grep -q 'brief 本文' '$rd/prompt.md' && ! grep -qF '$lc/contract' '$rd/prompt.md'"
chk "C1f claude 本体の環境に CONTRACT_DIR・BATCH を渡さない(MCP の env だけ。偽 claude が自分の env を記録)" bash -c "[ -f '$lc/m.env' ] && [ ! -s '$lc/m.env' ]"
chk "C1g 作業ルート(worktree)で動く" grep -qx "$lc/wt" "$lc/m.cwd"

# C2. kashiwagi の契約モード
FAKE_CLAUDE_LOG="$lc/k" bash "$core/scripts/claude-kashiwagi.sh" --no-loop -C "$lc/wt" --contract "$lc/contract" --batch b1 --log "$lc/k.log" >"$lc/k.out" 2>&1
rd="$(runs kashiwagi)"
chk "C2a kashiwagi 契約モードが起動して終わる(verdict の一語は偽 claude の最終メッセージ)" grep -q '^persona: kashiwagi' "$lc/k.out"
chk "C2b ゲート番号は既定で 2(acceptEdits が付く)" bash -c "grep -qx 'acceptEdits' '$lc/k.argv'"
chk "C2c --mcp-config・--strict-mcp-config・--allowedTools(brief_get・result_get・gate_put だけ)" bash -c "grep -qx -- '--mcp-config' '$lc/k.argv' && grep -qx -- '--strict-mcp-config' '$lc/k.argv' && grep -qx 'mcp__contract__brief_get,mcp__contract__result_get,mcp__contract__gate_put' '$lc/k.argv'"
chk "C2d mcp.json の道具は柏木の 3 つ(result_put を出さない)" python3 - "$rd/mcp.json" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1]))["mcpServers"]["contract"]["env"]["CONTRACT_TOOLS"] == "brief_get,result_get,gate_put" else 1)
PY
chk "C2e settings.json に write-guard(Bash の guard と Stop hook は残る)" python3 - "$rd/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["hooks"]
pre = s["PreToolUse"]
sys.exit(0 if any("NotebookEdit" in p["matcher"] for p in pre) and any(p["matcher"] == "Bash" for p in pre) and s.get("Stop") else 1)
PY
chk "C2f 最初の指示は brief_get / gate_put" bash -c "grep -q 'brief_get' '$rd/prompt.md' && grep -q 'gate_put' '$rd/prompt.md'"

# C3. -f の今の形は変わらない(契約の道具も write-guard も足さない)
FAKE_CLAUDE_LOG="$lc/mf" bash "$core/scripts/claude-makabe.sh" -C "$lc/wt" -f "$lc/f.md" --log "$lc/mf.log" >"$lc/mf.out" 2>&1
rd="$(runs makabe)"
chk "C3a makabe -f: --mcp-config を渡さず、mcp.json も作らない" bash -c "! grep -q -- 'mcp-config' '$lc/mf.argv' && [ ! -e '$rd/mcp.json' ]"
chk "C3b makabe -f: settings の matcher は従来の 4 つ(Write・Edit・NotebookEdit・Bash)で write-guard 無し" python3 - "$rd/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
ms = [p["matcher"] for p in s["hooks"]["PreToolUse"]]
sys.exit(0 if ms == ["Write", "Edit", "NotebookEdit", "Bash"] and "write-guard" not in json.dumps(s) else 1)
PY
chk "C3c makabe -f: 指示に FBRIEF が入り、契約モードの文は入らない" bash -c "grep -q FBRIEF '$rd/prompt.md' && ! grep -q 'brief_get' '$rd/prompt.md'"
FAKE_CLAUDE_LOG="$lc/kf" bash "$core/scripts/claude-kashiwagi.sh" --no-loop -C "$lc/wt" -f "$lc/f.md" --gate 2 --log "$lc/kf.log" >"$lc/kf.out" 2>&1
rd="$(runs kashiwagi)"
chk "C3d kashiwagi -f: --mcp-config・--allowedTools を渡さず、write-guard も入らない" bash -c "! grep -q -- 'mcp-config\|allowedTools' '$lc/kf.argv' && ! grep -q 'write-guard' '$rd/settings.json'"

# C3r. 無線(harness-radio R2): 契約モードでも -f でも、settings に読む hook 3 つと RADIO_ROLE が入る(利用者の settings と別に --settings で付く)
radio_settings_ok() { # radio_settings_ok <settings.json> <role> <core>
  python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys
s = json.load(open(sys.argv[1])); role = sys.argv[2]; core = sys.argv[3]
if s.get("env", {}).get("RADIO_ROLE") != role:
    sys.exit(1)
canon = os.path.realpath(os.path.expanduser("~/canonical/tech/.claude/_core"))
want = 'bash "$HOME/canonical/tech/.claude/_core/hooks/radio.sh"' if os.path.realpath(core) == canon else 'bash "%s/hooks/radio.sh"' % core
for ev in ("UserPromptSubmit", "PostToolBatch", "SessionStart"):
    hs = [h for g in s["hooks"].get(ev, []) for h in g["hooks"]]
    if len(hs) != 1 or hs[0]["command"] != want or hs[0]["timeout"] != 5 or hs[0]["type"] != "command":
        sys.exit(1)
if "PostToolUse" in s["hooks"]:      # PostToolUse は tool 1 本ごとに走る。読む口に付けない
    sys.exit(1)
sys.exit(0)
PY
}
rd="$(runs makabe)"
chk "C3r1 makabe(-f)の settings に radio の 3 hook(timeout 5)と RADIO_ROLE=makabe。PostToolUse には付けない" radio_settings_ok "$rd/settings.json" makabe "$core"
chk "C3r2 kashiwagi(-f)の settings に radio の 3 hook と RADIO_ROLE=kashiwagi" radio_settings_ok "$(runs kashiwagi)/settings.json" kashiwagi "$core"
chk "C3r3 既存の PreToolUse・Stop は残る(radio は足しただけ)" python3 - "$rd/settings.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
sys.exit(0 if [p["matcher"] for p in h["PreToolUse"]] == ["Write", "Edit", "NotebookEdit", "Bash"] and h.get("Stop") else 1)
PY
rdc="$(ls -d "$lc"/state/runs/makabe-* | head -1)"
chk "C3r4 契約モードの makabe の settings にも radio が入る" radio_settings_ok "$rdc/settings.json" makabe "$core"

# C4. 断る形(run_dir を作る前)
nr_before="$(ls "$lc/state/runs" | wc -l)"
chk "C4a --contract だけ(--batch 無し)は断る" bash -c "! bash '$core/scripts/claude-makabe.sh' -C '$lc/wt' --contract '$lc/contract' --dry-run >/dev/null 2>&1"
chk "C4b --batch に .. や / があれば断る" bash -c "! bash '$core/scripts/claude-makabe.sh' -C '$lc/wt' --contract '$lc/contract' --batch '../b1' --dry-run >/dev/null 2>&1 && ! bash '$core/scripts/claude-kashiwagi.sh' -C '$lc/wt' --contract '$lc/contract' --batch 'a/b' --dry-run >/dev/null 2>&1"
chk "C4c brief.md が無い便は断る" bash -c "! bash '$core/scripts/claude-makabe.sh' -C '$lc/wt' --contract '$lc/contract' --batch nobrief --dry-run >/dev/null 2>&1"
chk "C4d 断ったときは run_dir を作らない" is "$(ls "$lc/state/runs" | wc -l)" "$nr_before"

# C6. 契約の外では断る(役員 人見 2026-11-19)。抜け道の env を外して、--dry-run も含めて断ること・契約ありは通ることを見る
chk "C6a makabe は --contract 無しの起動を断り、文言に /t-contract と --contract --batch が出る" bash -c "out=\$(env -u HARNESS_ALLOW_NO_CONTRACT bash '$core/scripts/claude-makabe.sh' -C '$lc/wt' -f '$lc/f.md' 2>&1); rc=\$?; [ \$rc -ne 0 ] && echo \"\$out\" | grep -q '/t-contract' && echo \"\$out\" | grep -q -- '--contract'"
chk "C6b kashiwagi は --contract 無しの起動を断り、文言に /t-contract と --contract --batch が出る" bash -c "out=\$(env -u HARNESS_ALLOW_NO_CONTRACT bash '$core/scripts/claude-kashiwagi.sh' --no-loop -C '$lc/wt' -f '$lc/f.md' 2>&1); rc=\$?; [ \$rc -ne 0 ] && echo \"\$out\" | grep -q '/t-contract' && echo \"\$out\" | grep -q -- '--batch'"
chk "C6c makabe は --dry-run でも断る" bash -c "! env -u HARNESS_ALLOW_NO_CONTRACT bash '$core/scripts/claude-makabe.sh' -C '$lc/wt' -f '$lc/f.md' --dry-run >/dev/null 2>&1"
chk "C6d kashiwagi は --dry-run でも断る" bash -c "! env -u HARNESS_ALLOW_NO_CONTRACT bash '$core/scripts/claude-kashiwagi.sh' --no-loop -C '$lc/wt' -f '$lc/f.md' --dry-run >/dev/null 2>&1"
chk "C6e 契約ありは env 無しでも通る(makabe・kashiwagi の --dry-run が exit 0)" bash -c "env -u HARNESS_ALLOW_NO_CONTRACT bash '$core/scripts/claude-makabe.sh' -C '$lc/wt' --contract '$lc/contract' --batch b1 --dry-run >/dev/null 2>&1 && env -u HARNESS_ALLOW_NO_CONTRACT bash '$core/scripts/claude-kashiwagi.sh' --no-loop -C '$lc/wt' --contract '$lc/contract' --batch b1 --dry-run >/dev/null 2>&1"
chk "C6g 抜け道の env を付ければ契約なしでも通る(test 用)" bash -c "HARNESS_ALLOW_NO_CONTRACT=1 bash '$core/scripts/claude-makabe.sh' -C '$lc/wt' -f '$lc/f.md' --dry-run >/dev/null 2>&1"

# C5. 契約モードのログは <contract>/<便>/logs/ へ(--log 無し)。ランチャの出力も launcher.out に写す。契約モードでないときは今の場所
mkdir -p "$lc/contract/b5" "$lc/state5"; echo "b5" >"$lc/contract/b5/brief.md"
export_state="$lc/state5"
for who in makabe kashiwagi; do
  extra=(); [ "$who" = kashiwagi ] && extra=(--no-loop)
  rm -rf "$lc/contract/b5/logs" "$export_state"; mkdir -p "$export_state"
  CODEX_AGENT_STATE_DIR="$export_state" FAKE_CLAUDE_LOG="$lc/c5$who" bash "$core/scripts/claude-$who.sh" "${extra[@]}" -C "$lc/wt" --contract "$lc/contract" --batch b5 >"$lc/c5$who.out" 2>"$lc/c5$who.err"; rc=$?
  ld="$lc/contract/b5/logs"
  chk "C5a $who 契約モードの終了コードは 0" is "$rc" 0
  chk "C5b $who ログが <contract>/<便>/logs/$who-<run_id>.log にできる" bash -c "ls '$ld'/$who-*.log >/dev/null 2>&1"
  chk "C5c $who launcher.out が logs/ にでき、footer と同じ中身(persona・log: の行)を持つ" bash -c "f=\$(ls '$ld'/$who-*.launcher.out) && grep -q '^persona: $who' \"\$f\" && grep -q '^log: $ld/$who-' \"\$f\""
  chk "C5d $who 画面(stdout)にも出ている・footer の log: は新しい path" bash -c "grep -q '^log: $ld/$who-.*\\.log\$' '$lc/c5$who.out'"
  chk "C5e $who 既定の state/logs/ には作らない" bash -c "! ls '$export_state'/logs/*.log >/dev/null 2>&1"
  chk "C5f $who launcher.out は stdout と同じ行を含む(log: の行が 1 回)" bash -c "[ \$(grep -c '^log: ' \$(ls '$ld'/$who-*.launcher.out)) = 1 ]"
  # 終了コード: 偽 claude が 7 で落ちる。契約モードと(同じ便の)--log 明示で変わらない・tee が残らない
  rm -rf "$export_state"; mkdir -p "$export_state"
  FAKE_CLAUDE_RC=7 CODEX_AGENT_STATE_DIR="$export_state" FAKE_CLAUDE_LOG="$lc/c5r$who" bash "$core/scripts/claude-$who.sh" "${extra[@]}" -C "$lc/wt" --contract "$lc/contract" --batch b5 >/dev/null 2>&1; rc_c=$?
  FAKE_CLAUDE_RC=7 CODEX_AGENT_STATE_DIR="$export_state" FAKE_CLAUDE_LOG="$lc/c5n$who" bash "$core/scripts/claude-$who.sh" "${extra[@]}" -C "$lc/wt" -f "$lc/f.md" --log "$lc/c5n$who.log" >/dev/null 2>&1; rc_n=$?
  chk "C5g $who 偽 claude が非 0 で終わるとき、契約モードの終了コードは契約でないときと同じ($rc_n)" is "$rc_c" "$rc_n"
  chk "C5h $who 契約でない起動はログを state/logs/ か --log に置き、契約の logs/ を作らない" bash -c "[ -e '$lc/c5n$who.log' ] && [ ! -d '$lc/contract/nolog' ]"
  rm -rf "$export_state"; mkdir -p "$export_state"
  CODEX_AGENT_STATE_DIR="$export_state" FAKE_CLAUDE_LOG="$lc/c5d$who" bash "$core/scripts/claude-$who.sh" "${extra[@]}" -C "$lc/wt" -f "$lc/f.md" >/dev/null 2>&1
  chk "C5i $who 契約モードでなければ既定のログは state/logs/ にできる" bash -c "ls '$export_state'/logs/$who-*.log >/dev/null 2>&1"
  chk "C5j $who 終わったあと tee が残っていない" bash -c "! pgrep -f '[t]ee -a $ld/$who-' >/dev/null"
done

echo "1..$n"
exit "$fail"
