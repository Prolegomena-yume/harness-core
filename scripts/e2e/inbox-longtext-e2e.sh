#!/usr/bin/env bash
# usage: inbox-longtext-e2e.sh
#
# 受信箱(scripts/to.sh / scripts/from.sh)の長文往復の通し試験(BRIEF-inbox-limits、2026-09-21)。
# 実 codex / kimi は一切起こさない ── to-niekawa / from-takano を直接呼ぶだけ。
#
# 検証する不変条件:
#   1. 旧来の 1024 バイト固定切り詰めが無い(budget 内なら長文でも丸ごと入る)
#   2. budget を超える場合だけ、末尾に `…[切れた N 字、全文は <path>]` を付けて切り、
#      全文(改行/TAB を潰す前の原文)を便ディレクトリの messages/<時刻>-<pid>.md に一字一句残す
#   3. tsv 1 行は PIPE_BUF(4096 バイト)を超えない(ロック無し原子的 append の不変条件)
#   4. from-takano で読み戻した行が書き込んだ行と完全一致する
#
# 軽量・実処理無し。再実行可能(毎回新規の temp ディレクトリ)。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_dir="$(dirname "$(dirname "$script_dir")")"
to_sh="$core_dir/scripts/to.sh"
from_sh="$core_dir/scripts/from.sh"

test_root="$(mktemp -d /tmp/inbox-longtext-e2e.XXXXXX)"
cleanup() {
  if [[ "$test_root" = /tmp/inbox-longtext-e2e.* ]] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

bin_dir="$test_root/bin"
mkdir -p "$bin_dir"
ln -sfn "$to_sh" "$bin_dir/to-niekawa"
ln -sfn "$from_sh" "$bin_dir/from-takano"

inbox="$test_root/batch/to-niekawa.tsv"

pass_count=0
pass() { pass_count=$((pass_count + 1)); printf 'ok %d - %s\n' "$pass_count" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

run_to() {
  PATH="$bin_dir:$PATH" to-niekawa --inbox "$inbox" --kind 裁定 -- "$@"
}
run_to_stdin() {
  PATH="$bin_dir:$PATH" to-niekawa --inbox "$inbox" --kind 裁定
}

# ---- 1. 短文はそのまま(既存挙動の回帰確認) ----
run_to '短い裁定文' > "$test_root/out-short.txt"
short_line="$(cat "$test_root/out-short.txt")"
[[ "$short_line" == *$'\t'"短い裁定文" ]] || fail 'short message is not carried verbatim'
if [[ "$short_line" == *'切れた'* ]]; then fail 'short message unexpectedly marked as truncated'; fi
pass 'short summary passes through unchanged'

# ---- 2. gen-5 実例の再現:1040 字(全角、3120 バイト)は budget 内で丸ごと入る ----
msg1040="$(python3 -c "print('あ'*1040, end='')")"
run_to "$msg1040" > "$test_root/out-1040.txt"
line_1040="$(cat "$test_root/out-1040.txt")"
if [[ "$line_1040" == *'切れた'* ]]; then
  fail 'gen-5 の 1040 字が新方式でも切れている(旧 1024 バイト上限のバグが直っていない)'
fi
summary_1040="${line_1040#*$'\t'*$'\t'*$'\t'*$'\t'}"
[ "$(printf '%s' "$summary_1040" | wc -m)" -eq 1040 ] || fail 'gen-5 の 1040 字が全文で残っていない'
pass 'gen-5 実例(1040 字)は budget 内で丸ごと入り、切り詰めマーカーが付かない'

# ---- 3. budget 超過(2000 字、全角 6000 バイト)は明示マーカー + 全文サイドカー ----
raw_2000="$(python3 -c "print('あ'*2000, end='')")"
run_to "$raw_2000" > "$test_root/out-2000.txt"
line_2000="$(cat "$test_root/out-2000.txt")"
line_bytes="$(printf '%s' "$line_2000" | wc -c)"
[ "$line_bytes" -le 4096 ] || fail "truncated line exceeds PIPE_BUF: $line_bytes bytes"
[[ "$line_2000" == *'…[切れた 2000 字、全文は '*'/messages/'*'.md]' ]] || fail 'truncation marker is absent or malformed'
pass 'over-budget message is truncated with an explicit "切れた N 字、全文は <path>" marker, staying within PIPE_BUF'

sidecar_path="$(printf '%s' "$line_2000" | LC_ALL=C sed -n 's/.*全文は \(.*\)\]$/\1/p')"
[ -f "$sidecar_path" ] || fail "sidecar file not found: $sidecar_path"
[ "$(cat "$sidecar_path")" = "$raw_2000" ] || fail 'sidecar file does not contain the full original text verbatim'
[[ "$sidecar_path" == "$test_root/batch/messages/"* ]] || fail 'sidecar file is not under the batch messages/ directory'
pass 'the full original text is recoverable verbatim from the referenced messages/<timestamp>.md'

# ---- 4. 改行・TAB 入りの長文(2,000 字)も欠けずに往復できる(直接一致するか、
#         マーカー経由でサイドカーから全文を辿れるかのどちらか) ----
raw_multiline="$(python3 -c "
lines = []
for i in range(200):
    lines.append('行%d\tタブ入り本文\t続き' % i)
print('\n'.join(lines), end='')
")"
run_to_stdin <<< "$raw_multiline" > "$test_root/out-multiline.txt"
line_multiline="$(cat "$test_root/out-multiline.txt")"
line_multiline_bytes="$(printf '%s' "$line_multiline" | wc -c)"
[ "$line_multiline_bytes" -le 4096 ] || fail "multiline row exceeds PIPE_BUF: $line_multiline_bytes bytes"
if [[ "$line_multiline" == *'切れた'* ]]; then
  ml_sidecar="$(printf '%s' "$line_multiline" | LC_ALL=C sed -n 's/.*全文は \(.*\)\]$/\1/p')"
  [ -f "$ml_sidecar" ] || fail 'multiline sidecar file not found'
  diff -q "$ml_sidecar" <(printf '%s\n' "$raw_multiline") >/dev/null 2>&1 \
    || fail 'multiline sidecar does not match the original text exactly (newlines/tabs included)'
else
  ml_flat="$(printf '%s' "$raw_multiline" | tr '\n\t' '  ')"
  [[ "$line_multiline" == *"$ml_flat" ]] || fail 'multiline message not carried verbatim on the flattened tsv row'
fi
pass '2,000-character text with embedded newlines/tabs round-trips without loss (inline or via sidecar)'

# ---- 5. from-takano で読み戻した行が書き込んだ行と完全一致する ----
mapfile -t written_lines < "$inbox"
read_out="$(PATH="$bin_dir:$PATH" from-takano --inbox "$inbox" --after 0)"
mapfile -t read_lines <<< "$read_out"
[ "${read_lines[-1]}" = "LINES=${#written_lines[@]}" ] || fail 'from-takano LINES= footer mismatch'
unset 'read_lines[-1]'
for i in "${!written_lines[@]}"; do
  [ "${read_lines[$i]}" = "${written_lines[$i]}" ] || fail "from-takano row $i differs from what was written"
done
pass 'from-takano reads back every row byte-for-byte identical to what to-niekawa wrote'

printf '1..%d\n' "$pass_count"
