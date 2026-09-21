#!/usr/bin/env bash
# 柏木[CM]を Claude opus(effort xhigh)で起こすランチャ ── 実行経路 C(Opus 単独、K3 は足さない)。
# 役員 人見 2026-09-21 23:55「Opus 柏木の実行経路を作る。契約は effort xhigh」(PoC は --effort high だった)。
# 根拠: 庵野の再審 PoC(scratchpad stage5/kashiwagi-poc-results.md)で Opus 単発が sol 実績 5 件中 5 件を再現、
# K3 単発は 5 件中 2 件(B3 のエスカレーションと F3 の外向き契約破壊を見落とした)。
#
# 契約は codex-agent.sh kashiwagi(K3/sol 経路)と同じ入出力を保つ:
#   - run_dir 命名 kashiwagi-<ts>-<pid>-<rand>、便の gates.tsv への「ゲートは便に1回」の担保
#   - footer(persona: / session_id: / run_dir: / 巡数: / verdict: / session_ids: / log: / 変更ファイル数:)
#   - -f <plan.md|findings.md> でゲート番号を判定、-C で作業ルート、--log、--dry-run
#
# 差分(意図的):
#   - engine は claude -p --model opus --effort xhigh(--dangerously-skip-permissions は渡さない)。
#     **ゲート1(-f が plan.md、-C は贄川の run_dir 自身)は permission-mode を渡さない**(既定モードは
#     非対話では Write/Edit/NotebookEdit を一切承認しない、実測)。**ゲート2(-f が findings.md、-C は作業木)
#     だけ --permission-mode acceptEdits を足す**(cwd = 作業木 の中は自動承認、外は拒否、実測)。
#     ゲート1に acceptEdits を与えると、cwd = 贄川の run_dir 自身なので「作業木の中は自動承認」が
#     「run_dir(plan.md・他ゲートの所見)への書き込み許可」になってしまう ── PoC の事故と同じ穴
#     (役員 人見 2026-09-22 の指摘、庵野 2026-09-22 実測して修正)。--disallowedTools の path 付き rule は
#     acceptEdits 下でも --dangerously-skip-permissions 下でも完全に無視される実測が出たため使わない
#   - PreToolUse hook(worktree-guard-claude.sh)で Bash 経由の書き込み(リダイレクト・rm・sed -i・
#     git push/reset --hard 等)を作業木の外(~/.codex-agents/runs/**・~/canonical/**・~/.claude/**・
#     ~/.codex/**・~/bin/**)へは block する ── acceptEdits(ゲート2)も既定モード(ゲート1)も Bash の
#     cwd スコープを持たない(実測: cwd 外へのリダイレクト書き込み・rm が無条件で成功した)ため、
#     この hook が唯一の担保。env CLAUDE_KASHIWAGI_GATE=2 のときだけ「root 配下は常に許可」の
#     carve-out を有効にする(ゲート1・ゲート番号不明は carve-out 無し ── root 自身が禁止プレフィックス
#     配下でも block される。ゲート1の -C = 贄川の run_dir はまさにこのケース)
#   - **ゲート2(作業木のレビュー)は書ける。P2 の自己 commit は残す**(codex 柏木と同じ、
#     `git-as kashiwagi commit`、delegation.md:147 のまま。役員 人見 2026-09-22 の訂正 ── 当初案の
#     「レビュアーは書き込み無し」は締めすぎ)。**ゲート1(plan のレビュー)は一切書けない**(同日中の
#     再訂正 ── 「作業木の外だけ禁止」を素朴に実装すると、ゲート1の作業木＝run_dir 自身のせいで
#     PoC の事故と同じ穴が残ったため)
#   - --resume / --rounds は受けない(kashiwagi は元々巡ループを持たない。1 session = 1 ゲート)
#
# env:
#   KASHIWAGI_MODEL(既定 opus) / KASHIWAGI_EFFORT(既定 xhigh)
#
# 使い方: claude-kashiwagi.sh --no-loop [-C dir] -f <path> [--log path] [--model id] [--effort level] [--dry-run]
# -f は複数可(codex-agent.sh と同じ、末尾のファイル名でゲート番号を判定)。task 引数(-f 以外)も付けられる。

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: claude-kashiwagi.sh [options] [task...]

options:
  -f, --file <path>   タスク本文をファイルから読む。複数指定可(最後のファイル名でゲート番号を判定:
                       plan.md → ゲート1、findings.md → ゲート2、それ以外は判定なし)
  -C, --cd <dir>       作業ルート(既定: 起動時ディレクトリの git toplevel)
      --log <path>     ログ出力先
      --model <id>     Claude model(既定 opus、env KASHIWAGI_MODEL でも指定可)
      --effort <level> reasoning effort(既定 xhigh、env KASHIWAGI_EFFORT でも指定可)
      --no-loop        受理するが no-op(この経路は常に 1 session)
      --dry-run        起動コマンドを組み立てて stdout に出し、claude を起動せず exit 0(検算用)
  -h, --help           この usage を表示

task と --file が無い場合は標準入力からタスク本文を読む。
--resume / --rounds は無い。

起動時の run_dir(${CODEX_AGENT_STATE_DIR:-~/.codex-agents}/runs/kashiwagi-<ts>-<pid>-<rand>)を
CODEX_AGENT_RUN_DIR で export する。起動時に `rates claude` を 1 回叩いて <run_dir>/rates.json に残す。

NIEKAWA_INBOX が環境にあれば(贄川の子として起動された場合)、その dirname の gates.tsv で
「ゲートは便に1回」を判定する。-f の最後のファイル名が plan.md/findings.md のとき、該当ゲートが
既に記録済みなら run_dir を作る前に die する。die しなければ起動直後に 1 行 append する
(codex-agent.sh と同じ書き手責務、hook は検査専任)。
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
[ -f "$CORE/roles/kashiwagi.md" ] || die "人物像の正典が見つからない: $CORE/roles/kashiwagi.md"
[ -f "$CORE/claude/kashiwagi.md" ] || die "Claude 起動契約が見つからない: $CORE/claude/kashiwagi.md"

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
model="${KASHIWAGI_MODEL:-opus}"
effort="${KASHIWAGI_EFFORT:-xhigh}"
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
      model="$2"
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || die "$1 には level が必要"
      effort="$2"
      shift 2
      ;;
    --no-loop)
      shift
      ;;
    --resume|--rounds)
      die "$1 はこの経路(claude-kashiwagi)では受けない ── kashiwagi は 1 session = 1 ゲート"
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
[ -n "$model" ] || die "--model に空文字は指定できない"
[ -d "$root_input" ] || die "作業ルートが見つからない: $root_input"
root="$(cd "$root_input" && pwd -P)"

git_repo=0
git_root=""
if git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"; then
  git_repo=1
fi

for task_file in "${task_files[@]}"; do
  [ -f "$task_file" ] || die "タスクファイルが見つからない: $task_file"
  [ -r "$task_file" ] || die "タスクファイルを読めない: $task_file"
done

# ── ゲートの「便に1回」担保(codex-agent.sh の kashiwagi 分岐と同一ロジック、run_dir 作成前) ──
gate_batch_dir=""
if [ -n "${NIEKAWA_INBOX:-}" ]; then
  gate_batch_dir="$(dirname -- "$NIEKAWA_INBOX")"
fi
gate_gates_tsv=""
[ -z "$gate_batch_dir" ] || gate_gates_tsv="$gate_batch_dir/gates.tsv"

gate_has_gate_record() {
  [ -f "$1" ] && awk -F'\t' -v g="$2" '$3==g{found=1} END{exit !found}' "$1"
}

gate_target=""
if [ "${#task_files[@]}" -gt 0 ]; then
  gate_target="$(basename -- "${task_files[$((${#task_files[@]} - 1))]}")"
fi
gate_num=""
case "$gate_target" in
  plan.md) gate_num=1 ;;
  findings.md) gate_num=2 ;;
esac

if [ -n "$gate_batch_dir" ] && [ -n "$gate_num" ] && gate_has_gate_record "$gate_gates_tsv" "$gate_num"; then
  die "ゲート $gate_num は便に1回、直った巡は贄川の検収で閉じて次へ進む(claude-kashiwagi 経路)"
fi

timestamp="$(date '+%Y%m%d-%H%M%S')"
agent_state_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}"
run_id="kashiwagi-$timestamp-$$-$RANDOM"
run_dir="$agent_state_dir/runs/$run_id"
mkdir -p "$run_dir"
run_dir="$(cd -P "$run_dir" && pwd)"

# 死ぬ前に run_dir を作ってしまわないよう、append はここ(run_dir 作成の直後、claude 起動の前)。
# codex-agent.sh と同じ「書き手はランチャだけ」の責務分担 ── 経路を跨いでも同じ gates.tsv を見るため、
# codex-kashiwagi と claude-kashiwagi のどちらを先に使っても「便に1回」が壊れない。
if [ -n "$gate_batch_dir" ] && [ -n "$gate_num" ]; then
  gate_ts="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
  mkdir -p "$gate_batch_dir"
  printf '%s\t%s\t%s\n' "$gate_ts" "$run_dir" "$gate_num" >> "$gate_gates_tsv"
fi

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
if [ -f "$CORE/roles/kashiwagi.md" ]; then
  role_content="$(cat "$CORE/roles/kashiwagi.md")"
fi
claude_contract=""
if [ -f "$CORE/claude/kashiwagi.md" ]; then
  claude_contract="$(cat "$CORE/claude/kashiwagi.md")"
fi
system_prompt="$role_content"
if [ -n "$claude_contract" ]; then
  system_prompt="$system_prompt
$claude_contract"
fi

git_name="柏木"
export GIT_AUTHOR_NAME="$git_name" GIT_COMMITTER_NAME="$git_name"
export GIT_AUTHOR_EMAIL="kashiwagi@ai.yumemism.dev" GIT_COMMITTER_EMAIL="kashiwagi@ai.yumemism.dev"

# ゲート1(plan.md、-C は贄川の run_dir 自身)は書き込み無し ── acceptEdits の「cwd の中は自動承認」を
# 与えると、cwd = run_dir なので plan.md / 他ゲートの所見への書き込み許可になってしまう
# (PoC の事故 ── gate2.md 上書き ── と同じ穴、役員 人見 2026-09-22 の指摘)。
# ゲート2(findings.md、-C は作業木)だけ acceptEdits を与える(P2 の自己 commit はここだけ)。
# ゲート番号が判定できない呼び出し(-f が plan.md/findings.md 以外)も安全側で「書き込み無し」にする。
if [ "$gate_num" = "2" ]; then
  permission_mode_args=(--permission-mode acceptEdits)
else
  permission_mode_args=()
fi

# 作業木の外だけを塞ぐ hook(worktree-guard-claude.sh)。Write/Edit/NotebookEdit は上の分岐で cwd
# スコープに絞るか丸ごと拒否するかを決めるので、この hook は Bash 経由の書き込みだけを見る。
# CLAUDE_KASHIWAGI_GATE=2 のときだけ「root 配下は常に許可」の例外を有効にする(ゲート1は root 自身が
# 贄川の run_dir = ~/.codex-agents 配下なので、この例外を外すと root 配下への書き込みも禁止プレフィックスに
# 掛かって block される ── 「ゲート1は書き込み無し」を Bash 経由にも及ぼす)。
export CLAUDE_KASHIWAGI_ROOT="$root"
export CLAUDE_KASHIWAGI_GATE="$gate_num"
hooks_dir="$CORE/scripts/hooks"
settings_path="$run_dir/settings.json"
python3 - "$hooks_dir" "$settings_path" <<'PY'
import json
import sys

hooks_dir, out_path = sys.argv[1], sys.argv[2]
settings = {
    "hooks": {
        "PreToolUse": [
            {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": f"{hooks_dir}/worktree-guard-claude.sh", "timeout": 10}],
            }
        ],
    }
}
with open(out_path, "w") as f:
    json.dump(settings, f, ensure_ascii=False, indent=2)
PY

prompt_lines=()
{
  printf '柏木として、この経路(claude-kashiwagi、Opus, effort %s)で 1 session = 1 ゲートを担う。\n' "$effort"
  printf 'run_dir: %s\n' "$run_dir"
  if [ -n "$gate_num" ]; then
    printf 'ゲート番号: %s\n' "$gate_num"
  fi
  printf '\n## 今回のタスク\n\n'
  cat "$task_path"
} > "$run_dir/prompt.md"
prompt_size="$(wc -c < "$run_dir/prompt.md" | tr -d ' ')"
if [ "$prompt_size" -gt 102400 ]; then
  # claude-niekawa.sh と同じ回避策(argv 上限対策)。長文は先に読ませる。
  prompt_arg="まず $run_dir/prompt.md を読む"
else
  prompt_arg="$(cat "$run_dir/prompt.md")"
fi

if [ "$dry_run" -eq 1 ]; then
  echo "[kashiwagi/claude] dry-run root=$root run_dir=$run_dir model=$model effort=$effort"
  echo "[kashiwagi/claude] gate_num=${gate_num:-(無し)} gates.tsv=${gate_gates_tsv:-(便の外)}"
  echo "[kashiwagi/claude] permission_mode_args=${permission_mode_args[*]:-(無し、書き込み不可)}"
  echo "[kashiwagi/claude] settings: $settings_path"
  echo "--- prompt ---"
  cat "$run_dir/prompt.md"
  exit 0
fi

pre_status=""
pre_main_head=""
pre_master_head=""
if [ "$git_repo" -eq 1 ]; then
  pre_status="$(git -C "$root" status --porcelain=v1 --untracked-files=all 2>/dev/null | LC_ALL=C sort -u)"
  pre_main_head="$(git -C "$git_root" rev-parse --verify refs/heads/main 2>/dev/null || true)"
  pre_master_head="$(git -C "$git_root" rev-parse --verify refs/heads/master 2>/dev/null || true)"
fi

echo "[kashiwagi/claude] Claude 起動 root=$root log=$log_path model=$model effort=$effort"

round_json="$run_dir/last.json"
stderr_log="$run_dir/stderr.log"
current_child_pid=""
claude_status=0

on_term() {
  echo "[kashiwagi/claude] SIGTERM/SIGINT を受けた" >&2
  if [ -n "$current_child_pid" ]; then
    kill -TERM -- "-$current_child_pid" 2>/dev/null || kill -TERM "$current_child_pid" 2>/dev/null || true
  fi
  exit 3
}
trap on_term TERM INT

claude_args=(claude -p --model "$model" --effort "$effort")
claude_args+=("${permission_mode_args[@]}")
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

verdict="不明"
if [ -s "$run_dir/verdict.md" ]; then
  first_line="$(head -n 1 "$run_dir/verdict.md" | tr -d '\r')"
  case "$first_line" in
    'verdict: 継続'|'verdict:継続') verdict="継続" ;;
    'verdict: 承認'|'verdict:承認') verdict="承認" ;;
    'verdict: エスカレーション'|'verdict:エスカレーション') verdict="エスカレーション" ;;
  esac
fi

# 変更(P2 の自己 commit 含む)は作業木の中なら正常。逸脱は main/master の HEAD 移動(push 相当)だけを見る
# ── 作業木の外への書き込みは worktree-guard-claude.sh が実行前に block している(こちらは事後の確認)。
changed_count=0
violations=()
if [ "$git_repo" -eq 1 ]; then
  post_status="$(git -C "$root" status --porcelain=v1 --untracked-files=all 2>/dev/null | LC_ALL=C sort -u)"
  changed_count="$(comm -3 <(printf '%s\n' "$pre_status") <(printf '%s\n' "$post_status") | sed '/^$/d' | wc -l | tr -d ' ')"
  post_main_head="$(git -C "$git_root" rev-parse --verify refs/heads/main 2>/dev/null || true)"
  post_master_head="$(git -C "$git_root" rev-parse --verify refs/heads/master 2>/dev/null || true)"
  if [ "$pre_main_head" != "$post_main_head" ]; then
    violations+=("ref 変化を検出: refs/heads/main")
  fi
  if [ "$pre_master_head" != "$post_master_head" ]; then
    violations+=("ref 変化を検出: refs/heads/master")
  fi
fi

echo "persona: kashiwagi"
echo "engine: claude"
echo "session_id: $session_id"
echo "run_dir: $run_dir"
echo "巡数: 1"
echo "verdict: $verdict"
echo "session_ids: $session_id"
echo "log: $log_path"
if [ "$git_repo" -eq 1 ]; then
  echo "git diff --stat"
  git -C "$git_root" diff --stat || true
fi
echo "変更ファイル数: $changed_count"

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
