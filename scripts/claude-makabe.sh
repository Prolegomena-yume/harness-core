#!/usr/bin/env bash
# 真壁[IM]を Claude sonnet(effort high)で起こすランチャ ── codex weekly 逼迫時の実装代替経路。
# 役員 人見「リセットを待つ択は無い」、docs/delegation.md の枠の規則「codex が減りすぎ → 実装は庵野
# (この時だけ柏木のゲートを通す)」の実装。庵野 2026-09-22 作成、claude-kashiwagi.sh と同じ型。
#
# 契約は codex-agent.sh makabe(gpt-6-luna 経路)と同じ入出力を保つ:
#   - -f <task.md> でタスク本文、-C で作業ルート(worktree)、--log、--dry-run
#   - footer は codex 経路と同じ字面で `変更ファイル数:` と `makabe_commit_sha:` を出す
#     (起動時と終了時の worktree の HEAD を比較するだけ。checkpoint commit も squash 後の 1 本も拾う、H1)
#   - --model <id> は受けるが記録だけ(sol 指定の巡が来ても、この経路では常に sonnet を使う)
#
# 差分(意図的):
#   - engine は claude -p --model <MAKABE_CLAUDE_MODEL> --effort <MAKABE_CLAUDE_EFFORT>
#     --dangerously-skip-permissions(既定値は scripts/models.env、2026-09-24 時点で claude-sonnet-5 / high。
#     codex の --dangerously-bypass-approvals-and-sandbox に相当)。
#   - **PreToolUse hook(worktree-guard-claude-makabe.sh)で Write/Edit/NotebookEdit と Bash 経由の
#     書き込みの両方を作業ルートの外(~/.codex-agents/**・~/canonical/**・~/.claude/**・~/.codex/**・
#     ~/bin/**)へは block する**(--dangerously-skip-permissions 下では acceptEdits の cwd スコープが
#     効かないため、hook が唯一の担保。claude-kashiwagi の worktree-guard-claude.sh と同じ縛りを
#     Write/Edit/NotebookEdit にも広げた形)。
#   - commit は `git-as makabe commit ...`(GIT_AUTHOR/COMMITTER を真壁に固定、codex-agent.sh と同じ)。
#   - 巡ループ・ゲート番号の概念を持たない(makabe は codex 版でも supports_loop=0)。--resume は受けない
#     ── 続きは贄川が新しい指示書(前 run の sha を明記)で起こし直す(codex/makabe.md の「終端の見方」)。
#
# env:
#   MAKABE_MODEL(渡されても記録のみ、実際は常に models.env の MAKABE_CLAUDE_MODEL) /
#   MAKABE_EFFORT(既定は models.env の MAKABE_CLAUDE_EFFORT)
#
# 使い方: claude-makabe.sh [-C dir] -f <task.md> [--log path] [--model id] [--effort level] [--dry-run]
# -f は複数可(codex-agent.sh と同じ、末尾のファイルを task 本文として読む)。task 引数(-f 以外)も付けられる。

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: claude-makabe.sh [options] [task...]

options:
  -f, --file <path>   タスク本文をファイルから読む。複数指定可
  -C, --cd <dir>       作業ルート(既定: 起動時ディレクトリの git toplevel)
      --log <path>     ログ出力先
      --model <id>     記録のみ(この経路では常に claude sonnet を使う。env MAKABE_MODEL でも指定可)
      --effort <level> reasoning effort(既定 high、env MAKABE_EFFORT でも指定可)
      --dry-run        起動コマンドを組み立てて stdout に出し、claude を起動せず exit 0(検算用)
  -h, --help           この usage を表示

task と --file が無い場合は標準入力からタスク本文を読む。
--resume / --rounds は無い(1 起動 = 1 session、makabe は元々巡ループを持たない)。

起動時の run_dir(${CODEX_AGENT_STATE_DIR:-~/.codex-agents}/runs/makabe-<ts>-<pid>-<rand>)を
CODEX_AGENT_RUN_DIR で export する。起動時に `rates claude` を 1 回叩いて <run_dir>/rates.json に残す。
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

script_path="$(resolve_self)"
CORE="$(dirname "$(dirname "$script_path")")"
# shellcheck source=models.env
source "$CORE/scripts/models.env"
[ -f "$CORE/roles/makabe.md" ] || die "人物像の正典が見つからない: $CORE/roles/makabe.md"
[ -f "$CORE/claude/makabe.md" ] || die "Claude 起動契約が見つからない: $CORE/claude/makabe.md"

command -v claude >/dev/null 2>&1 || die 'claude が見つからない。PATH を確認してください'
command -v python3 >/dev/null 2>&1 || die 'JSON 解析に必要な python3 が見つからない'

invocation_dir="$(pwd -P)"
if default_root="$(git -C "$invocation_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  default_root="$invocation_dir"
fi

root_input="$default_root"
log_path=""
model_requested="${MAKABE_MODEL:-}"
effort="${MAKABE_EFFORT:-$MAKABE_CLAUDE_EFFORT}"
task_files=()
task_args=()
dry_run=0

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
    --model)
      [ "$#" -ge 2 ] || die "$1 には id が必要"
      model_requested="$2"
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || die "$1 には level が必要"
      effort="$2"
      shift 2
      ;;
    --resume|--rounds)
      die "$1 はこの経路(claude-makabe)では受けない ── 続きは新しい指示書で起こし直す"
      ;;
    --dry-run)
      dry_run=1
      shift
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

# この経路は常に Claude sonnet を使う。--model / MAKABE_MODEL で別 id(gpt-6-sol 等)が来ても
# 無視して sonnet を使い、要求は記録だけ残す(claude-niekawa.sh の round prompt に既に「claude 経路では
# 無視して sonnet でよい、記録だけ」と明記されている)。
model="$MAKABE_CLAUDE_MODEL"

git_repo=0
git_root=""
if git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"; then
  git_repo=1
fi
[ "$git_repo" -eq 1 ] || die "claude-makabe は git リポジトリ外では起動できない: $root"

for task_file in "${task_files[@]}"; do
  [ -f "$task_file" ] || die "タスクファイルが見つからない: $task_file"
  [ -r "$task_file" ] || die "タスクファイルを読めない: $task_file"
done

timestamp="$(date '+%Y%m%d-%H%M%S')"
agent_state_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}"
run_id="makabe-$timestamp-$$-$RANDOM"
run_dir="$agent_state_dir/runs/$run_id"
mkdir -p "$run_dir"
run_dir="$(cd -P "$run_dir" && pwd)"

log_path_was_default=0
if [ -z "$log_path" ]; then
  log_path="$agent_state_dir/logs/$run_id.log"
  log_path_was_default=1
fi
mkdir -p "$(dirname "$log_path")"
if [ "$log_path_was_default" -eq 1 ]; then
  : > "$log_path" 2>/dev/null || true
fi

if command -v rates >/dev/null 2>&1; then
  if ! rates claude > "$run_dir/rates.json" 2>"$run_dir/rates.err"; then
    echo "警告: rates claude の取得に失敗した(続行): $(tr '\n' ' ' < "$run_dir/rates.err")" >&2
    rm -f "$run_dir/rates.json"
  fi
else
  echo "警告: rates コマンドが見つからない(続行)" >&2
fi

export CODEX_AGENT_RUN_DIR="$run_dir"

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

role_content=""
if [ -f "$CORE/roles/makabe.md" ]; then
  role_content="$(cat "$CORE/roles/makabe.md")"
fi
claude_contract=""
if [ -f "$CORE/claude/makabe.md" ]; then
  claude_contract="$(cat "$CORE/claude/makabe.md")"
fi
codex_contract=""
if [ -f "$CORE/codex/makabe.md" ]; then
  # 受け方・commit 規律・exec の作法・出力契約は codex/makabe.md が正典(claude/makabe.md は差分だけ持つ)。
  codex_contract="$(cat "$CORE/codex/makabe.md")"
fi
system_prompt="$role_content"
if [ -n "$codex_contract" ]; then
  system_prompt="$system_prompt
$codex_contract"
fi
if [ -n "$claude_contract" ]; then
  system_prompt="$system_prompt
$claude_contract"
fi

git_name="真壁"
export GIT_AUTHOR_NAME="$git_name" GIT_COMMITTER_NAME="$git_name"
export GIT_AUTHOR_EMAIL="makabe@ai.yumemism.dev" GIT_COMMITTER_EMAIL="makabe@ai.yumemism.dev"

# 作業ルートの外への書き込みを block する hook(Write/Edit/NotebookEdit + Bash、carve-out は常時有効)。
export CLAUDE_MAKABE_ROOT="$root"
hooks_dir="$CORE/scripts/hooks"
settings_path="$run_dir/settings.json"
python3 - "$hooks_dir" "$settings_path" <<'PY'
import json
import sys

hooks_dir, out_path = sys.argv[1], sys.argv[2]
guard = f"{hooks_dir}/worktree-guard-claude-makabe.sh"
settings = {
    "hooks": {
        "PreToolUse": [
            {
                "matcher": "Write",
                "hooks": [{"type": "command", "command": guard, "timeout": 10}],
            },
            {
                "matcher": "Edit",
                "hooks": [{"type": "command", "command": guard, "timeout": 10}],
            },
            {
                "matcher": "NotebookEdit",
                "hooks": [{"type": "command", "command": guard, "timeout": 10}],
            },
            {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": guard, "timeout": 10}],
            },
        ],
    }
}
with open(out_path, "w") as f:
    json.dump(settings, f, ensure_ascii=False, indent=2)
PY

prompt_lines_path="$run_dir/prompt.md"
{
  printf '真壁として、この経路(claude-makabe、Claude sonnet, effort %s)で起こされた。1 起動 = 1 session、巡ループは無い。\n' "$effort"
  printf 'run_dir: %s\n' "$run_dir"
  printf '作業ルート(-C): %s\n' "$root"
  if [ -n "$model_requested" ] && [ "$model_requested" != "$MAKABE_CLAUDE_MODEL" ]; then
    printf '\n(注記: --model %s が指定されたが、この経路では常に %s を使う。記録のみ)\n' "$model_requested" "$MAKABE_CLAUDE_MODEL"
  fi
  printf '\n## 今回のタスク\n\n'
  cat "$task_path"
} > "$prompt_lines_path"
prompt_size="$(wc -c < "$prompt_lines_path" | tr -d ' ')"
if [ "$prompt_size" -gt 102400 ]; then
  prompt_arg="まず $prompt_lines_path を読む"
else
  prompt_arg="$(cat "$prompt_lines_path")"
fi

if [ "$dry_run" -eq 1 ]; then
  echo "[makabe/claude] dry-run root=$root run_dir=$run_dir model=$model effort=$effort model_requested=${model_requested:-(無し)}"
  echo "[makabe/claude] settings: $settings_path"
  echo "--- prompt ---"
  cat "$prompt_lines_path"
  exit 0
fi

pre_status="$(git -C "$root" status --porcelain=v1 --untracked-files=all 2>/dev/null | LC_ALL=C sort -u)"
pre_head="$(git -C "$git_root" rev-parse --verify HEAD 2>/dev/null || true)"
pre_main_head="$(git -C "$git_root" rev-parse --verify refs/heads/main 2>/dev/null || true)"
pre_master_head="$(git -C "$git_root" rev-parse --verify refs/heads/master 2>/dev/null || true)"

echo "[makabe/claude] Claude 起動 root=$root log=$log_path model=$model effort=$effort"

round_json="$run_dir/last.json"
stderr_log="$run_dir/stderr.log"
current_child_pid=""
claude_status=0

on_term() {
  echo "[makabe/claude] SIGTERM/SIGINT を受けた" >&2
  if [ -n "$current_child_pid" ]; then
    kill -TERM -- "-$current_child_pid" 2>/dev/null || kill -TERM "$current_child_pid" 2>/dev/null || true
  fi
  exit 3
}
trap on_term TERM INT

claude_args=(claude -p --model "$model" --effort "$effort" --dangerously-skip-permissions)
claude_args+=(--output-format json --append-system-prompt "$system_prompt" --settings "$settings_path" -- "$prompt_arg")

set +e
setsid bash -c 'cd "$1" || exit 91; shift; exec "$@"' _ "$root" "${claude_args[@]}" \
  < /dev/null > "$round_json" 2>"$stderr_log" &
current_child_pid=$!
wait "$current_child_pid"
claude_status=$?
current_child_pid=""
set -e

{
  echo "=== claude stdout(json) ==="
  cat "$round_json"
  echo
  if [ -s "$stderr_log" ]; then
    echo "=== claude stderr ==="
    cat "$stderr_log"
  fi
} >> "$log_path"

session_id="不明"
is_error=0
parse_err="$run_dir/parse.err"
if python3 - "$round_json" "$run_dir/parse.env" > "$run_dir/last-message.md" 2>"$parse_err"; then
  :
else
  echo "警告: Claude JSON を解析できない(parse.err 参照)" >&2
fi <<'PY'
import json
import sys

json_path, env_path = sys.argv[1], sys.argv[2]
try:
    with open(json_path) as f:
        data = json.load(f)
    session_id = data.get("session_id", "") or ""
    is_error = bool(data.get("is_error", False))
    result = data.get("result", "") or ""
except (OSError, ValueError) as error:
    sys.stderr.write(f"Claude JSON を解析できない: {error}\n")
    with open(env_path, "w") as f:
        f.write("session_id=不明\nis_error=1\n")
    sys.exit(1)
with open(env_path, "w") as f:
    f.write(f"session_id={session_id or '不明'}\n")
    f.write(f"is_error={1 if is_error else 0}\n")
print(result, end="")
PY

if [ -f "$run_dir/parse.env" ]; then
  # shellcheck disable=SC1091
  source "$run_dir/parse.env"
  is_error="${is_error:-0}"
fi
printf '%s\n' "$session_id" > "$run_dir/session_id"

# 変更ファイル数 ── 作業木の status 差分(comm -3)と、HEAD が動いた場合の commit 済み差分の両方を見る
# (checkpoint commit / squash で worktree が clean に戻ると status 差分だけでは拾えないため、H1 の形に
# 合わせて codex-agent.sh と同じ理屈を単一リポジトリ向けに簡略化して持つ)。
post_status="$(git -C "$root" status --porcelain=v1 --untracked-files=all 2>/dev/null | LC_ALL=C sort -u)"
post_head="$(git -C "$git_root" rev-parse --verify HEAD 2>/dev/null || true)"

declare -A changed_seen=()
changed_files=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path="${line:3}"
  if [ -z "${changed_seen[$path]+present}" ]; then
    changed_seen["$path"]=1
    changed_files+=("$path")
  fi
done < <(comm -3 <(printf '%s\n' "$pre_status") <(printf '%s\n' "$post_status") | sed '/^$/d')

if [ -n "$post_head" ] && [ "$post_head" != "$pre_head" ]; then
  before_head="$pre_head"
  if [ -z "$before_head" ]; then
    before_head="$(git -C "$git_root" hash-object -t tree /dev/null)"
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -z "${changed_seen[$path]+present}" ]; then
      changed_seen["$path"]=1
      changed_files+=("$path")
    fi
  done < <(git -C "$git_root" diff --name-only --no-renames "$before_head" "$post_head" 2>/dev/null || true)
fi

if [ "${#changed_files[@]}" -gt 0 ]; then
  printf '%s\n' "${changed_files[@]}" > "$run_dir/changed-files.txt"
else
  : > "$run_dir/changed-files.txt"
fi

# 事後ガード ── main/master の HEAD 移動(push 相当)だけを見る。作業ルートの外への書き込みは
# worktree-guard-claude-makabe.sh が実行前に block している(こちらは事後の確認)。
post_main_head="$(git -C "$git_root" rev-parse --verify refs/heads/main 2>/dev/null || true)"
post_master_head="$(git -C "$git_root" rev-parse --verify refs/heads/master 2>/dev/null || true)"
violations=()
if [ "$pre_main_head" != "$post_main_head" ]; then
  violations+=("ref 変化を検出: refs/heads/main")
fi
if [ "$pre_master_head" != "$post_master_head" ]; then
  violations+=("ref 変化を検出: refs/heads/master")
fi

echo "persona: makabe"
echo "engine: claude"
echo "session_id: $session_id"
echo "run_dir: $run_dir"
echo "log: $log_path"
echo "git diff --stat"
git -C "$git_root" diff --stat || true
echo "変更ファイル数: ${#changed_files[@]}"

# 真壁の終端に commit sha を機械可読な行で載せる(役員 人見 2026-09-21、H1。codex-agent.sh と同じ理屈 ──
# 起動時と終了時の worktree の HEAD を比較するだけ。squash 前の checkpoint commit も、squash 後の
# 1 本も、同じ理屈で拾う)。
if [ -n "$post_head" ] && [ "$post_head" != "$pre_head" ]; then
  echo "makabe_commit_sha: $post_head"
else
  echo "makabe_commit_sha: (無し)"
fi

if [ "${#violations[@]}" -gt 0 ]; then
  echo "権限逸脱"
  printf '  - %s\n' "${violations[@]}"
  exit 3
fi
if [ "$claude_status" -ne 0 ]; then
  exit "$claude_status"
fi
if [ "$is_error" = "1" ]; then
  exit 1
fi
exit 0
