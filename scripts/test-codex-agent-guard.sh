#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
launcher="$script_dir/codex-agent.sh"
kimi_launcher="$script_dir/kimi-niekawa.sh"
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

# 柏木の巡ループ用: CODEX_AGENT_FAKE_VERDICT(既定 承認、カンマ区切りで巡ごと、none で書かない)を run_dir の verdict.md に書く。
fake_verdict="${CODEX_AGENT_FAKE_VERDICT:-承認}"
if [ -n "${CODEX_AGENT_RUN_DIR:-}" ] && [ "$fake_verdict" != none ]; then
  fake_count_path="$CODEX_AGENT_RUN_DIR/.fake-round-count"
  fake_round=$(( $(cat "$fake_count_path" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$fake_round" > "$fake_count_path"
  IFS=, read -r -a fake_verdicts <<< "$fake_verdict"
  fake_index=$((fake_round - 1))
  if [ "$fake_index" -ge "${#fake_verdicts[@]}" ]; then
    fake_index=$((${#fake_verdicts[@]} - 1))
  fi
  printf 'verdict: %s\n巡 %s の判定\n' "${fake_verdicts[$fake_index]}" "$fake_round" > "$CODEX_AGENT_RUN_DIR/verdict.md"
  printf 'findings 巡 %s\n' "$fake_round" >> "$CODEX_AGENT_RUN_DIR/findings.md"
  if [ -n "$capture_dir" ]; then
    cp "$capture_dir/stdin.txt" "$capture_dir/stdin-r$fake_round.txt"
    cp "$capture_dir/argv.txt" "$capture_dir/argv-r$fake_round.txt"
  fi
fi

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
  worktree_branch_commit)
    [ -n "${CODEX_AGENT_FAKE_WORKTREE_DIR:-}" ] || exit 92
    git -C "$CODEX_AGENT_FAKE_WORKTREE_DIR" -c user.name=Guard -c user.email=guard@example.invalid commit --allow-empty -qm worktree-test ;;

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

# rates codex は起動時に 1 回だけ叩かれる(裁定 #8)。実ネットワークを叩かないよう固定 JSON を返す fake に差し替える。
cat > "$fake_bin/rates" <<'FAKE_RATES'
#!/usr/bin/env bash
set -euo pipefail
if [ "${CODEX_AGENT_FAKE_RATES_FAIL:-0}" = 1 ]; then
  echo "fake rates failure" >&2
  exit 1
fi
printf '{"email":"guard@example.invalid","remaining":{"5h":null,"weekly":%s,"monthly":null}}\n' \
  "${CODEX_AGENT_FAKE_RATES_WEEKLY:-69}"
FAKE_RATES
chmod +x "$fake_bin/rates"

# kimi-niekawa.sh 用の fake kimi。stream-json を模した 3 行(system.version / assistant / session.resume_hint)を
# 返し、CODEX_AGENT_RUN_DIR の .fake-round-count で巡番号を数え、CODEX_AGENT_FAKE_VERDICT を verdict.md に書く
# (fake codex と同じ仕組み)。-p の実引数と --agent-file / -m / --output-format を capture_dir に記録する。
cat > "$fake_bin/kimi" <<'FAKE_KIMI'
#!/usr/bin/env bash
set -euo pipefail

prompt_arg=""
agent_file=""
model=""
output_format=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) prompt_arg="$2"; shift 2 ;;
    --agent-file) agent_file="$2"; shift 2 ;;
    -m) model="$2"; shift 2 ;;
    --output-format) output_format="$2"; shift 2 ;;
    *) shift ;;
  esac
done

fake_round=1
if [ -n "${CODEX_AGENT_RUN_DIR:-}" ]; then
  fake_count_path="$CODEX_AGENT_RUN_DIR/.fake-round-count"
  fake_round=$(( $(cat "$fake_count_path" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$fake_round" > "$fake_count_path"
fi

capture_dir="${CODEX_AGENT_FAKE_CAPTURE_DIR:-}"
if [ -n "$capture_dir" ]; then
  mkdir -p "$capture_dir"
  printf '%s\n' "$prompt_arg" > "$capture_dir/prompt-r$fake_round.txt"
  printf '%s\n' "$agent_file" > "$capture_dir/agent-file-r$fake_round.txt"
  printf '%s\n' "$model" > "$capture_dir/model-r$fake_round.txt"
  printf '%s\n' "$output_format" > "$capture_dir/output-format-r$fake_round.txt"
  printf '%s\n' "${CODEX_AGENT_RUN_DIR:-}" > "$capture_dir/run-dir.txt"
  printf '%s\n' "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" "$GIT_COMMITTER_NAME" "$GIT_COMMITTER_EMAIL" > "$capture_dir/identity.txt"
fi

fake_verdict="${CODEX_AGENT_FAKE_VERDICT:-承認}"
if [ -n "${CODEX_AGENT_RUN_DIR:-}" ] && [ "$fake_verdict" != none ]; then
  IFS=, read -r -a fake_verdicts <<< "$fake_verdict"
  fake_index=$((fake_round - 1))
  if [ "$fake_index" -ge "${#fake_verdicts[@]}" ]; then
    fake_index=$((${#fake_verdicts[@]} - 1))
  fi
  printf 'verdict: %s\n巡 %s の判定\n' "${fake_verdicts[$fake_index]}" "$fake_round" > "$CODEX_AGENT_RUN_DIR/verdict.md"
  printf 'findings 巡 %s\n' "$fake_round" >> "$CODEX_AGENT_RUN_DIR/findings.md"
fi

session_id="session_fake-r$fake_round"
printf '{"role":"meta","type":"system.version","version":"0.40.1-fake"}\n'
printf '{"role":"assistant","content":"fake response r%s"}\n' "$fake_round"
printf '{"role":"meta","type":"session.resume_hint","session_id":"%s","command":"kimi -r %s","content":"resume"}\n' \
  "$session_id" "$session_id"
exit "${CODEX_AGENT_FAKE_KIMI_STATUS:-0}"
FAKE_KIMI
chmod +x "$fake_bin/kimi"

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
    CODEX_AGENT_FAKE_VERDICT="${FAKE_VERDICT:-承認}" \
    CODEX_AGENT_FAKE_WORKTREE_DIR="${FAKE_WORKTREE_DIR:-}" \
    "$launcher" "$persona" -C "$repo" "$@" "guard test" > "$output_path" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$test_root/$name.status"
}

run_kimi_launcher() {
  local name="$1"
  local repo="$2"
  shift 2
  local state_dir="$test_root/state-$name"
  local capture_dir="$test_root/capture-$name"
  local output_path="$test_root/$name.out"
  local status

  set +e
  PATH="$fake_bin:$PATH" \
    GIT_AUTHOR_NAME=old GIT_AUTHOR_EMAIL=old@example.invalid \
    GIT_COMMITTER_NAME=old GIT_COMMITTER_EMAIL=old@example.invalid \
    CODEX_AGENT_STATE_DIR="$state_dir" \
    CODEX_AGENT_FAKE_CAPTURE_DIR="$capture_dir" \
    CODEX_AGENT_FAKE_VERDICT="${FAKE_VERDICT:-承認}" \
    "$kimi_launcher" -C "$repo" "$@" > "$output_path" 2>&1
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

for test_persona in minase kashiwagi; do
  assert_arg_sequence "argv-$test_persona" '-c' 'model_reasoning_effort="high"'
done
assert_arg_sequence argv-makabe '-c' 'model_reasoning_effort="max"'
pass 'default reasoning effort is high for minase / kashiwagi and max for makabe'

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
assert_output tee-failure 'session_id: 00000000-0000-0000-0000-000000000000'
pass 'unreadable log does not bypass the post-run guard and the session id survives via the run_dir log'

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

# ---- 同じリポの他 worktree が動かした branch は逸脱にしない(BRIEF-inbox-limits、並列 makabe の誤検知対策)
repo="$test_root/worktree-main"
init_repo "$repo"
git -C "$repo" checkout -qb work
git -C "$repo" worktree add -q "$test_root/worktree-sibling" -b sibling-work
FAKE_WORKTREE_DIR="$test_root/worktree-sibling" run_launcher worktree-other-branch makabe "$repo" worktree_branch_commit
assert_status worktree-other-branch 0
assert_output worktree-other-branch '他 worktree の作業 branch のため記録しない'
pass 'a branch moved in another worktree of the same repo is not recorded as a violation'

git -C "$repo" worktree add -q "$test_root/worktree-main-branch" main
FAKE_WORKTREE_DIR="$test_root/worktree-main-branch" run_launcher worktree-main-branch makabe "$repo" worktree_branch_commit
assert_status worktree-main-branch 3
assert_output worktree-main-branch 'ref 変化を検出: root refs/heads/main'
pass 'main moved in another worktree still counts as a violation'

repo="$test_root/superproject"
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


# ---- 柏木の巡ループ(1 巡 = 1 session、verdict.md でつなぐ)。柏木は既定 off なので --rounds を明示して起動する。
repo="$test_root/rounds"
init_repo "$repo"
FAKE_VERDICT='継続,継続,承認' run_launcher rounds-3 kashiwagi "$repo" none --rounds 12
assert_status rounds-3 0
assert_output rounds-3 '巡数: 3'
assert_output rounds-3 'verdict: 承認'
rounds_run_dir="$(< "$test_root/capture-rounds-3/run-dir.txt")"
for n in 1 2 3; do
  [ -s "$rounds_run_dir/rounds/r$n/verdict.md" ] || fail "rounds-3: rounds/r$n/verdict.md is absent"
  [ -s "$rounds_run_dir/rounds/r$n/prompt.md" ] || fail "rounds-3: rounds/r$n/prompt.md is absent"
done
# BRIEF-inbox-2(2026-09-20)以降、run_dir 直下の verdict.md は cp で残す(mv すると to-takano の
# verdict ガードと便の終端通知が run_dir/verdict.md を読めなくなる)。round 3(最終巡)の写しと一致することを確かめる。
[ -s "$rounds_run_dir/verdict.md" ] || fail 'rounds-3: run_dir 直下の verdict.md が消えている(終端通知に使う)'
diff -q "$rounds_run_dir/verdict.md" "$rounds_run_dir/rounds/r3/verdict.md" >/dev/null 2>&1 \
  || fail 'rounds-3: run_dir/verdict.md が最終巡(r3)の写しと一致しない'
LC_ALL=C grep -Fq -- '巡: 2 / 12' "$test_root/capture-rounds-3/stdin-r2.txt" || fail 'rounds-3: round 2 prompt lacks the round line'
LC_ALL=C grep -Fq -- '## 前巡までの checkpoint(この session は巡 2。' "$test_root/capture-rounds-3/stdin-r2.txt" || fail 'rounds-3: round 2 prompt lacks the checkpoint section'
LC_ALL=C grep -Fq -- 'findings 巡 1' "$test_root/capture-rounds-3/stdin-r2.txt" || fail 'rounds-3: round 2 prompt lacks findings from round 1'
LC_ALL=C grep -Fq -- '巡 1 の判定' "$test_root/capture-rounds-3/stdin-r2.txt" || fail 'rounds-3: round 2 prompt lacks the previous verdict'
if LC_ALL=C grep -Fq -- '## 前巡までの checkpoint(' "$test_root/capture-rounds-3/stdin-r1.txt"; then
  fail 'rounds-3: round 1 prompt unexpectedly carries a checkpoint section'
fi
LC_ALL=C grep -Fxq -- "$rounds_run_dir/rounds/r3/last-message.md" "$test_root/capture-rounds-3/argv-r3.txt" || fail 'rounds-3: round 3 argv lacks its own -o path'
LC_ALL=C grep -Fxq -- 'features.multi_agent_v2.default_wait_timeout_ms=1200000' "$test_root/capture-rounds-3/argv.txt" || fail 'rounds-3: wait timeout override is absent'
pass 'kashiwagi loops one session per round until verdict 承認, carrying checkpoint into later prompts'

FAKE_VERDICT='none' run_launcher rounds-missing kashiwagi "$repo" none --rounds 12
assert_status rounds-missing 4
assert_output rounds-missing 'verdict.md が無いか'
pass 'kashiwagi without verdict.md exits 4'

FAKE_VERDICT='継続' run_launcher kashiwagi-default-off kashiwagi "$repo" none
assert_status kashiwagi-default-off 0
assert_output kashiwagi-default-off '巡数: 1'
pass 'kashiwagi loop defaults off (no --rounds): a single session runs even when the fake verdict is 継続'

FAKE_VERDICT='継続' run_launcher rounds-cap kashiwagi "$repo" none --rounds 2
assert_status rounds-cap 5
assert_output rounds-cap '巡数: 2'
assert_output rounds-cap '巡数上限 2 に到達'
pass 'kashiwagi hitting --rounds exits 5'

FAKE_VERDICT='継続' run_launcher rounds-noloop kashiwagi "$repo" none --no-loop
assert_status rounds-noloop 0
assert_output rounds-noloop '巡数: 1'
pass 'kashiwagi --no-loop runs a single session regardless of verdict'

FAKE_VERDICT='エスカレーション' run_launcher rounds-escalate kashiwagi "$repo" none
assert_status rounds-escalate 0
assert_output rounds-escalate 'verdict: エスカレーション'
assert_output rounds-escalate '巡数: 1'
pass 'kashiwagi verdict エスカレーション ends the loop after one round'

assert_no_arg argv-makabe 'features.multi_agent_v2.default_wait_timeout_ms=1200000'
assert_no_arg argv-minase 'features.multi_agent_v2.default_wait_timeout_ms=1200000'
pass 'wait timeout override is kashiwagi-only'

# ---- persona 別の既定 model(発注書 14)
assert_arg_sequence argv-kashiwagi '-m' 'gpt-6-astra'
assert_arg_sequence argv-makabe '-m' 'gpt-6-luna'
assert_no_arg argv-minase '-m'
pass 'kashiwagi defaults to gpt-6-astra, makabe to gpt-6-luna, minase has no default model'

repo="$test_root/niekawa"
init_repo "$repo"
run_launcher argv-niekawa niekawa "$repo" none
assert_status argv-niekawa 0
assert_arg_sequence argv-niekawa '-m' 'gpt-6-sol'
assert_arg_sequence argv-niekawa '-c' 'model_reasoning_effort="high"'
assert_no_arg argv-niekawa 'features.multi_agent_v2.default_wait_timeout_ms=1200000'
[ "$(cat "$test_root/capture-argv-niekawa/identity.txt")" = "$(printf '%s\n' 贄川 niekawa@ai.yumemism.dev 贄川 niekawa@ai.yumemism.dev)" ] \
  || fail 'niekawa: git identity mismatch'
pass 'niekawa defaults to gpt-6-sol, high effort, no wait-timeout override, and 贄川 git identity'

run_launcher override-model niekawa "$repo" none --model gpt-custom
assert_arg_sequence override-model '-m' 'gpt-custom'
pass '--model overrides the persona default'

# niekawa の巡ループは既定で on(--rounds を付けなくても継続 verdict で次巡へ進む)
FAKE_VERDICT='継続,承認' run_launcher niekawa-rounds niekawa "$repo" none
assert_status niekawa-rounds 0
assert_output niekawa-rounds '巡数: 2'
assert_output niekawa-rounds 'verdict: 承認'
pass 'niekawa loops by default without --rounds, unlike kashiwagi'

FAKE_VERDICT='継続' run_launcher niekawa-noloop niekawa "$repo" none --no-loop
assert_status niekawa-noloop 0
assert_output niekawa-noloop '巡数: 1'
pass 'niekawa --no-loop runs a single session regardless of verdict'

FAKE_VERDICT='none' run_launcher niekawa-missing niekawa "$repo" none
assert_status niekawa-missing 4
assert_output niekawa-missing 'verdict.md が無いか'
pass 'niekawa without verdict.md exits 4 (loop is on by default)'

# ---- rates codex は起動時に 1 回、失敗しても続行する(裁定 #8)
run_launcher rates-ok makabe "$repo" none
assert_status rates-ok 0
rates_run_dir="$(< "$test_root/capture-rates-ok/run-dir.txt")"
[ -s "$rates_run_dir/rates.json" ] || fail 'rates-ok: rates.json was not written'
LC_ALL=C grep -Fq '"weekly":69' "$rates_run_dir/rates.json" || fail 'rates-ok: rates.json content mismatch'
pass 'rates codex is captured once at startup into <run_dir>/rates.json'

set +e
PATH="$fake_bin:$PATH" GIT_AUTHOR_NAME=old GIT_AUTHOR_EMAIL=old@example.invalid \
  GIT_COMMITTER_NAME=old GIT_COMMITTER_EMAIL=old@example.invalid \
  CODEX_HOME="$empty_codex_home" CODEX_AGENT_STATE_DIR="$test_root/state-rates-fail" \
  CODEX_AGENT_FAKE_RATES_FAIL=1 \
  "$launcher" makabe -C "$repo" 'guard test' > "$test_root/rates-fail.out" 2>&1
rates_fail_status=$?
set -e
[ "$rates_fail_status" -eq 0 ] || fail "rates-fail: status $rates_fail_status, expected 0"
LC_ALL=C grep -Fq 'rates codex の取得に失敗した(続行)' "$test_root/rates-fail.out" || fail 'rates-fail: warning missing'
rates_fail_run_dir="$(find "$test_root/state-rates-fail/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [ -f "$rates_fail_run_dir/rates.json" ]; then
  fail 'rates-fail: rates.json should not exist after a failed rates call'
fi
pass 'rates codex failure warns and the launcher still runs to completion'

# ---- footer に run_dir: <絶対パス> を 1 行足す(session_id: の直後、鷹野 09-18 追加指示)
run_launcher run-dir-footer makabe "$repo" none
assert_status run-dir-footer 0
run_dir_footer_dir="$(< "$test_root/capture-run-dir-footer/run-dir.txt")"
assert_output run-dir-footer "run_dir: $run_dir_footer_dir"
[[ "$run_dir_footer_dir" = /* ]] || fail 'run-dir-footer: run_dir is not an absolute path'
LC_ALL=C awk -v want="session_id: $(< "$test_root/state-run-dir-footer/runs/${run_dir_footer_dir##*/}/session_id")" '
  $0 == want { found_session = NR }
  /^run_dir: / { found_run_dir = NR }
  END { exit (found_session && found_run_dir && found_run_dir == found_session + 1) ? 0 : 1 }
' "$test_root/run-dir-footer.out" || fail 'run-dir-footer: run_dir line does not immediately follow session_id in the footer'
pass 'footer carries run_dir: <絶対パス> immediately after session_id:'

# ==== kimi-niekawa.sh(fake kimi) ====

repo="$test_root/kimi-rounds"
init_repo "$repo"
FAKE_VERDICT='継続,承認' run_kimi_launcher kimi-rounds-2 "$repo" 'kimi guard test'
assert_status kimi-rounds-2 0
assert_output kimi-rounds-2 '巡 1 session_id:'
assert_output kimi-rounds-2 '巡 2 session_id:'
assert_output kimi-rounds-2 'session_id: session_fake-r2'
assert_output kimi-rounds-2 '巡数: 2'
assert_output kimi-rounds-2 'verdict: 承認'
assert_output kimi-rounds-2 'session_ids: session_fake-r1 session_fake-r2'
assert_output kimi-rounds-2 '変更ファイル数:'
kimi_rounds_run_dir="$(< "$test_root/capture-kimi-rounds-2/run-dir.txt")"
assert_output kimi-rounds-2 "run_dir: $kimi_rounds_run_dir"
LC_ALL=C grep -Fq -- 'kimi-code/k3-256k' "$test_root/capture-kimi-rounds-2/model-r1.txt" || fail 'kimi-rounds-2: model is not kimi-code/k3-256k'
LC_ALL=C grep -Fq -- 'stream-json' "$test_root/capture-kimi-rounds-2/output-format-r1.txt" || fail 'kimi-rounds-2: output-format is not stream-json'
LC_ALL=C grep -Fxq -- "$kimi_rounds_run_dir/agent.md" "$test_root/capture-kimi-rounds-2/agent-file-r1.txt" || fail 'kimi-rounds-2: --agent-file does not point at run_dir/agent.md'
[ -s "$kimi_rounds_run_dir/rounds/r1/verdict.md" ] || fail 'kimi-rounds-2: rounds/r1/verdict.md is absent'
[ -s "$kimi_rounds_run_dir/rounds/r2/verdict.md" ] || fail 'kimi-rounds-2: rounds/r2/verdict.md is absent'
LC_ALL=C grep -Fq -- '巡: 2 / 12' "$test_root/capture-kimi-rounds-2/prompt-r2.txt" || fail 'kimi-rounds-2: round 2 prompt lacks the round line'
LC_ALL=C grep -Fq -- '## 前巡までの checkpoint(この session は巡 2。' "$test_root/capture-kimi-rounds-2/prompt-r2.txt" || fail 'kimi-rounds-2: round 2 prompt lacks the checkpoint section'
pass 'kimi-niekawa loops one session per round until verdict 承認, with the same footer words as codex-agent.sh'

FAKE_VERDICT='継続' run_kimi_launcher kimi-noloop "$repo" --no-loop 'kimi guard test'
assert_status kimi-noloop 0
assert_output kimi-noloop '巡数: 1'
pass 'kimi-niekawa --no-loop runs a single session regardless of verdict'

FAKE_VERDICT='none' run_kimi_launcher kimi-missing "$repo" 'kimi guard test'
assert_status kimi-missing 4
assert_output kimi-missing 'verdict.md が無いか'
pass 'kimi-niekawa without verdict.md exits 4'

FAKE_VERDICT='継続' run_kimi_launcher kimi-cap "$repo" --rounds 2 'kimi guard test'
assert_status kimi-cap 5
assert_output kimi-cap '巡数上限 2 に到達'
pass 'kimi-niekawa hitting --rounds exits 5'

run_kimi_launcher kimi-identity "$repo" 'kimi guard test'
assert_status kimi-identity 0
kimi_identity_run_dir="$(< "$test_root/capture-kimi-identity/run-dir.txt")"
[ -s "$kimi_identity_run_dir/rates.json" ] || fail 'kimi-identity: rates.json was not written'
LC_ALL=C grep -Fq '"weekly":69' "$kimi_identity_run_dir/rates.json" || fail 'kimi-identity: rates.json content mismatch'
[ "$(cat "$test_root/capture-kimi-identity/identity.txt")" = "$(printf '%s\n' 贄川 niekawa@ai.yumemism.dev 贄川 niekawa@ai.yumemism.dev)" ] \
  || fail 'kimi-identity: git identity mismatch'
pass 'kimi-niekawa captures rates kimi once into <run_dir>/rates.json and sets the 贄川 git identity'

# roles/niekawa.md 欠落時は警告して空のまま続行する(水無瀬が並行で書いている最中を想定)
missing_core="$test_root/missing-core"
mkdir -p "$missing_core/scripts/lib"
cp "$kimi_launcher" "$missing_core/scripts/kimi-niekawa.sh"
cp "$script_dir/lib/batch-inbox.sh" "$missing_core/scripts/lib/batch-inbox.sh"
cp "$script_dir/models.env" "$missing_core/scripts/models.env"
mkdir -p "$missing_core/roles" "$missing_core/codex" "$missing_core/kimi"
repo="$test_root/kimi-missing-role"
init_repo "$repo"
set +e
PATH="$fake_bin:$PATH" GIT_AUTHOR_NAME=old GIT_AUTHOR_EMAIL=old@example.invalid \
  GIT_COMMITTER_NAME=old GIT_COMMITTER_EMAIL=old@example.invalid \
  CODEX_AGENT_STATE_DIR="$test_root/state-kimi-missing-role" \
  CODEX_AGENT_FAKE_CAPTURE_DIR="$test_root/capture-kimi-missing-role" \
  "$missing_core/scripts/kimi-niekawa.sh" --no-loop -C "$repo" 'kimi guard test' > "$test_root/kimi-missing-role.out" 2>&1
kimi_missing_role_status=$?
set -e
[ "$kimi_missing_role_status" -eq 0 ] || fail "kimi-missing-role: status $kimi_missing_role_status, expected 0"
LC_ALL=C grep -Fq 'roles/niekawa.md が無い(空として続行)' "$test_root/kimi-missing-role.out" || fail 'kimi-missing-role: missing roles/niekawa.md warning absent'
LC_ALL=C grep -Fq 'kimi/niekawa.md が無い(空として続行)' "$test_root/kimi-missing-role.out" || fail 'kimi-missing-role: missing kimi/niekawa.md warning absent'
pass 'kimi-niekawa warns and continues when roles/niekawa.md or kimi/niekawa.md is absent'

# -p の argv は 128KB で落ちる(09-18 実測)ので、100KB を超えたら prompt をファイル経由にする
repo="$test_root/kimi-bigprompt"
init_repo "$repo"
big_task="$test_root/kimi-big-task.md"
head -c 110000 /dev/zero | tr '\0' 'x' > "$big_task"
run_kimi_launcher kimi-bigprompt "$repo" -f "$big_task"
assert_status kimi-bigprompt 0
kimi_bigprompt_run_dir="$(< "$test_root/capture-kimi-bigprompt/run-dir.txt")"
[ "$(wc -c < "$kimi_bigprompt_run_dir/rounds/r1/prompt.md")" -gt 102400 ] || fail 'kimi-bigprompt: rendered prompt is not over 100KB'
LC_ALL=C grep -Fxq -- "まず $kimi_bigprompt_run_dir/rounds/r1/prompt.md を読む" "$test_root/capture-kimi-bigprompt/prompt-r1.txt" \
  || fail 'kimi-bigprompt: -p was not replaced with the file-read line'
pass 'kimi-niekawa routes prompts over 100KB through a file and passes a short "read this file" -p line'

small_task="$test_root/kimi-small-task.md"
printf 'small task\n' > "$small_task"
run_kimi_launcher kimi-smallprompt "$repo" -f "$small_task"
assert_status kimi-smallprompt 0
LC_ALL=C grep -Fq -- 'small task' "$test_root/capture-kimi-smallprompt/prompt-r1.txt" || fail 'kimi-smallprompt: -p should carry the full prompt under 100KB'
pass 'kimi-niekawa passes the full prompt via -p when it is under 100KB'

printf '1..%d\n' "$pass_count"
