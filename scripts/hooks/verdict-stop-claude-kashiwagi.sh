#!/usr/bin/env bash
# 柏木(claude-kashiwagi.sh、実行経路 C)の Stop hook。終端の成果物は claude/kashiwagi.md の
# 出力契約(「判定の一語 ── P0 無し / P0 あり(N 件) / エスカレーション」)から拾う ── 新しい
# 語彙は作らない。判定の一語が無いまま turn を終えようとしたら block して続けさせる
# (役員 人見 2026-09-24、終端の無い turn を hook で止める、3 点のうち柏木の分)。
#
# Stop hook の stdin JSON に last_assistant_message が入っている(実測、claude-code 2.1.246、
# /tmp/stopdiag の PoC)。verdict-stop-claude.sh はファイル(verdict.md)を見るが、柏木の経路 C は
# ファイルでなく最終メッセージそのものが所見(claude/kashiwagi.md「柏木自身が書き込む必要は無い」)
# なので、ここだけ stdin JSON を読む。
#
# 最大回数は設けない(人見の指示:書かせればよい、無ければ注入すればよい)。block は verdict-stop-claude.sh
# と同じく exit 2 + stderr(Claude Code の Stop は exit 2 でだけ block する、実測)。
#
# 適用は claude-kashiwagi.sh が起動のたびに書く run_dir 内 settings.json から(--settings)。
# ~/.claude/settings.json は触らない。

set -u

stdin_json="$(cat 2>/dev/null || true)"

last_message="$(printf '%s' "$stdin_json" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    print("")
    sys.exit(0)
print(data.get("last_assistant_message") or "")
' 2>/dev/null)"

case "$last_message" in
  *"P0 無し"*|*"P0 あり"*|*エスカレーション*)
    exit 0
    ;;
esac

echo "判定の一語(P0 無し / P0 あり(N 件) / エスカレーション)が最終メッセージに無い。書いてから終わる(claude/kashiwagi.md の出力契約)" >&2
exit 2
