#!/usr/bin/env bash
# 贄川[ORC]を Claude(opus、claude -p)で起こすランチャ。口は kimi-niekawa.sh / codex-agent.sh niekawa と
# 同じ(引数・便ディレクトリ・run 台帳・受信箱・終端)。中身だけ Claude opus に載せる。
#
# 射程: `tech/_drafts/plan/58-task-dag.v0.md` の工程に限り、贄川の主経路(役員 人見 2026-09-21、
# 段階的に2回裁定 ── ①Codex sol フォールバックの代替として着手 ②同日中に同工程の主へ格上げ、柏木は
# この工程だけ Codex sol でゲートを通し、既定 astra は鷹野が承認後の事後レビューで呼ぶ。
# 正典 docs/delegation.md の枠の規則表は変えない、工程限定の一時的な選択)。
# 柏木 / 真壁の model は --kashiwagi-model / --makabe-model(env KASHIWAGI_MODEL / MAKABE_MODEL)で
# round prompt に明示し、贄川(opus)が codex-kashiwagi / codex-makabe の起動コマンドに反映する。
#
# kimi-niekawa.sh との差分は起動系だけ:
#   - engine は `claude -p --model opus --dangerously-skip-permissions --output-format json`
#   - 人格の載せ方は --append-system-prompt(roles/niekawa.md + claude/niekawa.md)
#   - hooks は起動のたびに書く run_dir/settings.json から --settings で渡す(Stop = verdict-stop-claude.sh、
#     PreToolUse = gate-guard-claude.sh。kimi の hook と判定ロジックは同じだが、Claude Code は
#     Stop/PreToolUse を exit 2(stderr の理由)でだけ block する実測のため、別ファイルを使う。
#     ~/.claude/settings.json 等の母艦設定は一切触らない)
#   - 1 巡 = 1 session は `--resume` を渡さないことで担保(kimi の --agent-file 制約と同じ効果を構造で作る)
#
# 使い方は kimi-niekawa.sh --help と同じ(-f / --cd / --log / --rounds / --no-loop / --batch / --inbox /
# --resume-run / --dry-run)。--effort は low|high|max を検証するが記録のみで claude には high 固定で渡す
# (persona 既定は astra/luna と同じく high、他ランチャの語彙に揃える)。model は claude opus 固定
# (--model は受けない)。

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: claude-niekawa.sh [options] [task...]

options:
  -f, --file <path>     タスク本文をファイルから読む。複数指定可
  -C, --cd <dir>        作業ルート(既定: 起動時ディレクトリの git toplevel)
      --log <path>      ログ出力先
      --rounds <n>       巡数上限(既定 12)。verdict が「継続」の間、新しい claude -p プロセスで次の巡を起こす
      --no-loop          1 session だけ走らせる(巡ループ無し)
      --effort <level>   low|high|max(既定 high)。記録のみ、claude には常に high を渡す
      --kashiwagi-model <id>  贄川が柏木を起こすときの model(既定は KASHIWAGI_ROUTE 別 ── opus なら opus、
                         codex なら astra。env KASHIWAGI_MODEL でも指定できる)
                         柏木の実行経路は env KASHIWAGI_ROUTE(opus|codex、既定 opus)で切り替える。
                         opus は claude-kashiwagi.sh(effort xhigh)、codex は従来の codex-kashiwagi
      --makabe-model <id>     贄川が真壁を起こすときの model(既定は persona 既定の luna、env
                         MAKABE_MODEL でも指定できる。ゲート 2 の P0 を直す巡は既存の作法どおり sol)
      --batch <name>     便名を明示する(既定: BRIEF 本文の「便: <名>」行)
      --inbox <path>     鷹野の箱(to-takano.tsv)を明示する。既定は便ディレクトリの to-takano.tsv
      --resume-run [<前run_dir>]
                         新しい run_dir で便を再開する。前 run(省略時は便の runs.tsv の最終行)の
                         checkpoint を巡 1 の prompt 末尾に写す
      --dry-run          prompt を組み立てて stdout に出し、claude を起動せず exit 0(検算用)
  -h, --help             この usage を表示

task と --file が無い場合は標準入力からタスク本文を読む。
model は claude opus 固定(--model は受けない)。--resume は無い(巡ごとに新しい claude -p プロセス)。

起動時の run_dir(${CODEX_AGENT_STATE_DIR:-~/.codex-agents}/runs/niekawa-<run_id>)を CODEX_AGENT_RUN_DIR で export する。
起動時に `rates claude` を 1 回叩いて <run_dir>/rates.json に残す(失敗は警告のみで続行)。
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

script_path="$(resolve_self)"
CORE="$(dirname "$(dirname "$script_path")")"

# shellcheck source=lib/batch-inbox.sh
source "$CORE/scripts/lib/batch-inbox.sh"

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
effort="high"
max_rounds=12
loop_enabled=1
task_files=()
task_args=()
batch_name_arg=""
takano_inbox_arg=""
resume_run=0
resume_run_arg=""
dry_run=0
kashiwagi_model="${KASHIWAGI_MODEL:-}"
makabe_model="${MAKABE_MODEL:-}"
# 柏木の実行経路(役員 人見 2026-09-21 23:55、実行経路 C の新設)。既定 opus = claude-kashiwagi.sh(Opus,
# effort xhigh)。codex = 従来の codex-kashiwagi(gpt-6-astra または --kashiwagi-model の指定先)。
# 走行中の run には効かない(env は起動時に固定、新しい起動からだけ適用される)。
kashiwagi_route="${KASHIWAGI_ROUTE:-opus}"
case "$kashiwagi_route" in
  opus|codex) ;;
  *) die "KASHIWAGI_ROUTE は opus か codex のどちらか: $kashiwagi_route" ;;
esac

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
    --kashiwagi-model)
      [ "$#" -ge 2 ] || die "$1 には id が必要"
      kashiwagi_model="$2"
      shift 2
      ;;
    --makabe-model)
      [ "$#" -ge 2 ] || die "$1 には id が必要"
      makabe_model="$2"
      shift 2
      ;;
    --log)
      [ "$#" -ge 2 ] || die "$1 には path が必要"
      log_path="$2"
      shift 2
      ;;
    --rounds)
      [ "$#" -ge 2 ] || die "$1 には n が必要"
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--rounds は 1 以上の整数: $2"
      max_rounds="$2"
      shift 2
      ;;
    --no-loop)
      loop_enabled=0
      shift
      ;;
    --effort)
      [ "$#" -ge 2 ] || die "$1 には level が必要"
      effort="$2"
      shift 2
      ;;
    --batch)
      [ "$#" -ge 2 ] || die "$1 には name が必要"
      batch_name_arg="$2"
      shift 2
      ;;
    --inbox)
      [ "$#" -ge 2 ] || die "$1 には path が必要"
      takano_inbox_arg="$2"
      shift 2
      ;;
    --resume-run)
      resume_run=1
      if [ "$#" -ge 2 ] && [[ "$2" != -* ]]; then
        resume_run_arg="$2"
        shift 2
      else
        shift
      fi
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
  echo "警告: claude には常に --effort high を渡す(persona 既定、指定値 $effort は記録のみ)" >&2
fi

[ -d "$root_input" ] || die "作業ルートが見つからない: $root_input"
root="$(cd "$root_input" && pwd -P)"

git_repo=0
if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
  git_repo=1
fi

for task_file in "${task_files[@]}"; do
  [ -f "$task_file" ] || die "タスクファイルが見つからない: $task_file"
  [ -r "$task_file" ] || die "タスクファイルを読めない: $task_file"
done

timestamp="$(date '+%Y%m%d-%H%M%S')"
agent_state_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}"
run_id="niekawa-$timestamp-$$-$RANDOM"
run_dir="$agent_state_dir/runs/$run_id"
mkdir -p "$run_dir"
run_dir="$(cd -P "$run_dir" && pwd)"
rounds_dir="$run_dir/rounds"

log_path_was_default=0
if [ -z "$log_path" ]; then
  log_path="$agent_state_dir/logs/$run_id.log"
  log_path_was_default=1
fi
mkdir -p "$(dirname "$log_path")"
if [ "$log_path_was_default" -eq 1 ]; then
  : > "$log_path" 2>/dev/null || true
fi

# rates ゲートはランチャに入れない(裁定 #8)。自サービス(claude)の残量を起動時に 1 回だけ記録する。
if command -v rates >/dev/null 2>&1; then
  if ! rates claude > "$run_dir/rates.json" 2>"$run_dir/rates.err"; then
    echo "警告: rates claude の取得に失敗した(続行): $(tr '\n' ' ' < "$run_dir/rates.err")" >&2
    rm -f "$run_dir/rates.json"
  fi
else
  echo "警告: rates コマンドが見つからない(続行)" >&2
fi

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

export CODEX_AGENT_RUN_DIR="$run_dir"

batch_name=""
if batch_name="$(batch_resolve_name "$batch_name_arg" "$task_path")"; then
  :
else
  batch_name=""
  echo "警告: 便名が解決できない(--batch も BRIEF の「便:」行も無い)。run_dir を便扱いにする" >&2
fi

batch_dir=""
if [ -n "$batch_name" ]; then
  batch_dir="$agent_state_dir/batches/$batch_name"
  mkdir -p "$batch_dir"
  export NIEKAWA_INBOX="$batch_dir/to-niekawa.tsv"
fi

effective_niekawa_inbox="${NIEKAWA_INBOX:-$run_dir/to-niekawa.tsv}"
takano_inbox="$(batch_resolve_takano_inbox "$takano_inbox_arg" "$batch_dir")" || true

prev_run_dir=""
resume_checkpoint_text=""
if [ "$resume_run" -eq 1 ]; then
  if prev_run_dir="$(batch_resolve_prev_run "$resume_run_arg" "$batch_dir")"; then
    [ -d "$prev_run_dir" ] || die "--resume-run: 前 run_dir が見つからない: $prev_run_dir"
    resume_checkpoint_text="$(batch_render_resume_checkpoint "$prev_run_dir")"
  else
    die "--resume-run: 前 run_dir を解決できない(--resume-run <run_dir> を明示するか、便の runs.tsv が要る)"
  fi
fi

role_content=""
if [ -f "$CORE/roles/niekawa.md" ]; then
  role_content="$(cat "$CORE/roles/niekawa.md")"
else
  echo "警告: roles/niekawa.md が無い(空として続行)" >&2
fi
claude_contract=""
if [ -f "$CORE/claude/niekawa.md" ]; then
  claude_contract="$(cat "$CORE/claude/niekawa.md")"
else
  echo "警告: claude/niekawa.md が無い(空として続行)" >&2
fi
system_prompt="$role_content"
if [ -n "$claude_contract" ]; then
  system_prompt="$system_prompt
$claude_contract"
fi

git_name="贄川"
export GIT_AUTHOR_NAME="$git_name" GIT_COMMITTER_NAME="$git_name"
export GIT_AUTHOR_EMAIL="niekawa@ai.yumemism.dev" GIT_COMMITTER_EMAIL="niekawa@ai.yumemism.dev"

# 柏木 / 真壁の model 指定(工程限定、役員 人見 2026-09-21 の追加裁定)。子の claude -p プロセスへ
# env で渡す(Bash tool から素直に `echo $KASHIWAGI_MODEL` できる)のと、round prompt に明示の
# 2 段で確実にする ── LLM が env を自発的に読みに行くとは限らないため。
export KASHIWAGI_MODEL="$kashiwagi_model"
export MAKABE_MODEL="$makabe_model"
export KASHIWAGI_ROUTE="$kashiwagi_route"

# hooks 設定(run_dir 直下に 1 回だけ書く。全巡で同じものを使う)。
# ~/.claude/settings.json 等の母艦設定は一切触らない ── --settings <path> でこの run だけに効かせる。
hooks_dir="$CORE/scripts/hooks"
settings_path="$run_dir/settings.json"
python3 - "$hooks_dir" "$settings_path" <<'PY'
import json
import sys

hooks_dir, out_path = sys.argv[1], sys.argv[2]
settings = {
    "hooks": {
        "Stop": [
            {"hooks": [{"type": "command", "command": f"{hooks_dir}/verdict-stop-claude.sh", "timeout": 10}]}
        ],
        "PreToolUse": [
            {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": f"{hooks_dir}/gate-guard-claude.sh", "timeout": 10}],
            }
        ],
    }
}
with open(out_path, "w") as f:
    json.dump(settings, f, ensure_ascii=False, indent=2)
PY

# 巡 N の -p 本文を組む(kimi-niekawa.sh と同じ形)。
build_round_prompt() {
  local round="$1"
  local out="$2"
  local prev_verdict=""
  {
    printf 'checkpoint の置き場: %s(plan.md / findings.md / verdict.md)\n' "$run_dir"
    printf 'plan の置き場: %s/plan.md\n' "$run_dir"
    printf '巡: %s / %s\n' "$round" "$max_rounds"
    if [ "$kashiwagi_route" = opus ]; then
      printf '柏木の呼び出し: claude-kashiwagi を使う(env KASHIWAGI_ROUTE=opus、役員 人見 2026-09-21 23:55、実行経路C)。codex-kashiwagi は使わない\n'
      if [ -n "$kashiwagi_model" ]; then
        printf '柏木の model 指定: claude-kashiwagi に --model %s を足す(env KASHIWAGI_MODEL)\n' "$kashiwagi_model"
      else
        printf '柏木の model 指定: 既定のまま(--model を足さない、既定 opus)\n'
      fi
    else
      printf '柏木の呼び出し: codex-kashiwagi を使う(env KASHIWAGI_ROUTE=codex)\n'
      if [ -n "$kashiwagi_model" ]; then
        printf '柏木の model 指定: codex-kashiwagi に --model %s を足す(env KASHIWAGI_MODEL、工程限定の裁定)\n' "$kashiwagi_model"
      else
        printf '柏木の model 指定: 既定のまま(--model を足さない、persona 既定 astra)\n'
      fi
    fi
    if [ -n "$makabe_model" ]; then
      printf '真壁の model 指定: codex-makabe に --model %s を足す(env MAKABE_MODEL、工程限定の裁定)\n' "$makabe_model"
    else
      printf '真壁の model 指定: 既定のまま(--model を足さない、persona 既定 luna。ゲート 2 の P0 を直す巡は従来どおり --model gpt-5.6-sol)\n'
    fi
    if [ "$round" -gt 1 ]; then
      prev_verdict="$rounds_dir/r$((round - 1))/verdict.md"
      printf '\n## 前巡までの checkpoint(この session は巡 %s。以下は前の session が残したもの)\n' "$round"
      for name in plan.md findings.md; do
        if [ -s "$run_dir/$name" ]; then
          printf '\n### %s\n\n' "$name"
          cat "$run_dir/$name"
          printf '\n'
        fi
      done
      if [ -s "$prev_verdict" ]; then
        printf '\n### 前巡の verdict.md\n\n'
        cat "$prev_verdict"
        printf '\n'
      fi
    fi
    if [ "$round" -eq 1 ] && [ -n "$resume_checkpoint_text" ]; then
      printf '%s\n' "$resume_checkpoint_text"
    fi
    batch_render_niekawa_inbox "$effective_niekawa_inbox"
    printf '\n\n## 今回のタスク\n\n'
    cat "$task_path"
  } > "$out"
}

read_verdict() {
  local path="$1"
  local first
  [ -s "$path" ] || return 0
  first="$(head -n 1 "$path" | tr -d '\r')"
  case "$first" in
    'verdict: 継続'|'verdict:継続') printf '継続\n' ;;
    'verdict: 承認'|'verdict:承認') printf '承認\n' ;;
    'verdict: エスカレーション'|'verdict:エスカレーション') printf 'エスカレーション\n' ;;
    *) printf '\n' ;;
  esac
}

git_status_paths() {
  git -C "$1" status --porcelain=v1 --untracked-files=all 2>/dev/null | cut -c4- | LC_ALL=C sort -u
}

if [ "$dry_run" -eq 1 ]; then
  dry_round_dir="$rounds_dir/r1"
  mkdir -p "$dry_round_dir"
  dry_prompt="$dry_round_dir/prompt.md"
  build_round_prompt 1 "$dry_prompt"
  echo "[niekawa/claude] dry-run root=$root run_dir=$run_dir batch=${batch_name:-(無し)}"
  echo "[niekawa/claude] 便の箱: $effective_niekawa_inbox"
  echo "[niekawa/claude] 鷹野の箱: ${takano_inbox:-(post しない)}"
  echo "[niekawa/claude] settings: $settings_path"
  echo "--- prompt (巡1) ---"
  cat "$dry_prompt"
  exit 0
fi

if [ -n "$batch_dir" ]; then
  brief_paths_joined=""
  if [ "${#task_files[@]}" -gt 0 ]; then
    brief_paths_joined="$(IFS=,; printf '%s' "${task_files[*]}")"
  fi
  batch_append_run "$batch_dir" "$run_dir" "claude" "$brief_paths_joined" "$prev_run_dir"
else
  echo "警告: 便名が無いため runs.tsv に記録しない" >&2
fi

pre_status=""
if [ "$git_repo" -eq 1 ]; then
  pre_status="$(git_status_paths "$root")"
fi

echo "[niekawa/claude] Claude 起動 root=$root log=$log_path"

claude_status=0
verdict=""
verdict_status=0
rounds_run=0
session_id="不明"
session_ids=()
current_child_pid=""
takano_notified=0

notify_abnormal_exit() {
  local reason="$1"
  [ "$takano_notified" -eq 0 ] || return 0
  takano_notified=1
  batch_notify_takano "$takano_inbox" "$run_dir" "異常終了" "$reason"
}

on_term() {
  echo "[niekawa/claude] SIGTERM/SIGINT を受けた。子プロセスを止めて異常終了を通知する" >&2
  if [ -n "$current_child_pid" ]; then
    kill -TERM -- "-$current_child_pid" 2>/dev/null || kill -TERM "$current_child_pid" 2>/dev/null || true
  fi
  notify_abnormal_exit "SIGTERM/SIGINT で中断(run_dir: $run_dir)"
  exit 3
}
trap on_term TERM INT

on_exit() {
  local code=$?
  notify_abnormal_exit "異常終了(exit $code, run_dir: $run_dir)"
}
trap on_exit EXIT

round=1
while :; do
  round_dir="$rounds_dir/r$round"
  mkdir -p "$round_dir"
  round_prompt="$round_dir/prompt.md"
  build_round_prompt "$round" "$round_prompt"
  if [ "$round" -eq 1 ]; then
    cp "$round_prompt" "$run_dir/prompt.md"
  fi

  prompt_size="$(wc -c < "$round_prompt" | tr -d ' ')"
  if [ "$prompt_size" -gt 102400 ]; then
    prompt_arg="まず $round_prompt を読む"
  else
    prompt_arg="$(cat "$round_prompt")"
  fi

  rm -f "$run_dir/verdict.md"
  echo "[niekawa/claude] 巡 $round / $max_rounds 開始 session=新規"

  round_json="$round_dir/last.json"
  set +e
  setsid bash -c 'cd "$1" && exec claude -p --model opus --effort high --dangerously-skip-permissions --output-format json --append-system-prompt "$3" --settings "$4" -- "$2"' \
    _ "$root" "$prompt_arg" "$system_prompt" "$settings_path" \
    < /dev/null > "$round_json" 2>"$round_dir/stderr.log" &
  current_child_pid=$!
  wait "$current_child_pid"
  claude_status=$?
  current_child_pid=""
  set -e
  {
    echo "=== 巡 $round stdout(json) ==="
    cat "$round_json"
    echo
    if [ -s "$round_dir/stderr.log" ]; then
      echo "=== 巡 $round stderr ==="
      cat "$round_dir/stderr.log"
    fi
  } >> "$log_path"

  round_result_path="$round_dir/parse.env"
  if python3 - "$round_json" "$round_result_path" > "$round_dir/last-message.md" 2>"$round_dir/parse.err"; then
    :
  else
    echo "警告: 巡 $round の Claude JSON を解析できない(parse.err 参照)" >&2
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

  session_id="不明"
  round_is_error=0
  if [ -f "$round_result_path" ]; then
    # shellcheck disable=SC1090
    source "$round_result_path"
    round_is_error="${is_error:-0}"
  fi
  printf '%s\n' "$session_id" > "$round_dir/session_id"
  session_ids+=("$session_id")

  if [ -s "$round_dir/last-message.md" ]; then
    cp "$round_dir/last-message.md" "$run_dir/last-message.md"
  fi

  rounds_run="$round"
  verdict="$(read_verdict "$run_dir/verdict.md")"
  if [ -s "$run_dir/verdict.md" ]; then
    cp "$run_dir/verdict.md" "$round_dir/verdict.md"
  fi
  echo "巡 $round session_id: $session_id verdict: ${verdict:-不明}"

  if [ "$claude_status" -ne 0 ]; then
    echo "巡 $round: claude が異常終了(status=$claude_status)。ループを止める" >&2
    break
  fi
  if [ "$round_is_error" = "1" ] && [ -z "$verdict" ]; then
    echo "巡 $round: Claude JSON が is_error かつ verdict.md も不正。ループを止める" >&2
    claude_status=1
    break
  fi

  if [ "$loop_enabled" -eq 0 ]; then
    break
  fi

  case "$verdict" in
    承認|エスカレーション) break ;;
    継続)
      if [ "$round" -ge "$max_rounds" ]; then
        echo "巡数上限 $max_rounds に到達。verdict は継続のまま。鷹野が見る" >&2
        verdict_status=5
        break
      fi
      round=$((round + 1))
      ;;
    *)
      echo "巡 $round: verdict.md が無いか 1 行目が不正。鷹野が見る" >&2
      verdict_status=4
      break
      ;;
  esac
done

printf '%s\n' "$session_id" > "$run_dir/session_id"

changed_count=0
if [ "$git_repo" -eq 1 ]; then
  post_status="$(git_status_paths "$root")"
  changed_count="$(comm -3 <(printf '%s\n' "$pre_status") <(printf '%s\n' "$post_status") | sed '/^$/d' | wc -l | tr -d ' ')"
fi

if [ "$claude_status" -eq 0 ] && [ "$verdict_status" -ne 5 ] && { [ "$verdict" = "承認" ] || [ "$verdict" = "エスカレーション" ]; }; then
  summary="$(batch_verdict_summary "$run_dir/verdict.md")"
  batch_notify_takano "$takano_inbox" "$run_dir" "$verdict" "$summary"
  takano_notified=1
elif [ "$verdict_status" -eq 5 ]; then
  batch_notify_takano "$takano_inbox" "-" "エスカレーション" "巡数上限、verdict 継続のまま(run_dir: $run_dir)"
  takano_notified=1
fi

echo "persona: niekawa"
echo "engine: claude"
echo "session_id: $session_id"
echo "run_dir: $run_dir"
echo "巡数: $rounds_run"
echo "verdict: ${verdict:-不明}"
echo "session_ids: ${session_ids[*]}"
echo "log: $log_path"
if [ "$git_repo" -eq 1 ]; then
  echo "変更ファイル数: $changed_count"
else
  echo "変更ファイル数: 0 (非 git のため未計測)"
fi

if [ "$claude_status" -ne 0 ]; then
  exit "$claude_status"
fi
if [ "$verdict_status" -ne 0 ]; then
  exit "$verdict_status"
fi
exit 0
