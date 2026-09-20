#!/usr/bin/env bash
# usage: gate2-guard-e2e.sh
#
# ゲート 2 のランチャ側担保(scripts/codex-agent.sh)と hook 側担保(scripts/hooks/gate-guard.sh)の
# 通し試験(BRIEF-gate2-launcher-guard、2026-09-20)。実 codex は一切起こさない ──
# kashiwagi / makabe とも --dry-run で「die しなければ exit 0 で codex 手前まで進む」ことだけを見る。
# die する経路は codex-agent.sh の設計どおり run_dir 作成前に exit するので、そもそも codex に届かない。
#
# NIEKAWA_INBOX と <便>/gates.tsv を仮に置き、exit code と stderr(die の理由文)・gates.tsv の中身で判定する。
# `rates codex` は fake に差し替える(実ネットワークを叩かない、weekly を任意値に固定する)。
#
# 軽量・実処理無し。再実行可能($CODEX_AGENT_STATE_DIR と便ディレクトリを毎回新規の temp に作る)。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_dir="$(dirname "$(dirname "$script_dir")")"
launcher="$core_dir/scripts/codex-agent.sh"
hook="$core_dir/scripts/hooks/gate-guard.sh"

[ -x "$launcher" ] || { echo "エラー: ランチャが見つからない: $launcher" >&2; exit 2; }
[ -f "$hook" ] || { echo "エラー: hook が見つからない: $hook" >&2; exit 2; }

test_root="$(mktemp -d /tmp/gate2-guard-e2e.XXXXXX)"
cleanup() {
  if [[ "$test_root" = /tmp/gate2-guard-e2e.* ]] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

fake_bin="$test_root/bin"
empty_codex_home="$test_root/codex-home"
mkdir -p "$fake_bin" "$empty_codex_home"
: > "$empty_codex_home/config.toml"

# 実ネットワークを叩かない fake rates。CODEX_AGENT_FAKE_RATES_WEEKLY / _NULL / _FAIL で挙動を切り替える。
cat > "$fake_bin/rates" <<'FAKE_RATES'
#!/usr/bin/env bash
set -euo pipefail
if [ "${CODEX_AGENT_FAKE_RATES_FAIL:-0}" = 1 ]; then
  echo "fake rates failure" >&2
  exit 1
fi
if [ "${CODEX_AGENT_FAKE_RATES_NULL:-0}" = 1 ]; then
  printf '{"email":"e2e@example.invalid","remaining":{"5h":null,"weekly":null,"monthly":null}}\n'
  exit 0
fi
printf '{"email":"e2e@example.invalid","remaining":{"5h":null,"weekly":%s,"monthly":null}}\n' \
  "${CODEX_AGENT_FAKE_RATES_WEEKLY:-69}"
FAKE_RATES
chmod +x "$fake_bin/rates"

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
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

# gates.tsv の行数(TAB 区切りの gate 列が $1 のもの)を数える。
count_gate() {
  local file="$1" gate="$2"
  [ -f "$file" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v g="$gate" '$3==g{n++} END{print n+0}' "$file"
}

new_batch() {
  local name="$1"
  local batch_dir="$test_root/batches/$name"
  mkdir -p "$batch_dir"
  printf '%s\n' "$batch_dir"
}

run_launcher() {
  # $1=name $2=state_dir $3=NIEKAWA_INBOX(空文字可) $@=以降 codex-agent.sh への引数
  local name="$1" state_dir="$2" inbox="$3"
  shift 3
  local out="$test_root/$name.out"
  set +e
  if [ -n "$inbox" ]; then
    PATH="$fake_bin:$PATH" CODEX_HOME="$empty_codex_home" CODEX_AGENT_STATE_DIR="$state_dir" \
      NIEKAWA_INBOX="$inbox" \
      "$launcher" "$@" > "$out" 2>&1
  else
    PATH="$fake_bin:$PATH" CODEX_HOME="$empty_codex_home" CODEX_AGENT_STATE_DIR="$state_dir" \
      "$launcher" "$@" > "$out" 2>&1
  fi
  local status=$?
  set -e
  printf '%s\n' "$status" > "$test_root/$name.status"
  return 0
}

launcher_status() { cat "$test_root/$1.status"; }
launcher_out() { cat "$test_root/$1.out"; }

runs_count() {
  local state_dir="$1"
  if [ -d "$state_dir/runs" ]; then
    find "$state_dir/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

logs_count() {
  local state_dir="$1"
  if [ -d "$state_dir/logs" ]; then
    find "$state_dir/logs" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

echo "== 1. 柏木のゲート 2、1 回目は通り gates.tsv に append される =="
batch1="$(new_batch batch1)"
printf 'findings body\n' > "$batch1/findings.md"
state1="$test_root/state1"
run_launcher k-first "$state1" "$batch1/to-niekawa.tsv" \
  kashiwagi --no-loop -C "$repo" -f "$batch1/findings.md" --dry-run
[ "$(launcher_status k-first)" = 0 ] && pass 'kashiwagi gate2 1回目は --dry-run で exit 0' \
  || fail "k-first: exit $(launcher_status k-first), expected 0. out: $(launcher_out k-first)"
[ "$(count_gate "$batch1/gates.tsv" 2)" = 1 ] && pass 'kashiwagi gate2 1回目で gates.tsv に gate=2 が1行 append される' \
  || fail "gates.tsv の gate=2 行数が想定外: $(cat "$batch1/gates.tsv" 2>/dev/null || echo なし)"

echo "== 2. 柏木のゲート 2、2 回目は run_dir 作成前に die =="
before_runs="$(runs_count "$state1")"
run_launcher k-second "$state1" "$batch1/to-niekawa.tsv" \
  kashiwagi --no-loop -C "$repo" -f "$batch1/findings.md" --dry-run
after_runs="$(runs_count "$state1")"
[ "$(launcher_status k-second)" != 0 ] && pass 'kashiwagi gate2 2回目は非0で die' \
  || fail "k-second: exit 0 になった(die していない)。out: $(launcher_out k-second)"
LC_ALL=C grep -q 'ゲート 2 は便に 1 回' "$test_root/k-second.out" && pass 'die の理由文が stderr に出る' \
  || fail "die の理由文が出力に無い: $(launcher_out k-second)"
[ "$before_runs" = "$after_runs" ] && pass 'die は run_dir を作らない(runs/ の件数が変わらない)' \
  || fail "run_dir が作られた(before=$before_runs after=$after_runs)"
[ "$(count_gate "$batch1/gates.tsv" 2)" = 1 ] && pass '2回目の die で gates.tsv に重複 append されない' \
  || fail "gates.tsv に重複記録: $(cat "$batch1/gates.tsv")"

echo "== 3. 柏木のゲート 1(plan.md)、1回目は通り append、2回目は run_dir 作成前に die(BRIEF-gate1-once) =="
batch2="$(new_batch batch2)"
printf 'plan body\n' > "$batch2/plan.md"
state2="$test_root/state2"
run_launcher k-plan-1 "$state2" "$batch2/to-niekawa.tsv" \
  kashiwagi --no-loop -C "$repo" -f "$batch2/plan.md" --dry-run
[ "$(launcher_status k-plan-1)" = 0 ] && pass 'kashiwagi gate1 1回目は --dry-run で exit 0' \
  || fail "k-plan-1: exit $(launcher_status k-plan-1), expected 0. out: $(launcher_out k-plan-1)"
[ "$(count_gate "$batch2/gates.tsv" 1)" = 1 ] && pass 'kashiwagi gate1 1回目で gates.tsv に gate=1 が1行 append される' \
  || fail "gates.tsv の gate=1 行数が想定外: $(cat "$batch2/gates.tsv" 2>/dev/null || echo なし)"

before_runs_g1="$(runs_count "$state2")"
run_launcher k-plan-2 "$state2" "$batch2/to-niekawa.tsv" \
  kashiwagi --no-loop -C "$repo" -f "$batch2/plan.md" --dry-run
after_runs_g1="$(runs_count "$state2")"
[ "$(launcher_status k-plan-2)" != 0 ] && pass 'kashiwagi gate1 2回目は非0で die' \
  || fail "k-plan-2: exit 0 になった(die していない)。out: $(launcher_out k-plan-2)"
LC_ALL=C grep -q 'ゲート 1 は便に 1 回' "$test_root/k-plan-2.out" && pass 'gate1 die の理由文が stderr に出る' \
  || fail "die の理由文が出力に無い: $(launcher_out k-plan-2)"
[ "$before_runs_g1" = "$after_runs_g1" ] && pass 'gate1 の die も run_dir を作らない' \
  || fail "run_dir が作られた(before=$before_runs_g1 after=$after_runs_g1)"
[ "$(count_gate "$batch2/gates.tsv" 1)" = 1 ] && pass '2回目の die で gates.tsv に gate=1 が重複 append されない' \
  || fail "gates.tsv に重複記録: $(cat "$batch2/gates.tsv")"

echo "== 4. 真壁 ── ゲート2の後、既定(luna)は die。sol は通る。weekly<20 は例外で通る =="
batch3="$(new_batch batch3)"
printf '%s\t-\t2\n' "$(date '+%Y-%m-%dT%H:%M:%S%:z')" > "$batch3/gates.tsv"
task3="$batch3/task.md"
printf 'guard test\n' > "$task3"
state3="$test_root/state3"
before_runs4="$(runs_count "$state3")"
before_logs4="$(logs_count "$state3")"

CODEX_AGENT_FAKE_RATES_WEEKLY=50 run_launcher m-luna-die "$state3" "$batch3/to-niekawa.tsv" \
  makabe -C "$repo" -f "$task3" --dry-run
[ "$(launcher_status m-luna-die)" != 0 ] && pass '真壁(既定luna)は gate2 の後 weekly=50% で die' \
  || fail "m-luna-die: exit 0(die していない)。out: $(launcher_out m-luna-die)"
LC_ALL=C grep -q 'sol で起こす' "$test_root/m-luna-die.out" && pass 'die の理由に sol の再起動コマンドが出る' \
  || fail "die の理由文が無い: $(launcher_out m-luna-die)"

CODEX_AGENT_FAKE_RATES_NULL=1 run_launcher m-null-die "$state3" "$batch3/to-niekawa.tsv" \
  makabe -C "$repo" -f "$task3" --dry-run
[ "$(launcher_status m-null-die)" != 0 ] && pass 'weekly が null のときも die(不明は 0/100 と読まない)' \
  || fail "m-null-die: exit 0 になった。out: $(launcher_out m-null-die)"

CODEX_AGENT_FAKE_RATES_FAIL=1 run_launcher m-fail-die "$state3" "$batch3/to-niekawa.tsv" \
  makabe -C "$repo" -f "$task3" --dry-run
[ "$(launcher_status m-fail-die)" != 0 ] && pass 'rates 取得失敗のときも die(sol を要求)' \
  || fail "m-fail-die: exit 0 になった。out: $(launcher_out m-fail-die)"

after_runs4="$(runs_count "$state3")"
after_logs4="$(logs_count "$state3")"
[ "$before_runs4" = "$after_runs4" ] && [ "$before_logs4" = "$after_logs4" ] \
  && pass 'die(3回)後も runs/ の件数と logs/ の件数が不変(rates.json だけの空 run_dir・空 log を残さない)' \
  || fail "die の残骸: runs before=$before_runs4 after=$after_runs4, logs before=$before_logs4 after=$after_logs4"

CODEX_AGENT_FAKE_RATES_WEEKLY=15 run_launcher m-low-weekly-ok "$state3" "$batch3/to-niekawa.tsv" \
  makabe -C "$repo" -f "$task3" --dry-run
[ "$(launcher_status m-low-weekly-ok)" = 0 ] && pass 'weekly=15%(<20)は例外で luna のまま続行(exit 0)' \
  || fail "m-low-weekly-ok: exit $(launcher_status m-low-weekly-ok)。out: $(launcher_out m-low-weekly-ok)"

CODEX_AGENT_FAKE_RATES_WEEKLY=50 run_launcher m-sol-ok "$state3" "$batch3/to-niekawa.tsv" \
  makabe -C "$repo" -f "$task3" --dry-run --model gpt-5.6-sol
[ "$(launcher_status m-sol-ok)" = 0 ] && pass '--model gpt-5.6-sol は weekly に関わらず続行(exit 0)' \
  || fail "m-sol-ok: exit $(launcher_status m-sol-ok)。out: $(launcher_out m-sol-ok)"

echo "== 5. gate2 記録が無い便では真壁は既定(luna)のまま通る =="
batch4="$(new_batch batch4)"
: > "$batch4/gates.tsv"
task4="$batch4/task.md"
printf 'guard test\n' > "$task4"
state4="$test_root/state4"
CODEX_AGENT_FAKE_RATES_WEEKLY=90 run_launcher m-no-gate2-ok "$state4" "$batch4/to-niekawa.tsv" \
  makabe -C "$repo" -f "$task4" --dry-run
[ "$(launcher_status m-no-gate2-ok)" = 0 ] && pass 'gate2 の記録が無ければ真壁は既定 luna のまま exit 0' \
  || fail "m-no-gate2-ok: exit $(launcher_status m-no-gate2-ok)"

echo "== 6. 便の外(NIEKAWA_INBOX 無し)は両personaとも素通し、挙動が変わらない =="
state5="$test_root/state5"
run_launcher k-outside "$state5" "" \
  kashiwagi --no-loop -C "$repo" -f "$batch1/findings.md" --dry-run
[ "$(launcher_status k-outside)" = 0 ] && pass '柏木: 便の外では gates.tsv に既存の gate2 があっても exit 0' \
  || fail "k-outside: exit $(launcher_status k-outside)。out: $(launcher_out k-outside)"
run_launcher k-outside-plan "$state5" "" \
  kashiwagi --no-loop -C "$repo" -f "$batch2/plan.md" --dry-run
[ "$(launcher_status k-outside-plan)" = 0 ] && pass '柏木: 便の外では gates.tsv に既存の gate1 があっても exit 0' \
  || fail "k-outside-plan: exit $(launcher_status k-outside-plan)。out: $(launcher_out k-outside-plan)"
CODEX_AGENT_FAKE_RATES_WEEKLY=90 run_launcher m-outside "$state5" "" \
  makabe -C "$repo" -f "$task3" --dry-run
[ "$(launcher_status m-outside)" = 0 ] && pass '真壁: 便の外では weekly が高くても exit 0(luna のまま)' \
  || fail "m-outside: exit $(launcher_status m-outside)。out: $(launcher_out m-outside)"

echo "== 7. hook(K3 PreToolUse)は検査だけ ── 書かない、ランチャが書いた記録を読んで deny する =="
batch5="$(new_batch batch5)"
printf 'findings body\n' > "$batch5/findings.md"
state6="$test_root/state6"
run_launcher k-hook-seed "$state6" "$batch5/to-niekawa.tsv" \
  kashiwagi --no-loop -C "$repo" -f "$batch5/findings.md" --dry-run
[ "$(launcher_status k-hook-seed)" = 0 ] || fail "k-hook-seed: 事前の 1 回目 launcher 呼び出しが失敗: $(launcher_out k-hook-seed)"
[ "$(count_gate "$batch5/gates.tsv" 2)" = 1 ] || fail "k-hook-seed 後に gates.tsv の gate=2 が1行になっていない"

hook_json() {
  local cmd="$1"
  printf '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/","tool_name":"Bash","tool_input":{"command":"%s"},"tool_call_id":"c1"}' \
    "$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

hook_out1="$test_root/hook-second.out"
hook_json "codex-kashiwagi --no-loop -C $repo -f $batch5/findings.md" \
  | NIEKAWA_INBOX="$batch5/to-niekawa.tsv" bash "$hook" > "$hook_out1" 2>"$test_root/hook-second.err"
hook_status1=$?
[ "$hook_status1" -eq 0 ] && pass 'hook は block でも exit 0 で返す(kimi の contract)' \
  || fail "hook exit $hook_status1、期待は 0"
LC_ALL=C grep -q '"permissionDecision":"deny"' "$hook_out1" && pass 'hook はランチャが書いた gate=2 記録を読んで2回目を deny する' \
  || fail "hook が deny しなかった: $(cat "$hook_out1")"
[ "$(count_gate "$batch5/gates.tsv" 2)" = 1 ] && pass 'hook 自身は gates.tsv に何も書かない(2重記録が無い)' \
  || fail "hook が gates.tsv に書き足した: $(cat "$batch5/gates.tsv")"

hook_out2="$test_root/hook-plan-no-record.out"
hook_json "codex-kashiwagi --no-loop -C $repo -f $batch5/plan.md" \
  | NIEKAWA_INBOX="$batch5/to-niekawa.tsv" bash "$hook" > "$hook_out2" 2>"$test_root/hook-plan-no-record.err"
[ -s "$hook_out2" ] && fail "hook が gate1 記録の無い便で plan.md 呼び出しを誤って deny した: $(cat "$hook_out2")" \
  || pass 'hook は gate1 の記録が無い便では plan.md を通す(gate2 記録は見ない)'

echo "== 7b. hook は plan.md(ゲート1)の2回目も deny する(BRIEF-gate1-once) =="
hook_out2b="$test_root/hook-plan-second.out"
hook_json "codex-kashiwagi --no-loop -C $repo -f $batch2/plan.md" \
  | NIEKAWA_INBOX="$batch2/to-niekawa.tsv" bash "$hook" > "$hook_out2b" 2>"$test_root/hook-plan-second.err"
hook_status2b=$?
[ "$hook_status2b" -eq 0 ] && pass 'hook は plan.md の deny でも exit 0 で返す' \
  || fail "hook exit $hook_status2b、期待は 0"
LC_ALL=C grep -q '"permissionDecision":"deny"' "$hook_out2b" && pass 'hook はランチャが書いた gate=1 記録を読んで plan.md の2回目を deny する' \
  || fail "hook が plan.md の2回目を deny しなかった: $(cat "$hook_out2b")"
[ "$(count_gate "$batch2/gates.tsv" 1)" = 1 ] && pass 'hook 自身は plan.md でも gates.tsv に何も書かない' \
  || fail "hook が gates.tsv に書き足した: $(cat "$batch2/gates.tsv")"

hook_out3="$test_root/hook-no-inbox.out"
hook_json "codex-kashiwagi --no-loop -C $repo -f $batch5/findings.md" \
  | bash "$hook" > "$hook_out3" 2>"$test_root/hook-no-inbox.err"
[ -s "$hook_out3" ] && fail "hook が NIEKAWA_INBOX 無しで誤って deny した: $(cat "$hook_out3")" \
  || pass 'hook は NIEKAWA_INBOX 無し(人見の対話・便の外)では素通し'

echo
echo "== summary =="
echo "pass: $pass_count  fail: $fail_count"
if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
