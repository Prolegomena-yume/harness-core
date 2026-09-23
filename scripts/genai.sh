#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: genai.sh <in.md> <out.md> [--k3]

源内[WT] の日本語リライト。Gemini 3.8 Flash (High)(agy)を既定、--k3 で Kimi K3 にフォールバックする。
commit しない、in / out 以外のファイルを書かない、出力を返すだけ。

  <in.md>    リライト対象。100KB を超えたら分割せず exit 2 で断る
  <out.md>   リライト結果の書き出し先
  --k3       agy の代わりに kimi-code/k3-256k を使う(枠切れ時のフォールバック)
  -h, --help この usage を表示

指示文は固定:「日本語を整える、意味を変えない、Markdown 構造と code block を保つ、本文だけを返す」。
agy は `agy -p "<本文>" --model gemini-3.8-flash-high --output-format json --dangerously-skip-permissions --disable-slash-commands`
を空の一時 cwd で走らせ、`.response` を out に書く。--k3 は agent-file で
disallowedTools: [Bash, Write, Edit, Agent] を渡し、stream-json の最後の assistant content を取る。
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

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  usage
  exit 0
fi

use_k3=0
positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --k3)
      use_k3=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) die "不明な option: $1" ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

[ "${#positional[@]}" -eq 2 ] || die "使い方: genai.sh <in.md> <out.md> [--k3](position 引数は 2 つ)"
in_path="${positional[0]}"
out_path="${positional[1]}"

[ -f "$in_path" ] || die "入力が見つからない: $in_path"
[ -r "$in_path" ] || die "入力を読めない: $in_path"

in_size="$(wc -c < "$in_path" | tr -d ' ')"
[ "$in_size" -le 102400 ] || die "入力が 100KB を超える(分割しない): $in_path ($in_size バイト)"

instruction='日本語を整える、意味を変えない、Markdown 構造と code block を保つ、括弧で原文の語を添えない、本文だけを返す。'

work_dir="$(mktemp -d)"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT

prompt_path="$work_dir/prompt.md"
{
  printf '%s\n\n' "$instruction"
  cat "$in_path"
} > "$prompt_path"
prompt_content="$(cat "$prompt_path")"

if [ "$use_k3" -eq 1 ]; then
  command -v kimi >/dev/null 2>&1 || die "kimi が見つからない"
  agent_file="$work_dir/agent.md"
  {
    printf -- '---\n'
    printf 'name: gennai-k3\n'
    printf 'description: 源内フォールバック(K3)。日本語リライトのみ、実装はしない\n'
    printf 'disallowedTools: [Bash, Write, Edit, Agent]\n'
    printf -- '---\n'
    # shellcheck disable=SC2016
    printf '%s\n\n' '${base_prompt}'
    printf '%s\n' "$instruction"
  } > "$agent_file"

  out_jsonl="$work_dir/out.jsonl"
  k3_cwd="$work_dir/cwd"
  mkdir -p "$k3_cwd"
  set +e
  ( cd "$k3_cwd" && kimi -p "$prompt_content" --agent-file "$agent_file" -m "$KIMI_MODEL" --output-format stream-json ) \
    < /dev/null > "$out_jsonl" 2>"$work_dir/kimi.err"
  kimi_status=$?
  set -e
  [ "$kimi_status" -eq 0 ] || die "kimi が失敗した(status=$kimi_status): $(cat "$work_dir/kimi.err")"

  command -v jq >/dev/null 2>&1 || die "jq が見つからない"
  response="$(jq -rs '
      map(select(.role=="assistant" and (.content != null)))
      | if length > 0 then last.content else empty end
    ' "$out_jsonl" 2>/dev/null || true)"
  [ -n "$response" ] || die "kimi の出力から assistant content を取れない: $out_jsonl"
  printf '%s\n' "$response" > "$out_path"
else
  command -v agy >/dev/null 2>&1 || die "agy が見つからない"
  agy_cwd="$work_dir/cwd"
  mkdir -p "$agy_cwd"
  agy_out="$work_dir/agy.json"
  set +e
  ( cd "$agy_cwd" && agy -p "$prompt_content" --model "$GEMINI_MODEL" --output-format json \
      --dangerously-skip-permissions --disable-slash-commands ) > "$agy_out" 2>"$work_dir/agy.err"
  agy_status=$?
  set -e
  [ "$agy_status" -eq 0 ] || die "agy が失敗した(status=$agy_status): $(cat "$work_dir/agy.err")"

  command -v jq >/dev/null 2>&1 || die "jq が見つからない"
  response="$(jq -r '.response // empty' "$agy_out" 2>/dev/null || true)"
  [ -n "$response" ] || die "agy の出力から .response を取れない: $agy_out"
  printf '%s' "$response" > "$out_path"
fi

echo "書き出し: $out_path"
