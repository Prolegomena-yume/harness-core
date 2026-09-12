#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
launcher="$script_dir/codex-agent.sh"
test_root="$(mktemp -d /tmp/codex-agent-guard.XXXXXX)"
fake_bin="$test_root/bin"
empty_codex_home="$test_root/codex-home"
mkdir -p "$fake_bin" "$empty_codex_home"
cat > "$empty_codex_home/config.toml" <<'TOML'
[mcp_servers.alpha]
command = "true"

[mcp_servers.beta]
command = "true"
TOML

cleanup() {
  if [[ "$test_root" = /tmp/codex-agent-guard.* ]] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

capture_dir="${CODEX_AGENT_FAKE_CAPTURE_DIR:-}"
if [ -n "$capture_dir" ]; then
  mkdir -p "$capture_dir"
  printf '%s\n' "$@" > "$capture_dir/argv.txt"
  printf '%s\n' "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" "$GIT_COMMITTER_NAME" "$GIT_COMMITTER_EMAIL" > "$capture_dir/identity.txt"
  printf '%s\n' "${CODEX_AGENT_RUN_DIR:-}" > "$capture_dir/run-dir.txt"
  cat > "$capture_dir/stdin.txt"
  if [ -s "$capture_dir/stdin.txt" ]; then
    printf 'yes\n' > "$capture_dir/stdin-present.txt"
  else
    printf 'no\n' > "$capture_dir/stdin-present.txt"
  fi
else
  cat > /dev/null
fi

work_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      work_root="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
[ -n "$work_root" ] || exit 90
cd "$work_root"
fake_status=0
echo "session id: ${CODEX_AGENT_FAKE_SESSION_ID:-00000000-0000-0000-0000-000000000000}"

case "${CODEX_AGENT_FAKE_ACTION:-none}" in
  none) ;;
  new_branch) git branch new-branch ;;
  other_branch) git branch -f other HEAD^ ;;
  delete_branch) git branch -D other ;;
  new_tag) git tag forbidden ;;
  remote_create) git update-ref refs/remotes/origin/new HEAD ;;
  remote_delete) git update-ref -d refs/remotes/origin/main ;;
  commit_fail)
    printf 'commit\n' >> tracked.txt
    git add tracked.txt
    git commit -qm failure-test
    fake_status=7 ;;
  submodule_commit)
    git -C modules/child -c user.name=Guard -c user.email=guard@example.invalid commit --allow-empty -qm child ;;

  append_tracked) printf 'post\n' >> tracked.txt ;;
  append_untracked) printf 'post\n' >> untracked.txt ;;
  create_ignored) printf 'ignored\n' > build.generated ;;
  create_ignored_submodule) printf 'ignored\n' > modules/child/inside.generated ;;
  replace_symlink) ln -sfn target-b link.txt ;;
  modify_submodule) printf 'post\n' >> modules/child/inside.txt ;;
  commit)
    printf 'commit\n' >> tracked.txt
    git add tracked.txt
    git -c user.name=Guard -c user.email=guard@example.invalid commit -qm guard-test
    ;;
  commit_reset)
    printf 'commit then reset\n' >> tracked.txt
    git add tracked.txt
    git -c user.name=Guard -c user.email=guard@example.invalid commit -qm guard-reset-test
    git reset --hard -q HEAD^
    ;;
  commit_push)
    printf 'push\n' >> tracked.txt
    git add tracked.txt
    git -c user.name=Guard -c user.email=guard@example.invalid commit -qm guard-push-test
    git push -q origin HEAD
    ;;
  docs_md)
    mkdir -p docs
    printf '# allowed\n' > docs/x.md
    ;;
  docs_lua)
    mkdir -p docs
    printf 'return true\n' > docs/x.lua
    ;;
  rename_to_docs)
    mkdir -p docs
    git mv src/a.ts docs/a.md
    ;;
  review_write) printf 'review\n' > review.txt ;;
  codex_fail) fake_status=7 ;;
  review_write_fail)
    printf 'review\n' > review.txt
    fake_status=7
    ;;
  implement_write)
    mkdir -p src
    printf 'export {}\n' > src/new.ts
    ;;
  extra_session_id) echo 'session id: 11111111-1111-1111-1111-111111111111' ;;
  *) exit 91 ;;
esac

exit "$fake_status"
FAKE_CODEX
chmod +x "$fake_bin/codex"

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name Guard
  git -C "$repo" config user.email guard@example.invalid
  printf 'initial\n' > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm initial
}

run_launcher() {
  local name="$1"
  local persona="$2"
  local repo="$3"
  local action="$4"
  shift 4
  local state_dir="$test_root/state-$name"
  local capture_dir="$test_root/capture-$name"
  local output_path="$test_root/$name.out"
  local status

  set +e
  PATH="$fake_bin:$PATH" \
    GIT_AUTHOR_NAME=old GIT_AUTHOR_EMAIL=old@example.invalid \
    GIT_COMMITTER_NAME=old GIT_COMMITTER_EMAIL=old@example.invalid \
    CODEX_HOME="$empty_codex_home" \
    CODEX_AGENT_STATE_DIR="$state_dir" \
    CODEX_AGENT_FAKE_CAPTURE_DIR="$capture_dir" \
    CODEX_AGENT_FAKE_ACTION="$action" \
    "$launcher" "$persona" -C "$repo" "$@" "guard test" > "$output_path" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$test_root/$name.status"
}

assert_status() {
  local name="$1"
  local expected="$2"
  local actual
  actual="$(< "$test_root/$name.status")"
  [ "$actual" -eq "$expected" ] || fail "$name: status $actual, expected $expected; $(< "$test_root/$name.out")"
}

assert_output() {
  local name="$1"
  local pattern="$2"
  LC_ALL=C grep -Fq -- "$pattern" "$test_root/$name.out" || fail "$name: output does not contain: $pattern"
}

assert_changed() {
  local name="$1"
  local path="$2"
  local changed_file
  changed_file="$(find "$test_root/state-$name/runs" -name changed-files.txt -print -quit)"
  [ -n "$changed_file" ] || fail "$name: changed-files.txt not found"
  LC_ALL=C grep -Fxq -- "$path" "$changed_file" || fail "$name: changed path not found: $path"
}

assert_arg() {
  local name="$1"
  local expected="$2"
  LC_ALL=C grep -Fxq -- "$expected" "$test_root/capture-$name/argv.txt" \
    || fail "$name: argv does not contain argument: $expected"
}

assert_no_arg() {
  local name="$1"
  local unexpected="$2"
  if LC_ALL=C grep -Fxq -- "$unexpected" "$test_root/capture-$name/argv.txt"; then
    fail "$name: argv unexpectedly contains argument: $unexpected"
  fi
}

assert_arg_sequence() {
  local name="$1"
  local first="$2"
  local second="$3"
  awk -v first="$first" -v second="$second" '
    previous == first && $0 == second { found = 1 }
    { previous = $0 }
    END { exit found ? 0 : 1 }
  ' "$test_root/capture-$name/argv.txt" || fail "$name: argv sequence not found: $first $second"
}

repo="$test_root/argv"
init_repo "$repo"
for test_persona in minase makabe kashiwagi; do
  run_launcher "argv-$test_persona" "$test_persona" "$repo" none
done
assert_arg argv-minase '--dangerously-bypass-approvals-and-sandbox'
assert_arg argv-makabe '--dangerously-bypass-approvals-and-sandbox'
assert_arg argv-kashiwagi '--dangerously-bypass-approvals-and-sandbox'
assert_no_arg argv-kashiwagi '--sandbox'
pass 'persona sandbox flags are preserved in Codex argv'

for test_persona in minase makabe kashiwagi; do
  assert_arg_sequence "argv-$test_persona" '-c' 'model_reasoning_effort="high"'
done
pass 'default high reasoning effort is preserved for all personas'

for test_persona in minase makabe kashiwagi; do
  assert_arg_sequence "argv-$test_persona" '-c' 'mcp_servers.alpha.enabled=false'
  assert_arg_sequence "argv-$test_persona" '-c' 'mcp_servers.beta.enabled=false'
done
pass 'default MCP disable overrides are preserved for all personas'

run_launcher argv-mcp-enabled makabe "$repo" none --mcp
assert_no_arg argv-mcp-enabled 'mcp_servers.alpha.enabled=false'
assert_no_arg argv-mcp-enabled 'mcp_servers.beta.enabled=false'
pass '--mcp omits MCP disable overrides'

for test_persona in minase makabe kashiwagi; do
  name="argv-$test_persona"
  [ "$(< "$test_root/capture-$name/stdin-present.txt")" = yes ] || fail "$name: stdin is empty"
  LC_ALL=C grep -Fq -- 'guard test' "$test_root/capture-$name/stdin.txt" || fail "$name: prompt is absent from stdin"
  assert_no_arg "$name" 'guard test'
done
pass 'prompt is passed through stdin and does not appear in argv'

for test_persona in minase makabe kashiwagi; do
  name="argv-$test_persona"
  exported_run_dir="$(< "$test_root/capture-$name/run-dir.txt")"
  [ -n "$exported_run_dir" ] || fail "$name: CODEX_AGENT_RUN_DIR is not exported"
  [ -d "$exported_run_dir" ] || fail "$name: CODEX_AGENT_RUN_DIR is not a directory: $exported_run_dir"
  [ -f "$exported_run_dir/prompt.md" ] || fail "$name: prompt.md is not under CODEX_AGENT_RUN_DIR"
  [[ "$exported_run_dir" = "$test_root/state-$name/runs/$test_persona-"* ]] \
    || fail "$name: CODEX_AGENT_RUN_DIR is outside the state dir: $exported_run_dir"
done
pass 'CODEX_AGENT_RUN_DIR is exported to Codex and points at the run directory'

kashiwagi_run_dir="$(< "$test_root/capture-argv-kashiwagi/run-dir.txt")"
kashiwagi_stdin="$test_root/capture-argv-kashiwagi/stdin.txt"
LC_ALL=C grep -Fxq -- "plan の置き場: $kashiwagi_run_dir/plan.md" "$kashiwagi_stdin" \
  || fail 'argv-kashiwagi: plan placement line is absent from the prompt'
plan_line="$(LC_ALL=C grep -Fn -- 'plan の置き場: ' "$kashiwagi_stdin" | cut -d: -f1 | head -n 1)"
task_line="$(LC_ALL=C grep -Fxn -- '## 今回のタスク' "$kashiwagi_stdin" | cut -d: -f1 | head -n 1)"
[ -n "$task_line" ] || fail 'argv-kashiwagi: task heading is absent from the prompt'
[ "$plan_line" -lt "$task_line" ] || fail 'argv-kashiwagi: plan placement line is not before the task heading'
for test_persona in minase makabe; do
  if LC_ALL=C grep -Fq -- 'plan の置き場: ' "$test_root/capture-argv-$test_persona/stdin.txt"; then
    fail "argv-$test_persona: plan placement line must be Kashiwagi-only"
  fi
done
pass 'Kashiwagi prompt carries the plan placement line before the task heading; others do not'

resume_id='22222222-2222-2222-2222-222222222222'
run_launcher argv-resume makabe "$repo" none --resume "$resume_id"
assert_arg_sequence argv-resume resume "$resume_id"
pass '--resume builds the resume and session ID argv sequence'

repo="$test_root/dirty-tracked"
init_repo "$repo"
printf 'pre\n' >> "$repo/tracked.txt"
run_launcher dirty-tracked makabe "$repo" append_tracked
assert_status dirty-tracked 0
assert_changed dirty-tracked tracked.txt
pass 'pre-existing M content change is detected'

repo="$test_root/dirty-untracked"
init_repo "$repo"
printf 'pre\n' > "$repo/untracked.txt"
run_launcher dirty-untracked makabe "$repo" append_untracked
assert_status dirty-untracked 0
assert_changed dirty-untracked untracked.txt
pass 'pre-existing ?? content change is detected'

repo="$test_root/ignored"
init_repo "$repo"
printf '*.generated\n' > "$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -qm ignore-generated
run_launcher ignored minase "$repo" create_ignored
assert_status ignored 3
assert_changed ignored build.generated
assert_output ignored '変更禁止: build.generated'
pass 'ignored file creation is detected and rejected for Minase'

repo="$test_root/ignored-overflow"
init_repo "$repo"
printf '*.generated\n' > "$repo/.gitignore"
for ignored_index in $(seq 1 2001); do
  printf 'ignored\n' > "$repo/overflow-$ignored_index.generated"
done
git -C "$repo" add .gitignore
git -C "$repo" commit -qm ignore-overflow
run_launcher ignored-overflow minase "$repo" docs_lua
assert_status ignored-overflow 3
assert_output ignored-overflow 'ignored 一覧が 2000 件を超えたため収集を省略する'
assert_output ignored-overflow '変更禁止: docs/x.lua'
pass 'ignored overflow warns while tracked and untracked checks remain active'

repo="$test_root/symlink"
init_repo "$repo"
printf 'a\n' > "$repo/target-a"
printf 'b\n' > "$repo/target-b"
ln -s target-a "$repo/link.txt"
git -C "$repo" add target-a target-b link.txt
git -C "$repo" commit -qm symlink
ln -sfn target-dirty "$repo/link.txt"
run_launcher symlink minase "$repo" replace_symlink
assert_status symlink 3
assert_changed symlink link.txt
assert_output symlink '変更禁止: link.txt'
pass 'pre-dirty symlink target replacement is detected'

child_repo="$test_root/child-source"
init_repo "$child_repo"
mv "$child_repo/tracked.txt" "$child_repo/inside.txt"
printf '*.generated\n' > "$child_repo/.gitignore"
git -C "$child_repo" add -A
git -C "$child_repo" commit -qm inside
repo="$test_root/superproject"
init_repo "$repo"
git -C "$repo" -c protocol.file.allow=always submodule add -q "$child_repo" modules/child
git -C "$repo" commit -qm submodule
run_launcher submodule-ignored minase "$repo" create_ignored_submodule
assert_status submodule-ignored 3
assert_changed submodule-ignored modules/child/inside.generated
assert_output submodule-ignored '変更禁止: modules/child/inside.generated'
pass 'ignored file creation in a direct submodule is detected'

run_launcher submodule makabe "$repo" modify_submodule
assert_status submodule 0
assert_changed submodule modules/child/inside.txt
if changed_file="$(find "$test_root/state-submodule/runs" -name changed-files.txt -print -quit)" \
  && LC_ALL=C grep -Fxq -- modules/child "$changed_file"; then
  fail 'submodule: superproject submodule entry was double-counted'
fi
pass 'direct submodule content change is normalized and detected once'

repo="$test_root/commit"
init_repo "$repo"
run_launcher commit makabe "$repo" commit
assert_status commit 3
assert_output commit 'ref 変化を検出'
pass 'main commit is rejected through protected ref comparison'

repo="$test_root/commit-reset"
init_repo "$repo"
run_launcher commit-reset makabe "$repo" commit_reset
assert_status commit-reset 3
assert_output commit-reset '保護 branch reflog 変化を検出'
pass 'main commit followed by hard reset is rejected through protected branch reflog'

repo="$test_root/push"
remote_repo="$test_root/push-remote.git"
init_repo "$repo"
git init --bare -q "$remote_repo"
git -C "$repo" remote add origin "$remote_repo"
git -C "$repo" push -qu origin HEAD
run_launcher push makabe "$repo" commit_push
assert_status push 3
assert_output push 'ref 変化を検出'
pass 'commit and push are rejected through full ref comparison'

repo="$test_root/docs-md"
init_repo "$repo"
run_launcher docs-md minase "$repo" docs_md
assert_status docs-md 0
assert_changed docs-md docs/x.md
pass 'Minase may create docs/x.md'

repo="$test_root/docs-lua"
init_repo "$repo"
run_launcher docs-lua minase "$repo" docs_lua
assert_status docs-lua 3
assert_output docs-lua '変更禁止: docs/x.lua'
pass 'Minase may not create docs/x.lua'

repo="$test_root/rename"
init_repo "$repo"
mkdir -p "$repo/src"
printf 'export {}\n' > "$repo/src/a.ts"
git -C "$repo" add src/a.ts
git -C "$repo" commit -qm source
run_launcher rename minase "$repo" rename_to_docs
assert_status rename 3
assert_changed rename src/a.ts
assert_changed rename docs/a.md
assert_output rename '変更禁止: src/a.ts'
pass 'rename source and destination are both checked'

repo="$test_root/reviewer"
init_repo "$repo"
run_launcher reviewer kashiwagi "$repo" review_write
assert_status reviewer 0
assert_changed reviewer review.txt
pass 'Kashiwagi write is allowed'

repo="$test_root/implementer"
init_repo "$repo"
run_launcher implementer makabe "$repo" implement_write
assert_status implementer 0
assert_changed implementer src/new.ts
pass 'Makabe code write is allowed'

non_git="$test_root/non-git"
mkdir -p "$non_git"
run_launcher non-git-minase minase "$non_git" none
assert_status non-git-minase 2
assert_output non-git-minase 'git リポジトリ外では起動できない'
pass 'Minase non-git root fails closed'

run_launcher non-git-makabe makabe "$non_git" none
assert_status non-git-makabe 0
assert_output non-git-makabe '事後ガード無効で起動する'
assert_output non-git-makabe 'この実行では commit / push の検出も無効'
pass 'Makabe non-git root warns and runs'

repo="$test_root/tee-failure"
init_repo "$repo"
mkdir -p "$test_root/log-is-directory"
run_launcher tee-failure minase "$repo" review_write --log "$test_root/log-is-directory"
assert_status tee-failure 3
assert_output tee-failure '権限逸脱'
assert_output tee-failure 'session_id: 不明'
pass 'unreadable log does not bypass the post-run guard'

repo="$test_root/codex-failure"
init_repo "$repo"
run_launcher codex-failure makabe "$repo" codex_fail
assert_status codex-failure 7
pass 'Codex failure status is preserved when there is no violation'

repo="$test_root/violation-wins"
init_repo "$repo"
run_launcher violation-wins minase "$repo" review_write_fail
assert_status violation-wins 3
assert_output violation-wins '権限逸脱'
pass 'violation is displayed and exit 3 wins over Codex failure'

repo="$test_root/session-first"
init_repo "$repo"
run_launcher session-first makabe "$repo" extra_session_id
assert_status session-first 0
session_file="$(find "$test_root/state-session-first/runs" -name session_id -print -quit)"
[ -n "$session_file" ] || fail 'session-first: session_id file not found'
[ "$(< "$session_file")" = '00000000-0000-0000-0000-000000000000' ] \
  || fail "session-first: first session ID was not selected: $(< "$session_file")"
pass 'first session ID is selected when a later UUID appears in the log'

repo="$test_root/input-validation"
init_repo "$repo"
empty_task="$test_root/empty-task.md"
: > "$empty_task"
set +e
PATH="$fake_bin:$PATH" CODEX_HOME="$empty_codex_home" CODEX_AGENT_STATE_DIR="$test_root/state-empty-file" \
  "$launcher" makabe -C "$repo" -f "$empty_task" > "$test_root/empty-file.out" 2>&1
empty_file_status=$?
printf ' \n\t' | PATH="$fake_bin:$PATH" CODEX_HOME="$empty_codex_home" \
  CODEX_AGENT_STATE_DIR="$test_root/state-empty-stdin" \
  "$launcher" makabe -C "$repo" > "$test_root/empty-stdin.out" 2>&1
empty_stdin_status=$?
PATH="$fake_bin:$PATH" CODEX_HOME="$empty_codex_home" CODEX_AGENT_STATE_DIR="$test_root/state-empty-resume" \
  "$launcher" makabe -C "$repo" --resume '' 'task' > "$test_root/empty-resume.out" 2>&1
empty_resume_status=$?
set -e
[ "$empty_file_status" -eq 2 ] || fail "empty -f: status $empty_file_status, expected 2"
[ "$empty_stdin_status" -eq 2 ] || fail "empty stdin: status $empty_stdin_status, expected 2"
[ "$empty_resume_status" -eq 2 ] || fail "empty resume: status $empty_resume_status, expected 2"
LC_ALL=C grep -Fq 'タスク本文が空白のみ' "$test_root/empty-file.out" || fail 'empty -f was not rejected explicitly'
LC_ALL=C grep -Fq 'タスク本文が空白のみ' "$test_root/empty-stdin.out" || fail 'empty stdin was not rejected explicitly'
LC_ALL=C grep -Fq -- '--resume に空文字は指定できない' "$test_root/empty-resume.out" || fail 'empty resume was not rejected explicitly'
pass 'empty -f/stdin task and empty --resume are rejected with exit 2'

for test_persona in minase makabe kashiwagi; do
  case "$test_persona" in
    minase) role_name=水無瀬 ;;
    makabe) role_name=真壁 ;;
    kashiwagi) role_name=柏木 ;;
  esac
  expected="$(printf '%s\n' "$role_name" "$test_persona@ai.yumemism.dev" "$role_name" "$test_persona@ai.yumemism.dev")"
  [ "$(cat "$test_root/capture-argv-$test_persona/identity.txt")" = "$expected" ] || fail "identity mismatch: $test_persona"
done
pass 'all four Git identity variables override inherited values for every persona'

repo="$test_root/feature"
init_repo "$repo"
git -C "$repo" checkout -qb work
run_launcher feature-commit makabe "$repo" commit
assert_status feature-commit 0
assert_changed feature-commit tracked.txt
[ "$(git -C "$repo" log -1 --format='%an <%ae>|%cn <%ce>')" = '真壁 <makabe@ai.yumemism.dev>|真壁 <makabe@ai.yumemism.dev>' ] || fail 'commit identity differs'
pass 'current feature branch commit is allowed with role author and committer'
run_launcher feature-reset makabe "$repo" commit_reset
assert_status feature-reset 0
pass 'current feature branch commit and reset is allowed'

run_launcher minase-commit minase "$repo" commit
assert_status minase-commit 3
assert_changed minase-commit tracked.txt
assert_output minase-commit '変更禁止: tracked.txt'
pass 'Minase committed non-Markdown changes are detected even with a clean worktree'

run_launcher new-branch makabe "$repo" new_branch
assert_status new-branch 0
pass 'new local branch is allowed'
git -C "$repo" branch other
run_launcher other-branch makabe "$repo" other_branch
assert_status other-branch 3
assert_output other-branch 'refs/heads/other'
run_launcher delete-branch makabe "$repo" delete_branch
assert_status delete-branch 3
assert_output delete-branch 'refs/heads/other'
pass 'moving and deleting another local branch are rejected'
run_launcher new-tag makabe "$repo" new_tag
assert_status new-tag 3
assert_output new-tag 'refs/tags/forbidden'
pass 'new non-branch local ref is rejected'
run_launcher remote-create makabe "$repo" remote_create
assert_status remote-create 3
assert_output remote-create 'refs/remotes/origin/new'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
run_launcher remote-delete makabe "$repo" remote_delete
assert_status remote-delete 3
assert_output remote-delete 'refs/remotes/origin/main'
pass 'creating and deleting remote-tracking refs are rejected'

repo="$test_root/feature-push"
init_repo "$repo"
git -C "$repo" checkout -qb work
remote_repo="$test_root/feature-remote.git"
git init --bare -q "$remote_repo"
git -C "$repo" remote add origin "$remote_repo"
git -C "$repo" push -qu origin HEAD
run_launcher feature-push makabe "$repo" commit_push
assert_status feature-push 3
assert_output feature-push 'refs/remotes/origin/work'
pass 'feature branch push is detected through remote-tracking ref changes'

repo="$test_root/kashiwagi-guard"
init_repo "$repo"
run_launcher kashiwagi-off kashiwagi "$repo" commit
assert_status kashiwagi-off 0
run_launcher kashiwagi-on kashiwagi "$repo" commit --guard
assert_status kashiwagi-on 3
assert_output kashiwagi-on 'refs/heads/main'
run_launcher kashiwagi-write-guard kashiwagi "$repo" review_write --guard
assert_status kashiwagi-write-guard 0
assert_changed kashiwagi-write-guard review.txt
run_launcher explicit-off makabe "$repo" commit --no-guard
assert_status explicit-off 0
pass 'Kashiwagi guard defaults off, explicit guard checks refs and permits writes, --no-guard remains available'

repo="$test_root/master"
init_repo "$repo"
git -C "$repo" branch -m master
run_launcher master makabe "$repo" commit
assert_status master 3
assert_output master 'refs/heads/master'
pass 'master HEAD changes are rejected'

repo="$test_root/superproject"
run_launcher submodule-commit makabe "$repo" submodule_commit
assert_status submodule-commit 3
assert_output submodule-commit 'modules/child refs/heads/main'
pass 'protected branch changes in direct submodules are rejected'

run_launcher removed-option kashiwagi "$repo" none --notify-sock /unused
assert_status removed-option 2
assert_output removed-option '不明な option: --notify-sock'
pass 'removed --notify-sock is rejected explicitly'

# 日付を固定し、同じ秒・同じ state directory へ実際に 2 本を並行起動する。
cat > "$fake_bin/date" <<'DATE'
#!/usr/bin/env bash
printf '20260913-120000\n'
DATE
chmod +x "$fake_bin/date"
for slot in 1 2; do
  PATH="$fake_bin:$PATH" CODEX_HOME="$empty_codex_home" \
    CODEX_AGENT_STATE_DIR="$test_root/state-concurrent" \
    CODEX_AGENT_FAKE_CAPTURE_DIR="$test_root/capture-concurrent-$slot" \
    "$launcher" makabe -C "$repo" "parallel $slot" > "$test_root/concurrent-$slot.out" 2>&1 &
  if [ "$slot" -eq 1 ]; then first_pid=$!; else second_pid=$!; fi
done
wait "$first_pid" || fail 'first concurrent launcher failed'
wait "$second_pid" || fail 'second concurrent launcher failed'
mapfile -t concurrent_runs < <(find "$test_root/state-concurrent/runs" -mindepth 1 -maxdepth 1 -type d)
mapfile -t concurrent_logs < <(find "$test_root/state-concurrent/logs" -type f)
[ "${#concurrent_runs[@]}" -eq 2 ] || fail 'concurrent run directories collided'
[ "${#concurrent_logs[@]}" -eq 2 ] || fail 'concurrent log paths collided'
for slot in 1 2; do
  LC_ALL=C grep -Fxq "parallel $slot" "$test_root/capture-concurrent-$slot/stdin.txt" || fail 'concurrent prompts collided'
done
for run in "${concurrent_runs[@]}"; do
  [[ "${run##*/}" =~ ^makabe-20260913-120000-[0-9]+-[0-9]+$ ]] || fail 'run ID format differs'
  [ -f "$test_root/state-concurrent/logs/${run##*/}.log" ] || fail 'run log missing'
done
pass 'same-second concurrent launches have distinct run directories, logs and intact prompts'

printf '1..%d\n' "$pass_count"
