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
# cloud の追加(役員 人見 2026-10-01「A で」、BRIEF cloud-8):
#   - 対象に _sessions/**(締めのサマリ)を足す。tech の main の unprotected_file_patterns は `.claude/memory/**;_sessions/**`。
#     母艦の対象は今までどおり memory だけ(サマリは鷹野が push する)。混在の commit は作らない(対象の path しか載せない)
#   - _sessions は足すだけ: 手元に無いファイルの削除は Forgejo へ流さず、同じ path を両側が違う中身で作った(並行セッションの
#     連番の衝突)ときは **どちらも上書きせず**(手元のサマリも消さない)、push しないで記録に conflict を残す(本物の未保存を隠さない)
#   - Forgejo への push が済んだ後、Anthropic が VM に入れる Stop の git 検査(~/.claude/stop-hook-git-check.sh)の要求に応える
#     (branch_push_cloud): 差分・未追跡・未 push の commit が全部対象の path のときだけ、session の branch に git-as 鷹野で commit し、
#     `git push origin HEAD:<branch>`(force しない)。対象外が 1 つでもあれば何もせず、警告も残す。検査は消さない・上書きしない
#
# 母艦の追加条件: 作業木(既定 ~/canonical/tech)が main で、HEAD が今回の commit の祖先で、差分が memory だけ。
#   満たさなければ push しない(作業木を壊さない)。満たすときだけ HEAD と index の memory を commit に進める。
#
# env: MEMSYNC_NO_BRANCH=1(cloud-bootstrap の起動時の取り込みが付ける。session の branch に commit・push しない)
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
sessdir="$repo/_sessions"
G() { git -C "$repo" "$@"; }
# 対象の root: 母艦は memory だけ、cloud は memory と _sessions
roots=("$MP"); [ "$mode" = cloud ] && roots+=(_sessions)
disp() { case "$1" in "$MP"/*) printf '%s' "${1#$MP/}" ;; *) printf '%s' "$1" ;; esac; }   # 記録・message 用(memory は今までの短い形)

# cloud: Forgejo の main への push が済んだ後、Anthropic が VM に入れる Stop の git 検査(~/.claude/stop-hook-git-check.sh)の要求
# 「commit して origin の branch に push せよ」にそのまま応える(役員 人見・鷹野の裁定 2026-10-01、cloud-9)。検査が exit 2 で止める条件は
# 未 commit の差分・未追跡ファイル・origin/<branch>(無ければ origin/HEAD)に対する未 push の commit。
#   - 差分・未追跡・未 push の commit が全部「対象の path(.claude/memory/**・_sessions/**)」のときだけ、その path を session の branch に
#     git-as 鷹野で commit し(message は Forgejo への commit と同じ形)、`git push origin HEAD:<branch>` する。対象外の path が 1 つでも
#     あれば何もしない(本物の作業。警告もそのまま残す)。force はしない。non-FF・commit 失敗(署名など)・push 失敗は記録して止める
#   - GitHub の session の branch への push は検査のための副産物で、正典は Forgejo の main。GitHub に PR は立てない
branch_push_cloud() {
  local br up mb p k n files=() shown=() kind=memory msg
  G remote get-url origin >/dev/null 2>&1 || { log "branch: no origin remote (skip)"; return 0; }
  br="$(G symbolic-ref -q --short HEAD)" || { log "branch: detached HEAD (skip)"; return 0; }
  case "$br" in main|master) log "branch: on $br (skip; never push a mirror's main from here)"; return 0 ;; esac
  allowed() { case "$1" in "$MP"/*|_sessions/*) return 0 ;; esac; return 1; }
  up="refs/remotes/origin/$br"
  G rev-parse -q --verify "$up^{commit}" >/dev/null 2>&1 || { up=refs/remotes/origin/HEAD; G rev-parse -q --verify "$up^{commit}" >/dev/null 2>&1 || up=refs/remotes/origin/main; }
  G rev-parse -q --verify "$up^{commit}" >/dev/null 2>&1 || { log "branch: no origin tracking ref to compare with (skip)"; return 0; }
  mb="$(G merge-base "$up" HEAD 2>/dev/null)" || { log "branch: no merge-base with $up (skip)"; return 0; }
  # (1) push していない commit が対象の path だけか
  while IFS= read -r -d '' p; do
    allowed "$p" || { log "branch: unpushed commit touches $p (real work; nothing done)"; return 0; }
  done < <(G diff -z --name-only "$mb" HEAD)
  # (2) commit していない差分・未追跡が対象の path だけか
  while IFS= read -r -d '' p; do
    allowed "$p" || { log "branch: uncommitted/untracked $p (real work; nothing done)"; return 0; }
    files+=("$p")
  done < <({ G diff -z --name-only HEAD; G diff -z --cached --name-only; G ls-files -z --others --exclude-standard; } 2>/dev/null)
  if [ "${#files[@]}" -gt 0 ]; then
    n="${#files[@]}"
    for k in "${files[@]}"; do case "$k" in _sessions/*) kind=sessions ;; esac; shown+=("$(disp "$k")"); done
    msg="$kind: $mode から $n 件(${shown[*]:0:5}$([ "$n" -gt 5 ] && echo ' ほか'))"
    G add -A -- "${files[@]}" 2>>"$state/sync.log" || { log "branch: git add failed (nothing committed)"; return 0; }
    if ! "$gas" takano -C "$repo" commit -q -m "$msg" 2>>"$state/sync.log"; then
      G reset -q -- "${files[@]}" 2>/dev/null; log "branch: commit failed (signing? hook?); left as is"; return 0
    fi
    log "branch: committed $n file(s) on $br: ${shown[*]:0:5}"
  fi
  # (3) origin の branch へ(無ければ作る)。追いつく commit が無ければ何もしない
  [ -n "$(G rev-list -n1 "$up..HEAD" 2>/dev/null)" ] || return 0
  if timeout 30 git -C "$repo" push --quiet origin "HEAD:refs/heads/$br" 2>>"$state/sync.log"; then
    log "branch: pushed HEAD $(G rev-parse --short HEAD) to origin/$br (side effect for the Stop check; Forgejo main is the canon)"
  else
    log "branch: push to origin/$br failed (non-FF or network; not forced; committed locally)"
  fi
}


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
  local m ty h p r
  # base / remote: commit の対象 root 以下の blob(key は repo からの相対 path)
  for r in "${roots[@]}"; do
    while IFS=$' \t' read -r m ty h p; do [ "$ty" = blob ] && B["$p"]="$h"; done < <(G ls-tree -r "$Bc" -- "$r/" 2>/dev/null)
    while IFS=$' \t' read -r m ty h p; do [ "$ty" = blob ] && Rm["$p"]="$h"; done < <(G ls-tree -r "$R" -- "$r/" 2>/dev/null)
  done
  # mine: 手元のファイル(隠しファイルと非通常ファイルは除く)
  local files=() f nmem=0 rd
  for r in "${roots[@]}"; do
    rd="$repo/$r"; [ -d "$rd" ] || continue
    local rf=()
    while IFS= read -r -d '' f; do rf+=("$f"); done < <(cd "$rd" && find . -type f ! -name '.*' ! -path '*/.*' -print0 | sed -z 's|^\./||')
    if [ "${#rf[@]}" -gt 0 ]; then
      local hashes; mapfile -t hashes < <(cd "$rd" && printf "$rd/%s\n" "${rf[@]}" | git -C "$rd" hash-object -w --stdin-paths 2>/dev/null)
      [ "${#hashes[@]}" = "${#rf[@]}" ] || { log "skip: hash-object count mismatch"; return 0; }
      local i; for i in "${!rf[@]}"; do A["$r/${rf[$i]}"]="${hashes[$i]}"; done
    fi
    [ "$r" = "$MP" ] && nmem="${#rf[@]}"
  done
  # 手元の memory が空なのに base には有る ── 消えたのではなく取り違えを疑う(全消しを push しない)
  local nbm=0; for p in "${!B[@]}"; do case "$p" in "$MP"/*) nbm=$((nbm+1)) ;; esac; done
  if [ "$nmem" = 0 ] && [ "$nbm" -gt 0 ]; then log "skip: memory dir empty but base has $nbm files"; return 0; fi

  # ファイル単位の 3 者比較
  declare -A Res seen; local conflicts=() changed_local=() changed_remote=() k a b r
  for k in "${!A[@]}" "${!B[@]}" "${!Rm[@]}"; do
    [ -n "${seen[$k]+x}" ] && continue; seen[$k]=1
    a="${A[$k]:-}"; b="${B[$k]:-}"; r="${Rm[$k]:-}"
    case "$k" in
      _sessions/*)
        # 足すだけ。手元に無い(= base か remote にだけ有る)ファイルの削除は流さない。両側が違う中身なら、どちらも上書きしない
        if [ -z "$a" ] && [ -n "$b" ]; then continue; fi
        if [ -n "$r" ] && [ "$a" != "$r" ] && [ "$r" != "$b" ] && [ "$a" != "$b" ]; then
          log "conflict: $k exists on Forgejo with different content; not pushed, local file kept (renumber and retry)"; continue
        fi ;;
    esac
    if [ "$a" = "$r" ]; then Res[$k]="$a"
    elif [ "$a" = "$b" ]; then Res[$k]="$r"
    elif [ "$r" = "$b" ]; then Res[$k]="$a"
    else
      conflicts+=("$(disp "$k")")
      if [ "$k" = "$MP/MEMORY.md" ] && [ -n "$a" ] && [ -n "$r" ]; then
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
      if [ -n "${Res[$k]}" ]; then GIT_INDEX_FILE="$idx" G update-index --add --cacheinfo "100644,${Res[$k]},$k"
      else GIT_INDEX_FILE="$idx" G update-index --force-remove -- "$k"; fi
    done
    local tree msg kind=memory shown=() d; tree="$(GIT_INDEX_FILE="$idx" G write-tree)"; rm -f "$idx"
    for k in "${changed_remote[@]}"; do case "$k" in _sessions/*) kind=sessions ;; esac; shown+=("$(disp "$k")"); done
    msg="$kind: $mode から ${#changed_remote[@]} 件(${shown[*]:0:5}$([ ${#changed_remote[@]} -gt 5 ] && echo ' ほか'))"
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
    log "pushed $N: ${shown[*]} (conflicts: ${conflicts[*]:-none})"
  fi

  # 2) 手元へ: remote 側だけが変えたファイルを書く
  for k in "${changed_local[@]}"; do
    if [ -n "${Res[$k]}" ]; then mkdir -p "$(dirname "$repo/$k")"; G cat-file blob "${Res[$k]}" >"$repo/$k.memsync.$$" && mv -f "$repo/$k.memsync.$$" "$repo/$k"
    else rm -f "$repo/$k"; fi
  done
  G update-ref refs/memory-sync/base "$N"

  # 3) 母艦: HEAD と index の memory を N に進める(memory 以外の index 項目は触らない)
  if [ "$mode" = host ] && [ "$N" != "$(G rev-parse HEAD)" ]; then
    if G reset -q "$N" -- "$MP" 2>/dev/null; then
      G update-ref -m "memory-sync" refs/heads/main "$N" "$(G rev-parse HEAD)" 2>/dev/null \
        && log "host HEAD -> $N" || log "host HEAD not advanced (moved meanwhile)"
    else log "host index locked: HEAD not advanced (next time)"; fi
  fi
  # Stop の worker だけ(起動時の取り込みでは branch に触らない。降りた memory は次の Stop で拾う)
  [ "$mode" = cloud ] && [ "${MEMSYNC_NO_BRANCH:-}" != 1 ] && branch_push_cloud
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
# cloud: 起動時に Forgejo から降ろした memory など、対象の path に commit していない差分が残っていれば、Stop の検査に先回りして worker を走らせる
[ "$mode" = cloud ] && [ -n "$(G status --porcelain -- "$MP" _sessions 2>/dev/null | head -1)" ] && need=1
[ "$mode" = cloud ] && [ -e "$stamp" ] && [ -d "$sessdir" ] && [ -n "$(find "$sessdir" -type f -newer "$stamp" -print -quit 2>/dev/null)" ] && need=1
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
