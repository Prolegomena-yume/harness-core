#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: codex-agent.sh <persona> [options] [task...]

persona:
  minase | makabe | kashiwagi

options:
  -f, --file <path>        タスク本文をファイルから読む。複数指定可
  -C, --cd <dir>           作業ルート
      --log <path>         ログ出力先
      --resume <id>        同じ Codex セッションを継続
      --effort <level>     reasoning effort。既定 high
      --model <id>         Codex model を指定
      --no-guard           実行後の権限ガードを省略
      --mcp                MCP server を有効のまま起動
      --notify-sock <path> kashiwagi 専用。宛先 role の messaging socket 1本だけに送信の穴を空ける(rulings #59)。sandbox は workspace-write になるが -C は空の scratch に差し替わり、リポは書けないまま
  -h, --help               この usage を表示

task と --file が無い場合は標準入力からタスク本文を読む。
USAGE
}

die() {
  echo "エラー: $*" >&2
  exit 2
}

resolve_self() {
  local source_path="${BASH_SOURCE[0]}"
  local source_dir link_target

  while [ -L "$source_path" ]; do
    source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    link_target="$(readlink "$source_path")"
    if [[ "$link_target" = /* ]]; then
      source_path="$link_target"
    else
      source_path="$source_dir/$link_target"
    fi
  done

  source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
  printf '%s/%s\n' "$source_dir" "$(basename "$source_path")"
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
fi

persona="$1"
shift
case "$persona" in
  minase|makabe|kashiwagi) ;;
  *) die "不正な persona: $persona" ;;
esac

script_path="$(resolve_self)"
CORE="$(dirname "$(dirname "$script_path")")"
[ -d "$CORE/roles" ] || die "roles ディレクトリが見つからない: $CORE/roles"
[ -d "$CORE/codex" ] || die "codex ディレクトリが見つからない: $CORE/codex"
[ -f "$CORE/roles/$persona.md" ] || die "人物像の正典が見つからない: $CORE/roles/$persona.md"
[ -f "$CORE/codex/$persona.md" ] || die "Codex 起動定義が見つからない: $CORE/codex/$persona.md"

invocation_dir="$(pwd -P)"
if default_root="$(git -C "$invocation_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  default_root="$invocation_dir"
fi

root_input="$default_root"
log_path=""
resume_id=""
effort="high"
model=""
guard_enabled=1
mcp_enabled=0
notify_sock=""
task_files=()
task_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--file)
      [ "$#" -ge 2 ] || die "$1 には path が必要"
      task_files+=("$2")
      shift 2
      ;;
    -C|--cd)
      [ "$#" -ge 2 ] || die "$1 には dir が必要"
      root_input="$2"
      shift 2
      ;;
    --log)
      [ "$#" -ge 2 ] || die "$1 には path が必要"
      log_path="$2"
      shift 2
      ;;
    --resume)
      [ "$#" -ge 2 ] || die "$1 には session_id が必要"
      [[ "$2" =~ [^[:space:]] ]] || die "--resume に空文字は指定できない"
      resume_id="$2"
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || die "$1 には level が必要"
      effort="$2"
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || die "$1 には id が必要"
      model="$2"
      shift 2
      ;;
    --no-guard)
      guard_enabled=0
      shift
      ;;
    --mcp)
      mcp_enabled=1
      shift
      ;;
    --notify-sock)
      [ "$#" -ge 2 ] || die "$1 には path が必要"
      notify_sock="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      task_args+=("$@")
      break
      ;;
    -*) die "不明な option: $1" ;;
    *)
      task_args+=("$1")
      shift
      ;;
  esac
done

[ -n "$effort" ] || die "--effort に空文字は指定できない"
[ -d "$root_input" ] || die "作業ルートが見つからない: $root_input"
root="$(cd "$root_input" && pwd -P)"

if [ -n "$notify_sock" ]; then
  [ "$persona" = "kashiwagi" ] || die "--notify-sock は kashiwagi 専用(rulings #59 ── レビュアーの送信穴)"
  [ -S "$notify_sock" ] || die "--notify-sock が socket ではない: $notify_sock"
  notify_sock="$(cd "$(dirname "$notify_sock")" && pwd -P)/$(basename "$notify_sock")"
fi

git_repo=0
git_root=""
if git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"; then
  git_repo=1
fi
if [ "$git_repo" -eq 0 ]; then
  if [ "$persona" != "makabe" ] && [ "$guard_enabled" -eq 1 ]; then
    die "$persona は git リポジトリ外では起動できない。明示的に許可する場合は --no-guard を指定する: $root"
  fi
  echo "警告: git リポジトリ外のため、事後ガード無効で起動する。この実行では commit / push の検出も無効: $root" >&2
fi

for task_file in "${task_files[@]}"; do
  [ -f "$task_file" ] || die "タスクファイルが見つからない: $task_file"
  [ -r "$task_file" ] || die "タスクファイルを読めない: $task_file"
done

timestamp="$(date '+%Y%m%d-%H%M%S')"
agent_state_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}"
run_dir="$agent_state_dir/runs/$persona-$timestamp"
if [ -e "$run_dir" ]; then
  run_dir="$run_dir-$$"
fi
mkdir -p "$run_dir"

if [ -z "$log_path" ]; then
  log_path="$agent_state_dir/logs/$persona-$timestamp.log"
fi
mkdir -p "$(dirname "$log_path")"

task_path="$run_dir/task.md"
if [ "${#task_files[@]}" -eq 0 ] && [ "${#task_args[@]}" -eq 0 ]; then
  if [ -t 0 ]; then
    usage >&2
    exit 2
  fi
  cat > "$task_path"
else
  {
    for task_file in "${task_files[@]}"; do
      cat "$task_file"
      printf '\n'
    done
    if [ "${#task_args[@]}" -gt 0 ]; then
      printf '%s\n' "${task_args[*]}"
    fi
  } > "$task_path"
fi
LC_ALL=C grep -q '[^[:space:]]' "$task_path" || die "タスク本文が空白のみ"

prompt_path="$run_dir/prompt.md"
{
  cat "$CORE/roles/$persona.md"
  printf '\n\n'
  cat "$CORE/codex/$persona.md"
  printf '\n\n## 今回のタスク\n\n'
  cat "$task_path"
} > "$prompt_path"

mcp_args=()
if [ "$mcp_enabled" -eq 0 ]; then
  codex_config_dir="${CODEX_HOME:-$HOME/.codex}"
  codex_config="$codex_config_dir/config.toml"
  mcp_names_path="$run_dir/mcp-servers.txt"
  if [ -f "$codex_config" ]; then
    if command -v python3 >/dev/null 2>&1; then
      if ! python3 - "$codex_config" > "$mcp_names_path" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)
for name in config.get("mcp_servers", {}):
    print(name)
PY
      then
        die "MCP server 一覧を config.toml から読めない: $codex_config"
      fi
    else
      awk '
        /^\[mcp_servers\.[A-Za-z0-9_-]+\]$/ {
          name = $0
          sub(/^\[mcp_servers\./, "", name)
          sub(/\]$/, "", name)
          print name
        }
      ' "$codex_config" > "$mcp_names_path"
    fi

    while IFS= read -r mcp_name; do
      [ -n "$mcp_name" ] || continue
      [[ "$mcp_name" =~ ^[A-Za-z0-9_-]+$ ]] || die "override できない MCP server 名: $mcp_name"
      mcp_args+=(-c "mcp_servers.$mcp_name.enabled=false")
    done < "$mcp_names_path"
  fi
fi

permission_args=()
sandbox_cwd="$root"
case "$persona" in
  minase|makabe)
    permission_args+=(--dangerously-bypass-approvals-and-sandbox)
    ;;
  kashiwagi)
    if [ -n "$notify_sock" ]; then
      # rulings #59 ── 送信だけの穴。書けるのは宛先 socket 1本 + 空の scratch(+/tmp)だけで、
      # リポは物理的に書けないまま。-C を scratch へ差し替えるのはそのため(workspace-write は cwd を書ける)。
      # 事後ガードは元の root の git に対して従来どおり走る。
      # writable_roots はディレクトリ前提(bwrap が .git/.codex を合成 mount するため socket ファイル直指定は即死)。
      # 同一 tmpfs 上の私設ディレクトリへ socket を hardlink し、そのディレクトリだけを開ける ── 宛先1本限定。
      sandbox_cwd="$run_dir/sandbox-root"
      mkdir -p "$sandbox_cwd"
      notify_base="$(basename "$notify_sock")"
      notify_hole_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/codex-notify/${notify_base%.sock}-d"
      mkdir -p "$notify_hole_dir"
      ln -f "$notify_sock" "$notify_hole_dir/$notify_base" 2>/dev/null \
        || die "--notify-sock を hardlink できない(別 filesystem?): $notify_sock → $notify_hole_dir"
      permission_args+=(--sandbox workspace-write -c "sandbox_workspace_write.writable_roots=[\"$notify_hole_dir\"]")
    else
      permission_args+=(--sandbox read-only)
    fi
    ;;
esac

common_args=(
  "${permission_args[@]}"
  -c "model_reasoning_effort=\"$effort\""
  "${mcp_args[@]}"
  -C "$sandbox_cwd"
  -o "$run_dir/last-message.md"
)
if [ -n "$model" ]; then
  common_args+=(-m "$model")
fi
if [ "$git_repo" -eq 0 ] || [ "$sandbox_cwd" != "$root" ]; then
  # notify モード時は -C が scratch(非 git)なので trusted-directory 検査を跳ばす。
  # 事後ガードは元の root の git に対して従来どおり走る。
  common_args+=(--skip-git-repo-check)
fi

if [ -n "$resume_id" ]; then
  command_args=(codex exec "${common_args[@]}" resume "$resume_id" -)
else
  command_args=(codex exec "${common_args[@]}" -)
fi

if [ "${CODEX_AGENT_DRY_RUN:-0}" = "1" ]; then
  printf 'dry-run command:'
  printf ' %q' "${command_args[@]}"
  printf ' < %q\n' "$prompt_path"
  printf 'prompt: %s\n' "$prompt_path"
  printf 'prompt 行数: %s\n' "$(wc -l < "$prompt_path" | tr -d ' ')"
  exit 0
fi

declare -a repository_labels=(root)
declare -a repository_dirs=("$git_root")
declare -a repository_prefixes=("")
declare -a submodule_paths=()

# 直下のサブモジュールだけを列挙する。入れ子はガードの対象外。
load_direct_submodules() {
  local config_key submodule_path submodule_root

  [ "$git_repo" -eq 1 ] || return 0
  [ -f "$git_root/.gitmodules" ] || return 0
  while IFS= read -r config_key; do
    [ -n "$config_key" ] || continue
    submodule_path="$(git -C "$git_root" config -f .gitmodules --get "$config_key" 2>/dev/null || true)"
    [ -n "$submodule_path" ] || continue
    if ! submodule_root="$(git -C "$git_root/$submodule_path" rev-parse --show-toplevel 2>/dev/null)"; then
      continue
    fi
    submodule_paths+=("$submodule_path")
    repository_labels+=("$submodule_path")
    repository_dirs+=("$submodule_root")
    repository_prefixes+=("$submodule_path")
  done < <(git -C "$git_root" config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
}

is_direct_submodule_path() {
  local candidate="$1"
  local submodule_path
  for submodule_path in "${submodule_paths[@]}"; do
    [ "$candidate" != "$submodule_path" ] || return 0
  done
  return 1
}

hash_worktree_path() {
  local repo_dir="$1"
  local internal_path="$2"
  local absolute_path="$repo_dir/$internal_path"
  local hash_output

  if [ ! -e "$absolute_path" ] && [ ! -L "$absolute_path" ]; then
    printf '%s\n' 'HASH_MISSING'
  elif [ -L "$absolute_path" ]; then
    if ! hash_output="$(readlink -- "$absolute_path" 2>/dev/null)"; then
      printf '%s\n' 'HASH_UNAVAILABLE'
    elif command -v sha256sum >/dev/null 2>&1; then
      hash_output="$(printf '%s' "$hash_output" | sha256sum 2>/dev/null || true)"
      if [ -n "$hash_output" ]; then
        printf 'SYMLINK:%s\n' "${hash_output%% *}"
      else
        printf '%s\n' 'HASH_UNAVAILABLE'
      fi
    elif command -v shasum >/dev/null 2>&1; then
      hash_output="$(printf '%s' "$hash_output" | shasum -a 256 2>/dev/null || true)"
      if [ -n "$hash_output" ]; then
        printf 'SYMLINK:%s\n' "${hash_output%% *}"
      else
        printf '%s\n' 'HASH_UNAVAILABLE'
      fi
    else
      printf '%s\n' 'HASH_UNAVAILABLE'
    fi
  elif [ ! -f "$absolute_path" ] || [ ! -r "$absolute_path" ]; then
    printf '%s\n' 'HASH_UNAVAILABLE'
  elif command -v sha256sum >/dev/null 2>&1; then
    hash_output="$(sha256sum -- "$absolute_path" 2>/dev/null || true)"
    if [ -n "$hash_output" ]; then
      printf '%s\n' "${hash_output%% *}"
    else
      printf '%s\n' 'HASH_UNAVAILABLE'
    fi
  elif command -v shasum >/dev/null 2>&1; then
    hash_output="$(shasum -a 256 -- "$absolute_path" 2>/dev/null || true)"
    if [ -n "$hash_output" ]; then
      printf '%s\n' "${hash_output%% *}"
    else
      printf '%s\n' 'HASH_UNAVAILABLE'
    fi
  else
    printf '%s\n' 'HASH_UNAVAILABLE'
  fi
}

declare -A pre_status=()
declare -A pre_hash=()
declare -A pre_repo=()
declare -A pre_internal=()
declare -A post_status=()
declare -A post_hash=()
declare -A post_repo=()
declare -A post_internal=()

# ignored 一覧がこれを超える場合は、通常の追跡・未追跡だけを検査する。
IGNORED_PATH_LIMIT=2000
declare -A ignored_collection_skipped=()
declare -A ignored_warning_shown=()

record_snapshot_path() {
  local status_name="$1"
  local hash_name="$2"
  local repo_name="$3"
  local internal_name="$4"
  local repo_dir="$5"
  local prefix="$6"
  local internal_path="$7"
  local status="$8"
  local normalized_path="$internal_path"
  local -n status_ref="$status_name"
  local -n hash_ref="$hash_name"
  local -n repo_ref="$repo_name"
  local -n internal_ref="$internal_name"

  if [ -n "$prefix" ]; then
    normalized_path="$prefix/$internal_path"
  elif is_direct_submodule_path "$internal_path"; then
    return 0
  fi
  status_ref["$normalized_path"]="$status"
  hash_ref["$normalized_path"]="$(hash_worktree_path "$repo_dir" "$internal_path")"
  repo_ref["$normalized_path"]="$repo_dir"
  internal_ref["$normalized_path"]="$internal_path"
}

capture_repo_status() {
  local repo_dir="$1"
  local prefix="$2"
  local status_name="$3"
  local hash_name="$4"
  local repo_name="$5"
  local internal_name="$6"
  local entry status path original_path

  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    path="${entry:3}"
    record_snapshot_path "$status_name" "$hash_name" "$repo_name" "$internal_name" \
      "$repo_dir" "$prefix" "$path" "$status"
    if [[ "$status" = *R* ]] || [[ "$status" = *C* ]]; then
      if IFS= read -r -d '' original_path; then
        record_snapshot_path "$status_name" "$hash_name" "$repo_name" "$internal_name" \
          "$repo_dir" "$prefix" "$original_path" "$status (source)"
      fi
    fi
  done < <(git -C "$repo_dir" status --porcelain=v1 -z --untracked-files=all)
}

remove_ignored_snapshot_paths() {
  local repo_dir="$1"
  local status_name="$2"
  local hash_name="$3"
  local repo_name="$4"
  local internal_name="$5"
  local -n status_ref="$status_name"
  local -n hash_ref="$hash_name"
  local -n repo_ref="$repo_name"
  local -n internal_ref="$internal_name"
  local path

  for path in "${!status_ref[@]}"; do
    if [ "${repo_ref[$path]:-}" = "$repo_dir" ] && [ "${status_ref[$path]}" = '!!' ]; then
      unset 'status_ref[$path]' 'hash_ref[$path]' 'repo_ref[$path]' 'internal_ref[$path]'
    fi
  done
}

capture_repo_ignored() {
  local repo_dir="$1"
  local prefix="$2"
  local status_name="$3"
  local hash_name="$4"
  local repo_name="$5"
  local internal_name="$6"
  local entry status path
  local -a ignored_paths=()

  [ -z "${ignored_collection_skipped[$repo_dir]+present}" ] || return 0
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    [ "$status" = '!!' ] || continue
    ignored_paths+=("${entry:3}")
    if [ "${#ignored_paths[@]}" -gt "$IGNORED_PATH_LIMIT" ]; then
      ignored_collection_skipped["$repo_dir"]=1
      if [ -z "${ignored_warning_shown[$repo_dir]+present}" ]; then
        echo "警告: ignored 一覧が ${IGNORED_PATH_LIMIT} 件を超えたため収集を省略する: $repo_dir" >&2
        ignored_warning_shown["$repo_dir"]=1
      fi
      remove_ignored_snapshot_paths "$repo_dir" pre_status pre_hash pre_repo pre_internal
      remove_ignored_snapshot_paths "$repo_dir" post_status post_hash post_repo post_internal
      return 0
    fi
  done < <(git -C "$repo_dir" status --porcelain=v1 -z --untracked-files=all --ignored=matching)

  for path in "${ignored_paths[@]}"; do
    record_snapshot_path "$status_name" "$hash_name" "$repo_name" "$internal_name" \
      "$repo_dir" "$prefix" "$path" '!!'
  done
}

capture_all_status() {
  local status_name="$1"
  local hash_name="$2"
  local repo_name="$3"
  local internal_name="$4"
  local index

  for index in "${!repository_dirs[@]}"; do
    capture_repo_status "${repository_dirs[$index]}" "${repository_prefixes[$index]}" \
      "$status_name" "$hash_name" "$repo_name" "$internal_name"
    capture_repo_ignored "${repository_dirs[$index]}" "${repository_prefixes[$index]}" \
      "$status_name" "$hash_name" "$repo_name" "$internal_name"
  done
}

declare -A pre_refs=()
declare -A pre_reflog_head=()
declare -A pre_reflog_count=()
declare -A post_refs=()
declare -A post_reflog_head=()
declare -A post_reflog_count=()

capture_refs() {
  local refs_name="$1"
  local reflog_head_name="$2"
  local reflog_count_name="$3"
  local -n refs_ref="$refs_name"
  local -n reflog_head_ref="$reflog_head_name"
  local -n reflog_count_ref="$reflog_count_name"
  local index label repo_dir value
  local -a reflog_entries=()

  for index in "${!repository_dirs[@]}"; do
    label="${repository_labels[$index]}"
    repo_dir="${repository_dirs[$index]}"
    value="$(git -C "$repo_dir" show-ref --head 2>/dev/null || true)"
    refs_ref["$label"]="$value"
    mapfile -t reflog_entries < <(git -C "$repo_dir" reflog show --format='%H' HEAD 2>/dev/null || true)
    reflog_head_ref["$label"]="${reflog_entries[0]:-}"
    reflog_count_ref["$label"]="${#reflog_entries[@]}"
  done
}

if [ "$git_repo" -eq 1 ]; then
  load_direct_submodules
  capture_all_status pre_status pre_hash pre_repo pre_internal
  capture_refs pre_refs pre_reflog_head pre_reflog_count
fi

echo "[$persona] Codex 起動 root=$root log=$log_path"
set +e
if command -v stdbuf >/dev/null 2>&1; then
  stdbuf -oL -eL "${command_args[@]}" < "$prompt_path" 2>&1 | stdbuf -oL tee "$log_path"
else
  "${command_args[@]}" < "$prompt_path" 2>&1 | tee "$log_path"
fi
pipeline_status=("${PIPESTATUS[@]}")
set -e
codex_status="${pipeline_status[0]:-1}"
tee_status="${pipeline_status[1]:-0}"

session_id="$(sed -nE 's/.*session id:[[:space:]]*([0-9a-fA-F-]{36}).*/\1/p' "$log_path" 2>/dev/null | head -n 1 || true)"
if [ -z "$session_id" ]; then
  session_id="不明"
fi
printf '%s\n' "$session_id" > "$run_dir/session_id"
echo "session_id: $session_id"

changed_files=()
violations=()
if [ "$git_repo" -eq 1 ]; then
  capture_all_status post_status post_hash post_repo post_internal
  capture_refs post_refs post_reflog_head post_reflog_count

  # 実行前から dirty なパスが clean になっても比較できるよう、実行後のハッシュを取る。
  for path in "${!pre_status[@]}"; do
    if [ -z "${post_status[$path]+present}" ]; then
      post_status["$path"]="  "
      post_repo["$path"]="${pre_repo[$path]}"
      post_internal["$path"]="${pre_internal[$path]}"
      post_hash["$path"]="$(hash_worktree_path "${pre_repo[$path]}" "${pre_internal[$path]}")"
    fi
  done

  for path in "${!post_status[@]}"; do
    if [ -z "${pre_status[$path]+present}" ] \
      || [ "${pre_status[$path]}" != "${post_status[$path]}" ] \
      || [ "${pre_hash[$path]:-}" != "${post_hash[$path]}" ]; then
      changed_files+=("$path")
    fi
  done
  for path in "${!pre_status[@]}"; do
    if [ -z "${post_status[$path]+present}" ]; then
      changed_files+=("$path")
    fi
  done

  declare -A changed_seen=()
  deduplicated_changes=()
  for path in "${changed_files[@]}"; do
    if [ -z "${changed_seen[$path]+present}" ]; then
      changed_seen["$path"]=1
      deduplicated_changes+=("$path")
    fi
  done
  changed_files=("${deduplicated_changes[@]}")

  if [ "${#changed_files[@]}" -gt 0 ]; then
    printf '%s\n' "${changed_files[@]}" > "$run_dir/changed-files.txt"
  else
    : > "$run_dir/changed-files.txt"
  fi

  if [ "$guard_enabled" -eq 1 ]; then
    for path in "${changed_files[@]}"; do
      case "$persona" in
        minase)
          # Markdown だけを書き込み可とする。docs/_sessions は途中階層でも照合し、
          # docs/x.lua のような非 Markdown コードは許可リストへ入れない。
          case "$path" in
            *.md) ;;
            docs|*/docs|_sessions|*/_sessions) ;;
            *) violations+=("変更禁止: $path") ;;
          esac
          ;;
        makabe) ;;
        kashiwagi) violations+=("変更禁止: $path") ;;
      esac
    done

    for label in "${repository_labels[@]}"; do
      if [ "${pre_refs[$label]:-}" != "${post_refs[$label]:-}" ]; then
        violations+=("ref 変化を検出: $label")
      fi
      if [ "${pre_reflog_head[$label]:-}" != "${post_reflog_head[$label]:-}" ] \
        || [ "${pre_reflog_count[$label]:-0}" != "${post_reflog_count[$label]:-0}" ]; then
        violations+=("HEAD reflog 変化を検出: $label (${pre_reflog_head[$label]:-不明}/${pre_reflog_count[$label]:-0} -> ${post_reflog_head[$label]:-不明}/${post_reflog_count[$label]:-0})")
      fi
    done
  fi
fi

guard_status=0
if [ "${#violations[@]}" -gt 0 ]; then
  guard_status=3
  echo "権限逸脱"
  printf '  - %s\n' "${violations[@]}"
fi

if [ "$git_repo" -eq 1 ]; then
  echo "git diff --stat"
  git -C "$git_root" diff --stat || true
  for index in "${!repository_dirs[@]}"; do
    [ "$index" -ne 0 ] || continue
    echo "git -C ${repository_labels[$index]} diff --stat"
    git -C "${repository_dirs[$index]}" diff --stat || true
  done
fi

echo "persona: $persona"
echo "session_id: $session_id"
echo "log: $log_path"
if [ "$git_repo" -eq 1 ]; then
  echo "変更ファイル数: ${#changed_files[@]}"
else
  echo "変更ファイル数: 0 (非 git のため未計測)"
fi

# 権限逸脱を最優先し、それがなければ Codex / tee の失敗を返す。
if [ "$guard_status" -ne 0 ]; then
  exit 3
fi
if [ "$codex_status" -ne 0 ]; then
  exit "$codex_status"
fi
if [ "$tee_status" -ne 0 ]; then
  exit "$tee_status"
fi
exit 0
