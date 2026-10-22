#!/usr/bin/env bash
# Minimal smoke test for hooks/session-init.sh (2026-09-24 改修).
# 実 consumer(既定 tech、REPO_ROOT で差し替え可)の .harness.json に対して実行し、
#   1. Index recent documents の見出しに JST が付く
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

if printf '%s' "$ctx" | grep -Eq '### Index recent documents \(harness_index_db, JST\)'; then
  ok "Index heading marks JST"
elif printf '%s' "$ctx" | grep -q 'fetch failed'; then
  ok "Neon fetch unavailable in this environment (skip JST check)"
elif printf '%s' "$ctx" | grep -q 'Neon の鍵なし(想定内)'; then
  ok "no Neon key on this machine, ymos kb search guided (skip JST check)"
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

# Dleam の url(host が *.neon.tech でない)を向けたとき、dleam-sql が無ければ「届かない」と分かる 1 行にして exit 0 を保つ。
# 一時 HOME と一時 consumer で流す(実際の urlFile には触れない)。
tmp="$(mktemp -d)"
mkdir -p "$tmp/home/.ssh" "$tmp/repo"
printf 'postgresql://u:p@dleam.example.test/harness_index_db\n' > "$tmp/home/.ssh/neon-harness-index-url.txt"
printf '{"neon":{"urlFile":"~/.ssh/neon-harness-index-url.txt"},"mirror":{"enabled":false}}\n' > "$tmp/repo/.harness.json"
dleam_out="$(HOME="$tmp/home" DLEAM_SQL_BIN="$tmp/missing-dleam-sql" CLAUDE_PROJECT_DIR="$tmp/repo" bash "$hook" 2>/dev/null)"
dleam_rc=$?
dleam_ctx="$(printf '%s' "$dleam_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
if [ "$dleam_rc" -eq 0 ] && printf '%s' "$dleam_ctx" | grep -q -- '- fetch failed: 索引 DB の url は Dleam.*dleam-sql が無い'; then
  ok "Dleam を向いて client が無いと fetch failed の 1 行、hook は exit 0"
else
  not_ok "Dleam を向いて client が無いときの fetch failed が出ない(rc=$dleam_rc)"
fi
rm -rf "$tmp"

# Claude アプリの worktree:CLAUDE_PROJECT_DIR は本体、stdin の cwd が同じリポの worktree。
# branch・status・log はその worktree から、cwd が別のリポなら本体のまま。
wt="$(mktemp -d)"
git init -q -b main "$wt/main"
printf '{"mirror":{"enabled":false}}\n' > "$wt/main/.harness.json"
git -C "$wt/main" add .harness.json
git -C "$wt/main" -c user.name=t -c user.email=t@t commit -q -m base
git -C "$wt/main" worktree add -q -b claude/wt-test "$wt/main/.claude/worktrees/wt-test"
git -C "$wt/main/.claude/worktrees/wt-test" -c user.name=t -c user.email=t@t commit -q --allow-empty -m wt-only
touch "$wt/main/dirty"
git init -q -b other "$wt/other"
ctx_of() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
wt_ctx="$(printf '{"cwd":"%s"}' "$wt/main/.claude/worktrees/wt-test" | CLAUDE_PROJECT_DIR="$wt/main" bash "$hook" 2>/dev/null | ctx_of)"
if printf '%s' "$wt_ctx" | grep -q 'branch: `claude/wt-test`; working tree: clean' && printf '%s' "$wt_ctx" | grep -q ' wt-only$'; then
  ok "worktree の cwd では branch・status・log が worktree のもの"
else
  not_ok "worktree の cwd で本体の branch・status・log が出る"
fi
main_ctx="$(printf '{"cwd":"%s"}' "$wt/main" | CLAUDE_PROJECT_DIR="$wt/main" bash "$hook" 2>/dev/null | ctx_of)"
other_ctx="$(printf '{"cwd":"%s"}' "$wt/other" | CLAUDE_PROJECT_DIR="$wt/main" bash "$hook" 2>/dev/null | ctx_of)"
none_ctx="$(CLAUDE_PROJECT_DIR="$wt/main" bash "$hook" </dev/null 2>/dev/null | ctx_of)"
if printf '%s\n%s\n%s' "$main_ctx" "$other_ctx" "$none_ctx" | grep -c 'branch: `main`; working tree: .*?? dirty' | grep -qx 3; then
  ok "本体の cwd・別リポの cwd・stdin 無しでは本体のまま"
else
  not_ok "本体の cwd・別リポの cwd・stdin 無しで本体の状態にならない"
fi
rm -rf "$wt"

echo "1..$count"
exit $fail
