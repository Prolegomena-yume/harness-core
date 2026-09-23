#!/usr/bin/env bash
# 真壁(claude-makabe.sh、codex weekly 逼迫時の代替経路)の Stop hook。終端の成果物は
# codex/makabe.md の契約から拾う ── 「checkpoint commit まで届いた」(HEAD が session 開始時から
# 動いた)か、契約が既に持っている停止の言い回し(claude/makabe.md「止まり方」の 2 つ目 ──
# 最終メッセージに「矛盾」か「贄川さんに確認が必要」と、その中身を書く)のどちらか。
# 新しい語彙は作らない。どちらも無いまま turn を終えようとしたら block して続けさせる
# (役員 人見 2026-09-24、終端の無い turn を hook で止める、3 点のうち真壁の分)。
#
# 停止理由は「行の先頭」で判定する ── contains ではなく startswith。codex/makabe.md の
# 出力契約が持つ「確かめていないこと: <...>」欄は自由記述で、そこに「矛盾」「確認」の語が
# 中身として出てくることがある(未確認の前提を書けば当然出うる)。これは停止理由ではないので
# 誤って通さない(09-24、庵野)。
#
# pre_head は claude-makabe.sh が claude 起動の前に $CODEX_AGENT_RUN_DIR/pre_head.txt へ書く
# (Stop hook は別プロセスなのでランチャの bash 変数を読めない)。無ければ素通し(ランチャ経由でない
# 起動、または pre_head.txt を書く前の異常系)。
#
# 最大回数は設けない(人見の指示:書かせればよい、無ければ注入すればよい)。

set -u

stdin_json="$(cat 2>/dev/null || true)"

if [ -z "${CODEX_AGENT_RUN_DIR:-}" ] || [ -z "${CLAUDE_MAKABE_ROOT:-}" ]; then
  exit 0
fi

pre_head_file="$CODEX_AGENT_RUN_DIR/pre_head.txt"
[ -f "$pre_head_file" ] || exit 0
pre_head="$(cat "$pre_head_file" 2>/dev/null || true)"

current_head="$(git -C "$CLAUDE_MAKABE_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"

# commit が増えていれば(HEAD が動いていれば)「checkpoint commit まで届いた」ので終端を許す。
if [ -n "$current_head" ] && [ "$current_head" != "$pre_head" ]; then
  exit 0
fi

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

if printf '%s\n' "$last_message" | grep -Eq '^[[:space:]]*(矛盾|贄川さんに確認が必要)'; then
  exit 0
fi

echo "checkpoint commit も、矛盾 / 確認が必要の停止理由も無い。git-as makabe commit で commit するか、矛盾 / 要確認の理由を書いてから終わる(codex/makabe.md の契約)" >&2
exit 2
