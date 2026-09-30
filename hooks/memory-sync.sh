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
#   - push が通った後、VM の作業木を「commit していない変更も push していない commit も無い」状態に揃える(realign_cloud)。
#     Anthropic が VM に入れる Stop の git 検査(~/.claude/stop-hook-git-check.sh)に静かに通らせるため。検査は消さない・
#     上書きしない(origin の追跡 ref も書き換えない)。揃えた後 `git fetch origin` で push mirror が追いつくのを待つ。揃えるのは、手元の差分が全部「対象の path で、中身が今回 Forgejo に載せたものと同じ」のときだけ
#     (session の branch に本物の作業が残っていれば何もせず、警告もそのまま残る)
#
# 母艦の追加条件: 作業木(既定 ~/canonical/tech)が main で、HEAD が今回の commit の祖先で、差分が memory だけ。
#   満たさなければ push しない(作業木を壊さない)。満たすときだけ HEAD と index の memory を commit に進める。
#
# env: MEMSYNC_NO_REALIGN=1(cloud-bootstrap の起動時の取り込みが付ける。作業木・branch を動かさない)
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

# cloud: 作業木を揃えた後、Forgejo→GitHub の push mirror が追いつくのを `git fetch origin` で待つ(2 秒おき・最長 20 秒)。
# origin の追跡先(検査が見るもの = origin/<branch>、無ければ origin/HEAD)が HEAD を含んだら終わり。間に合わなければ何もせず記録だけ
# (その回の検査は警告が出てよい、次の Stop で通る)。origin/<branch> が在るのに HEAD を含まないときは書き換えず記録だけ
await_origin() { # <branch>
  local br="$1" wait="${MEMSYNC_ORIGIN_WAIT:-20}" iv="${MEMSYNC_ORIGIN_INTERVAL:-2}" t0 up
  t0=$(date +%s)
  while :; do
    timeout 10 git -C "$repo" fetch --quiet origin 2>>"$state/sync.log" || log "realign: git fetch origin failed (keep waiting)"
    if G rev-parse -q --verify "refs/remotes/origin/$br^{commit}" >/dev/null 2>&1; then
      if G merge-base --is-ancestor HEAD "refs/remotes/origin/$br" 2>/dev/null; then log "realign: origin/$br contains HEAD"
      else log "realign: origin/$br exists on origin but does not contain HEAD $(G rev-parse --short HEAD) (origin/$br at $(G rev-parse --short "refs/remotes/origin/$br")); left as is, not rewritten"; fi
      return 0
    fi
    up=origin/HEAD; G rev-parse -q --verify 'origin/HEAD^{commit}' >/dev/null 2>&1 || up=origin/main
    if G merge-base --is-ancestor HEAD "$up" 2>/dev/null; then log "realign: $up contains HEAD (origin caught up after $(( $(date +%s) - t0 ))s)"; return 0; fi
    if [ $(( $(date +%s) - t0 )) -ge "$wait" ]; then log "realign: $up did not reach HEAD within ${wait}s (left as is; the next Stop should pass)"; return 0; fi
    sleep "$iv"
  done
}

# cloud: 手元の差分が全部「対象の path で中身が N と同じ」なら、作業木の branch を N に揃える(後述の呼び出しを参照)
realign_cloud() { # <N = 今回の Forgejo main>
  local N="$1" br p nb wb ib hb mb
  br="$(G symbolic-ref -q --short HEAD)" || { log "realign: detached HEAD (skip)"; return 0; }
  allowed() { case "$1" in "$MP"/*|_sessions/*) return 0 ;; esac; return 1; }
  nblob() { G rev-parse -q --verify "$N:$1" 2>/dev/null; }
  # submodule(.claude/_core)の指す commit が HEAD と N で違うと、reset --hard の後に submodule が modified に見える
  [ "$(G ls-tree -r HEAD | awk '$1=="160000"{print $4" "$3}' | sort)" = "$(G ls-tree -r "$N" | awk '$1=="160000"{print $4" "$3}' | sort)" ] \
    || { log "realign: submodule pointer differs from Forgejo main (skip)"; return 0; }
  mb="$(G merge-base "$N" HEAD 2>/dev/null)" || { log "realign: no merge-base with Forgejo main (skip)"; return 0; }
  # (1) push していない commit: 正味の差分が対象の path だけで、中身が N と同じ
  while IFS= read -r -d '' p; do
    allowed "$p" || { log "realign: local commit touches $p (real work, skip)"; return 0; }
    [ "$(G rev-parse -q --verify "HEAD:$p" 2>/dev/null)" = "$(nblob "$p")" ] || { log "realign: $p in HEAD differs from Forgejo main (skip)"; return 0; }
  done < <(G diff -z --name-only "$mb" HEAD)
  # (2) commit していない変更(unstaged / staged): 対象の path で、手元も index も N と同じ中身
  while IFS= read -r -d '' p; do
    allowed "$p" || { log "realign: uncommitted change in $p (real work, skip)"; return 0; }
    nb="$(nblob "$p")"; wb=""; [ -f "$repo/$p" ] && wb="$(G hash-object -- "$p")"
    ib="$(G rev-parse -q --verify ":$p" 2>/dev/null)"; hb="$(G rev-parse -q --verify "HEAD:$p" 2>/dev/null)"
    [ "$wb" = "$nb" ] && { [ "$ib" = "$nb" ] || [ "$ib" = "$hb" ]; } || { log "realign: $p differs from what was pushed (skip)"; return 0; }
  done < <({ G diff -z --name-only HEAD; G diff -z --cached --name-only; } 2>/dev/null)
  # (3) 追跡されていないファイル: 対象の path で、N に同じ中身がある
  while IFS= read -r -d '' p; do
    allowed "$p" || { log "realign: untracked $p (real work, skip)"; return 0; }
    nb="$(nblob "$p")"; wb="$(G hash-object -- "$p" 2>/dev/null)"
    [ -n "$nb" ] && [ "$wb" = "$nb" ] || { log "realign: untracked $p was not pushed (skip)"; return 0; }
  done < <(G ls-files -z --others --exclude-standard 2>/dev/null)
  if [ "$(G rev-parse HEAD)" != "$N" ]; then
    G reset -q --hard "$N" 2>>"$state/sync.log" || { log "realign: reset --hard failed (skip)"; return 0; }
  fi
  # Anthropic の検査は origin/<branch>(無ければ origin/HEAD)との差で「push していない commit」を数える。origin は GitHub の写しで、
  # Forgejo の main への push は push mirror(sync_on_commit)が数秒で同じ commit にする(役員 人見の裁定 2026-10-01)。
  # ref を手元で書き換えず、fetch して本物の値が揃うのを待つ
  await_origin "$br"
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
  # 揃えるのは Stop の worker だけ(起動時の取り込みでは作業木・branch を動かさない)で、今回 push したか、手元に差分が残っているときだけ
  if [ "$mode" = cloud ] && [ "${MEMSYNC_NO_REALIGN:-}" != 1 ]; then
    if [ "${#changed_remote[@]}" -gt 0 ] || [ -n "$(G status --porcelain 2>/dev/null)" ]; then realign_cloud "$N"
    elif [ "$(G rev-parse HEAD)" = "$N" ]; then
      # 前の Stop で揃えたが push mirror が間に合わなかった(origin の追跡先がまだ HEAD を含まない)ときの 2 度目。fetch しない限り追跡先は動かない
      local br up; br="$(G symbolic-ref -q --short HEAD)" && {
        up="refs/remotes/origin/$br"; G rev-parse -q --verify "$up^{commit}" >/dev/null 2>&1 || { up=refs/remotes/origin/HEAD; G rev-parse -q --verify "$up^{commit}" >/dev/null 2>&1 || up=refs/remotes/origin/main; }
        G merge-base --is-ancestor HEAD "$up" 2>/dev/null || await_origin "$br"; }
    fi
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
