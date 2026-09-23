#!/usr/bin/env bash
# usage: niekawa-route-time-e2e.sh
#
# kimi-niekawa.sh / claude-niekawa.sh の口を揃える改修(役員 人見 2026-09-24、庵野)の通し試験。
# 実 kimi / claude は一切起こさない ── --dry-run で prompt(巡1)の中身だけを見る。
#
#   1. kimi-niekawa.sh の既定(KASHIWAGI_ROUTE 未指定 = opus)は claude 版と同じ文言で
#      「柏木の呼び出し: claude-kashiwagi を使う」の行を出す
#   2. KASHIWAGI_ROUTE=codex なら「柏木の呼び出し: codex-kashiwagi を使う」に切り替わる(kimi 版)
#   3. --budget 無指定では両版とも「時間: elapsed」の行を出さない
#   4. --budget 指定時は両版とも「時間: elapsed <秒>s / <秒>s」の行を出す(budget_min*60 と一致)
#   5. --resume-run で前 run の runs.tsv 1 行目(便の最初の run)からの経過秒を通算する(kimi 版)
#
# 軽量・実処理無し。再実行可能($CODEX_AGENT_STATE_DIR を毎回新規の temp に作る)。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_dir="$(dirname "$(dirname "$script_dir")")"
kimi_launcher="$core_dir/scripts/kimi-niekawa.sh"
claude_launcher="$core_dir/scripts/claude-niekawa.sh"

for f in "$kimi_launcher" "$claude_launcher"; do
  [ -e "$f" ] || { echo "エラー: ランチャが見つからない: $f" >&2; exit 2; }
done

test_root="$(mktemp -d /tmp/niekawa-route-time-e2e.XXXXXX)"
cleanup() {
  if [[ "$test_root" = /tmp/niekawa-route-time-e2e.* ]] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

# claude-niekawa.sh は起動直後に `command -v claude` を要求する(--dry-run でも呼ばない箇所だが
# チェック自体は通る必要がある)。実 claude を呼ばない fake を PATH に置く。
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
echo "エラー: この試験は claude を実行しないはず" >&2
exit 9
FAKE_CLAUDE
chmod +x "$fake_bin/claude"

repo="$test_root/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b impl/e2e
git -C "$repo" config user.name E2E
git -C "$repo" config user.email e2e@example.invalid
printf 'initial\n' > "$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -qm initial

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); printf 'ok %d - %s\n' "$pass_count" "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'not ok - %s\n' "$1" >&2; }

# --------------------------------------------------------------------------
echo "== 1. kimi-niekawa.sh 既定(KASHIWAGI_ROUTE 未指定) ── claude 版と同じ文言 =="
batch1="dry-batch-1"
brief1="$test_root/brief1.md"
printf '便: %s\n\nタスク本文\n' "$batch1" > "$brief1"
state1="$test_root/state1"

kimi_default_out="$test_root/kimi-default.out"
set +e
PATH="$fake_bin:$PATH" CODEX_AGENT_STATE_DIR="$state1" \
  "$kimi_launcher" -f "$brief1" --dry-run > "$kimi_default_out" 2>&1
kimi_default_status=$?
set -e
[ "$kimi_default_status" -eq 0 ] && pass 'kimi-niekawa --dry-run は既定で exit 0' \
  || fail "exit $kimi_default_status: $(cat "$kimi_default_out")"
LC_ALL=C grep -Fq '柏木の呼び出し: claude-kashiwagi を使う(env KASHIWAGI_ROUTE=opus' "$kimi_default_out" \
  && pass 'kimi 版: KASHIWAGI_ROUTE 未指定(既定 opus)で claude-kashiwagi の行が出る(claude 版と同文言)' \
  || fail "claude-kashiwagi の行が無い: $(cat "$kimi_default_out")"
LC_ALL=C grep -Fq '時間: elapsed' "$kimi_default_out" \
  && fail '--budget 無指定なのに 時間: elapsed の行が出た' \
  || pass 'kimi 版: --budget 無指定では 時間: elapsed の行を出さない'

echo "== 2. kimi-niekawa.sh KASHIWAGI_ROUTE=codex で codex-kashiwagi に切り替わる =="
kimi_codex_out="$test_root/kimi-codex.out"
set +e
PATH="$fake_bin:$PATH" CODEX_AGENT_STATE_DIR="$state1" KASHIWAGI_ROUTE=codex \
  "$kimi_launcher" -f "$brief1" --batch "dry-batch-2" --dry-run > "$kimi_codex_out" 2>&1
kimi_codex_status=$?
set -e
[ "$kimi_codex_status" -eq 0 ] && pass 'kimi-niekawa --dry-run(KASHIWAGI_ROUTE=codex)は exit 0' \
  || fail "exit $kimi_codex_status: $(cat "$kimi_codex_out")"
LC_ALL=C grep -Fq '柏木の呼び出し: codex-kashiwagi を使う(env KASHIWAGI_ROUTE=codex)' "$kimi_codex_out" \
  && pass 'kimi 版: KASHIWAGI_ROUTE=codex で codex-kashiwagi の行に切り替わる' \
  || fail "codex-kashiwagi の行が無い: $(cat "$kimi_codex_out")"

echo "== 3. --budget 指定で両版とも 時間: elapsed の行が出る =="
kimi_budget_out="$test_root/kimi-budget.out"
set +e
PATH="$fake_bin:$PATH" CODEX_AGENT_STATE_DIR="$state1" \
  "$kimi_launcher" -f "$brief1" --batch "dry-batch-3" --budget 30 --dry-run > "$kimi_budget_out" 2>&1
kimi_budget_status=$?
set -e
[ "$kimi_budget_status" -eq 0 ] && pass 'kimi-niekawa --dry-run --budget 30 は exit 0' \
  || fail "exit $kimi_budget_status: $(cat "$kimi_budget_out")"
LC_ALL=C grep -Eq '時間: elapsed [0-9]+s / 1800s' "$kimi_budget_out" \
  && pass 'kimi 版: --budget 30 で 時間: elapsed <秒>s / 1800s の行が出る' \
  || fail "時間: elapsed の行が想定外: $(cat "$kimi_budget_out")"

claude_budget_out="$test_root/claude-budget.out"
set +e
PATH="$fake_bin:$PATH" CODEX_AGENT_STATE_DIR="$state1" \
  "$claude_launcher" -f "$brief1" --batch "dry-batch-4" --budget 15 --dry-run > "$claude_budget_out" 2>&1
claude_budget_status=$?
set -e
[ "$claude_budget_status" -eq 0 ] && pass 'claude-niekawa --dry-run --budget 15 は exit 0' \
  || fail "exit $claude_budget_status: $(cat "$claude_budget_out")"
LC_ALL=C grep -Eq '時間: elapsed [0-9]+s / 900s' "$claude_budget_out" \
  && pass 'claude 版: --budget 15 で 時間: elapsed <秒>s / 900s の行が出る' \
  || fail "時間: elapsed の行が想定外: $(cat "$claude_budget_out")"

echo "== 4. --resume-run で便の最初の run からの経過秒を通算する(kimi 版) =="
batch5="dry-batch-5"
batch5_dir="$state1/batches/$batch5"
mkdir -p "$batch5_dir"
old_ts="$(date -d '-10 minutes' '+%Y-%m-%dT%H:%M:%S%:z')"
fake_prev_run="$state1/runs/fake-prev-run"
mkdir -p "$fake_prev_run"
printf '%s\tfake_run_dir\tkimi\t-\t-\n' "$old_ts" > "$batch5_dir/runs.tsv"
brief5="$test_root/brief5.md"
printf '便: %s\n\nタスク本文\n' "$batch5" > "$brief5"

kimi_resume_out="$test_root/kimi-resume.out"
set +e
PATH="$fake_bin:$PATH" CODEX_AGENT_STATE_DIR="$state1" \
  "$kimi_launcher" -f "$brief5" --budget 30 --resume-run "$fake_prev_run" --dry-run > "$kimi_resume_out" 2>&1
kimi_resume_status=$?
set -e
[ "$kimi_resume_status" -eq 0 ] && pass 'kimi-niekawa --dry-run --resume-run --budget 30 は exit 0' \
  || fail "exit $kimi_resume_status: $(cat "$kimi_resume_out")"
elapsed_val="$(LC_ALL=C grep -Eo '時間: elapsed [0-9]+s' "$kimi_resume_out" | grep -Eo '[0-9]+' || true)"
if [ -n "$elapsed_val" ] && [ "$elapsed_val" -ge 590 ] && [ "$elapsed_val" -le 650 ]; then
  pass "kimi 版: --resume-run は便最初の run(10分前)からの経過を通算する(elapsed=${elapsed_val}s)"
else
  fail "elapsed が想定外(10分=600s 近辺のはず): ${elapsed_val:-なし} / $(cat "$kimi_resume_out")"
fi

echo "== 5. --budget に不正値を渡すと die(exit 2) =="
kimi_bad_budget_out="$test_root/kimi-bad-budget.out"
set +e
PATH="$fake_bin:$PATH" CODEX_AGENT_STATE_DIR="$state1" \
  "$kimi_launcher" -f "$brief1" --budget abc --dry-run > "$kimi_bad_budget_out" 2>&1
kimi_bad_budget_status=$?
set -e
[ "$kimi_bad_budget_status" -eq 2 ] && pass 'kimi-niekawa --budget abc は exit 2 で die' \
  || fail "exit $kimi_bad_budget_status(期待 2): $(cat "$kimi_bad_budget_out")"

echo
echo "== summary =="
echo "pass: $pass_count  fail: $fail_count"
if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
