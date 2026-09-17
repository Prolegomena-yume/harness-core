#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: harness-route.sh

4 サービス(claude / codex / kimi / agy)の `rates` を叩き、weekly 残量に発注書 14 の閾値表を当てて
配役表を stdout に出す read-only の 1 コマンド。何も起動しない。

閾値表:
  agy    < 20%  源内は K3 で動かす
  kimi   < 30%  贄川は Codex sol で動かす
  claude < 20%  Claude は鷹野の窓だけに絞る。庵野を使わず真壁へ。段取りは Codex sol
  codex  < 20%  実装は庵野(この時だけ柏木のゲートを通す)。段取りは bg の Claude Code で水無瀬が持つ

`remaining.weekly` が null の場合は「不明」と表示し、切り替えない(null は 0 でも 100 でもない)。
USAGE
}

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || { echo "エラー: 引数は取らない: $1" >&2; usage >&2; exit 2; }

command -v rates >/dev/null 2>&1 || { echo "エラー: rates コマンドが見つからない" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "エラー: jq コマンドが見つからない" >&2; exit 2; }

fetch_weekly() {
  local service="$1" json
  if ! json="$(rates "$service" 2>/dev/null)"; then
    printf '\n'
    return 0
  fi
  printf '%s\n' "$json" | jq -r '.remaining.weekly // empty' 2>/dev/null || true
}

fmt_weekly() {
  local value="$1"
  if [ -z "$value" ] || [ "$value" = null ]; then
    printf '不明'
  else
    printf '%s%%' "$value"
  fi
}

below_threshold() {
  local value="$1" threshold="$2"
  [ -n "$value" ] || return 1
  awk -v v="$value" -v t="$threshold" 'BEGIN { exit !(v + 0 < t + 0) }'
}

claude_weekly="$(fetch_weekly claude)"
codex_weekly="$(fetch_weekly codex)"
kimi_weekly="$(fetch_weekly kimi)"
agy_weekly="$(fetch_weekly agy)"

echo "== rates(weekly) =="
printf '  claude: %s\n' "$(fmt_weekly "$claude_weekly")"
printf '  codex : %s\n' "$(fmt_weekly "$codex_weekly")"
printf '  kimi  : %s\n' "$(fmt_weekly "$kimi_weekly")"
printf '  agy   : %s\n' "$(fmt_weekly "$agy_weekly")"
echo
echo "== 配役表(閾値表、null=不明は切替しない) =="

if below_threshold "$agy_weekly" 20; then
  echo "  源内: K3(agy weekly < 20%)"
else
  echo "  源内: agy(通常)"
fi

if below_threshold "$kimi_weekly" 30; then
  echo "  贄川: Codex sol(kimi weekly < 30%)"
else
  echo "  贄川: Kimi K3(通常)"
fi

if below_threshold "$claude_weekly" 20; then
  echo "  Claude: 鷹野の窓だけに絞る。庵野を使わず真壁へ。段取りは Codex sol(claude weekly < 20%)"
else
  echo "  Claude: 通常(鷹野 / 水無瀬 / 庵野を使う)"
fi

if below_threshold "$codex_weekly" 20; then
  echo "  実装: 庵野(codex weekly < 20%、この時だけ柏木のゲートを通す)。段取りは bg の Claude Code で水無瀬が持つ"
else
  echo "  実装: 真壁(通常)"
fi
