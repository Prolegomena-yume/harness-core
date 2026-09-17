#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: kimi-niekawa.sh [options] [task...]

options:
  -f, --file <path>     タスク本文をファイルから読む。複数指定可
  -C, --cd <dir>        作業ルート(既定: 起動時ディレクトリの git toplevel)
      --log <path>      ログ出力先
      --rounds <n>       巡数上限(既定 12)。verdict が「継続」の間、新しい session で次の巡を起こす
      --no-loop          1 session だけ走らせる(巡ループ無し)
      --effort <level>   low|high|max(既定 high)。kimi CLI に渡す手段が無く記録のみ(下記参照)
  -h, --help             この usage を表示

task と --file が無い場合は標準入力からタスク本文を読む。
model は kimi-code/k3-256k 固定(--model は受けない)。--resume は無い(--agent-file は --session / --continue と併用不可のため、
巡ごとに新しい session になる)。

起動時の run_dir(${CODEX_AGENT_STATE_DIR:-~/.codex-agents}/runs/niekawa-<run_id>)を CODEX_AGENT_RUN_DIR で export する。
起動時に `rates kimi` を 1 回叩いて <run_dir>/rates.json に残す(失敗は警告のみで続行)。
`-p` に渡すのは checkpoint の置き場(<run_dir>/plan.md / findings.md / verdict.md)と巡番号、前巡までの checkpoint、
今回のタスク。100KB を超えたら rounds/r<N>/prompt.md にファイルとして置き、`-p` は「まず <path> を読む」の 1 行にする
(kimi -p の argv は 128KB で落ちるため)。
verdict.md の 1 行目が 継続 / 承認 / エスカレーション。巡ループ実行中に verdict が無い・不正なら exit 4、
巡数上限に当たったら exit 5。--no-loop は 1 session だけ走らせ、verdict の値によらず exit 0。

--effort について: kimi CLI(0.40.1)の -p モードには reasoning effort を渡す CLI 引数が無い(config.toml の
モデル別 default_effort だけが効く。kimi-code/k3-256k の既定は high で、このランチャの既定と一致する)。
このオプションは codex-agent.sh との引数の語を揃えるために受け付け、low|high|max を検証するが、
high 以外を指定しても kimi の挙動は変わらないため警告を出す。
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
  echo "警告: kimi CLI に effort を渡す手段が無い(config.toml の kimi-code/k3-256k 既定 high が使われる。指定値 $effort は記録のみ)" >&2
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

if [ -z "$log_path" ]; then
  log_path="$agent_state_dir/logs/$run_id.log"
fi
mkdir -p "$(dirname "$log_path")"

# rates ゲートはランチャに入れない(裁定 #8)。自サービスの残量を起動時に 1 回だけ記録する。失敗は警告のみで続行。
if command -v rates >/dev/null 2>&1; then
  if ! rates kimi > "$run_dir/rates.json" 2>"$run_dir/rates.err"; then
    echo "警告: rates kimi の取得に失敗した(続行): $(tr '\n' ' ' < "$run_dir/rates.err")" >&2
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

# roles/niekawa.md と kimi/niekawa.md は水無瀬が並行で書いている最中の場合がある。無ければ空として扱い警告を出して続行する。
role_content=""
if [ -f "$CORE/roles/niekawa.md" ]; then
  role_content="$(cat "$CORE/roles/niekawa.md")"
else
  echo "警告: roles/niekawa.md が無い(空として続行)" >&2
fi
kimi_contract=""
if [ -f "$CORE/kimi/niekawa.md" ]; then
  kimi_contract="$(cat "$CORE/kimi/niekawa.md")"
else
  echo "警告: kimi/niekawa.md が無い(空として続行)" >&2
fi

git_name="贄川"
export GIT_AUTHOR_NAME="$git_name" GIT_COMMITTER_NAME="$git_name"
export GIT_AUTHOR_EMAIL="niekawa@ai.yumemism.dev" GIT_COMMITTER_EMAIL="niekawa@ai.yumemism.dev"

# agent.md を run_dir 直下の 1 箇所に巡ごとに描画し直す(--agent-file <path>)。
# frontmatter は name / description / tools だけ(Agent は渡さない = 真壁を起こす手段は Bash からの codex-makabe だけ)。
render_agent_md() {
  local out="$1"
  {
    printf -- '---\n'
    printf 'name: niekawa\n'
    printf 'description: 贄川 ORC ── 段取り(prolegomena 群、Kimi K3)\n'
    printf 'tools: [Bash, Read, Write, Edit, Glob, Grep]\n'
    printf -- '---\n'
    # 文字どおりの ${base_prompt} トークンを書く(kimi --agent-file が既定の system prompt を残す構文。展開しない)。
    # shellcheck disable=SC2016
    printf '%s\n\n' '${base_prompt}'
    if [ -n "$role_content" ]; then
      printf '%s\n\n' "$role_content"
    fi
    if [ -n "$kimi_contract" ]; then
      printf '%s\n' "$kimi_contract"
    fi
  } > "$out"
}

# 巡 N の -p 本文を組む(checkpoint の置き場 + 巡番号 + 前巡までの checkpoint + 今回のタスク)。
# roles / kimi の起動契約は agent.md の system prompt 側に入るので、ここでは重複させない。
build_round_prompt() {
  local round="$1"
  local out="$2"
  local prev_verdict=""
  {
    printf 'checkpoint の置き場: %s(plan.md / findings.md / verdict.md)\n' "$run_dir"
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
    printf '\n\n## 今回のタスク\n\n'
    cat "$task_path"
  } > "$out"
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

git_status_paths() {
  git -C "$1" status --porcelain=v1 --untracked-files=all 2>/dev/null | cut -c4- | LC_ALL=C sort -u
}

pre_status=""
if [ "$git_repo" -eq 1 ]; then
  pre_status="$(git_status_paths "$root")"
fi

echo "[niekawa] Kimi 起動 root=$root log=$log_path"

kimi_status=0
verdict=""
verdict_status=0
rounds_run=0
session_id="不明"
session_ids=()

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
  render_agent_md "$run_dir/agent.md"
  echo "[niekawa] 巡 $round / $max_rounds 開始 session=新規"

  round_log="$round_dir/log.jsonl"
  set +e
  ( cd "$root" && kimi -p "$prompt_arg" --agent-file "$run_dir/agent.md" -m kimi-code/k3-256k --output-format stream-json ) \
    < /dev/null > "$round_log" 2>"$round_dir/stderr.log"
  kimi_status=$?
  set -e
  cat "$round_log" >> "$log_path"
  if [ -s "$round_dir/stderr.log" ]; then
    cat "$round_dir/stderr.log" >> "$log_path"
  fi

  session_id="$(jq -rs '
      map(select(.role=="meta" and .type=="session.resume_hint" and (.session_id != null)))
      | if length > 0 then last.session_id else empty end
    ' "$round_log" 2>/dev/null || true)"
  [ -n "$session_id" ] || session_id="不明"
  printf '%s\n' "$session_id" > "$round_dir/session_id"
  session_ids+=("$session_id")

  last_message="$(jq -rs '
      map(select(.role=="assistant" and (.content != null)))
      | if length > 0 then last.content else empty end
    ' "$round_log" 2>/dev/null || true)"
  if [ -n "$last_message" ]; then
    printf '%s\n' "$last_message" > "$round_dir/last-message.md"
    cp "$round_dir/last-message.md" "$run_dir/last-message.md"
  fi

  rounds_run="$round"
  verdict="$(read_verdict "$run_dir/verdict.md")"
  if [ -s "$run_dir/verdict.md" ]; then
    mv "$run_dir/verdict.md" "$round_dir/verdict.md"
  fi
  echo "巡 $round session_id: $session_id verdict: ${verdict:-不明}"

  if [ "$kimi_status" -ne 0 ]; then
    echo "巡 $round: kimi が異常終了(status=$kimi_status)。ループを止める" >&2
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

echo "persona: niekawa"
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

if [ "$kimi_status" -ne 0 ]; then
  exit "$kimi_status"
fi
if [ "$verdict_status" -ne 0 ]; then
  exit "$verdict_status"
fi
exit 0
