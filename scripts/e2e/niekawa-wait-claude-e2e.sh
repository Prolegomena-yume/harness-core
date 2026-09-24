#!/usr/bin/env bash
# usage: niekawa-wait-claude-e2e.sh
#
# scripts/niekawa-wait-claude.sh(案 A、claude 経路の待ちの道具、役員 人見 2026-09-25)の通し試験。
# 実 claude / kimi は一切起こさない ── .out ファイルと to-niekawa.tsv を直接作り、道具の
# 3 つの返り方(終端で即返る / 受信で即返る / timeout で返る)を実測する。timeout は env で縮めて試す。
#
# 軽量・実処理無し。再実行可能(毎回新規の temp)。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_dir="$(dirname "$(dirname "$script_dir")")"
tool="$core_dir/scripts/niekawa-wait-claude.sh"

[ -x "$tool" ] || { echo "エラー: 道具が見つからない: $tool" >&2; exit 2; }
command -v from-takano >/dev/null 2>&1 || { echo "エラー: from-takano が PATH に無い" >&2; exit 2; }

test_root="$(mktemp -d /tmp/niekawa-wait-claude-e2e.XXXXXX)"
cleanup() {
  if [[ "$test_root" = /tmp/niekawa-wait-claude-e2e.* ]] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); printf 'ok %d - %s\n' "$pass_count" "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'NG - %s\n' "$1" >&2; }

echo "== 0. 引数不正は exit 4 =="
if bash "$tool" >/tmp/niekawa-wait-claude-e2e-noout.$$ 2>&1; then
  fail "--out 無しでも通ってしまう"
else
  code=$?
  [ "$code" -eq 4 ] && pass "--out が無いと exit 4" || fail "--out が無いときの exit code が違う: $code"
fi
rm -f "/tmp/niekawa-wait-claude-e2e-noout.$$"

echo "== 1. 終端(footer)が先に出れば即座に exit 0 で返る =="
out1="$test_root/makabe-a.out"
: > "$out1"
(
  sleep 2
  {
    echo "session_id: fake-1"
    echo "変更ファイル数: 3"
  } >> "$out1"
) &
bgpid=$!
start=$(date +%s)
set +e
result1="$(NIEKAWA_WAIT_POLL=1 bash "$tool" --out "$out1" --timeout 20)"
code1=$?
set -e
elapsed1=$(( $(date +%s) - start ))
wait "$bgpid" 2>/dev/null || true
if [ "$code1" -eq 0 ]; then
  pass "終端検知で exit 0"
else
  fail "終端検知の exit code が違う: $code1"
fi
if [ "$elapsed1" -le 10 ]; then
  pass "終端検知は timeout(20秒)を待たず約2秒で返った(実測 ${elapsed1}秒)"
else
  fail "終端検知が遅すぎる(実測 ${elapsed1}秒)"
fi
if printf '%s' "$result1" | grep -q '^REASON=footer'; then
  pass "REASON=footer が出る"
else
  fail "REASON=footer が出ない: $result1"
fi
if printf '%s' "$result1" | grep -q '^変更ファイル数: 3'; then
  pass "footer 行(変更ファイル数: 3)がそのまま返る"
else
  fail "footer 行が返らない: $result1"
fi

echo "== 2. 鷹野からの新着が先に出れば即座に exit 1 で返る(footer は出ないまま) =="
out2="$test_root/makabe-b.out"
: > "$out2"
inbox2="$test_root/to-niekawa.tsv"
: > "$inbox2"
(
  sleep 2
  to-niekawa --inbox "$inbox2" --kind 裁定 -- "テスト新着" >/dev/null 2>&1 || true
) &
bgpid2=$!
start2=$(date +%s)
set +e
result2="$(NIEKAWA_WAIT_POLL=1 bash "$tool" --out "$out2" --inbox "$inbox2" --after 0 --timeout 20)"
code2=$?
set -e
elapsed2=$(( $(date +%s) - start2 ))
wait "$bgpid2" 2>/dev/null || true
if [ "$code2" -eq 1 ]; then
  pass "新着検知で exit 1"
else
  fail "新着検知の exit code が違う: $code2"
fi
if [ "$elapsed2" -le 10 ]; then
  pass "新着検知は timeout(20秒)を待たず約2秒で返った(実測 ${elapsed2}秒)"
else
  fail "新着検知が遅すぎる(実測 ${elapsed2}秒)"
fi
if printf '%s' "$result2" | grep -q '^REASON=inbox'; then
  pass "REASON=inbox が出る"
else
  fail "REASON=inbox が出ない: $result2"
fi
if printf '%s' "$result2" | grep -q 'テスト新着'; then
  pass "新着行の本文が返る"
else
  fail "新着行の本文が返らない: $result2"
fi
if printf '%s' "$result2" | grep -qE '^LINES=[1-9][0-9]*$'; then
  pass "LINES= が新しい行数を指す"
else
  fail "LINES= が出ない/0のまま: $result2"
fi

echo "== 2b. --inbox 省略時は from-takano と同じ既定解決(env NIEKAWA_INBOX)に任せる =="
out2b="$test_root/makabe-b2.out"
: > "$out2b"
inbox2b="$test_root/to-niekawa-2b.tsv"
: > "$inbox2b"
(
  sleep 2
  NIEKAWA_INBOX="$inbox2b" to-niekawa --kind 指示 -- "env 経由の新着" >/dev/null 2>&1 || true
) &
bgpid2b=$!
set +e
result2b="$(NIEKAWA_INBOX="$inbox2b" NIEKAWA_WAIT_POLL=1 bash "$tool" --out "$out2b" --after 0 --timeout 20)"
code2b=$?
set -e
wait "$bgpid2b" 2>/dev/null || true
if [ "$code2b" -eq 1 ] && printf '%s' "$result2b" | grep -q '^REASON=inbox'; then
  pass "--inbox を渡さなくても env NIEKAWA_INBOX 経由で新着を検知する"
else
  fail "--inbox 省略時の env 解決に失敗: code=$code2b result=$result2b"
fi

echo "== 3. 何も起きなければ --timeout 秒(縮めて 3 秒)で exit 2 =="
out3="$test_root/makabe-c.out"
: > "$out3"
start3=$(date +%s)
set +e
result3="$(NIEKAWA_WAIT_POLL=1 bash "$tool" --out "$out3" --timeout 3)"
code3=$?
set -e
elapsed3=$(( $(date +%s) - start3 ))
if [ "$code3" -eq 2 ]; then
  pass "timeout で exit 2"
else
  fail "timeout の exit code が違う: $code3"
fi
if [ "$elapsed3" -ge 3 ] && [ "$elapsed3" -le 8 ]; then
  pass "timeout は指定した約3秒で返った(実測 ${elapsed3}秒)"
else
  fail "timeout の実測が想定と違う(実測 ${elapsed3}秒)"
fi
if printf '%s' "$result3" | grep -q '^REASON=timeout'; then
  pass "REASON=timeout が出る"
else
  fail "REASON=timeout が出ない: $result3"
fi
if printf '%s' "$result3" | grep -q '^まだ$'; then
  pass "footer 未検知は「まだ」と返る"
else
  fail "footer 未検知の表示が違う: $result3"
fi
if printf '%s' "$result3" | grep -q '^無し$'; then
  pass "新着無しは「無し」と返る"
else
  fail "新着無しの表示が違う: $result3"
fi

echo "== 4. 既定の timeout は 590 秒(env で上書きしない限り) =="
if grep -q 'timeout="\${NIEKAWA_WAIT_TIMEOUT:-590}"' "$tool"; then
  pass "既定 --timeout は 590(NIEKAWA_WAIT_TIMEOUT 未設定時)"
else
  fail "既定 590 がソースに見当たらない"
fi

echo
echo "== summary =="
echo "pass: $pass_count  fail: $fail_count"
[ "$fail_count" -eq 0 ]
