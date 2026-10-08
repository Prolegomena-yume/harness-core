#!/usr/bin/env bash
# scripts/hooks/git-commit-guard.sh の表テスト。
# hook に {"tool_name":"Bash","tool_input":{"command":"…"}} を stdin で渡し、exit code
# (2=block / 0=通し)を確かめる。JSON は jq で組む(クォートを手で埋めない)。
# 事故の形(素の `git merge --no-ff` が pax 名義の merge commit を作った、2026-10-09)を含む。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$script_dir/hooks/git-commit-guard.sh"

command -v jq >/dev/null 2>&1 || { echo "jq が要る" >&2; exit 1; }
[ -f "$hook" ] || { echo "hook not found: $hook" >&2; exit 1; }

total=0
bad=0

run_json() { # <json> -> hook の exit code
  local rc=0
  printf '%s' "$1" | bash "$hook" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

check() { # <block|pass> <command>
  local want="$1" cmd="$2" want_rc got json
  case "$want" in block) want_rc=2 ;; pass) want_rc=0 ;; *) echo "bad want: $want" >&2; exit 1 ;; esac
  json="$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  got="$(run_json "$json")"
  total=$((total + 1))
  if [ "$got" = "$want_rc" ]; then
    printf '○ %-5s %s\n' "$want" "${cmd//$'\n'/ ⏎ }"
  else
    bad=$((bad + 1))
    printf '× %-5s %s   (exit %s, 期待 %s)\n' "$want" "${cmd//$'\n'/ ⏎ }" "$got" "$want_rc"
  fi
}

check_json() { # <block|pass> <label> <json>
  local want="$1" label="$2" json="$3" want_rc got
  [ "$want" = block ] && want_rc=2 || want_rc=0
  got="$(run_json "$json")"
  total=$((total + 1))
  if [ "$got" = "$want_rc" ]; then
    printf '○ %-5s %s\n' "$want" "$label"
  else
    bad=$((bad + 1))
    printf '× %-5s %s   (exit %s, 期待 %s)\n' "$want" "$label" "$got" "$want_rc"
  fi
}

# ---- block -----------------------------------------------------------------
check block 'git commit -m x'
check block 'git merge -q --no-ff feat -m "m"'
check block 'git merge feat'
check block 'git merge --continue'
check block 'git pull'
check block 'git pull --rebase'
check block 'git pull -r'
check block 'git pull --no-ff'
check block 'git revert HEAD'
check block 'git revert --continue'
check block 'git cherry-pick abc'
check block 'git cherry-pick --continue'
check block 'git cherry-pick --skip'
check block 'git rebase -i HEAD~3'
check block 'git rebase --continue'
check block 'git rebase --skip'
check block 'git rebase main'
check block 'git am x.patch'
check block 'git am --continue'
check block 'git commit-tree T -p P -m x'
check block 'git tag -a v1 -m x'
check block 'git tag -m x v1'
check block 'git tag -am x v1'
check block 'git tag -sm x v1'
check block 'git tag -s v1'
check block 'git tag -u KEY v1'
check block 'git tag -mfoo v1'
check block 'git tag -F msg.txt v1'
check block 'git tag --annotate v1'
check block 'git tag --sign v1'
check block 'git tag --local-user=KEY v1'
check block 'git tag --message=foo v1'
check block 'git tag --file=msg.txt v1'
check block 'git tag v1 -m x'
check block 'git -C /x -c a=b merge feat'
check block 'cd /x && git merge feat'
check block '(cd /x && git commit -m y)'
check block '/usr/bin/git commit -m x'
check block 'env FOO=1 git merge feat'
check block 'git commit -m "a; b"'
check block 'git commit -m "a | b && c"'
check block 'git -c user.name=鷹野 commit -m x'
check block 'echo ok; git pull'
check block 'FOO=1 git merge feat'
check block 'sudo -u bob git commit -m x'
check block 'nohup git pull &'
check block 'git status && git merge feat'
check block 'git status | git commit -F -'
check block 'git merge --no-ff feat; git push'
check block $'echo ok\ngit merge feat'
check block 'echo $(git commit -m x)'
check block 'echo "$(git merge feat)"'
check block 'echo `git pull`'
check block 'bash -c "git merge feat"'
check block "sh -c 'cd x && git commit -m y'"
check block 'git commit -m "unterminated'
check block $'cat <<EOF\nfoo\nEOF\ngit merge feat'
check block 'git merge -m "--abort" feat'
check block 'git -C /x merge feat 2>&1'
check block 'git merge feat > /dev/null'
check block $'git-as 鷹野 status\ngit commit -m x'

# ---- 通し ------------------------------------------------------------------
check pass 'git-as 大橋 merge -q --no-ff feat -m "m"'
check pass 'git-as 鷹野 commit -m "a; b"'
check pass '~/bin/git-as 鷹野 pull'
check pass '$HOME/bin/git-as 鷹野 commit -m x'
check pass 'git pull --ff-only'
check pass 'git pull --ff-only origin main'
check pass 'git merge --ff-only origin/main'
check pass 'git merge --abort'
check pass 'git merge --quit'
check pass 'git merge --no-commit feat'
check pass 'git merge --squash feat'
check pass 'git rebase --abort'
check pass 'git rebase --quit'
check pass 'git rebase --show-current-patch'
check pass 'git rebase --edit-todo'
check pass 'git cherry-pick --abort'
check pass 'git cherry-pick --quit'
check pass 'git cherry-pick -n abc'
check pass 'git revert --abort'
check pass 'git revert --no-commit HEAD'
check pass 'git revert -n HEAD'
check pass 'git am --abort'
check pass 'git am --show-current-patch'
check pass 'git tag v1'
check pass 'git tag'
check pass 'git tag -l'
check pass 'git tag -l "v*"'
check pass 'git tag --list'
check pass 'git tag -d v1'
check pass 'git tag -v v1'
check pass 'git tag -l --sort=-creatordate'
check pass 'git log --grep=commit'
check pass 'git log --grep commit --oneline'
check pass 'git status'
check pass 'git fetch origin'
check pass 'git diff --stat'
check pass 'git push origin HEAD'
check pass 'git -C /x log -1'
check pass 'git merge-base main feat'
check pass 'git help commit'
check pass 'echo "git commit"'
check pass 'echo "git commit -m x; git merge feat"'
check pass "echo 'git merge --no-ff feat'"
check pass 'grep -rn "git merge" docs/'
check pass 'git status # git commit'
check pass 'git-as 鷹野 commit -m "$(git log -1 --format=%s)"'
check pass $'git-as 鷹野 commit -F - <<\'EOF\'\nfix\n\ngit merge --no-ff feat で入れた\nEOF'
check pass $'git-as 鷹野 commit -m "$(cat <<\'EOF\'\nfix\n\ngit merge --no-ff feat で入れた\nEOF\n)"'
check pass $'git-as 鷹野 commit -F - <<EOF\ngit commit -m x\nEOF'
check pass $'git-as 鷹野 commit -F - <<"EOF"\ngit pull\nEOF'
check pass $'git-as 鷹野 commit -F - <<-EOF\n\tgit merge feat\n\tEOF'
check pass $'cat <<\'EOF\' | git-as 鷹野 commit -F -\ngit merge feat\nEOF'
check pass $'git-as 鷹野 commit -F - <<\'EOF\'\ngit merge feat\nEOF\ngit status'
check pass 'git status 2>&1 | head'
check pass 'ls && echo done'
check pass 'bash -c "git status"'
check pass 'true'
check_json pass 'jq の空入力' ''
check_json pass 'tool_name が Read' '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
check_json pass 'tool_name が Bash 以外で commit を含む' "$(jq -n '{tool_name:"Edit",tool_input:{command:"git commit -m x"}}')"
check_json pass 'command が空' '{"tool_name":"Bash","tool_input":{"command":""}}'
check_json pass 'command が無い' '{"tool_name":"Bash","tool_input":{}}'

# stderr の文面(列挙・git-as・例・出典・該当セグメント)
err="$(jq -n --arg c 'git merge -q --no-ff feat -m "m"' '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$hook" 2>&1 >/dev/null || true)"
for needle in 'cherry-pick' 'git-as <役>' 'git-as 大橋 merge --no-ff <branch>' '役員 人見 2026-09-25' '2026-10-09 大橋[PJM]' '該当セグメント: git merge -q --no-ff feat'; do
  total=$((total + 1))
  if printf '%s' "$err" | grep -qF -- "$needle"; then
    printf '○ msg   %s\n' "$needle"
  else
    bad=$((bad + 1))
    printf '× msg   %s が stderr に無い\n' "$needle"
  fi
done

echo
echo "git-commit-guard: $((total - bad))/$total ○, $bad ×"
[ "$bad" -eq 0 ]
