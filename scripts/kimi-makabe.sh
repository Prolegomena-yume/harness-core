#!/usr/bin/env bash
# 真壁[IM]を Kimi K3(kimi-code CLI、`kimi -p`)で起こすランチャ ── 贄川を通さない直書き便の経路。
# 役員 人見 2026-09-29「MuseArch www の画面を本物のフロントに組む便は直書き(真壁 → 柏木 Opus ゲート 2 を 1 回)、
# 真壁は K3 で回す」(Claude weekly 残 15%、kimi 残 94%)の実装。庵野 2026-09-29 作成。
# 呼び方・run_dir・footer は claude-makabe.sh に揃え、kimi の起動と出力の読み方は kimi-niekawa.sh から取った。
#
# 契約は claude-makabe.sh / codex-agent.sh makabe と同じ入出力を保つ:
#   - -f <task.md> でタスク本文、-C で作業ルート(worktree)、--log、--dry-run
#   - footer は同じ字面で `変更ファイル数:` と `makabe_commit_sha:` を出す(起動時と終了時の HEAD を比較するだけ)。
#     加えてこの経路だけ `makabe_terminal:`(完了 / 詰まり / 未達)と `makabe_stuck:` を出す(下記)
#   - --model <id> は受けるが記録だけ(実際は常に models.env の MAKABE_KIMI_MODEL)
#
# 差分(意図的):
#   - engine は `kimi -p <prompt> --agent-file <run_dir>/agent.md -m <MAKABE_KIMI_MODEL> --output-format stream-json`。
#     人格・規律(roles/makabe.md + codex/makabe.md + kimi/makabe.md)は agent.md の system prompt(`${base_prompt}` の後)へ。
#     tools は Bash / Read / Write / Edit / Glob / Grep の 6 つ(kimi 内部の子 Agent は渡さない)。
#   - **hook は config.toml の [[hooks]](全 kimi 共通)を使う**。run 単位に hook を足す口が kimi に無いので、
#     既存の gate-guard.sh(PreToolUse)/ verdict-stop.sh(Stop)が env KIMI_MAKABE_ROOT を見て
#     worktree-guard-kimi-makabe.sh / commit-stop-kimi-makabe.sh へ分岐する。config.toml は触らない。
#   - **終端が 3 つ**(`makabe_terminal:`): 完了(HEAD が動いた = checkpoint commit / squash まで届いた)/
#     詰まり($run_dir/stuck.md がある ── 矛盾・要確認・外部要因で完了条件に届かない)/ 未達(どちらも無い ──
#     kimi の異常終了、5 時間枠切れ、SIGTERM)。claude 版は詰まりを最終メッセージの行頭で見るが、kimi の Stop hook の
#     stdin には最終メッセージが無いので、stuck.md(run_dir の中、hook がこの 1 ファイルだけ書き込みを許す)に置く。
#   - main / master の上では起動しない(claude 版は事後に権限逸脱で見るだけ)。
#   - commit は `git-as makabe commit ...`(GIT_AUTHOR/COMMITTER を真壁に固定、claude 版と同じ)。
#   - 巡ループ・ゲート番号を持たない。--resume は受けない ── 続きは新しい指示書(前 run の sha を明記)で起こし直す。
#   - unit-wrap(systemd --user の独立 service 化)はしない(claude-makabe.sh と同じ)。
#
# env:
#   MAKABE_MODEL(渡されても記録のみ) / MAKABE_KIMI_MODEL(models.env の既定を上書き) /
#   MAKABE_EFFORT(記録のみ ── kimi -p に effort を渡す手段が無い)
#
# 使い方: kimi-makabe.sh [-C dir] -f <task.md> [--log path] [--model id] [--effort level] [--dry-run]

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: kimi-makabe.sh [options] [task...]

options:
  -f, --file <path>   タスク本文をファイルから読む。複数指定可
  -C, --cd <dir>       作業ルート(既定: 起動時ディレクトリの git toplevel)。main / master の上では起動しない
      --log <path>     ログ出力先(既定 ~/.codex-agents/logs/<run_id>.log)
      --model <id>     記録のみ(この経路では常に models.env の MAKABE_KIMI_MODEL = K3 を使う。env MAKABE_MODEL でも指定可)
      --effort <level> low|high|max(既定 high)。kimi -p に渡す手段が無く記録のみ(config.toml の既定 high が効く)
      --dry-run        agent.md と prompt を組み立てて stdout に出し、kimi を起動せず exit 0(検算用)
  -h, --help           この usage を表示

task と --file が無い場合は標準入力からタスク本文を読む。
--resume / --rounds は無い(1 起動 = 1 session、続きは新しい指示書で起こし直す)。

起動時の run_dir(${CODEX_AGENT_STATE_DIR:-~/.codex-agents}/runs/makabe-<ts>-<pid>-<rand>)を CODEX_AGENT_RUN_DIR で export する。
run_dir の中: task.md / prompt.md / agent.md / rates.json / stream.jsonl / stderr.log / last-message.md / session_id /
changed-files.txt / pre_head.txt / pid(launcher)/ kimi.pid / stuck.md(真壁が詰まったときだけ)。

終端は footer の `makabe_terminal:` で読む ── 完了(commit まで届いた)/ 詰まり(stuck.md、理由が 1 行目)/ 未達
(kimi の異常終了・枠切れ・SIGTERM。指示を差し替えず同じ指示書で起こし直す)。`makabe_commit_sha:` と
`変更ファイル数:` は claude-makabe と同じ字面。箱(to-takano)には何も post しない ── Bash の run_in_background で起こして
終了の通知を待ち、footer を読む(`from-niekawa --wait` は箱の見張りなので使えない)。

注意: K3 の 5 時間の利用上限(403 "5-hour usage limit")は並列で一気に食う。**同時に走らせるのは 2 本まで**
(kimi-niekawa の便と合わせて 2 本まで)。2 本以上の走行中の run があると起動時に警告を出す。
kimi の Bash tool は 300 秒を超えると kill されず裏へ回る(待つ手段が無い)── 長い build / test の待ち方は kimi/makabe.md にある。
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
[ -f "$CORE/kimi/makabe.md" ] || die "Kimi 起動契約が見つからない: $CORE/kimi/makabe.md"
[ -x "$CORE/scripts/hooks/worktree-guard-kimi-makabe.sh" ] || die "hook が見つからないか実行できない: $CORE/scripts/hooks/worktree-guard-kimi-makabe.sh"
[ -x "$CORE/scripts/hooks/commit-stop-kimi-makabe.sh" ] || die "hook が見つからないか実行できない: $CORE/scripts/hooks/commit-stop-kimi-makabe.sh"

model="$MAKABE_KIMI_MODEL"

invocation_dir="$(pwd -P)"
if default_root="$(git -C "$invocation_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  default_root="$invocation_dir"
fi

root_input="$default_root"
log_path=""
model_requested="${MAKABE_MODEL:-}"
effort="${MAKABE_EFFORT:-high}"
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
      die "$1 はこの経路(kimi-makabe)では受けない ── 続きは新しい指示書で起こし直す"
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

case "$effort" in
  low|high|max) ;;
  *) die "--effort は low|high|max のどれか: $effort" ;;
esac
if [ "$effort" != high ]; then
  echo "警告: kimi -p に effort を渡す手段が無い(config.toml の $model 既定 high が使われる。指定値 $effort は記録のみ)" >&2
fi

command -v kimi >/dev/null 2>&1 || die 'kimi が見つからない。PATH を確認してください'
command -v jq >/dev/null 2>&1 || die 'stream-json の解析に必要な jq が見つからない'

[ -d "$root_input" ] || die "作業ルートが見つからない: $root_input"
root="$(cd "$root_input" && pwd -P)"

git_root=""
git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || die "kimi-makabe は git リポジトリ外では起動できない: $root"

current_branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)"
case "$current_branch" in
  main|master) die "作業ルートが $current_branch の上にある: $root ── 作業 branch の worktree を -C に渡す(main / master には触らない)" ;;
esac

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
printf '%s\n' "$$" > "$run_dir/pid"
printf 'kimi\n' > "$run_dir/engine"

log_path_was_default=0
if [ -z "$log_path" ]; then
  log_path="$agent_state_dir/logs/$run_id.log"
  log_path_was_default=1
fi
mkdir -p "$(dirname "$log_path")"
if [ "$log_path_was_default" -eq 1 ]; then
  : > "$log_path" 2>/dev/null || true
fi

# 走行中の kimi-makabe(engine=kimi の run の pid が生きている)を数え、2 本以上なら警告する
# (5 時間枠を並列で一気に食うため。止めはしない ── 判断は鷹野)。
alive_kimi_runs=0
for other in "$agent_state_dir"/runs/makabe-*/; do
  [ -f "$other/engine" ] && [ "$(cat "$other/engine" 2>/dev/null)" = kimi ] || continue
  [ "${other%/}" = "$run_dir" ] && continue
  other_pid="$(cat "$other/kimi.pid" 2>/dev/null || true)"
  [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null && alive_kimi_runs=$((alive_kimi_runs + 1))
done
if [ "$alive_kimi_runs" -ge 2 ]; then
  echo "警告: 走行中の kimi-makabe が既に $alive_kimi_runs 本ある。K3 の 5 時間枠は並列で一気に食う(2 本までが目安)" >&2
fi

if command -v rates >/dev/null 2>&1; then
  if ! rates kimi > "$run_dir/rates.json" 2>"$run_dir/rates.err"; then
    echo "警告: rates kimi の取得に失敗した(続行): $(tr '\n' ' ' < "$run_dir/rates.err")" >&2
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

role_content="$(cat "$CORE/roles/makabe.md")"
codex_contract=""
if [ -f "$CORE/codex/makabe.md" ]; then
  # 受け方・commit 規律・exec の作法・出力契約は codex/makabe.md が正典(kimi/makabe.md は差分だけ持つ)。
  codex_contract="$(cat "$CORE/codex/makabe.md")"
fi
kimi_contract="$(cat "$CORE/kimi/makabe.md")"

git_name="真壁"
export GIT_AUTHOR_NAME="$git_name" GIT_COMMITTER_NAME="$git_name"
export GIT_AUTHOR_EMAIL="makabe@ai.yumemism.dev" GIT_COMMITTER_EMAIL="makabe@ai.yumemism.dev"

# hook の分岐キー(gate-guard.sh / verdict-stop.sh がこの env を見る)。kimi が hook を spawn するとき
# process.env を引き継ぐ(2026-09-29 実測)ので、export しておけば hook に届く。
export KIMI_MAKABE_ROOT="$root"
# 贄川の便から起こされた場合に、贄川用の gate-guard の判定が混ざらないようにする。
unset NIEKAWA_INBOX

stuck_path="$run_dir/stuck.md"

# agent.md ── kimi の --agent-file。frontmatter は name / description / tools だけ。
# 文字どおりの ${base_prompt} トークンを書く(kimi が既定の system prompt を残す構文。展開しない)。
agent_path="$run_dir/agent.md"
{
  printf -- '---\n'
  printf 'name: makabe\n'
  printf 'description: 真壁 IM ── 実装(Kimi K3、直書き経路)\n'
  printf 'tools: [Bash, Read, Write, Edit, Glob, Grep]\n'
  printf -- '---\n'
  # shellcheck disable=SC2016
  printf '%s\n\n' '${base_prompt}'
  printf '%s\n\n' "$role_content"
  if [ -n "$codex_contract" ]; then
    printf '%s\n\n' "$codex_contract"
  fi
  printf '%s\n' "$kimi_contract"
} > "$agent_path"

prompt_lines_path="$run_dir/prompt.md"
{
  printf '真壁として、この経路(kimi-makabe、Kimi K3 %s)で起こされた。1 起動 = 1 session、巡ループは無い。贄川は居ない ── 報告先は起こした鷹野。\n' "$model"
  printf 'run_dir: %s\n' "$run_dir"
  printf '作業ルート(-C): %s\n' "$root"
  printf '停止理由の置き場(詰まったときだけ書く): %s\n' "$stuck_path"
  printf 'commit trailer の Model: %s\n' "$model"
  if [ -n "$model_requested" ] && [ "$model_requested" != "$model" ]; then
    printf '\n(注記: --model %s が指定されたが、この経路では常に %s を使う。記録のみ)\n' "$model_requested" "$model"
  fi
  printf '\n## 今回のタスク\n\n'
  cat "$task_path"
} > "$prompt_lines_path"
prompt_size="$(wc -c < "$prompt_lines_path" | tr -d ' ')"
# kimi -p の argv は 128KB で落ちる。100KB を超えたらファイルに置いて読ませる。
if [ "$prompt_size" -gt 102400 ]; then
  prompt_arg="まず $prompt_lines_path を読む"
else
  prompt_arg="$(cat "$prompt_lines_path")"
fi

if [ "$dry_run" -eq 1 ]; then
  echo "[makabe/kimi] dry-run root=$root run_dir=$run_dir model=$model effort=$effort model_requested=${model_requested:-(無し)}"
  echo "[makabe/kimi] agent: $agent_path($(wc -c < "$agent_path" | tr -d ' ') bytes)"
  echo "[makabe/kimi] argv: kimi -p <${#prompt_arg} chars> --agent-file $agent_path -m $model --output-format stream-json"
  echo "--- prompt ---"
  cat "$prompt_lines_path"
  exit 0
fi

pre_status="$(git -C "$root" status --porcelain=v1 --untracked-files=all 2>/dev/null | LC_ALL=C sort -u)"
pre_head="$(git -C "$git_root" rev-parse --verify HEAD 2>/dev/null || true)"
# Stop hook(commit-stop-kimi-makabe.sh)は別プロセスなのでこの bash 変数を読めない。ファイルへ写しておく。
printf '%s' "$pre_head" > "$run_dir/pre_head.txt"
pre_main_head="$(git -C "$git_root" rev-parse --verify refs/heads/main 2>/dev/null || true)"
pre_master_head="$(git -C "$git_root" rev-parse --verify refs/heads/master 2>/dev/null || true)"

echo "[makabe/kimi] Kimi 起動 root=$root log=$log_path model=$model effort=$effort run_dir=$run_dir"

stream_log="$run_dir/stream.jsonl"
stderr_log="$run_dir/stderr.log"
current_child_pid=""
kimi_status=0
interrupted=0

on_term() {
  echo "[makabe/kimi] SIGTERM/SIGINT を受けた" >&2
  interrupted=1
  if [ -n "$current_child_pid" ]; then
    kill -TERM -- "-$current_child_pid" 2>/dev/null || kill -TERM "$current_child_pid" 2>/dev/null || true
  fi
  exit 3
}
trap on_term TERM INT

set +e
setsid bash -c 'cd "$1" || exit 91; shift; exec "$@"' _ "$root" \
  kimi -p "$prompt_arg" --agent-file "$agent_path" -m "$model" --output-format stream-json \
  < /dev/null > "$stream_log" 2>"$stderr_log" &
current_child_pid=$!
printf '%s\n' "$current_child_pid" > "$run_dir/kimi.pid"
wait "$current_child_pid"
kimi_status=$?
current_child_pid=""
set -e

{
  echo "=== kimi stdout(stream-json) ==="
  cat "$stream_log"
  if [ -s "$stderr_log" ]; then
    echo "=== kimi stderr ==="
    cat "$stderr_log"
  fi
} >> "$log_path"

session_id="$(jq -rs '
    map(select(.role=="meta" and .type=="session.resume_hint" and (.session_id != null)))
    | if length > 0 then last.session_id else empty end
  ' "$stream_log" 2>/dev/null || true)"
[ -n "$session_id" ] || session_id="不明"
printf '%s\n' "$session_id" > "$run_dir/session_id"

last_message="$(jq -rs '
    map(select(.role=="assistant" and (.content != null)))
    | if length > 0 then last.content else empty end
  ' "$stream_log" 2>/dev/null || true)"
if [ -n "$last_message" ]; then
  printf '%s\n' "$last_message" > "$run_dir/last-message.md"
else
  : > "$run_dir/last-message.md"
  echo "警告: kimi の最終メッセージを取れなかった(stream.jsonl / stderr.log を見る)" >&2
fi

# 変更ファイル数 ── 作業木の status 差分(comm -3)と、HEAD が動いた場合の commit 済み差分の両方を見る
# (claude-makabe.sh と同じ理屈。checkpoint commit / squash で worktree が clean に戻ると status 差分だけでは拾えない)。
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
# worktree-guard-kimi-makabe.sh が実行前に block している(こちらは事後の確認)。
post_main_head="$(git -C "$git_root" rev-parse --verify refs/heads/main 2>/dev/null || true)"
post_master_head="$(git -C "$git_root" rev-parse --verify refs/heads/master 2>/dev/null || true)"
violations=()
if [ "$pre_main_head" != "$post_main_head" ]; then
  violations+=("ref 変化を検出: refs/heads/main")
fi
if [ "$pre_master_head" != "$post_master_head" ]; then
  violations+=("ref 変化を検出: refs/heads/master")
fi

# 終端の判定(stuck.md があれば詰まり、無く HEAD が動いていれば完了、どちらも無ければ未達)。
stuck_reason=""
if [ -s "$stuck_path" ]; then
  stuck_reason="$(head -n 1 "$stuck_path" | tr -d '\r')"
fi
head_moved=0
if [ -n "$post_head" ] && [ "$post_head" != "$pre_head" ]; then
  head_moved=1
fi
if [ -n "$stuck_reason" ]; then
  # commit まで届いたうえで stuck.md もある = 外部要因で完了条件に届かず checkpoint commit を残した形も、詰まり。
  terminal="詰まり"
elif [ "$head_moved" -eq 1 ] && [ "$kimi_status" -eq 0 ]; then
  terminal="完了"
else
  terminal="未達"
fi

echo "persona: makabe"
echo "engine: kimi"
echo "session_id: $session_id"
echo "run_dir: $run_dir"
echo "log: $log_path"
echo "git diff --stat"
git -C "$git_root" diff --stat || true
echo "変更ファイル数: ${#changed_files[@]}"

# 真壁の終端に commit sha を機械可読な行で載せる(claude-makabe.sh と同じ ── 起動時と終了時の
# worktree の HEAD を比較するだけ。squash 前の checkpoint commit も、squash 後の 1 本も拾う)。
if [ "$head_moved" -eq 1 ]; then
  echo "makabe_commit_sha: $post_head"
else
  echo "makabe_commit_sha: (無し)"
fi
echo "makabe_terminal: $terminal"
if [ -n "$stuck_reason" ]; then
  echo "makabe_stuck: $stuck_reason"
else
  echo "makabe_stuck: (無し)"
fi

if [ "${#violations[@]}" -gt 0 ]; then
  echo "権限逸脱"
  printf '  - %s\n' "${violations[@]}"
  exit 3
fi
if [ "$kimi_status" -ne 0 ]; then
  echo "kimi が異常終了(status=$kimi_status)。stderr.log の末尾: $(tail -n 3 "$stderr_log" 2>/dev/null | tr '\n' ' ')" >&2
  exit "$kimi_status"
fi
exit 0
