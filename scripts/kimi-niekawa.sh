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
      --kashiwagi-model <id>  贄川が柏木を起こすときの model(既定は KASHIWAGI_ROUTE 別 ── opus なら opus、
                         codex なら sol(astra は既定から退役、役員 人見 2026-09-24)。env KASHIWAGI_MODEL でも指定できる)
                         柏木の実行経路は env KASHIWAGI_ROUTE(opus|codex、既定 opus)で切り替える。
                         opus は claude-kashiwagi.sh(effort xhigh)、codex は従来の codex-kashiwagi
      --makabe-model <id>     贄川が真壁を起こすときの model(既定は persona 既定の luna、env
                         MAKABE_MODEL でも指定できる。ゲート 2 の P0 を直す巡は既存の作法どおり sol)
                         真壁の実行経路は env MAKABE_ROUTE(claude|codex、既定 codex)で切り替える。
                         claude は codex-makabe が内部で claude-makabe(Claude sonnet)へ分岐する経路
                         (codex weekly 逼迫時の代替、庵野 2026-09-22)、codex は従来の codex-makabe
      --batch <name>     便名を明示する(既定: BRIEF 本文の「便: <名>」行)
      --inbox <path>     鷹野の箱(to-takano.tsv)を明示する。既定は便ディレクトリの to-takano.tsv
      --resume-run [<前run_dir>]
                         新しい run_dir で便を再開する。前 run(省略時は便の runs.tsv の最終行)の
                         checkpoint を巡 1 の prompt 末尾に写す
      --budget <分>      便全体の時間予算(分)。env NIEKAWA_BUDGET_MIN でも指定できる。指定時は
                         巡ごとの prompt 冒頭に経過時間を出す。起点は便の最初の run(runs.tsv 1 行目)の
                         起動時刻 ── --resume-run で起こし直しても通算する。無指定なら行を出さない
      --dry-run          prompt を組み立てて stdout に出し、kimi を起動せず exit 0(検算用)
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

便のディレクトリ(${CODEX_AGENT_STATE_DIR:-~/.codex-agents}/batches/<便名>/)に to-takano.tsv(鷹野の箱)・
to-niekawa.tsv(便の箱)・runs.tsv(便の run 台帳)を持つ。便名が解決できないときは post をスキップして
警告だけ出し、続行する(run_dir 単位の旧動作にフォールバック)。

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

# shellcheck source=models.env
source "$CORE/scripts/models.env"
# shellcheck source=lib/batch-inbox.sh
source "$CORE/scripts/lib/batch-inbox.sh"
# 便を Claude デスクトップの scope から切り離し、systemd --user の service に載せ直す
# (案 A、役員 人見 裁定 2026-09-25)。wrap したらここで終わる ── 詳細は lib/unit-wrap.sh。
# lib/unit-wrap.sh 自体が無い CORE(古い pin、水無瀬が並行で書いている最中 等)は
# 警告無しで unit化せず続行する(他の退避口と同じ扱い ── 無くても起動を止めない)。
if [ -f "$CORE/scripts/lib/unit-wrap.sh" ]; then
  # shellcheck source=lib/unit-wrap.sh
  source "$CORE/scripts/lib/unit-wrap.sh"
  if niekawa_unit_wrap "niekawa" "$script_path" "$@"; then
    exit "$NIEKAWA_UNIT_WRAP_EXIT_CODE"
  fi
fi

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
budget_min="${NIEKAWA_BUDGET_MIN:-}"
# 柏木の実行経路(役員 人見 2026-09-21 23:55、実行経路 C の新設)。既定 opus = claude-kashiwagi.sh(Opus,
# effort xhigh)。codex = 従来の codex-kashiwagi(既定 gpt-6-sol、astra は既定から退役。--kashiwagi-model の指定先も可)。
# 走行中の run には効かない(env は起動時に固定、新しい起動からだけ適用される)。
kashiwagi_route="${KASHIWAGI_ROUTE:-opus}"
case "$kashiwagi_route" in
  opus|codex) ;;
  *) die "KASHIWAGI_ROUTE は opus か codex のどちらか: $kashiwagi_route" ;;
esac
# 真壁の実行経路(codex weekly 逼迫時の代替、庵野 2026-09-22)。既定 codex = 従来の codex-makabe
# (gpt-6-luna)。claude なら codex-makabe が内部で claude-makabe(Claude sonnet)へ分岐する ──
# 贄川の呼び出しコマンド自体は codex-makabe のまま変えない。走行中の run には効かない(env は
# 起動時に固定、新しい起動からだけ適用される)。
makabe_route="${MAKABE_ROUTE:-codex}"
case "$makabe_route" in
  claude|codex) ;;
  *) die "MAKABE_ROUTE は claude か codex のどちらか: $makabe_route" ;;
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
    --budget)
      [ "$#" -ge 2 ] || die "$1 には 分 が必要"
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--budget は 1 以上の整数(分): $2"
      budget_min="$2"
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
      # 任意引数(次が option っぽくなければ前 run_dir として食う)
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
  echo "警告: kimi CLI に effort を渡す手段が無い(config.toml の kimi-code/k3-256k 既定 high が使われる。指定値 $effort は記録のみ)" >&2
fi
if [ -n "$budget_min" ] && ! [[ "$budget_min" =~ ^[1-9][0-9]*$ ]]; then
  die "budget(分)は 1 以上の整数: $budget_min(env NIEKAWA_BUDGET_MIN か --budget で指定)"
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
  # 既定の log は必ず作る(--log 未指定で作られない不具合の修正、2b-2 実測 09-20)。
  # 明示 --log は触らない(テスト等で意図的に無効なパスを渡す場合があるため)。
  : > "$log_path" 2>/dev/null || true
fi

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

# 便名の解決(--batch > BRIEF 本文の「便:」行)。解決できなければ空(旧動作: run_dir 単位)。
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

# 便の箱(NIEKAWA_INBOX があれば便ディレクトリ、無ければ run_dir 直下)。
effective_niekawa_inbox="${NIEKAWA_INBOX:-$run_dir/to-niekawa.tsv}"

# 鷹野の箱(--inbox > env TAKANO_INBOX > 便ディレクトリ)。
takano_inbox="$(batch_resolve_takano_inbox "$takano_inbox_arg" "$batch_dir")" || true

# --resume-run: 前 run を解決し、巡 1 に写す checkpoint を組む。
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

# 柏木 / 真壁の model 指定(工程限定、役員 人見 2026-09-21 の追加裁定)。子の kimi プロセスから
# Bash で起こす codex-kashiwagi / codex-makabe / claude-kashiwagi へ env で渡す(Bash tool から素直に
# `echo $KASHIWAGI_MODEL` できる)のと、round prompt に明示の 2 段で確実にする ── LLM が env を
# 自発的に読みに行くとは限らないため。
export KASHIWAGI_MODEL="$kashiwagi_model"
export MAKABE_MODEL="$makabe_model"
export KASHIWAGI_ROUTE="$kashiwagi_route"
export MAKABE_ROUTE="$makabe_route"

# 時間予算の起点(genesis)。--budget / env NIEKAWA_BUDGET_MIN が無ければ計算しない。
# 便の最初の run の開始時刻(runs.tsv 1 行目、この run 自身がまだ append していない時点で読む)を
# 起点にする ── --resume-run で新しい run_dir を起こしても、同じ便なら runs.tsv の 1 行目は
# 変わらないので通算になる。runs.tsv が無い(この run が便の最初、または便名が無い)ときは
# この run 自身の起動時刻を起点にする(elapsed は 0 から始まり、この run 内では正しく進む)。
budget_sec=""
elapsed_genesis_epoch=""
if [ -n "$budget_min" ]; then
  budget_sec=$((budget_min * 60))
  genesis_ts=""
  if [ -n "$batch_dir" ] && [ -s "$batch_dir/runs.tsv" ]; then
    genesis_ts="$(head -n 1 "$batch_dir/runs.tsv" | awk -F'\t' '{print $1}')"
  fi
  if [ -n "$genesis_ts" ]; then
    elapsed_genesis_epoch="$(date -d "$genesis_ts" +%s 2>/dev/null || true)"
  fi
  [ -n "$elapsed_genesis_epoch" ] || elapsed_genesis_epoch="$(date +%s)"
fi

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

# 巡 N の -p 本文を組む(checkpoint の置き場 + 巡番号 + 前巡までの checkpoint + 前 run の checkpoint(巡1のみ)
# + 鷹野からの受信(全巡) + 今回のタスク)。roles / kimi の起動契約は agent.md の system prompt 側に入るので、
# ここでは重複させない。
build_round_prompt() {
  local round="$1"
  local out="$2"
  local prev_verdict=""
  {
    printf 'checkpoint の置き場: %s(plan.md / findings.md / verdict.md)\n' "$run_dir"
    printf 'plan の置き場: %s/plan.md\n' "$run_dir"
    printf '巡: %s / %s\n' "$round" "$max_rounds"
    if [ -n "$budget_min" ]; then
      local now_epoch elapsed_sec
      now_epoch="$(date +%s)"
      elapsed_sec=$((now_epoch - elapsed_genesis_epoch))
      [ "$elapsed_sec" -ge 0 ] || elapsed_sec=0
      printf '時間: elapsed %ss / %ss\n' "$elapsed_sec" "$budget_sec"
    fi
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
        printf '柏木の model 指定: 既定のまま(--model を足さない、persona 既定 sol)\n'
      fi
    fi
    if [ "$makabe_route" = claude ]; then
      printf '真壁の呼び出し: codex-makabe をそのまま使う(env MAKABE_ROUTE=claude、wrapper が内部で claude-makabe(Claude sonnet)へ分岐する。codex weekly 逼迫時の代替経路、庵野 2026-09-22)\n'
    fi
    if [ -n "$makabe_model" ]; then
      printf '真壁の model 指定: codex-makabe に --model %s を足す(env MAKABE_MODEL、工程限定の裁定。MAKABE_ROUTE=claude の間は無視されて claude sonnet 固定)\n' "$makabe_model"
    else
      printf '真壁の model 指定: 既定のまま(--model を足さない、persona 既定 luna。ゲート 2 の P0 を直す巡は従来どおり --model %s、MAKABE_ROUTE=claude の間は sonnet 固定)\n' "$CODEX_SOL_MODEL"
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

# --dry-run: 巡 1 の prompt を組み立てて出すだけで、kimi は起動しない。runs.tsv にも書かない。
if [ "$dry_run" -eq 1 ]; then
  dry_round_dir="$rounds_dir/r1"
  mkdir -p "$dry_round_dir"
  dry_prompt="$dry_round_dir/prompt.md"
  build_round_prompt 1 "$dry_prompt"
  echo "[niekawa] dry-run root=$root run_dir=$run_dir batch=${batch_name:-(無し)}"
  echo "[niekawa] 便の箱: $effective_niekawa_inbox"
  echo "[niekawa] 鷹野の箱: ${takano_inbox:-(post しない)}"
  echo "--- prompt (巡1) ---"
  cat "$dry_prompt"
  exit 0
fi

# 便の run 台帳に 1 行 append(起動時のみ、更新しない)。
if [ -n "$batch_dir" ]; then
  brief_paths_joined=""
  if [ "${#task_files[@]}" -gt 0 ]; then
    brief_paths_joined="$(IFS=,; printf '%s' "${task_files[*]}")"
  fi
  batch_append_run "$batch_dir" "$run_dir" "kimi" "$brief_paths_joined" "$prev_run_dir"
else
  echo "警告: 便名が無いため runs.tsv に記録しない" >&2
fi

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
current_child_pid=""
takano_notified=0

# trap: verdict が確定せずに終わる経路(exit 4 / kimi 異常終了 / SIGTERM)は「異常終了」で鷹野へ通知する。
# 正常終了(承認・エスカレーション・巡数上限)はメイン処理側で先に通知して takano_notified=1 にする。
notify_abnormal_exit() {
  local reason="$1"
  [ "$takano_notified" -eq 0 ] || return 0
  takano_notified=1
  batch_notify_takano "$takano_inbox" "$run_dir" "異常終了" "$reason"
}

on_term() {
  echo "[niekawa] SIGTERM/SIGINT を受けた。子プロセスを止めて異常終了を通知する" >&2
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
  render_agent_md "$run_dir/agent.md"
  echo "[niekawa] 巡 $round / $max_rounds 開始 session=新規"

  round_log="$round_dir/log.jsonl"
  set +e
  setsid bash -c 'cd "$1" && exec kimi -p "$2" --agent-file "$3" -m "$4" --output-format stream-json' \
    _ "$root" "$prompt_arg" "$run_dir/agent.md" "$KIMI_MODEL" \
    < /dev/null > "$round_log" 2>"$round_dir/stderr.log" &
  current_child_pid=$!
  wait "$current_child_pid"
  kimi_status=$?
  current_child_pid=""
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
    # cp で残す(mv だと run_dir 直下の verdict.md が消え、終端の to-takano 検証・E2E の検算ができなくなる)。
    cp "$run_dir/verdict.md" "$round_dir/verdict.md"
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

# 終端の通知(trap より先に、確定した結果で to-takano へ post する)。
if [ "$kimi_status" -eq 0 ] && [ "$verdict_status" -ne 5 ] && { [ "$verdict" = "承認" ] || [ "$verdict" = "エスカレーション" ]; }; then
  summary="$(batch_verdict_summary "$run_dir/verdict.md")"
  batch_notify_takano "$takano_inbox" "$run_dir" "$verdict" "$summary"
  takano_notified=1
elif [ "$verdict_status" -eq 5 ]; then
  # 巡数上限: verdict.md はまだ「継続」のままなので to-takano の verdict ガードに掛からないよう run_dir は "-" で渡す。
  batch_notify_takano "$takano_inbox" "-" "エスカレーション" "巡数上限、verdict 継続のまま(run_dir: $run_dir)"
  takano_notified=1
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
