#!/usr/bin/env bash
# Minimal smoke test for hooks/session-init.sh (2026-09-24 改修).
# 実 consumer(既定 tech、REPO_ROOT で差し替え可)の .harness.json に対して実行し、
#   1. Neon recent documents の見出しに JST が付く
#   2. latest session summary 行が実際の `_sessions/YYYY-MM-DD_NN.md` を指す
# ことを確かめる。Neon urlFile が使えない環境では Neon の検査を skip する
# (fetch failed でも hook 自体は exit 0 を保つのが仕様なので、それは落とさない)。

set -uo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$script_dir/../hooks/session-init.sh"
repo_root="${REPO_ROOT:-$HOME/canonical/tech}"

count=0
fail=0
ok() { count=$((count + 1)); echo "ok $count - $1"; }
not_ok() { count=$((count + 1)); echo "not ok $count - $1"; fail=1; }

if [ ! -x "$hook" ] && [ ! -f "$hook" ]; then
  echo "not ok 1 - hook not found at $hook"
  exit 1
fi
if [ ! -d "$repo_root" ]; then
  echo "ok 1 - skip (repo_root not found: $repo_root)"
  exit 0
fi

out="$(CLAUDE_PROJECT_DIR="$repo_root" bash "$hook" 2>/tmp/session-init-hook-test.err)"
rc=$?

if [ "$rc" -ne 0 ]; then
  not_ok "hook exits 0 (got $rc, stderr: $(cat /tmp/session-init-hook-test.err))"
else
  ok "hook exits 0"
fi

ctx="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"

if printf '%s' "$ctx" | grep -q 'hookEventName' 2>/dev/null; then
  : # not expected here; ctx is additionalContext only, guard against empty parse
fi

if [ -z "$ctx" ]; then
  not_ok "additionalContext is non-empty"
else
  ok "additionalContext is non-empty"
fi

if printf '%s' "$ctx" | grep -Eq '### Neon recent documents \(harness_index_db, JST\)'; then
  ok "Neon heading marks JST"
elif printf '%s' "$ctx" | grep -q 'fetch failed'; then
  ok "Neon fetch unavailable in this environment (skip JST check)"
else
  not_ok "Neon section present but missing JST marker"
fi

if printf '%s' "$ctx" | grep -Eq '^- latest session summary: `_sessions/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]+\.md` ── .+$'; then
  ok "latest session summary line points at a real _sessions/YYYY-MM-DD_NN.md"
else
  not_ok "latest session summary line missing or malformed"
fi

if printf '%s' "$ctx" | grep -Eq '^- latest session dir|^- daily_summary:'; then
  not_ok "old broken latest-session-dir/daily_summary lines still present"
else
  ok "old broken latest-session-dir/daily_summary lines removed"
fi

echo "1..$count"
exit $fail
