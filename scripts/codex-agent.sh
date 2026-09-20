#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: codex-agent.sh <persona> [options] [task...]

persona:
  minase | makabe | kashiwagi | niekawa

options:
  -f, --file <path>        タスク本文をファイルから読む。複数指定可
  -C, --cd <dir>           作業ルート
      --log <path>         ログ出力先
      --resume <id>        同じ Codex セッションを継続
      --effort <level>     reasoning effort。既定は makabe が max、他は high
      --model <id>         Codex model を指定(既定は persona 別: kashiwagi=gpt-6-astra / makabe=gpt-5.6-luna / niekawa=gpt-5.6-sol / minase=指定無し)
      --guard              実行後の権限ガードを有効化(既定: minase / makabe は on、kashiwagi / niekawa は off)
      --no-guard           実行後の権限ガードを省略
      --mcp                MCP server を有効のまま起動
      --rounds <n>         巡数上限(既定 12)。verdict が「継続」の間、新しい session で次の巡を起こす。
                            kashiwagi は既定で巡ループ off、この option を明示した時だけ on。niekawa は既定で on
      --no-loop             1 session だけ走らせる(巡ループ無し)。kashiwagi / niekawa に対して有効
      --allow-push          事後ガードの「ref 変化を検出」のうち push 相当(main/master/remote-tracking の移動)を
                            記録しない。BRIEF 本文に「push: 可」の行があるときも同じ扱いになる(niekawa 専用)
      --batch <name>        便名を明示する(既定: BRIEF 本文の「便: <名>」行、niekawa のみ)
      --inbox <path>        鷹野の箱(to-takano.tsv)を明示する(niekawa のみ)
      --resume-run [<前run_dir>]
                            新しい run_dir で便を再開する(niekawa のみ)。前 run の checkpoint を巡 1 に写す
      --dry-run             prompt を組み立てて stdout に出し、Codex を起動せず exit 0(検算用)
  -h, --help               この usage を表示

task と --file が無い場合は標準入力からタスク本文を読む。

起動時の run_dir(~/.codex-agents/runs/<run_id>)を CODEX_AGENT_RUN_DIR で Codex へ渡す。起動時に `rates codex` を 1 回叩いて
<run_dir>/rates.json に残す(失敗は警告のみで続行)。
kashiwagi / niekawa はプロンプト末尾(「今回のタスク」の前)に checkpoint の置き場(<run_dir>/plan.md / findings.md / verdict.md)と巡番号を受け取る。
1 巡 = 1 session(役員 人見 2026-09-16)。各巡の終わりに <run_dir>/verdict.md の 1 行目を読み、
「verdict: 継続」なら新しい session で次の巡、「verdict: 承認」「verdict: エスカレーション」で終端。
巡ループが有効な実行で verdict が無い・不正なら exit 4、巡数上限に当たったら exit 5。--resume 時はループしない。

niekawa は便のディレクトリ(~/.codex-agents/batches/<便名>/)に to-takano.tsv(鷹野の箱)・to-niekawa.tsv(便の箱)・
runs.tsv(便の run 台帳)を持つ。便名が解決できないときは post をスキップして警告だけ出し、続行する。
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
  minase|makabe|kashiwagi|niekawa) ;;
  *) die "不正な persona: $persona" ;;
esac

# 巡ループ(checkpoint + verdict.md)対応 persona。kashiwagi は既定 off、niekawa は既定 on(下で分岐)。
case "$persona" in
  kashiwagi|niekawa) supports_loop=1 ;;
  *) supports_loop=0 ;;
esac

script_path="$(resolve_self)"
CORE="$(dirname "$(dirname "$script_path")")"
[ -d "$CORE/roles" ] || die "roles ディレクトリが見つからない: $CORE/roles"
[ -d "$CORE/codex" ] || die "codex ディレクトリが見つからない: $CORE/codex"
[ -f "$CORE/roles/$persona.md" ] || die "人物像の正典が見つからない: $CORE/roles/$persona.md"
[ -f "$CORE/codex/$persona.md" ] || die "Codex 起動定義が見つからない: $CORE/codex/$persona.md"

# shellcheck source=lib/batch-inbox.sh
source "$CORE/scripts/lib/batch-inbox.sh"

invocation_dir="$(pwd -P)"
if default_root="$(git -C "$invocation_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  default_root="$invocation_dir"
fi

root_input="$default_root"
log_path=""
resume_id=""
# 既定の reasoning effort は persona 別(役員 人見 09-13 ── astra は high、luna は max)
case "$persona" in
  makabe) effort="max" ;;
  *) effort="high" ;;
esac
# 既定の model は persona 別(発注書 14 ── ランチャが --model を渡さないと codex の既定 gpt-5.6-sol になる欠陥への対処)。
case "$persona" in
  kashiwagi) model="gpt-6-astra" ;;
  makabe) model="gpt-5.6-luna" ;;
  niekawa) model="gpt-5.6-sol" ;;
  *) model="" ;;
esac
guard_enabled=1
case "$persona" in
  kashiwagi|niekawa) guard_enabled=0 ;;
esac
mcp_enabled=0
max_rounds=12
# 巡ループの既定は persona 別:niekawa は on、kashiwagi は off(--rounds を明示した時だけ on)、他は無効化される(下で強制 off)。
case "$persona" in
  niekawa) loop_enabled=1 ;;
  *) loop_enabled=0 ;;
esac
task_files=()
task_args=()
allow_push=0
batch_name_arg=""
takano_inbox_arg=""
resume_run=0
resume_run_arg=""
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
    --guard)
      guard_enabled=1
      shift
      ;;
    --no-guard)
      guard_enabled=0
      shift
      ;;
    --mcp)
      mcp_enabled=1
      shift
      ;;
    --rounds)
      [ "$#" -ge 2 ] || die "$1 には n が必要"
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--rounds は 1 以上の整数: $2"
      max_rounds="$2"
      # --rounds を明示したら巡ループを起動する(kashiwagi の既定 off を上書き)。
      loop_enabled=1
      shift 2
      ;;
    --no-loop)
      loop_enabled=0
      shift
      ;;
    --allow-push)
      allow_push=1
      shift
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

[ -n "$effort" ] || die "--effort に空文字は指定できない"
[ -d "$root_input" ] || die "作業ルートが見つからない: $root_input"
root="$(cd "$root_input" && pwd -P)"

if [ "$persona" != niekawa ]; then
  if [ -n "$batch_name_arg" ] || [ -n "$takano_inbox_arg" ] || [ "$resume_run" -eq 1 ]; then
    echo "警告: --batch / --inbox / --resume-run は niekawa 専用で、persona=$persona では無視する" >&2
  fi
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

# ゲート 2 の担保(ランチャ側)。kimi の PreToolUse hook(gate-guard.sh)は K3 経路にしか効かないため、
# sol 贄川(codex-niekawa)・人の手・真壁の起動を含む全経路で同じ判定をランチャに置く
# (BRIEF-gate2-launcher-guard、役員 人見 2026-09-20)。便の外(NIEKAWA_INBOX 無し)は素通し、挙動を変えない。
gate_batch_dir=""
if [ -n "${NIEKAWA_INBOX:-}" ]; then
  gate_batch_dir="$(dirname -- "$NIEKAWA_INBOX")"
fi
gate_gates_tsv=""
[ -z "$gate_batch_dir" ] || gate_gates_tsv="$gate_batch_dir/gates.tsv"

gate_has_gate2_record() {
  # $1 の gates.tsv(時刻 \t run_dir \t gate)にゲート 2 の行が既にあるか。
  [ -f "$1" ] && awk -F'\t' '$3=="2"{found=1} END{exit !found}' "$1"
}

gate_has_gate_record() {
  # $1 の gates.tsv に $2 のゲート番号の行が既にあるか。
  [ -f "$1" ] && awk -F'\t' -v g="$2" '$3==g{found=1} END{exit !found}' "$1"
}

if [ -n "$gate_batch_dir" ] && [ "$persona" = kashiwagi ]; then
  # 柏木の 2 回目は run_dir を作る前に die。ゲート 1(plan.md)もゲート 2(findings.md)も便に 1 回
  # (BRIEF-gate1-once、役員 人見 2026-09-20)。
  gate_target=""
  if [ "${#task_files[@]}" -gt 0 ]; then
    gate_target="$(basename -- "${task_files[$((${#task_files[@]} - 1))]}")"
  fi
  gate_num=""
  case "$gate_target" in
    plan.md) gate_num=1 ;;
    findings.md) gate_num=2 ;;
  esac
  if [ "$gate_num" = 1 ] && gate_has_gate_record "$gate_gates_tsv" 1; then
    die "ゲート 1 は便に 1 回、直した plan は贄川の検収で閉じて真壁へ進む"
  fi
  if [ "$gate_num" = 2 ] && gate_has_gate2_record "$gate_gates_tsv"; then
    die "ゲート 2 は便に 1 回、直った巡は贄川の検収で閉じる"
  fi
  if [ -n "$gate_num" ]; then
    # append はランチャだけがやる(hook 側の 2 重記録を消す、hook は検査だけになる)。
    gate_ts="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
    mkdir -p "$gate_batch_dir"
    printf '%s\t%s\t%s\n' "$gate_ts" "${CODEX_AGENT_RUN_DIR:--}" "$gate_num" >> "$gate_gates_tsv"
  fi
fi

timestamp="$(date '+%Y%m%d-%H%M%S')"
agent_state_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}"
run_id="$persona-$timestamp-$$-$RANDOM"
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
  # 既定の log は必ず作る(--log 未指定で作られない不具合の修正、2b-2 実測 09-20)。
  # 明示 --log は触らない(テスト等で意図的に無効なパスを渡す場合があるため)。
  : > "$log_path" 2>/dev/null || true
fi

# rates ゲートはランチャに入れない(裁定 #8)。自サービスの残量を起動時に 1 回だけ記録する。失敗は警告のみで続行。
if command -v rates >/dev/null 2>&1; then
  if ! rates codex > "$run_dir/rates.json" 2>"$run_dir/rates.err"; then
    echo "警告: rates codex の取得に失敗した(続行): $(tr '\n' ' ' < "$run_dir/rates.err")" >&2
    rm -f "$run_dir/rates.json"
  fi
else
  echo "警告: rates コマンドが見つからない(続行)" >&2
fi

if [ -n "$gate_batch_dir" ] && [ "$persona" = makabe ] && [ "$model" != "gpt-5.6-sol" ] \
  && gate_has_gate2_record "$gate_gates_tsv"; then
  # ゲート 2 の後の真壁は sol でなければ die。例外は codex weekly < 20%(luna を残す、rates は起動時に取得済み)。
  # ここは「luna を許すかどうか」の例外判定であって、起動可否を残量で決める rates ゲート(裁定 #8)ではない。
  gate_weekly=""
  if [ -s "$run_dir/rates.json" ] && command -v jq >/dev/null 2>&1; then
    gate_weekly="$(jq -r '.remaining.weekly // empty' "$run_dir/rates.json" 2>/dev/null || true)"
  fi
  if [[ "$gate_weekly" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && awk -v v="$gate_weekly" 'BEGIN { exit !(v + 0 < 20) }'; then
    echo "[$persona] ゲート 2 の後だが codex weekly ${gate_weekly}%( < 20%)のため luna のまま続行する" >&2
  else
    # die の前にこの経路で作った run_dir と(--log 未指定の既定 log のときだけ)log_path を消す。
    # 消さないと贄川が起こし直すたびに rates.json だけの空 run_dir と空 log が残り、runs/ を数える経路が紛れる
    # (鷹野[PDM] 差し戻し 2026-09-20)。明示 --log は触らない。
    rm -rf -- "$run_dir"
    if [ "$log_path_was_default" -eq 1 ]; then
      rm -f -- "$log_path"
    fi
    die "ゲート 2 の後の真壁は sol で起こす: codex-makabe --model gpt-5.6-sol(codex weekly: ${gate_weekly:-不明})"
  fi
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

# push 許可の解決(--allow-push か BRIEF 本文の「push: 可」行)。事後ガードの ref 変化検出のうち
# push 相当(main/master/remote-tracking の移動)だけを対象に、記録しない扱いにする。
push_allowed=0
if [ "$allow_push" -eq 1 ]; then
  push_allowed=1
elif LC_ALL=C grep -qE '^push:[[:space:]]*可[[:space:]]*$' "$task_path"; then
  push_allowed=1
  echo "[$persona] BRIEF の「push: 可」行を検出。push 相当の ref 変化はガードで記録しない" >&2
fi

# 柏木は plan を作業木でなく run_dir に置く(真壁に検収の手を見せない)。場所は推測させず、環境とプロンプトの両方で渡す。
export CODEX_AGENT_RUN_DIR="$run_dir"

# 巡ループ対応 persona 以外、および --resume 時は 1 session だけ
if [ "$supports_loop" -eq 0 ] || [ -n "$resume_id" ]; then
  loop_enabled=0
fi
rounds_dir="$run_dir/rounds"

# niekawa だけ: 便名の解決(--batch > BRIEF 本文の「便:」行)。解決できなければ post をスキップして続行する。
batch_name=""
batch_dir=""
effective_niekawa_inbox="$run_dir/to-niekawa.tsv"
takano_inbox=""
prev_run_dir=""
resume_checkpoint_text=""
if [ "$persona" = niekawa ]; then
  if batch_name="$(batch_resolve_name "$batch_name_arg" "$task_path")"; then
    :
  else
    batch_name=""
    echo "警告: 便名が解決できない(--batch も BRIEF の「便:」行も無い)。run_dir を便扱いにする" >&2
  fi
  if [ -n "$batch_name" ]; then
    batch_dir="$agent_state_dir/batches/$batch_name"
    mkdir -p "$batch_dir"
    export NIEKAWA_INBOX="$batch_dir/to-niekawa.tsv"
    effective_niekawa_inbox="$NIEKAWA_INBOX"
  fi
  takano_inbox="$(batch_resolve_takano_inbox "$takano_inbox_arg" "$batch_dir")" || true
  if [ "$resume_run" -eq 1 ]; then
    if prev_run_dir="$(batch_resolve_prev_run "$resume_run_arg" "$batch_dir")"; then
      [ -d "$prev_run_dir" ] || die "--resume-run: 前 run_dir が見つからない: $prev_run_dir"
      resume_checkpoint_text="$(batch_render_resume_checkpoint "$prev_run_dir")"
    else
      die "--resume-run: 前 run_dir を解決できない(--resume-run <run_dir> を明示するか、便の runs.tsv が要る)"
    fi
  fi
fi

# 巡 N のプロンプトを組む。巡 2 以降は前巡までの checkpoint(plan / findings / 前巡の verdict)を末尾に写す。
# niekawa は加えて、巡 1 に「前 run の checkpoint」(--resume-run 時)、全巡に「鷹野からの受信」を末尾へ写す。
build_prompt() {
  local round="$1"
  local out="$2"
  local prev_verdict=""
  {
    cat "$CORE/roles/$persona.md"
    printf '\n\n'
    cat "$CORE/codex/$persona.md"
    if [ "$supports_loop" -eq 1 ]; then
      printf '\ncheckpoint の置き場: %s(plan.md / findings.md / verdict.md)\n' "$run_dir"
      printf 'plan の置き場: %s/plan.md\n' "$run_dir"
      printf '巡: %s / %s\n' "$round" "$max_rounds"
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
    fi
    if [ "$persona" = niekawa ]; then
      if [ "$round" -eq 1 ] && [ -n "$resume_checkpoint_text" ]; then
        printf '%s\n' "$resume_checkpoint_text"
      fi
      batch_render_niekawa_inbox "$effective_niekawa_inbox"
    fi
    printf '\n\n## 今回のタスク\n\n'
    cat "$task_path"
  } > "$out"
}

prompt_path="$run_dir/prompt.md"
build_prompt 1 "$prompt_path"

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

permission_args=(--dangerously-bypass-approvals-and-sandbox)
case "$persona" in
  minase) git_name="水無瀬" ;;
  makabe) git_name="真壁" ;;
  kashiwagi) git_name="柏木" ;;
  niekawa) git_name="贄川" ;;
esac
export GIT_AUTHOR_NAME="$git_name" GIT_COMMITTER_NAME="$git_name"
export GIT_AUTHOR_EMAIL="$persona@ai.yumemism.dev" GIT_COMMITTER_EMAIL="$persona@ai.yumemism.dev"

common_args=(
  "${permission_args[@]}"
  -c "model_reasoning_effort=\"$effort\""
  "${mcp_args[@]}"
  -C "$root"
)
if [ -n "$model" ]; then
  common_args+=(-m "$model")
fi
if [ "$persona" = kashiwagi ]; then
  # wait_agent の既定 timeout は 30 秒(codex 0.153.4、未修正)。20 分に 1 回しか起きない(役員 人見 2026-09-16)。
  common_args+=(-c "features.multi_agent_v2.default_wait_timeout_ms=1200000")
fi
if [ "$git_repo" -eq 0 ]; then
  common_args+=(--skip-git-repo-check)
fi

if [ -n "$resume_id" ]; then
  command_args_base=(codex exec "${common_args[@]}" resume "$resume_id")
else
  command_args_base=(codex exec "${common_args[@]}")
fi
command_args=("${command_args_base[@]}" -o "$run_dir/last-message.md" -)

if [ "$dry_run" -eq 1 ] || [ "${CODEX_AGENT_DRY_RUN:-0}" = "1" ]; then
  printf 'dry-run command:'
  printf ' %q' "${command_args[@]}"
  printf ' < %q\n' "$prompt_path"
  printf 'prompt: %s\n' "$prompt_path"
  printf 'prompt 行数: %s\n' "$(wc -l < "$prompt_path" | tr -d ' ')"
  if [ "$persona" = niekawa ]; then
    echo "run_dir: $run_dir"
    echo "便: ${batch_name:-(無し)}"
    echo "便の箱: $effective_niekawa_inbox"
    echo "鷹野の箱: ${takano_inbox:-(post しない)}"
  fi
  echo "--- prompt (巡1) ---"
  cat "$prompt_path"
  exit 0
fi

# 便の run 台帳に 1 行 append(起動時のみ、更新しない。niekawa だけ)。
if [ "$persona" = niekawa ]; then
  if [ -n "$batch_dir" ]; then
    brief_paths_joined=""
    if [ "${#task_files[@]}" -gt 0 ]; then
      brief_paths_joined="$(IFS=,; printf '%s' "${task_files[*]}")"
    fi
    batch_append_run "$batch_dir" "$run_dir" "codex" "$brief_paths_joined" "$prev_run_dir"
  else
    echo "警告: 便名が無いため runs.tsv に記録しない" >&2
  fi
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
  # nameref で呼び出し元の連想配列を名前で受ける。record_snapshot_path と同名なので ShellCheck は
  # 「配列に文字列を代入」と読む(SC2178)。hash_ref / internal_ref は下の unset(引用符内)で使う(SC2034)。
  # shellcheck disable=SC2034,SC2178
  local -n status_ref="$status_name"
  # shellcheck disable=SC2034,SC2178
  local -n hash_ref="$hash_name"
  # shellcheck disable=SC2034,SC2178
  local -n repo_ref="$repo_name"
  # shellcheck disable=SC2034,SC2178
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

declare -A pre_refs=() post_refs=()
declare -A initial_branch=() initial_head=()
declare -A pre_protected_reflogs=() post_protected_reflogs=()

capture_refs() {
  local -n refs_ref="$1"
  local -n reflogs_ref="$2"
  local index label repo_dir oid ref
  for index in "${!repository_dirs[@]}"; do
    label="${repository_labels[$index]}"
    repo_dir="${repository_dirs[$index]}"
    while read -r oid ref; do
      [ -n "$ref" ] || continue
      # nameref 経由で呼び出し元の pre_refs / post_refs に書く。ShellCheck は未使用と読む。
      # shellcheck disable=SC2034
      refs_ref["$label|$ref"]="$oid"
    done < <(git -C "$repo_dir" for-each-ref --format='%(objectname) %(refname)')
    # main/master の commit → reset も記録が残る限り検出する。
    for ref in refs/heads/main refs/heads/master; do
      # shellcheck disable=SC2034
      reflogs_ref["$label|$ref"]="$(git -C "$repo_dir" reflog show --format='%H %gs' "$ref" 2>/dev/null || true)"
    done
    if [ "$1" = pre_refs ]; then
      initial_branch["$label"]="$(git -C "$repo_dir" symbolic-ref -q HEAD || true)"
      initial_head["$label"]="$(git -C "$repo_dir" rev-parse --verify HEAD 2>/dev/null || true)"
    fi
  done
}

if [ "$git_repo" -eq 1 ]; then
  load_direct_submodules
  capture_all_status pre_status pre_hash pre_repo pre_internal
  capture_refs pre_refs pre_protected_reflogs
fi

echo "[$persona] Codex 起動 root=$root log=$log_path"

# 1 巡ぶん Codex を走らせる。stdout は $log_path へ(巡 1 は上書き、巡 2 以降は追記)、session id は巡ごとの log から取る。
# パイプライン全体を setsid + 背景実行にして current_child_pid に pid を残す(SIGTERM/SIGINT を trap から
# 子プロセスグループへ転送するため)。PIPESTATUS はサブシェル内で status_file に書き出して読み戻す。
current_child_pid=""
run_codex_once() {
  local in_prompt="$1"
  local round_log="$2"
  local mode="${3:-overwrite}"
  local append=0
  local use_stdbuf=0
  if [ "$mode" = append ]; then
    append=1
  fi
  if command -v stdbuf >/dev/null 2>&1; then
    use_stdbuf=1
  fi
  local status_file
  status_file="$(mktemp "$run_dir/.codex-status.XXXXXX")"
  set +e
  setsid bash -c '
    round_log="$1"; log_path="$2"; append="$3"; status_file="$4"; use_stdbuf="$5"
    shift 5
    tee_opts=()
    [ "$append" = "1" ] && tee_opts=(-a)
    if [ "$use_stdbuf" = "1" ]; then
      stdbuf -oL -eL "$@" 2>&1 | stdbuf -oL tee "$round_log" | stdbuf -oL tee "${tee_opts[@]}" "$log_path"
    else
      "$@" 2>&1 | tee "$round_log" | tee "${tee_opts[@]}" "$log_path"
    fi
    st=("${PIPESTATUS[@]}")
    printf "%s\n" "${st[@]}" > "$status_file"
  ' _ "$round_log" "$log_path" "$append" "$status_file" "$use_stdbuf" "${command_args[@]}" \
    < "$in_prompt" &
  current_child_pid=$!
  wait "$current_child_pid"
  current_child_pid=""
  set -e
  local statuses=()
  if [ -s "$status_file" ]; then
    mapfile -t statuses < "$status_file"
  fi
  rm -f "$status_file"
  codex_status="${statuses[0]:-1}"
  tee_status="${statuses[1]:-0}"
  if [ "$tee_status" -eq 0 ]; then
    tee_status="${statuses[2]:-0}"
  fi
  session_id="$(sed -nE 's/.*session id:[[:space:]]*([0-9a-fA-F-]{36}).*/\1/p' "$round_log" 2>/dev/null | head -n 1 || true)"
  if [ -z "$session_id" ]; then
    session_id="不明"
  fi
}

# verdict.md の 1 行目を読む。継続 / 承認 / エスカレーション 以外は空を返す。
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

codex_status=0
tee_status=0
session_id="不明"
verdict=""
verdict_status=0
rounds_run=0
session_ids=()
takano_notified=0

# trap(niekawa のみ意味を持つ。他 persona は takano_inbox が空なので notify は無音で戻る):
# verdict が確定せずに終わる経路(exit 4 / Codex 異常終了 / SIGTERM)は「異常終了」で鷹野へ通知する。
# 正常終了(承認・エスカレーション・巡数上限)はメイン処理側で先に通知して takano_notified=1 にする。
notify_abnormal_exit() {
  local reason="$1"
  [ "$persona" = niekawa ] || return 0
  [ "$takano_notified" -eq 0 ] || return 0
  takano_notified=1
  batch_notify_takano "$takano_inbox" "$run_dir" "異常終了" "$reason"
}

on_term() {
  echo "[$persona] SIGTERM/SIGINT を受けた。子プロセスを止めて異常終了を通知する" >&2
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

if [ "$loop_enabled" -eq 0 ]; then
  run_codex_once "$prompt_path" "$run_dir/codex.log"
  rounds_run=1
  session_ids+=("$session_id")
  if [ "$supports_loop" -eq 1 ]; then
    verdict="$(read_verdict "$run_dir/verdict.md")"
  fi
else
  round=1
  while :; do
    round_dir="$rounds_dir/r$round"
    mkdir -p "$round_dir"
    round_prompt="$round_dir/prompt.md"
    if [ "$round" -eq 1 ]; then
      cp "$prompt_path" "$round_prompt"
    else
      build_prompt "$round" "$round_prompt"
    fi
    # 前巡の verdict.md が残っていたら退避済みのはず。残っていれば古いものとして消す。
    rm -f "$run_dir/verdict.md"
    echo "[$persona] 巡 $round / $max_rounds 開始 session=新規"
    command_args=("${command_args_base[@]}" -o "$round_dir/last-message.md" -)
    if [ "$round" -eq 1 ]; then
      run_codex_once "$round_prompt" "$round_dir/codex.log"
    else
      run_codex_once "$round_prompt" "$round_dir/codex.log" append
    fi
    rounds_run="$round"
    session_ids+=("$session_id")
    printf '%s\n' "$session_id" > "$round_dir/session_id"
    if [ -s "$round_dir/last-message.md" ]; then
      cp "$round_dir/last-message.md" "$run_dir/last-message.md"
    fi
    verdict="$(read_verdict "$run_dir/verdict.md")"
    if [ -s "$run_dir/verdict.md" ]; then
      # cp で残す(mv だと run_dir 直下の verdict.md が消え、終端の to-takano 検証・E2E の検算ができなくなる)。
      cp "$run_dir/verdict.md" "$round_dir/verdict.md"
    fi
    echo "巡 $round session_id: $session_id verdict: ${verdict:-不明}"
    if [ "$codex_status" -ne 0 ]; then
      echo "巡 $round: Codex が異常終了(status=$codex_status)。ループを止める" >&2
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
fi

printf '%s\n' "$session_id" > "$run_dir/session_id"
echo "session_id: $session_id"

# 終端の通知(trap より先に、確定した結果で to-takano へ post する。niekawa のみ)。
if [ "$persona" = niekawa ]; then
  if [ "$codex_status" -eq 0 ] && [ "$verdict_status" -ne 5 ] && { [ "$verdict" = "承認" ] || [ "$verdict" = "エスカレーション" ]; }; then
    takano_summary="$(batch_verdict_summary "$run_dir/verdict.md")"
    batch_notify_takano "$takano_inbox" "$run_dir" "$verdict" "$takano_summary"
    takano_notified=1
  elif [ "$verdict_status" -eq 5 ]; then
    # 巡数上限: verdict.md はまだ「継続」のままなので to-takano の verdict ガードに掛からないよう run_dir は "-" で渡す。
    batch_notify_takano "$takano_inbox" "-" "エスカレーション" "巡数上限、verdict 継続のまま(run_dir: $run_dir)"
    takano_notified=1
  fi
fi

changed_files=()
violations=()
if [ "$git_repo" -eq 1 ]; then
  capture_all_status post_status post_hash post_repo post_internal
  capture_refs post_refs post_protected_reflogs

  # 実行前から dirty なパスが clean になっても比較できるよう、実行後のハッシュを取る。
  for path in "${!pre_status[@]}"; do
    if [ -z "${post_status[$path]+present}" ]; then
      post_status["$path"]="  "
      # post_repo / post_internal は capture_all_status に名前で渡して nameref で読む。ShellCheck は未使用と読む。
      # shellcheck disable=SC2034
      post_repo["$path"]="${pre_repo[$path]}"
      # shellcheck disable=SC2034
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

  # commit で status から消えた変更も権限チェックに含める。
  for index in "${!repository_dirs[@]}"; do
    label="${repository_labels[$index]}"
    before_head="${initial_head[$label]:-}"
    after_head="$(git -C "${repository_dirs[$index]}" rev-parse --verify HEAD 2>/dev/null || true)"
    if [ -n "$after_head" ] && [ "$before_head" != "$after_head" ]; then
      if [ -z "$before_head" ]; then
        # unborn branch の初回 commit は空の tree と比較する。
        before_head="$(git -C "${repository_dirs[$index]}" hash-object -t tree /dev/null)"
      fi
      while IFS= read -r -d '' path; do
        if [ -n "${repository_prefixes[$index]}" ]; then
          changed_files+=("${repository_prefixes[$index]}/$path")
        elif ! is_direct_submodule_path "$path"; then
          changed_files+=("$path")
        fi
      done < <(git -C "${repository_dirs[$index]}" diff --name-only --no-renames -z "$before_head" "$after_head")
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
        makabe|kashiwagi|niekawa) ;;
      esac
    done

    declare -A checked_refs=()
    for key in "${!pre_refs[@]}" "${!post_refs[@]}"; do
      [ -z "${checked_refs[$key]+present}" ] || continue
      checked_refs["$key"]=1
      [ "${pre_refs[$key]:-}" != "${post_refs[$key]:-}" ] || continue
      label="${key%%|*}"
      ref="${key#*|}"
      case "$ref" in
        refs/heads/main|refs/heads/master|refs/remotes/*)
          if [ "$push_allowed" -eq 1 ]; then
            echo "[$persona] push 許可により記録しない: $label $ref" >&2
          else
            violations+=("ref 変化を検出: $label $ref")
          fi ;;
        refs/heads/*)
          # 新規 branch 作成と起動時 current branch への commit は許可。
          if [ -n "${pre_refs[$key]+present}" ] && [ "$ref" != "${initial_branch[$label]}" ]; then
            violations+=("ref 変化を検出: $label $ref")
          fi ;;
        *) violations+=("ref 変化を検出: $label $ref") ;;
      esac
    done
    for key in "${!pre_protected_reflogs[@]}"; do
      if [ "${pre_protected_reflogs[$key]}" != "${post_protected_reflogs[$key]}" ]; then
        violations+=("保護 branch reflog 変化を検出: $key")
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
echo "run_dir: $run_dir"
if [ "$supports_loop" -eq 1 ]; then
  echo "巡数: $rounds_run"
  echo "verdict: ${verdict:-不明}"
  echo "session_ids: ${session_ids[*]}"
fi
echo "log: $log_path"
if [ "$git_repo" -eq 1 ]; then
  echo "変更ファイル数: ${#changed_files[@]}"
else
  echo "変更ファイル数: 0 (非 git のため未計測)"
fi

# 権限逸脱を最優先し、それがなければ Codex / tee の失敗、次に verdict の異常(4: 不正・欠落、5: 巡数上限)を返す。
if [ "$guard_status" -ne 0 ]; then
  exit 3
fi
if [ "$codex_status" -ne 0 ]; then
  exit "$codex_status"
fi
if [ "$tee_status" -ne 0 ]; then
  exit "$tee_status"
fi
if [ "$verdict_status" -ne 0 ]; then
  exit "$verdict_status"
fi
exit 0
