#!/usr/bin/env bash
# ctr.sh — Claude セッションのトランスクリプトを読める形で出す
#
#   ctr.sh                 直近のセッション
#   ctr.sh 0ac6c324        sessionId の先頭一致
#   ctr.sh sonnet-probe    claude agents --json の name から解決
#   ctr.sh -l              セッション一覧(モデルと消費量つき)
#   ctr.sh -f <id|name>    リアルタイム追尾(起動直後で未生成なら待つ)
set -uo pipefail

FOLLOW=0
[[ "${1:-}" == "-f" ]] && { FOLLOW=1; shift; }

ROOT="$HOME/.claude/projects"

resolve() {
  local q="${1:-}"
  # 引数なし = 直近
  if [[ -z "$q" ]]; then
    ls -t "$ROOT"/*/*.jsonl 2>/dev/null | head -1
    return
  fi
  # sessionId 先頭一致(glob は sanitize 済みディレクトリ名を跨ぐ)
  local hit
  hit=$(ls -t "$ROOT"/*/"$q"*.jsonl 2>/dev/null | head -1)
  [[ -n "$hit" ]] && { echo "$hit"; return; }
  # name から sessionId を引く
  local sid
  sid=$(claude agents --json 2>/dev/null | jq -r --arg n "$q" '.[] | select(.name==$n) | .sessionId' | head -1)
  [[ -n "$sid" ]] && ls -t "$ROOT"/*/"$sid"*.jsonl 2>/dev/null | head -1
}

# 消費量とモデルを1行に畳む
summary() {
  jq -s -r '
    [.[] | select(.type=="assistant") | .message] as $m
    | if ($m|length)==0 then "(assistant 応答なし)"
      else
        ($m[0].model // "?") as $model
        | ([$m[].usage.input_tokens]              | add // 0) as $in
        | ([$m[].usage.output_tokens]             | add // 0) as $out
        | ([$m[].usage.cache_creation_input_tokens]| add // 0) as $cc
        | ([$m[].usage.cache_read_input_tokens]   | add // 0) as $cr
        | "\($model)  in=\($in)  out=\($out)  cache(w/r)=\($cc)/\($cr)"
      end' "$1"
}

# 一覧モード
if [[ "${1:-}" == "-l" ]]; then
  printf '%-10s %-22s %-16s %s\n' ID NAME KIND MODEL/USAGE
  claude agents --json 2>/dev/null | jq -r '.[] | "\(.sessionId)\t\(.name // "-")\t\(.kind)"' |
  while IFS=$'\t' read -r sid name kind; do
    f=$(ls -t "$ROOT"/*/"$sid"*.jsonl 2>/dev/null | head -1)
    printf '%-10s %-22s %-16s %s\n' "${sid:0:8}" "$name" "$kind" \
      "$([[ -n "$f" ]] && summary "$f" || echo '(transcript 未生成)')"
  done
  exit 0
fi

F=$(resolve "${1:-}")

# 追尾時は起動直後で未生成のことがあるので現れるまで待つ
if [[ -z "$F" && $FOLLOW -eq 1 ]]; then
  for _ in $(seq 60); do
    sleep 1
    F=$(resolve "${1:-}")
    [[ -n "$F" ]] && break
  done
fi
[[ -z "$F" ]] && { echo "見つからない: ${1:-<直近>}" >&2; exit 1; }

echo "── $F"
if [[ $FOLLOW -eq 1 ]]; then
  echo "── 追尾中(Ctrl-C で終了)"
else
  echo "── $(summary "$F")"
fi
echo

RENDER='
  select(.type=="user" or .type=="assistant")
  | (.message.role // .type) as $role
  | (if (.message.content|type)=="string" then .message.content
     elif (.message.content|type)=="array" then
       (.message.content | map(
          if   .type=="text"        then .text
          elif .type=="thinking"    then "  (thinking)"
          elif .type=="tool_use"    then "  → \(.name)"
          elif .type=="tool_result" then "  ← 結果"
          else "  [\(.type)]" end) | join("\n"))
     else "" end) as $body
  | select($body != "")
  | "[1m\($role)[0m\n\($body)\n"
'

if [[ $FOLLOW -eq 1 ]]; then
  # --unbuffered が無いと jq が溜め込んでリアルタイムにならない
  tail -n +1 -f "$F" | jq --unbuffered -r "$RENDER"
else
  jq -r "$RENDER" "$F"
fi
