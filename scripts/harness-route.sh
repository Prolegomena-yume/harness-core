#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: harness-route.sh

4 サービス(claude / codex / kimi / agy)の `rates` を叩き、weekly の消費ペース(発注書 14 / 09-21 置換)に
判定表を当てて配役表を stdout に出す read-only の 1 コマンド。何も起動しない。

判定表(`verdict.weekly`):
  agy    が減りすぎ  源内は K3 で動かす
  kimi   が減りすぎ  贄川は Codex sol で動かす
  claude が減りすぎ  Claude は鷹野の窓だけに絞る。庵野を使わず真壁へ。段取りは Codex sol
  codex  が減りすぎ  実装は庵野(この時だけ柏木のゲートを通す)。段取りは bg の Claude Code で水無瀬が持つ

`verdict.weekly` が null の場合は切り替えない ── pace が ±10pt 以内の「無印」と、残量かリセット時刻が
取れない「不明」を区別して表示する(null は 0 でも 100 でもない)。
USAGE
}

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || { echo "エラー: 引数は取らない: $1" >&2; usage >&2; exit 2; }

command -v rates >/dev/null 2>&1 || { echo "エラー: rates コマンドが見つからない" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "エラー: jq コマンドが見つからない" >&2; exit 2; }

# 4 サービスは 1 回の `rates`(引数なし、並列)で揃える。1 サービスが失敗しても他は
# 通常どおり出る({"error":"..."} になるだけ)ので、exit status は無視して拾う。
rates_json="$(rates 2>/dev/null || true)"

weekly_fields() {
  local service="$1"
  printf '%s\n' "$rates_json" | jq -r --arg s "$service" '
    (.[$s] // {}) as $x
    | [$x.remaining.weekly, $x.elapsed.weekly, $x.pace.weekly, $x.verdict.weekly]
    | map(if . == null then "" else tostring end)
    | join("\t")
  ' 2>/dev/null || true
}

fmt_percent() {
  local value="$1"
  if [ -z "$value" ] || [ "$value" = null ]; then
    printf -- '-'
  else
    printf '%s%%' "$value"
  fi
}

fmt_pace() {
  local value="$1"
  if [ -z "$value" ] || [ "$value" = null ]; then
    printf -- '-'
  else
    awk -v v="$value" 'BEGIN { printf (v >= 0 ? "+%s" : "%s"), v }'
  fi
}

fmt_verdict() {
  local verdict="$1" pace="$2"
  if [ -n "$verdict" ] && [ "$verdict" != null ]; then
    printf '%s' "$verdict"
  elif [ -n "$pace" ] && [ "$pace" != null ]; then
    printf '無印'
  else
    printf '不明'
  fi
}

# Prints the display line for real (not through a subshell) and stashes the
# verdict into the caller's variable named by $3, so the switch section below
# can branch on it without re-querying rates.
print_service_line() {
  local label="$1" service="$2" out_var="$3" remaining elapsed pace verdict
  IFS=$'\t' read -r remaining elapsed pace verdict <<<"$(weekly_fields "$service")"
  printf '  %-6s: 残 %s / 経過 %s / pace %s / %s\n' "$label" \
    "$(fmt_percent "$remaining")" "$(fmt_percent "$elapsed")" \
    "$(fmt_pace "$pace")" "$(fmt_verdict "$verdict" "$pace")"
  printf -v "$out_var" '%s' "$verdict"
}

echo "== rates(weekly) =="
claude_verdict='' codex_verdict='' kimi_verdict='' agy_verdict=''
print_service_line claude claude claude_verdict
print_service_line codex codex codex_verdict
print_service_line kimi kimi kimi_verdict
print_service_line agy agy agy_verdict
echo
echo "== 配役表(verdict.weekly == 減りすぎ のときだけ切替を出す) =="

switched=0

if [ "$agy_verdict" = 減りすぎ ]; then
  echo "  源内: K3(agy が減りすぎ)"
  switched=1
fi

if [ "$kimi_verdict" = 減りすぎ ]; then
  echo "  贄川: Codex sol(kimi が減りすぎ)"
  switched=1
fi

if [ "$claude_verdict" = 減りすぎ ]; then
  echo "  Claude: 鷹野の窓だけに絞る。庵野を使わず真壁へ。段取りは Codex sol(claude が減りすぎ)"
  switched=1
fi

if [ "$codex_verdict" = 減りすぎ ]; then
  echo "  実装: 庵野(codex が減りすぎ、この時だけ柏木のゲートを通す)。段取りは bg の Claude Code で水無瀬が持つ"
  switched=1
fi

[ "$switched" -eq 1 ] || echo "  (切替なし)"
