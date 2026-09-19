#!/usr/bin/env bash
# 便ディレクトリ・鷹野との箱まわりの共通処理(kimi-niekawa.sh / codex-agent.sh から source する)。
# 契約は BRIEF-inbox-2(2026-09-20)。単体では実行しない(関数定義のみ)。

# 行の TAB/改行を空白へ潰す(to.sh と同じ流儀)。
batch_flatten() {
  printf '%s' "$1" | tr '\n\t' '  '
}

# --batch 明示 > BRIEF 本文の「便: <名>」行。無ければ空文字(呼び出し側で警告)。
batch_resolve_name() {
  local explicit="$1" taskfile="$2" line name
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -f "$taskfile" ]; then
    line="$(LC_ALL=C grep -m1 -E '^便:[[:space:]]*' "$taskfile" 2>/dev/null || true)"
    if [ -n "$line" ]; then
      name="${line#便:}"
      name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ -n "$name" ]; then
        printf '%s\n' "$name"
        return 0
      fi
    fi
  fi
  return 1
}

# 鷹野の箱の解決順: --inbox(呼び出し側の明示引数) > env TAKANO_INBOX > 便ディレクトリ/to-takano.tsv。
# どれも無ければ空文字を返す(呼び出し側は post しない)。
batch_resolve_takano_inbox() {
  local cli_inbox="$1" batch_dir="$2"
  if [ -n "$cli_inbox" ]; then
    printf '%s\n' "$cli_inbox"
    return 0
  fi
  if [ -n "${TAKANO_INBOX:-}" ]; then
    printf '%s\n' "$TAKANO_INBOX"
    return 0
  fi
  if [ -n "$batch_dir" ]; then
    printf '%s\n' "$batch_dir/to-takano.tsv"
    return 0
  fi
  printf ''
  return 1
}

# runs.tsv に 1 行 append する。列: 起動時刻 run_dir 実体 BRIEFのパス 前run。
batch_append_run() {
  local batch_dir="$1" run_dir="$2" entity="$3" brief_paths="$4" prev_run="$5"
  local runs_tsv="$batch_dir/runs.tsv"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
  [ -n "$brief_paths" ] || brief_paths="-"
  [ -n "$prev_run" ] || prev_run="-"
  mkdir -p "$batch_dir"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(batch_flatten "$ts")" "$(batch_flatten "$run_dir")" "$(batch_flatten "$entity")" \
    "$(batch_flatten "$brief_paths")" "$(batch_flatten "$prev_run")" >> "$runs_tsv"
}

# --resume-run の前 run_dir を決める。引数指定があればそれ、無ければ便の runs.tsv の最終行。
batch_resolve_prev_run() {
  local explicit="$1" batch_dir="$2"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -n "$batch_dir" ] && [ -f "$batch_dir/runs.tsv" ]; then
    local last
    last="$(tail -n 1 "$batch_dir/runs.tsv" | awk -F'\t' '{print $2}')"
    if [ -n "$last" ]; then
      printf '%s\n' "$last"
      return 0
    fi
  fi
  return 1
}

# 前 run の rounds/r<N>/ のうち番号最大のものを返す。無ければ空。
batch_last_round_dir() {
  local prev_run_dir="$1" d b n last_n=-1 last_dir=""
  [ -d "$prev_run_dir/rounds" ] || { printf ''; return 0; }
  for d in "$prev_run_dir"/rounds/r*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    n="${b#r}"
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$last_n" ]; then
      last_n="$n"
      last_dir="${d%/}"
    fi
  done
  printf '%s' "$last_dir"
}

# 「## 前 run の checkpoint」ブロックを stdout に書く(plan.md / findings.md / 前 run 最終巡の verdict.md)。
batch_render_resume_checkpoint() {
  local prev_run_dir="$1" name last_round_dir
  printf '\n## 前 run の checkpoint(前 run_dir: %s)\n' "$prev_run_dir"
  for name in plan.md findings.md; do
    if [ -s "$prev_run_dir/$name" ]; then
      printf '\n### %s\n\n' "$name"
      cat "$prev_run_dir/$name"
      printf '\n'
    fi
  done
  last_round_dir="$(batch_last_round_dir "$prev_run_dir")"
  if [ -n "$last_round_dir" ] && [ -s "$last_round_dir/verdict.md" ]; then
    printf '\n### 前 run 最終巡の verdict.md\n\n'
    cat "$last_round_dir/verdict.md"
    printf '\n'
  fi
}

# 「## 鷹野からの受信」ブロックを stdout に書く。箱が無い/空なら何も出さない(見出しごと省略)。
batch_render_niekawa_inbox() {
  local inbox="$1" ts f_from f_kind f_rundir f_summary
  [ -n "$inbox" ] && [ -s "$inbox" ] || return 0
  printf '\n## 鷹野からの受信\n\n'
  while IFS=$'\t' read -r ts f_from f_kind f_rundir f_summary; do
    [ -n "${f_kind:-}" ] || continue
    printf -- '- %s %s: %s\n' "$ts" "$f_kind" "$f_summary"
  done < "$inbox"
}

# verdict.md から to-takano への要旨を作る。
#   エスカレーション想定:「## 問い」見出し以下、次の見出しまで
#   それ以外: 2行目以降の先頭 1 段落
# 1行に潰して返す。
batch_verdict_summary() {
  local f="$1"
  if [ ! -s "$f" ]; then
    printf '(verdict.md 無し)'
    return 0
  fi
  if LC_ALL=C grep -q '^## 問い' "$f"; then
    awk '
      /^## 問い/ { flag=1; next }
      /^## / { if (flag) exit }
      flag { print }
    ' "$f" | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  else
    tail -n +2 "$f" | awk '
      BEGIN { started = 0 }
      /[^[:space:]]/ { started = 1 }
      started && /^[[:space:]]*$/ { exit }
      started { print }
    ' | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  fi
}

# to-takano を呼ぶ。inbox が空なら post せず警告だけ出す(便名が無いケース)。
batch_notify_takano() {
  local inbox="$1" rundir="$2" kind="$3" summary="$4"
  if [ -z "$inbox" ]; then
    echo "警告: 便名が無いため to-takano へ post しない(kind=$kind、要旨: $summary)" >&2
    return 0
  fi
  if ! to-takano --from 贄川 --kind "$kind" --run-dir "$rundir" --inbox "$inbox" -- "$summary" >&2; then
    echo "警告: to-takano 呼び出しに失敗した(kind=$kind)" >&2
    return 1
  fi
  return 0
}
