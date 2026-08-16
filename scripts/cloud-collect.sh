#!/usr/bin/env bash
set -euo pipefail

# push mirror は送り先にだけ在る余分な ref を消す。
# cloud セッション終了後は GitHub の ref が唯一の実体となり得るため、消失前に Forgejo へ回収する。

usage() {
  echo '使い方: cloud-collect.sh [-C <repo>] [--remote <name>] [--prefix <name>] [--dry-run]' >&2
}

repo_arg=.
remote=github
prefix=cloud
dry_run=false

while (($# > 0)); do
  case "$1" in
    -C)
      if (($# < 2)); then
        echo 'エラー: -C の対象リポジトリ未指定' >&2
        usage
        exit 2
      fi
      repo_arg=$2
      shift 2
      ;;
    --remote)
      if (($# < 2)); then
        echo 'エラー: --remote の名前未指定' >&2
        usage
        exit 2
      fi
      remote=$2
      shift 2
      ;;
    --prefix)
      if (($# < 2)); then
        echo 'エラー: --prefix の名前空間未指定' >&2
        usage
        exit 2
      fi
      prefix=$2
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'エラー: 未知の引数 %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! repo=$(git -C "$repo_arg" rev-parse --show-toplevel 2>/dev/null); then
  printf 'エラー: git リポジトリではない場所 %s\n' "$repo_arg" >&2
  exit 2
fi

if [[ $remote == -* ]] || ! git -C "$repo" remote get-url "$remote" >/dev/null 2>&1; then
  printf 'エラー: remote %s の未登録\n' "$remote" >&2
  printf '追加コマンド: git -C %q remote add %q %q\n' \
    "$repo" "$remote" 'https://github.com/<owner>/<repo>.git' >&2
  exit 2
fi

if ! git check-ref-format "refs/heads/$prefix/probe" >/dev/null 2>&1; then
  printf 'エラー: prefix に使えない名前 %s\n' "$prefix" >&2
  exit 2
fi

if ! source_rows=$(git -C "$repo" ls-remote --heads "$remote" 2>/dev/null); then
  printf 'エラー: remote %s の参照取得失敗\n' "$remote" >&2
  exit 1
fi

if ! origin_rows=$(git -C "$repo" ls-remote --heads origin 2>/dev/null); then
  echo 'エラー: origin の参照取得失敗' >&2
  exit 1
fi

declare -A origin_sha=()
while IFS=$'\t' read -r sha ref; do
  [[ -n ${sha:-} && -n ${ref:-} ]] || continue
  origin_sha["$ref"]=$sha
done <<<"$origin_rows"

declare -a source_names=()
declare -a source_refs=()
declare -a destination_names=()
declare -a listed_shas=()

while IFS=$'\t' read -r sha ref; do
  [[ -n ${sha:-} && -n ${ref:-} ]] || continue
  case "$ref" in
    refs/heads/claude/*)
      remainder=${ref#refs/heads/claude/}
      ;;
    refs/heads/claude--*)
      remainder=${ref#refs/heads/claude--}
      ;;
    *)
      continue
      ;;
  esac
  [[ -n $remainder ]] || continue
  source_names+=("${ref#refs/heads/}")
  source_refs+=("$ref")
  destination_names+=("$prefix/$remainder")
  listed_shas+=("$sha")
done <<<"$source_rows"

collected=0
skipped=0
failed=0
declare -a candidate_indexes=()
need_slash=false
need_dash=false

for i in "${!source_names[@]}"; do
  destination_ref="refs/heads/${destination_names[$i]}"
  if [[ ${origin_sha[$destination_ref]:-} == "${listed_shas[$i]}" ]]; then
    printf 'skip %s ── 既に同一\n' "${source_names[$i]}"
    ((skipped += 1))
    continue
  fi
  candidate_indexes+=("$i")
  case "${source_refs[$i]}" in
    refs/heads/claude/*) need_slash=true ;;
    refs/heads/claude--*) need_dash=true ;;
  esac
done

if $dry_run; then
  for i in "${candidate_indexes[@]}"; do
    printf '回収 %s -> %s (%.7s)\n' \
      "${source_names[$i]}" "${destination_names[$i]}" "${listed_shas[$i]}"
    ((collected += 1))
  done
  printf '回収 %d件 / skip %d件\n' "$collected" "$skipped"
  exit 0
fi

if $need_slash; then
  if ! git -C "$repo" fetch --quiet "$remote" "refs/heads/claude/*:refs/heads/$prefix/*"; then
    printf 'エラー: remote %s の claude/* fetch 失敗\n' "$remote" >&2
    exit 1
  fi
fi
if $need_dash; then
  if ! git -C "$repo" fetch --quiet "$remote" "refs/heads/claude--*:refs/heads/$prefix/*"; then
    printf 'エラー: remote %s の claude--* fetch 失敗\n' "$remote" >&2
    exit 1
  fi
fi

for i in "${candidate_indexes[@]}"; do
  local_ref="refs/heads/${destination_names[$i]}"
  actual_sha=$(git -C "$repo" rev-parse "$local_ref")
  if push_output=$(git -C "$repo" push --porcelain origin "$local_ref" 2>&1); then
    printf '回収 %s -> %s (%.7s)\n' \
      "${source_names[$i]}" "${destination_names[$i]}" "$actual_sha"
    ((collected += 1))
    continue
  fi

  current_origin_sha=$(git -C "$repo" ls-remote --heads origin "$local_ref" | awk 'NR == 1 { print $1 }')
  non_fast_forward=false
  if [[ -n $current_origin_sha ]]; then
    git -C "$repo" fetch --quiet origin "$local_ref" || true
    if git -C "$repo" cat-file -e "$current_origin_sha^{commit}" 2>/dev/null \
      && ! git -C "$repo" merge-base --is-ancestor "$current_origin_sha" "$actual_sha"; then
      non_fast_forward=true
    fi
  fi

  if $non_fast_forward; then
    printf '警告: %s ── 非早送りのため回収対象外\n' "${source_names[$i]}" >&2
    printf 'skip %s ── 非早送り\n' "${source_names[$i]}"
    ((skipped += 1))
  else
    printf 'エラー: %s の push 失敗\n%s\n' "${source_names[$i]}" "$push_output" >&2
    ((failed += 1))
  fi
done

printf '回収 %d件 / skip %d件\n' "$collected" "$skipped"
if ((failed > 0)); then
  exit 1
fi
