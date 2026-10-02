#!/usr/bin/env bash
# 便・真壁・柏木のランチャが「run の前後で作業木と main/master がどう動いたか」を測る共通の関数。
# source して使う(claude-makabe / kimi-makabe / claude-kashiwagi / claude-niekawa / kimi-niekawa)。
# 起点は 2026-10-03 の claude-makabe の事故(役員 人見 の報告)── 起動時に汚れた作業木を run の中で全部 commit して
# clean に戻すと、`printf '%s\n' "$post" | comm -3` が post 側に空行を 1 本作り、comm が tab を前置した
# 「\t」だけの行が `sed '/^$/d'` をすり抜けて path が空になった(bash の連想配列は空キーで落ちる / 件数だけの
# 呼び手は +1 ずれる)。status は改行区切りでなく NUL 区切りの record で比べる。
#
# 使い方:
#   # shellcheck source=lib/git-run-diff.sh
#   source "$CORE/scripts/lib/git-run-diff.sh"
#   git_status_records "$root" > "$run_dir/pre_status.z"        # `XY<空白>path` の NUL 区切り、C ロケールで sort -u
#   git_status_records "$root" paths > "$run_dir/pre_status.z"  # path だけの NUL 区切り(XY を落とす)
#   git_status_diff_count "$run_dir/pre_status.z" "$run_dir/post_status.z"   # 片側にだけ在る record の数
#   LC_ALL=C comm -z -3 pre post | while IFS= read -r -d '' rec; do rec="${rec#$'\t'}"; ... "${rec:3}" ...; done

# git_status_records <worktree> [paths]
# - `--porcelain=v1 -z`: パスは引用符なし・エスケープなしの生のまま(日本語・空白名がずれない)。
# - 改名・複製(R / C)は `XY new\0old\0` の 2 つ組で来る。old 側にも同じ XY を付けた別の record にする
#   (HEAD 差分側は --no-renames で新旧両方を挙げるので数え方をそろえる)。paths のときは新旧の path が各 1 本。
# - 空の status は record 0 本(旧版の `printf '%s\n' ""` が作っていた空行を作らない)。
git_status_records() {
  local dir="$1" mode="${2:-xy}" entry xy skip=0 skip_xy=""
  while IFS= read -r -d '' entry; do
    if [ "$skip" -eq 1 ]; then
      skip=0
      [ -z "$entry" ] && continue
      if [ "$mode" = paths ]; then
        printf '%s\0' "$entry"
      else
        printf '%s\0' "$skip_xy $entry"
      fi
      continue
    fi
    [ "${#entry}" -gt 3 ] || continue
    if [ "$mode" = paths ]; then
      printf '%s\0' "${entry:3}"
    else
      printf '%s\0' "$entry"
    fi
    xy="${entry:0:2}"
    case "$xy" in
      R?|C?|?R|?C) skip=1; skip_xy="$xy" ;;
    esac
  done < <(git -C "$dir" status --porcelain=v1 -z --untracked-files=all 2>/dev/null) | LC_ALL=C sort -z -u
}

# git_status_diff_count <pre.z> <post.z> ── 片側にだけある record の数(両方 git_status_records の出力、同じ mode)
git_status_diff_count() {
  LC_ALL=C comm -z -3 "$1" "$2" | tr -cd '\0' | wc -c | tr -d ' '
}

# git_ref_log_count <git_root> <ref> ── ref の reflog の件数(reflog が無い・ref が無いときは 0)。
# 起動時に数えて、終了後の git_ref_moved_by に渡す。
git_ref_log_count() {
  local n
  n="$(git -C "$1" reflog show --format=%H "$2" 2>/dev/null | wc -l | tr -d ' ')" || n=0
  printf '%s\n' "${n:-0}"
}

# git_ref_moved_by <git_root> <ref> <pre_sha> <pre_count> <email>
# run の間に積まれた reflog のうち(終了時の件数 - 起動時の件数 = 新しい側の k 本)、committer 名義が <email> の
# ものがあるかを見て stdout に 1 語返す(呼び手は ref が実際に変わったときだけ呼ぶ):
#   self    ── <email>(launcher が agent に与える名義)のエントリがある = agent が動かした
#   foreign ── 新しい k 本がすべて別名義 = 別窓(鷹野・人見)の操作
#   unknown ── 見分けられない(reflog が無い / 件数が増えていない / 起動時の値 <pre_sha> が k 本目の下に見つからない
#              = 期限切れ・消去・core.logAllRefUpdates=false)。呼び手は安全側で「逸脱」に倒す
# 起動時に ref が無かった(<pre_sha> が空)ときは新しい k 本 = reflog の全部として見る。
git_ref_moved_by() {
  local root="$1" ref="$2" pre_sha="$3" pre_n="$4" email="$5"
  local -a hs=() es=()
  local h e n k i
  while IFS='|' read -r h e; do
    hs+=("$h")
    es+=("$e")
  done < <(git -C "$root" reflog show --format='%H|%ge' "$ref" 2>/dev/null || true)
  n="${#hs[@]}"
  k=$((n - pre_n))
  if [ "$k" -le 0 ]; then
    echo unknown
    return 0
  fi
  if [ -n "$pre_sha" ]; then
    if [ "$k" -ge "$n" ] || [ "${hs[$k]}" != "$pre_sha" ]; then
      echo unknown
      return 0
    fi
  fi
  for ((i = 0; i < k; i++)); do
    if [ "${es[$i]}" = "$email" ]; then
      echo self
      return 0
    fi
  done
  echo foreign
}

# git_ref_guard <git_root> <ref> <pre_sha> <pre_count> <post_sha> <email>
# 事後ガードの 1 ref 分。変化が無ければ何も出さず 0。逸脱なら stdout に「ref 変化を検出: <ref>(理由)」を 1 行出して 1。
# 別名義だけの変化は stderr に警告 1 行を出して 0(footer は通常どおり)。
git_ref_guard() {
  local root="$1" ref="$2" pre_sha="$3" pre_n="$4" post_sha="$5" email="$6" who
  [ "$pre_sha" != "$post_sha" ] || return 0
  who="$(git_ref_moved_by "$root" "$ref" "$pre_sha" "$pre_n" "$email")"
  case "$who" in
    foreign)
      echo "警告: $ref が run の間に動いた(${pre_sha:0:9} -> ${post_sha:0:9})が、reflog の名義は $email ではない ── 別窓の操作と見て逸脱にしない" >&2
      return 0
      ;;
    self)
      printf 'ref 変化を検出: %s(reflog に %s 名義の更新がある)\n' "$ref" "$email"
      ;;
    *)
      printf 'ref 変化を検出: %s(reflog で誰が動かしたか見分けられない、変化は逸脱として扱う)\n' "$ref"
      ;;
  esac
  return 1
}
