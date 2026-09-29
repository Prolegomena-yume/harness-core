#!/usr/bin/env bash
# tech の Stop hook: auto memory(.claude/memory)を Forgejo の main と、母艦・cloud の間で同じにする。
# 必ず exit 0・標準出力は空(Stop を止めない)。記録は ~/.cache/harness-memory-sync/sync.log。
#
# 前提と形(役員 人見 2026-09-30、BRIEF cloud-2。設計は docs/cloud-session.md の「memory の同期」):
#   - 触るのは .claude/memory/ だけ。作業木の index も HEAD も他のファイルも触らない ── 一時 index と
#     git の plumbing(hash-object / commit-tree)で「Forgejo の main の tree の memory だけを差し替えた commit」を
#     作り、main に直接 push する。tech の main は `unprotected_file_patterns: .claude/memory/**` があるので、
#     memory だけの commit なら保護を通る(memory 以外を含む commit は保護が弾く)。
#   - 母艦と cloud で同じ処理。違いは「取り先の URL」と「作業木のつなぎ方」だけ。
#   - 3 者比較: base(前回同期した commit の memory)/ mine(手元の memory)/ remote(Forgejo main の memory)を
#     ファイル単位で見る。片側だけ変えたファイルはそのまま採る。両側が違う中身に変えたファイルは衝突:
#       MEMORY.md(索引)は行の和集合(git merge-file --union)、それ以外は「同期を打った側が後勝ち」。
#       負けた側の版は Forgejo の履歴に残る。commit message に衝突した path を書く。
#   - 遅くしない: 前景では find(memory に新しいファイルがあるか)と stamp を見るだけ。あれば worker を
#     切り離して(母艦)/ timeout 付きで(cloud、VM が消えるので前景)走らせる。flock で同時 1 本、取れなければ黙って次回。
#
# 母艦の追加条件: 作業木(既定 ~/canonical/tech)が main で、HEAD が今回の commit の祖先で、差分が memory だけ。
#   満たさなければ push しない(作業木を壊さない)。満たすときだけ HEAD と index の memory を commit に進める。
#
# env(test 用の上書き): MEMSYNC_REPO MEMSYNC_URL MEMSYNC_STATE MEMSYNC_REMOTE_MODE(host|cloud)
#   MEMSYNC_FOREGROUND=1 MEMSYNC_FETCH_EVERY(秒、既定 600) MEMSYNC_NO_PUSH=1

set -u
MP=.claude/memory
state="${MEMSYNC_STATE:-$HOME/.cache/harness-memory-sync}"
mkdir -p "$state" 2>/dev/null
log() { echo "$(date -u +%FT%TZ) $*" >>"$state/sync.log" 2>/dev/null; }

mode="${MEMSYNC_REMOTE_MODE:-}"
[ -n "$mode" ] || { [ "${CLAUDE_CODE_REMOTE:-}" = true ] && mode=cloud || mode=host; }
if [ "$mode" = cloud ]; then
  repo="${MEMSYNC_REPO:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  url="${MEMSYNC_URL:-https://git.yumemism.com/company/tech.git}"
else
  repo="${MEMSYNC_REPO:-$HOME/canonical/tech}"
  url="${MEMSYNC_URL:-$(git -C "$repo" remote get-url origin 2>/dev/null)}"
fi
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gas="$core/scripts/git-as"
memdir="$repo/$MP"
G() { git -C "$repo" "$@"; }

worker() {
  exec 9>"$state/lock"; flock -n 9 || { log "skip: another sync running"; return 0; }
  [ -d "$memdir" ] && [ -n "$url" ] && G rev-parse --git-dir >/dev/null 2>&1 || { log "skip: no repo/memdir/url"; return 0; }
  local t0; t0=$(date +%s)
  if [ "$mode" = host ]; then
    [ "$(G symbolic-ref -q --short HEAD)" = main ] || { log "skip: host tree not on main"; return 0; }
  fi
  timeout 30 git -C "$repo" fetch --quiet "$url" main 2>>"$state/sync.log" || { log "skip: fetch failed"; return 0; }
  local R; R="$(G rev-parse -q --verify 'FETCH_HEAD^{commit}')" || { log "skip: no FETCH_HEAD"; return 0; }
  local Bc; Bc="$(G rev-parse -q --verify refs/memory-sync/base^{commit} 2>/dev/null || G rev-parse -q --verify HEAD^{commit})"

  declare -A A B Rm
  local m ty h p
  # base / remote: commit の .claude/memory 以下の blob
  while IFS=$' \t' read -r m ty h p; do [ "$ty" = blob ] && B["${p#$MP/}"]="$h"; done < <(G ls-tree -r "$Bc" -- "$MP/" 2>/dev/null)
  while IFS=$' \t' read -r m ty h p; do [ "$ty" = blob ] && Rm["${p#$MP/}"]="$h"; done < <(G ls-tree -r "$R" -- "$MP/" 2>/dev/null)
  # mine: 手元のファイル(隠しファイルと非通常ファイルは除く)
  local files=() f
  while IFS= read -r -d '' f; do files+=("$f"); done < <(cd "$memdir" && find . -type f ! -name '.*' ! -path '*/.*' -print0 | sed -z 's|^\./||')
  if [ "${#files[@]}" -gt 0 ]; then
    local hashes; mapfile -t hashes < <(cd "$memdir" && printf "$memdir/%s\n" "${files[@]}" | git -C "$memdir" hash-object -w --stdin-paths 2>/dev/null)
    [ "${#hashes[@]}" = "${#files[@]}" ] || { log "skip: hash-object count mismatch"; return 0; }
    local i; for i in "${!files[@]}"; do A["${files[$i]}"]="${hashes[$i]}"; done
  fi
  # 手元の memory が空なのに base には有る ── 消えたのではなく取り違えを疑う(全消しを push しない)
  if [ "${#files[@]}" = 0 ] && [ "${#B[@]}" -gt 0 ]; then log "skip: memory dir empty but base has ${#B[@]} files"; return 0; fi

  # ファイル単位の 3 者比較
  declare -A Res seen; local conflicts=() changed_local=() changed_remote=() k a b r
  for k in "${!A[@]}" "${!B[@]}" "${!Rm[@]}"; do
    [ -n "${seen[$k]+x}" ] && continue; seen[$k]=1
    a="${A[$k]:-}"; b="${B[$k]:-}"; r="${Rm[$k]:-}"
    if [ "$a" = "$r" ]; then Res[$k]="$a"
    elif [ "$a" = "$b" ]; then Res[$k]="$r"
    elif [ "$r" = "$b" ]; then Res[$k]="$a"
    else
      conflicts+=("$k")
      if [ "$k" = MEMORY.md ] && [ -n "$a" ] && [ -n "$r" ]; then
        local tb ta tr; tb="$(mktemp)"; ta="$(mktemp)"; tr="$(mktemp)"
        [ -n "$b" ] && G cat-file blob "$b" >"$tb"; G cat-file blob "$a" >"$ta"; G cat-file blob "$r" >"$tr"
        git merge-file -p --union "$ta" "$tb" "$tr" >"$ta.out" 2>/dev/null
        Res[$k]="$(G hash-object -w "$ta.out")"; rm -f "$tb" "$ta" "$tr" "$ta.out"
      else Res[$k]="$a"; fi   # 後勝ち(同期を打った側)。空(=手元で削除)なら削除
    fi
    [ "${Res[$k]}" != "$a" ] && changed_local+=("$k")
    [ "${Res[$k]}" != "$r" ] && changed_remote+=("$k")
  done

  # 1) Forgejo 側へ: remote から memory だけ差し替えた commit
  local N="$R"
  if [ "${#changed_remote[@]}" -gt 0 ]; then
    local idx; idx="$(mktemp -u "$state/idx.XXXXXX")"
    GIT_INDEX_FILE="$idx" G read-tree "$R" || { log "skip: read-tree"; return 0; }
    for k in "${changed_remote[@]}"; do
      if [ -n "${Res[$k]}" ]; then GIT_INDEX_FILE="$idx" G update-index --add --cacheinfo "100644,${Res[$k]},$MP/$k"
      else GIT_INDEX_FILE="$idx" G update-index --force-remove -- "$MP/$k"; fi
    done
    local tree msg; tree="$(GIT_INDEX_FILE="$idx" G write-tree)"; rm -f "$idx"
    msg="memory: $mode から ${#changed_remote[@]} 件(${changed_remote[*]:0:5}$([ ${#changed_remote[@]} -gt 5 ] && echo ' ほか'))"
    [ "${#conflicts[@]}" -gt 0 ] && msg="$msg
衝突(${conflicts[*]}): MEMORY.md は行の和集合、他は後勝ち"
    N="$(G rev-parse "$tree^{tree}" >/dev/null && printf '%s\n' "$msg" | "$gas" takano -C "$repo" commit-tree "$tree" -p "$R")" || { log "skip: commit-tree"; return 0; }
    if [ "$mode" = host ]; then
      # 母艦: 作業木を進められるときだけ push する
      G merge-base --is-ancestor HEAD "$N" || { log "skip: HEAD is not an ancestor (unpushed or diverged commits on main); no push"; return 0; }
      if [ -n "$(G diff --name-only HEAD "$N" | grep -v "^$MP/")" ]; then log "skip: HEAD..new has non-memory paths (pull first); no push"; return 0; fi
    fi
    if [ "${MEMSYNC_NO_PUSH:-}" = 1 ]; then log "dry: would push $N"; return 0; fi
    timeout 30 git -C "$repo" push --quiet "$url" "$N:refs/heads/main" 2>>"$state/sync.log" \
      || { log "push rejected/failed (nothing changed locally): ${changed_remote[*]}"; return 0; }
    log "pushed $N: ${changed_remote[*]} (conflicts: ${conflicts[*]:-none})"
  fi

  # 2) 手元へ: remote 側だけが変えたファイルを書く
  for k in "${changed_local[@]}"; do
    if [ -n "${Res[$k]}" ]; then mkdir -p "$(dirname "$memdir/$k")"; G cat-file blob "${Res[$k]}" >"$memdir/$k.memsync.$$" && mv -f "$memdir/$k.memsync.$$" "$memdir/$k"
    else rm -f "$memdir/$k"; fi
  done
  G update-ref refs/memory-sync/base "$N"

  # 3) 母艦: HEAD と index の memory を N に進める(memory 以外の index 項目は触らない)
  if [ "$mode" = host ] && [ "$N" != "$(G rev-parse HEAD)" ]; then
    if G reset -q "$N" -- "$MP" 2>/dev/null; then
      G update-ref -m "memory-sync" refs/heads/main "$N" "$(G rev-parse HEAD)" 2>/dev/null \
        && log "host HEAD -> $N" || log "host HEAD not advanced (moved meanwhile)"
    else log "host index locked: HEAD not advanced (next time)"; fi
  fi
  log "done in $(( $(date +%s) - t0 ))s local:${#changed_local[@]} remote:${#changed_remote[@]}"
}

# ---- 前景: 安いかどうかだけ見る ----
cat >/dev/null 2>&1 || true
stamp="$state/last-run"; fstamp="$state/last-fetch"
every="${MEMSYNC_FETCH_EVERY:-600}"
need=0
[ -d "$memdir" ] || exit 0
[ ! -e "$stamp" ] && need=1
[ -e "$stamp" ] && [ -n "$(find "$memdir" -type f -newer "$stamp" -print -quit 2>/dev/null)" ] && need=1
[ -e "$fstamp" ] && [ -z "$(find "$fstamp" -mmin +$((every/60)) -print 2>/dev/null)" ] || need=1
[ "$need" = 1 ] || exit 0

run() { worker; touch "$stamp" "$fstamp"; }
if [ "$mode" = cloud ] || [ "${MEMSYNC_FOREGROUND:-}" = 1 ]; then
  ( run ) 2>>"$state/sync.log" >/dev/null || true
else
  ( run ) </dev/null >/dev/null 2>>"$state/sync.log" &
  disown 2>/dev/null || true
fi
exit 0
