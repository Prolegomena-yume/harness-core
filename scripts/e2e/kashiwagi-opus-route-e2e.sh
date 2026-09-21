#!/usr/bin/env bash
# usage: kashiwagi-opus-route-e2e.sh
#
# claude-kashiwagi.sh(柏木の実行経路C、Opus)のランチャ側担保と、codex-agent.sh(従来の codex-kashiwagi
# 経路)との相互運用を通し試験する(役員 人見 2026-09-21 23:55 の新設、2026-09-22 00:0x の訂正 ──
# 作業木の中は書ける・外は書けない)。実 claude は起こさない ── --dry-run で「die しなければ exit 0 で
# claude 手前まで進む」ことだけを見る。gate2-guard-e2e.sh(codex 版)の姉妹試験。
#
# 実際の Opus 呼び出しを伴う手動確認(P0 の再現・書き込み境界の実測)は
# scratchpad の stage5/kashiwagi-opus-e2e/(claude-kashiwagi.sh の外)で別途行う ── ここでは
# claude weekly を使わない軽量・再実行可能な部分だけを見る。
#
# 軽量・実処理無し。再実行可能($CODEX_AGENT_STATE_DIR と便ディレクトリを毎回新規の temp に作る)。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_dir="$(dirname "$(dirname "$script_dir")")"
codex_launcher="$core_dir/scripts/codex-agent.sh"
claude_launcher="$core_dir/scripts/claude-kashiwagi.sh"
guard_hook="$core_dir/scripts/hooks/worktree-guard-claude.sh"
gate_hook_kimi="$core_dir/scripts/hooks/gate-guard.sh"
gate_hook_claude="$core_dir/scripts/hooks/gate-guard-claude.sh"

for f in "$codex_launcher" "$claude_launcher" "$guard_hook" "$gate_hook_kimi" "$gate_hook_claude"; do
  [ -e "$f" ] || { echo "エラー: 必要なファイルが見つからない: $f" >&2; exit 2; }
done

test_root="$(mktemp -d /tmp/kashiwagi-opus-route-e2e.XXXXXX)"
cleanup() {
  if [[ "$test_root" = /tmp/kashiwagi-opus-route-e2e.* ]] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

fake_bin="$test_root/bin"
empty_codex_home="$test_root/codex-home"
mkdir -p "$fake_bin" "$empty_codex_home"
: > "$empty_codex_home/config.toml"
cat > "$fake_bin/rates" <<'FAKE_RATES'
#!/usr/bin/env bash
printf '{"email":"e2e@example.invalid","remaining":{"5h":null,"weekly":69,"monthly":null}}\n'
FAKE_RATES
chmod +x "$fake_bin/rates"

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b impl/e2e
  git -C "$repo" config user.name E2E
  git -C "$repo" config user.email e2e@example.invalid
  printf 'initial\n' > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm initial
}

repo="$test_root/repo"
init_repo "$repo"

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); printf 'ok %d - %s\n' "$pass_count" "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'not ok - %s\n' "$1" >&2; }

count_gate() {
  local file="$1" gate="$2"
  [ -f "$file" ] && awk -F'\t' -v g="$gate" '$3==g{n++} END{print n+0}' "$file" || printf '0\n'
}

new_batch() {
  local name="$1"
  local batch_dir="$test_root/batches/$name"
  mkdir -p "$batch_dir"
  printf '%s\n' "$batch_dir"
}

run_claude_launcher() {
  local name="$1" state_dir="$2" inbox="$3"
  shift 3
  local out="$test_root/$name.out"
  set +e
  PATH="$fake_bin:$PATH" CODEX_AGENT_STATE_DIR="$state_dir" NIEKAWA_INBOX="$inbox" \
    "$claude_launcher" "$@" > "$out" 2>&1
  local status=$?
  set -e
  printf '%s\n' "$status" > "$test_root/$name.status"
  return 0
}

run_codex_launcher() {
  local name="$1" state_dir="$2" inbox="$3"
  shift 3
  local out="$test_root/$name.out"
  set +e
  PATH="$fake_bin:$PATH" CODEX_HOME="$empty_codex_home" CODEX_AGENT_STATE_DIR="$state_dir" NIEKAWA_INBOX="$inbox" \
    "$codex_launcher" "$@" > "$out" 2>&1
  local status=$?
  set -e
  printf '%s\n' "$status" > "$test_root/$name.status"
  return 0
}

st() { cat "$test_root/$1.status"; }
out() { cat "$test_root/$1.out"; }

echo "== 1. claude-kashiwagi ゲート2、1回目は通り gates.tsv に append される =="
batch1="$(new_batch batch1)"
printf 'findings body\n' > "$batch1/findings.md"
state1="$test_root/state1"
run_claude_launcher c-first "$state1" "$batch1/to-niekawa.tsv" \
  --no-loop -C "$repo" -f "$batch1/findings.md" --dry-run
[ "$(st c-first)" = 0 ] && pass 'claude-kashiwagi gate2 1回目は --dry-run で exit 0' \
  || fail "c-first: exit $(st c-first)。out: $(out c-first)"
[ "$(count_gate "$batch1/gates.tsv" 2)" = 1 ] && pass 'gates.tsv に gate=2 が1行 append される' \
  || fail "gates.tsv の gate=2 行数が想定外: $(cat "$batch1/gates.tsv" 2>/dev/null || echo なし)"

echo "== 2. claude-kashiwagi ゲート2、2回目は run_dir 作成前に die =="
before_runs="$(find "$state1/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
run_claude_launcher c-second "$state1" "$batch1/to-niekawa.tsv" \
  --no-loop -C "$repo" -f "$batch1/findings.md" --dry-run
after_runs="$(find "$state1/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$(st c-second)" != 0 ] && pass 'claude-kashiwagi gate2 2回目は非0で die' \
  || fail "c-second: exit 0(die していない)。out: $(out c-second)"
LC_ALL=C grep -q 'ゲート 2 は便に1回' "$test_root/c-second.out" && pass 'die の理由文が出る' \
  || fail "die の理由文が無い: $(out c-second)"
[ "$before_runs" = "$after_runs" ] && pass 'die は run_dir を作らない' \
  || fail "run_dir が作られた(before=$before_runs after=$after_runs)"
[ "$(count_gate "$batch1/gates.tsv" 2)" = 1 ] && pass '2回目の die で重複 append されない' \
  || fail "gates.tsv に重複記録: $(cat "$batch1/gates.tsv")"

echo "== 3. 経路をまたいでも便に1回 ── codex-kashiwagi で先に通した gate1 は claude-kashiwagi でも die =="
batch2="$(new_batch batch2)"
printf 'plan body\n' > "$batch2/plan.md"
state2="$test_root/state2"
run_codex_launcher k-plan-1 "$state2" "$batch2/to-niekawa.tsv" \
  kashiwagi --no-loop -C "$repo" -f "$batch2/plan.md" --dry-run
[ "$(st k-plan-1)" = 0 ] && pass 'codex-kashiwagi gate1 1回目は exit 0' \
  || fail "k-plan-1: exit $(st k-plan-1)。out: $(out k-plan-1)"
run_claude_launcher c-plan-2 "$state2" "$batch2/to-niekawa.tsv" \
  --no-loop -C "$repo" -f "$batch2/plan.md" --dry-run
[ "$(st c-plan-2)" != 0 ] && pass 'codex-kashiwagi で通した gate1 は claude-kashiwagi でも die(経路をまたいで1回)' \
  || fail "c-plan-2: exit 0 になった(またいで die していない)。out: $(out c-plan-2)"

echo "== 4. 逆方向 ── claude-kashiwagi で先に通した gate1 は codex-kashiwagi でも die =="
batch3="$(new_batch batch3)"
printf 'plan body\n' > "$batch3/plan.md"
state3="$test_root/state3"
run_claude_launcher c-plan3-1 "$state3" "$batch3/to-niekawa.tsv" \
  --no-loop -C "$repo" -f "$batch3/plan.md" --dry-run
[ "$(st c-plan3-1)" = 0 ] && pass 'claude-kashiwagi gate1 1回目は exit 0' \
  || fail "c-plan3-1: exit $(st c-plan3-1)。out: $(out c-plan3-1)"
run_codex_launcher k-plan3-2 "$state3" "$batch3/to-niekawa.tsv" \
  kashiwagi --no-loop -C "$repo" -f "$batch3/plan.md" --dry-run
[ "$(st k-plan3-2)" != 0 ] && pass 'claude-kashiwagi で通した gate1 は codex-kashiwagi でも die(逆方向も1回)' \
  || fail "k-plan3-2: exit 0 になった。out: $(out k-plan3-2)"

echo "== 5. hook(gate-guard.sh / gate-guard-claude.sh)が claude-kashiwagi のリテラルを検知する =="
batch4="$(new_batch batch4)"
printf 'findings body\n' > "$batch4/findings.md"
state4="$test_root/state4"
run_claude_launcher c-hook-seed "$state4" "$batch4/to-niekawa.tsv" \
  --no-loop -C "$repo" -f "$batch4/findings.md" --dry-run
[ "$(st c-hook-seed)" = 0 ] || fail "c-hook-seed: 事前の1回目が失敗: $(out c-hook-seed)"

hook_json() {
  printf '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/","tool_name":"Bash","tool_input":{"command":"%s"},"tool_call_id":"c1"}' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
hook_out_kimi="$test_root/hook-kimi.out"
hook_json "claude-kashiwagi --no-loop -C $repo -f $batch4/findings.md" \
  | NIEKAWA_INBOX="$batch4/to-niekawa.tsv" bash "$gate_hook_kimi" > "$hook_out_kimi" 2>&1
LC_ALL=C grep -q '"permissionDecision":"deny"' "$hook_out_kimi" && pass 'gate-guard.sh(kimi)が claude-kashiwagi の2回目を検知して deny する' \
  || fail "gate-guard.sh が deny しなかった: $(cat "$hook_out_kimi")"

hook_out_claude="$test_root/hook-claude.out"
set +e
hook_json "claude-kashiwagi --no-loop -C $repo -f $batch4/findings.md" \
  | NIEKAWA_INBOX="$batch4/to-niekawa.tsv" bash "$gate_hook_claude" > "$hook_out_claude" 2>"$test_root/hook-claude.err"
hook_status="${PIPESTATUS[1]}"
set -e
[ "$hook_status" -eq 2 ] && pass 'gate-guard-claude.sh(claude)が claude-kashiwagi の2回目を exit 2 で block する' \
  || fail "gate-guard-claude.sh の exit が想定外: $hook_status"
LC_ALL=C grep -q 'ゲート 2 は便に 1 回' "$test_root/hook-claude.err" && pass 'block の理由が stderr に出る' \
  || fail "block 理由が出ていない: $(cat "$test_root/hook-claude.err")"

echo "== 6. worktree-guard-claude.sh ── 作業木の中は通す、外(禁止プレフィックス)は書き込みだけ block する =="
wtroot="$test_root/wt"
mkdir -p "$wtroot"
guard_test() {
  local desc="$1" root="$2" cmd="$3" expect="$4" gate="${5:-}"
  local result
  set +e
  hook_json "$cmd" | CLAUDE_KASHIWAGI_ROOT="$root" CLAUDE_KASHIWAGI_GATE="$gate" bash "$guard_hook" >/dev/null 2>&1
  result="${PIPESTATUS[1]}"
  set -e
  if [ "$expect" = allow ]; then
    [ "$result" -eq 0 ] && pass "$desc" || fail "$desc(exit $result、期待 0)"
  else
    [ "$result" -eq 2 ] && pass "$desc" || fail "$desc(exit $result、期待 2)"
  fi
}
guard_test 'root 内の git commit は許可(gate=2)' "$wtroot" "git commit -m x" allow 2
guard_test 'root 内へのリダイレクト書き込みは許可(gate=2)' "$wtroot" "echo a > $wtroot/inside.txt" allow 2
guard_test 'root の外(.codex-agents)へのリダイレクトは block(gate=2でも)' "$wtroot" "echo a > $HOME/.codex-agents/e2e-guard-test/leak.txt" deny 2
guard_test 'root の外(canonical)への rm は block(gate=2でも)' "$wtroot" "rm -rf $HOME/canonical/tech/README.md" deny 2
guard_test '読み取り(cat)は禁止プレフィックスでも許可' "$wtroot" "cat $HOME/.claude/settings.json" allow 2

echo "-- carve-out は gate=2 だけ有効(役員 人見 2026-09-22 の訂正) --"
guard_test 'root が .codex-agents 配下でも gate=2 なら root 内は許可(ゲート2の carve-out)' \
  "$HOME/.codex-agents/runs/e2e-fake-run" "echo a > $HOME/.codex-agents/runs/e2e-fake-run/plan.md" allow 2
guard_test 'root が .codex-agents 配下でも gate=2 なら他の run_dir への書き込みは block' \
  "$HOME/.codex-agents/runs/e2e-fake-run" "echo a > $HOME/.codex-agents/runs/other-run/leak.txt" deny 2

echo "== 7. (g)(h) ゲート1(gate=1)は carve-out 無し ── 贄川の run_dir(= root)自身への書き込みも block する =="
guard_test '(h) ゲート1: root(= 贄川の run_dir)自身への Bash echo リダイレクトも block' \
  "$HOME/.codex-agents/runs/e2e-fake-niekawa-run" "echo a > $HOME/.codex-agents/runs/e2e-fake-niekawa-run/gate1-leak.txt" deny 1
guard_test '(h) ゲート1: 他の run_dir への書き込みも block(従来通り)' \
  "$HOME/.codex-agents/runs/e2e-fake-niekawa-run" "echo a > $HOME/.codex-agents/runs/other-run/leak.txt" deny 1
guard_test 'ゲート番号不明(空)も carve-out 無し ── 安全側のデフォルト' \
  "$HOME/.codex-agents/runs/e2e-fake-niekawa-run" "echo a > $HOME/.codex-agents/runs/e2e-fake-niekawa-run/x.txt" deny ""

echo "== 8. (g) claude-kashiwagi.sh 自体の分岐 ── gate1 は permission_mode_args が空、gate2 は acceptEdits =="
batch5="$(new_batch batch5)"
printf 'plan body\n' > "$batch5/plan.md"
printf 'findings body\n' > "$batch5/findings.md"
state5="$test_root/state5"
run_claude_launcher c-gate1-mode "$state5" "$batch5/to-niekawa.tsv" \
  --no-loop -C "$repo" -f "$batch5/plan.md" --dry-run
LC_ALL=C grep -q 'permission_mode_args=(無し、書き込み不可)' "$test_root/c-gate1-mode.out" \
  && pass '(g) ゲート1(plan.md)は permission_mode_args が空(書き込み不可)' \
  || fail "ゲート1の permission_mode_args が想定外: $(out c-gate1-mode)"
run_claude_launcher c-gate2-mode "$state5" "$batch5/to-niekawa.tsv" \
  --no-loop -C "$repo" -f "$batch5/findings.md" --dry-run
LC_ALL=C grep -q 'permission_mode_args=--permission-mode acceptEdits' "$test_root/c-gate2-mode.out" \
  && pass 'ゲート2(findings.md)は --permission-mode acceptEdits を渡す' \
  || fail "ゲート2の permission_mode_args が想定外: $(out c-gate2-mode)"

echo
echo "== summary =="
echo "pass: $pass_count  fail: $fail_count"
if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
