#!/usr/bin/env bash
# 便ごとに溜まる linked worktree を、「もう誰も使っていない」ものだけ片付ける。既定は dry-run。
#
#   wt-sweep.sh [--apply] [--min-age HOURS] [--no-size] [--exclude GLOB]... [REPO...]    # 既定は $WT_SWEEP_ROOT(~/yumemism_repo)直下の全リポ
#   wt-sweep.sh [--apply] --only <worktree のパス>                   # 1 本だけ判定・削除(便の締めから)
#
# 消す条件(全部満たすものだけ。迷えば残す):
#   [1] HEAD が main(または origin/main)に merge 済み     ── どちらで判定したかを base 列に出す
#   [2] git status --porcelain が空(submodule も含む)。submodule は clean かつ HEAD が remote にあること
#   [3] cwd がその worktree の中のプロセス、または引数にそのパスを含むプロセスが無い(見るだけで kill しない)
#   [4] <repo>/.git/worktrees/<name>/HEAD の mtime が MIN_AGE(既定 12 時間)より古い
# 判定に使わないもの: reflog(logs/HEAD)と index の mtime(全部同時刻に書き換わる / git status が書く)
# 対象外: リポ本体(main worktree)、locked、bare、$WT_SWEEP_EXCLUDE(既定 ~/old-pc)と ~/.codex ~/.claude ~/.kimi-code の下(出力にも出さない)、
#         */.claude/worktrees/*(Claude のアプリが持つ木。走査では「残す」の行、--only で名指しすると exit 2)、
#         走査のときは $WT_SWEEP_ROOT の外の worktree(「残す」の行で出す)、--exclude GLOB(worktree のパスに bash の glob で一致)
# 枝は消さない。git worktree prune は、1 本以上消したリポでだけ消した後に呼ぶ。
#
# exit: 0 = 正常(--only では「消す / 消した」)  1 = --apply で削除に失敗  2 = 使い方の誤り
#       3 = --only で「残す」(理由は出力)
set -euo pipefail

ROOT="${WT_SWEEP_ROOT:-$HOME/yumemism_repo}"
EXCLUDE="${WT_SWEEP_EXCLUDE:-$HOME/old-pc}"
MIN_AGE_H=12
APPLY=0
SIZE=1
ONLY=""
REPOS=()
EXCLUDE_GLOBS=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "wt-sweep: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --only) [ "$#" -ge 2 ] || die "--only にはパスが要る"; ONLY="$2"; shift ;;
    --only=*) ONLY="${1#--only=}" ;;
    --min-age) [ "$#" -ge 2 ] || die "--min-age には時間が要る"; MIN_AGE_H="$2"; shift ;;
    --no-size) SIZE=0 ;;
    --exclude) [ "$#" -ge 2 ] || die "--exclude には glob が要る"; EXCLUDE_GLOBS+=("$2"); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "知らない引数: $1" ;;
    *) REPOS+=("$1") ;;
  esac
  shift
done
[[ "$MIN_AGE_H" =~ ^[0-9]+$ ]] || die "--min-age は整数(時間)"
[ -z "$ONLY" ] || [ "${#REPOS[@]}" -eq 0 ] || die "--only とリポ指定は一緒に使えない"

# ---- 引数のパスは cd / の前に絶対化する(自分の子プロセスの cwd が worktree に残って「使用中」に見えないように) ----
if [ -n "$ONLY" ]; then
  [ -d "$ONLY" ] || die "worktree が無い: $ONLY"
  ONLY="$(cd -P "$ONLY" && pwd)"
fi
abs_repos=()
for r in "${REPOS[@]+"${REPOS[@]}"}"; do
  if [ -d "$r/.git" ]; then abs_repos+=("$(cd -P "$r" && pwd)")
  elif [ -d "$ROOT/$r/.git" ]; then abs_repos+=("$(cd -P "$ROOT/$r" && pwd)")
  else die "リポが見つからない(main worktree のパスか $ROOT 直下の名前): $r"; fi
done
EXCLUDE_REAL="$(realpath -m "$EXCLUDE")"
ROOT_REAL="$(realpath -m "$ROOT")"
HARD_EXCLUDES=("$EXCLUDE_REAL" "$(realpath -m "$HOME/.codex")" "$(realpath -m "$HOME/.claude")" "$(realpath -m "$HOME/.kimi-code")")
cd /

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
NOW="$(date +%s)"

# ---- プロセスの snapshot(読むだけ) ----
# procs.cwd: pid<TAB>cwd  /  procs.arg: pid<TAB>引数 1 つ 1 行。自分($$)は除く。
# 祖先(呼び出し元の shell など)は cwd だけ数え、cmdline は数えない(`bash -c "wt-sweep --only <wt>"` が自分を止めないため)。
snapshot_procs() {
  local anc=" " p=$$ pp pid d arg
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    anc+="$p "
    pp="$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)" || break
    p="$pp"
  done
  find /proc -mindepth 2 -maxdepth 2 -name cwd -printf '%h\t%l\n' 2>/dev/null \
    | while IFS=$'\t' read -r d link; do
        pid="${d#/proc/}"
        [ "$pid" = "$$" ] && continue
        printf '%s\t%s\n' "$pid" "${link% (deleted)}"
      done >"$T/procs.cwd" || true
  : >"$T/procs.arg"
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "$pid" = "$$" ] && continue
    case "$anc" in *" $pid "*) continue ;; esac
    [ -r "$d/cmdline" ] || continue
    while IFS= read -r -d '' arg; do
      printf '%s\t%s\n' "$pid" "${arg//$'\n'/ }"
    done <"$d/cmdline" 2>/dev/null >>"$T/procs.arg" || true
  done
}

# proc_use <path>... : そのパスを使っているプロセスを「pid(コマンド名):cwd|cmdline」で 1 行ずつ
proc_use() {
  local pid cwd q pat out="" w
  for w in "$@"; do
    while IFS=$'\t' read -r pid cwd; do
      if [[ "$cwd" == "$w" || "$cwd" == "$w"/* ]]; then
        echo "$pid:cwd"
      fi
    done <"$T/procs.cwd"
    # 引数の中に、パスが「単語として」現れるもの(musearch-acc が musearch-acc-n1 に当たらないよう、後ろは / か非パス文字か行末)
    q="$w"
    LC_ALL=C grep -aP "^([0-9]+)\t(.*[^\w./-])?\Q${q}\E(\$|/|[^\w.-])" "$T/procs.arg" 2>/dev/null | cut -f1 | sort -un | sed 's/$/:cmdline/' || true
  done | sort -u | while IFS=: read -r pid kind; do
    printf '%s(%s):%s\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')" "$kind"
  done
}

# ---- 1 本の判定 ----
# evaluate <repo> <wt> <head_sha> <branch|detached> <locked 0/1> <missing 0/1>
# 結果: V(消す|残す)  BASE_USED  REASONS(; 区切り)  HAS_SUB(force が要るか)
evaluate() {
  local repo="$1" wt="$2" head="$3" locked="$4" missing="$5"
  local reasons=() cats=() r gd mt age ref st n subs sp sstat bc ev real
  add() { reasons+=("$1"); cats+=("$2"); }
  V="残す"; BASE_USED="-"; HAS_SUB=0; CATS=""

  if [ "$locked" = 1 ]; then add "locked(対象外)" "locked"; fi
  if [ "$missing" = 1 ] || [ ! -d "$wt" ]; then
    add "実体なし(prunable)" "実体なし"
    REASONS="$(printf '%s; ' "${reasons[@]}")"; REASONS="${REASONS%; }"; CATS="$(printf '%s\n' "${cats[@]}" | sort -u | paste -sd, -)"; return
  fi
  real="$(cd -P "$wt" && pwd)"

  # [4] HEAD ファイルの mtime
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -n "$gd" ] && mt="$(stat -c %Y "$gd/HEAD" 2>/dev/null)"; then
    age=$(( NOW - mt ))
    if [ "$age" -lt $(( MIN_AGE_H * 3600 )) ]; then
      add "[4] HEAD ファイルが $(( age / 3600 )) 時間前に更新(${MIN_AGE_H} 時間以内)" "[4] HEAD ファイルが新しい"
    fi
  else
    add "[4] HEAD ファイルの mtime が読めない" "[4] HEAD ファイルが新しい"
  fi

  # [1] merge 済みか
  if [ -z "$head" ]; then
    add "[1] HEAD が無い(unborn)" "[1] 未 merge"
  else
    local cands=() found=""
    for ref in main origin/main; do
      git -C "$repo" rev-parse --verify -q "refs/heads/$ref^{commit}" >/dev/null 2>&1 && cands+=("$ref") && continue
      git -C "$repo" rev-parse --verify -q "refs/remotes/$ref^{commit}" >/dev/null 2>&1 && cands+=("$ref")
    done
    if [ "${#cands[@]}" -eq 0 ]; then
      for ref in master origin/master; do
        git -C "$repo" rev-parse --verify -q "refs/heads/$ref^{commit}" >/dev/null 2>&1 && cands+=("$ref") && continue
        git -C "$repo" rev-parse --verify -q "refs/remotes/$ref^{commit}" >/dev/null 2>&1 && cands+=("$ref")
      done
    fi
    if [ "${#cands[@]}" -eq 0 ]; then
      add "[1] main / origin/main が無い" "[1] 未 merge"
    else
      for ref in "${cands[@]}"; do
        if git -C "$repo" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then found="$ref"; break; fi
      done
      if [ -n "$found" ]; then BASE_USED="$found"
      else add "[1] ${cands[*]} に未 merge" "[1] 未 merge"; fi
    fi
  fi

  # [2] status(submodule 込み)
  if st="$(git -C "$wt" status --porcelain --ignore-submodules=none 2>/dev/null)"; then
    if [ -n "$st" ]; then
      n="$(printf '%s\n' "$st" | wc -l)"
      if [ -z "$(printf '%s\n' "$st" | grep -v '^?? ' || true)" ]; then
        # 未追跡(??)の行だけ: 消す条件は変えず、理由を分けて名前を最大 3 つ添える
        add "[2] 未追跡のみ ${n} 件: $(printf '%s\n' "$st" | sed 's/^?? //' | head -3 | paste -sd, - | sed 's/,/, /g')$([ "$n" -gt 3 ] && echo ' ほか')" "[2] 未追跡のみ"
      else
        add "[2] 変更あり(追跡ファイル・submodule の変更 / staged を含む ${n} 行)" "[2] 変更あり"
      fi
    else
      # submodule: 初期化済み(status の行頭が '-' でない)ものは clean かつ HEAD が remote にあること
      subs="$(git -C "$wt" submodule status --recursive 2>/dev/null | grep -v '^-' | awk '{print $2}' || true)"
      if [ -n "$subs" ]; then
        HAS_SUB=1
        while IFS= read -r sp; do
          [ -n "$sp" ] || continue
          if sstat="$(git -C "$wt/$sp" status --porcelain 2>/dev/null)"; then
            if [ -n "$sstat" ]; then add "[2] submodule $sp が dirty" "[2] submodule が dirty / remote に無い"; continue; fi
          else add "[2] submodule $sp の status が取れない" "[2] submodule が dirty / remote に無い"; continue; fi
          bc="$(git -C "$wt/$sp" branch -r --contains HEAD 2>/dev/null || true)"
          [ -n "$bc" ] || add "[2] submodule $sp の HEAD が remote に無い(fetch 無しで判定できず残す)" "[2] submodule が dirty / remote に無い"
        done <<<"$subs"
      fi
    fi
  else
    add "[2] git status が失敗" "[2] 変更あり"
  fi

  # [3] プロセス
  ev="$(proc_use "$wt" "$real" | sort -u | head -4 | paste -sd, - || true)"
  if [ -n "$ev" ]; then add "[3] 使用中 pid=$ev" "[3] 使用中"; fi

  if [ "${#reasons[@]}" -eq 0 ]; then V="消す"; REASONS="全条件を満たす"
  else
    REASONS="$(printf '%s; ' "${reasons[@]}")"; REASONS="${REASONS%; }"
    CATS="$(printf '%s\n' "${cats[@]}" | sort -u | paste -sd, -)"
  fi
}

# ---- worktree の列挙 ----
# list_wts <repo> : "wt<TAB>head<TAB>branch<TAB>locked<TAB>missing" を main 以外について出す
list_wts() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v RS= -F'\n' '
    NR==1 { next }
    {
      wt=""; head=""; br="detached"; lk=0; ms=0; bare=0
      for (i=1;i<=NF;i++) {
        if ($i ~ /^worktree /) wt=substr($i,10)
        else if ($i ~ /^HEAD /) head=substr($i,6)
        else if ($i ~ /^branch /) { br=substr($i,8); sub(/^refs\/heads\//,"",br) }
        else if ($i ~ /^locked/) lk=1
        else if ($i ~ /^prunable/) ms=1
        else if ($i == "bare") bare=1
      }
      if (bare) next
      print wt "\t" head "\t" br "\t" lk "\t" ms
    }'
}

under_exclude() { local e; for e in "${HARD_EXCLUDES[@]}"; do [[ "$1" == "$e" || "$1" == "$e"/* ]] && return 0; done; return 1; }
# soft_exclude <wt> : 走査の範囲外(ROOT の外 / --exclude)なら REASONS・CATS を立てて 0
soft_exclude() {
  local g real; real="$(realpath -m "$1")"
  if [[ "$real" == */.claude/worktrees/* ]]; then   # Claude のアプリが作って持っている木。既定の対象外
    V="残す"; BASE_USED="-"; HAS_SUB=0; REASONS="対象外(Claude アプリの worktree)"; CATS="Claude アプリの worktree"; return 0
  fi
  if [[ "$real" != "$ROOT_REAL"/* ]]; then
    V="残す"; BASE_USED="-"; HAS_SUB=0; REASONS="対象外(\$WT_SWEEP_ROOT の外)"; CATS="ROOT の外"; return 0
  fi
  for g in "${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"}"; do
    # shellcheck disable=SC2053
    if [[ "$real" == $g || "$1" == $g ]]; then V="残す"; BASE_USED="-"; HAS_SUB=0; REASONS="対象外(--exclude $g)"; CATS="--exclude"; return 0; fi
  done
  return 1
}

fmt_kb() { awk -v k="$1" 'BEGIN{ if(k<1024) printf "%dK",k; else if(k<1048576) printf "%.0fM",k/1024; else printf "%.1fG",k/1048576 }'; }

# ---- 走査 ----
ROWS="$T/rows"   # 並べ替え key<TAB>判定<TAB>repo<TAB>wt<TAB>branch<TAB>base<TAB>理由<TAB>force
: >"$ROWS"
skipped_excl=0

scan_repo() {
  local repo="$1" wt head br lk ms rname
  rname="$(basename "$repo")"
  while IFS=$'\t' read -r wt head br lk ms; do
    [ -n "$wt" ] || continue
    if under_exclude "$(realpath -m "$wt")"; then skipped_excl=$((skipped_excl + 1)); continue; fi
    soft_exclude "$wt" || evaluate "$repo" "$wt" "$head" "$lk" "$ms"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$([ "$V" = 消す ] && echo 0 || echo 1)" "$V" "$rname" "$wt" "$br" "$BASE_USED" "$REASONS" "$HAS_SUB" "$CATS" >>"$ROWS"
  done < <(list_wts "$repo")
}

snapshot_procs

if [ -n "$ONLY" ]; then
  real_only="$ONLY"
  under_exclude "$real_only" && die "対象外(\$WT_SWEEP_EXCLUDE の下): $real_only"
  [[ "$real_only" == */.claude/worktrees/* ]] && die "対象外(Claude アプリの worktree): $real_only"
  common="$(git -C "$real_only" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "git の worktree ではない: $real_only"
  [ "$(basename "$common")" = .git ] || die "bare / 特殊な構成は扱わない: $common"
  repo="$(dirname "$common")"
  if [ "$(cd -P "$repo" && pwd)" = "$real_only" ]; then
    printf '残す\t-\t%s\t%s\t-\t-\t対象外(リポ本体 = main worktree)\n' "$(basename "$repo")" "$real_only"
    exit 3
  fi
  found=0
  while IFS=$'\t' read -r wt head br lk ms; do
    [ "$(realpath -m "$wt")" = "$real_only" ] || continue
    found=1
    evaluate "$repo" "$wt" "$head" "$lk" "$ms"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$([ "$V" = 消す ] && echo 0 || echo 1)" "$V" "$(basename "$repo")" "$wt" "$br" "$BASE_USED" "$REASONS" "$HAS_SUB" "$CATS" >>"$ROWS"
  done < <(list_wts "$repo")
  [ "$found" = 1 ] || die "$repo に登録された linked worktree ではない: $real_only"
else
  if [ "${#abs_repos[@]}" -gt 0 ]; then repo_list=("${abs_repos[@]}")
  else
    repo_list=()
    for d in "$ROOT"/*/; do
      d="${d%/}"
      [ -d "$d/.git" ] || continue
      [ "$(git -C "$d" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')" -gt 1 ] || continue
      repo_list+=("$d")
    done
  fi
  for repo in "${repo_list[@]+"${repo_list[@]}"}"; do scan_repo "$repo"; done
fi

# ---- サイズ(worktree ごとに du。4 並列、低優先度。--apply では消す行だけ) ----
declare -A SZ=()
if [ "$SIZE" = 1 ] && [ -s "$ROWS" ]; then
  if [ "$APPLY" = 1 ]; then want="$(awk -F'\t' '$2=="消す"{print $4}' "$ROWS")"
  else want="$(cut -f4 "$ROWS")"; fi
  if [ -n "$want" ]; then
    while IFS=$'\t' read -r kb path; do [ -n "$path" ] && SZ["$path"]="$kb"; done < <(
      printf '%s\n' "$want" | tr '\n' '\0' \
        | xargs -0 -r -P 4 -n 1 nice -n 10 sh -c 'kb=$(du -skx -- "$1" 2>/dev/null | cut -f1); printf "%s\t%s\n" "${kb:-0}" "$1"' _
    )
  fi
fi

# ---- 出力 ----
sort -t$'\t' -k1,1n -k3,3 -k4,4 "$ROWS" >"$T/rows.sorted"
print_row() { # 判定 サイズ repo wt branch base 理由
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}
if [ -z "$ONLY" ]; then
  echo "# wt-sweep $( [ "$APPLY" = 1 ] && echo '--apply' || echo 'dry-run(何も消さない)' )  $(date '+%F %T')  ROOT=$ROOT  MIN_AGE=${MIN_AGE_H}h  対象外=$EXCLUDE,~/.codex,~/.claude,~/.kimi-code"
  echo "# 列: 判定 / サイズ / repo / worktree / branch / merge 先 / 理由  ([1]merge 済み [2]status clean [3]使用中なし [4]HEAD ファイルが古い)"
  print_row 判定 サイズ repo worktree branch base 理由
fi
del_n=0; del_kb=0; keep_n=0; keep_kb=0
declare -A WHY=()
while IFS=$'\t' read -r key v repo wt br base why force cats; do
  kb="${SZ[$wt]:-}"
  sz="-"; [ -n "$kb" ] && sz="$(fmt_kb "$kb")"
  print_row "$v" "$sz" "$repo" "$wt" "$br" "$base" "$why"
  if [ "$v" = 消す ]; then del_n=$((del_n + 1)); del_kb=$((del_kb + ${kb:-0}))
  else
    keep_n=$((keep_n + 1)); keep_kb=$((keep_kb + ${kb:-0}))
    # 内訳: 落ちた条件ごとに数える(cats 列はコンマ区切り)
    while IFS= read -r lab; do [ -n "$lab" ] && WHY["$lab"]=$(( ${WHY["$lab"]:-0} + 1 )); done < <(printf '%s\n' "$cats" | tr ',' '\n')
  fi
done <"$T/rows.sorted"

# ---- 削除 ----
rm_ok=0; rm_fail=0; rm_kb=0
if [ "$APPLY" = 1 ] && [ "$del_n" -gt 0 ]; then
  declare -A touched=()
  while IFS=$'\t' read -r key v repo wt br base why force cats <&3; do
    [ "$v" = 消す ] || continue
    # 直前にもう一度、新しい snapshot で判定し直す(判定から削除までの間に使い始められていないか)
    rrepo="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs -r dirname)"
    snapshot_procs
    [ -n "$rrepo" ] || { echo "# 見送り(リポが引けない): $wt" >&2; continue; }
    head=""; lk=0; ms=0
    IFS=$'\t' read -r _w head _b lk ms < <(list_wts "$rrepo" | awk -F'\t' -v w="$wt" '$1==w') || true
    evaluate "$rrepo" "$wt" "$head" "$lk" "$ms"
    if [ "$V" != 消す ]; then
      echo "# 見送り(直前の再判定で残す): $wt ── $REASONS" >&2
      continue
    fi
    kb="${SZ[$wt]:-0}"
    if [ "$HAS_SUB" = 1 ]; then rmcmd=(git -C "$rrepo" worktree remove --force "$wt")
    else rmcmd=(git -C "$rrepo" worktree remove "$wt"); fi
    if "${rmcmd[@]}" 2>"$T/rm.err"; then
      rm_ok=$((rm_ok + 1)); rm_kb=$((rm_kb + kb)); touched["$rrepo"]=1
      echo "# 削除: $wt ($(fmt_kb "$kb"))"
    else
      rm_fail=$((rm_fail + 1)); echo "# 失敗: $wt ── $(head -1 "$T/rm.err")" >&2
    fi
  done 3<"$T/rows.sorted"
  for r in "${!touched[@]}"; do git -C "$r" worktree prune; done
fi

# ---- 末尾 ----
if [ -z "$ONLY" ]; then
  if [ "$APPLY" = 1 ]; then
    echo "# 削除した ${rm_ok} 本、合計 $(fmt_kb "$rm_kb")(判定時 消す ${del_n} 本 / 失敗 ${rm_fail} 本)。残した ${keep_n} 本"
  else
    echo "# 消す ${del_n} 本、合計 $(fmt_kb "$del_kb")(--apply で初めて消す)。残す ${keep_n} 本、合計 $(fmt_kb "$keep_kb")"
  fi
  [ "$skipped_excl" -eq 0 ] || echo "# 対象外($EXCLUDE ・~/.codex ・~/.claude ・~/.kimi-code の下)として走査しなかった: ${skipped_excl} 本"
  if [ "$keep_n" -gt 0 ]; then
    echo "# 残す理由の内訳(1 本が複数の条件で落ちることがある。のべ):"
    for k in "${!WHY[@]}"; do printf '%s\t%s\n' "${WHY[$k]}" "$k"; done | sort -rn | sed 's/^/#   /'
  fi
fi
if [ -n "$ONLY" ]; then
  if [ "$V" = 消す ]; then
    if [ "$APPLY" = 1 ] && [ "$rm_ok" -eq 1 ]; then echo "削除した: $ONLY"; exit 0
    elif [ "$APPLY" = 1 ] && [ "$rm_fail" -gt 0 ]; then exit 1
    elif [ "$APPLY" = 1 ]; then exit 3
    else echo "消す(dry-run。--apply で消える): $ONLY"; exit 0; fi
  else
    echo "残す: $ONLY ── $REASONS"; exit 3
  fi
fi
[ "$rm_fail" -eq 0 ] || exit 1
exit 0
