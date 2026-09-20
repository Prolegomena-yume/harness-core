#!/usr/bin/env bash
# kimi 0.40.1 の PreToolUse hook。書式は verdict-stop.sh の冒頭コメントと同じ(実測の出所も同じ)。
#
# PreToolUse の inputData(camelCase → snake_case): {hook_event_name, session_id, cwd,
#   tool_name, tool_input, tool_call_id}。config の matcher は使わない(付けると呼ばれない、2026-09-20 実測)、
#   tool_name はここで見る。
#
# この hook の中身:Bash の command に `codex-kashiwagi` を含み、`-f` / `--file` の指す
# ファイル名が `findings.md`(= ゲート 2)のとき、便ディレクトリの `gates.tsv`
# (`時刻 \t run_dir \t gate`)を見て、ゲート 2 の行が既に 1 本あれば block する
# (理由「ゲート 2 は便に 1 回、直った巡は自分の検収で閉じる」)。無ければ 1 行 append して通す。
# ゲート 1(plan.md)は記録するだけで block しない。
#
# NIEKAWA_INBOX が無い(人見の対話 kimi、または便ディレクトリが無いランチャ実行)なら素通し。
# jq が無い環境でも素通し(壊れたシステムより通す方を選ぶ)。
#
# 適用は鷹野が config.toml に足す(このスクリプト自体は config.toml を編集しない)。

set -u

stdin_json="$(cat 2>/dev/null || true)"

if [ -z "${NIEKAWA_INBOX:-}" ]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

command_str="$(printf '%s' "$stdin_json" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
case "$command_str" in
  *codex-kashiwagi*) ;;
  *) exit 0 ;;
esac

# -f <path> / --file <path> / -f=<path> の最後の指定を拾い、引用符を剥がして basename を見る。
fpath="$(printf '%s' "$command_str" \
  | grep -oE '(^|[[:space:]])(-f|--file)[=[:space:]]+[^[:space:]]+' \
  | tail -1 \
  | sed -E 's/^[[:space:]]*(-f|--file)[=[:space:]]+//')"
fpath="${fpath%\"}"
fpath="${fpath#\"}"
fpath="${fpath%\'}"
fpath="${fpath#\'}"
base=""
[ -n "$fpath" ] && base="$(basename -- "$fpath")"

gate=""
case "$base" in
  plan.md) gate=1 ;;
  findings.md) gate=2 ;;
esac

batch_dir="$(dirname -- "$NIEKAWA_INBOX")"
gates_tsv="$batch_dir/gates.tsv"
run_dir="${CODEX_AGENT_RUN_DIR:--}"

# block は「exit 0 + stdout の JSON({hookSpecificOutput:{permissionDecision:"deny",...}})」の形
# (verdict-stop.sh と同じ、kimi 0.40.1 実測)。
block() {
  local reason="$1" escaped
  escaped="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$escaped"
  echo "$reason" >&2
  exit 0
}

if [ "$gate" = "2" ] && [ -f "$gates_tsv" ] \
  && awk -F'\t' '$3=="2"{found=1} END{exit !found}' "$gates_tsv"; then
  block "ゲート 2 は便に 1 回、直った巡は自分の検収で閉じる"
fi

if [ -n "$gate" ]; then
  ts="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
  mkdir -p "$batch_dir"
  printf '%s\t%s\t%s\n' "$ts" "$run_dir" "$gate" >> "$gates_tsv"
fi

exit 0
