#!/usr/bin/env bash
# usage: inbox-read.sh [-n N=20] [--inbox <path>]
#
# 鷹野の受信箱(TSV)の末尾 N 行を列を揃えて表示する。最小実装。
# パス解決: --inbox > env TAKANO_INBOX > exit 4

set -u

usage() {
  echo "usage: inbox-read [-n N=20] [--inbox <path>]" >&2
}

n=20
inbox="${TAKANO_INBOX:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) n="${2:-}"; shift 2 ;;
    --inbox) inbox="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 4 ;;
  esac
done

if [ -z "$inbox" ]; then
  echo "[inbox-read] エラー: --inbox も TAKANO_INBOX も無い" >&2
  exit 4
fi

if [ ! -f "$inbox" ]; then
  echo "[inbox-read] 受信箱が無い: $inbox" >&2
  exit 0
fi

{
  printf '時刻\t差出人\t種別\trun_dir\t要旨\n'
  tail -n "$n" "$inbox"
} | column -t -s "$(printf '\t')"
