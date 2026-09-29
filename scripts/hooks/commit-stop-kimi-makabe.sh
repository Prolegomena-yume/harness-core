#!/usr/bin/env bash
# kimi-makabe.sh(K3 直書き経路)の Stop hook。verdict-stop.sh が env KIMI_MAKABE_ROOT を見てここへ
# exec で分岐する(config.toml の [[hooks]] は全 kimi 共通で run 単位に足せないため)。
#
# commit-stop-claude-makabe.sh の kimi 版。終端は 2 つ ──
#   1. 「checkpoint commit まで届いた」(HEAD が session 開始時 = $CODEX_AGENT_RUN_DIR/pre_head.txt から動いた)
#   2. 停止理由 ── $CODEX_AGENT_RUN_DIR/stuck.md の 1 行目が「矛盾」「確認が必要」「届かない」のどれかで始まる
#      (claude/makabe.md の「止まり方」の 3 場合に対応: 矛盾 / 設計判断の曖昧さ / 外部要因で完了条件に届かない)
# どちらも無いまま turn を閉じようとしたら block して続けさせる(回数の上限は無い、claude 版と同じ)。
#
# claude 版との差: kimi の Stop の stdin({hook_event_name, session_id, cwd, client_type, stop_hook_active})には
# 最終メッセージが無い(2026-09-29 実測)ので、停止理由は最終メッセージの行頭でなく stuck.md で見る。
# stuck.md は run_dir の中で、worktree-guard-kimi-makabe.sh がこの 1 ファイルだけ書き込みを許す。
#
# block は「exit 0 + stdout の JSON」と「exit 2 + stderr」のどちらでも効く(verdict-stop.sh の実測)。
# ここは exit 2 + stderr(claude 版と同じ)。

set -u

cat > /dev/null 2>&1 || true

if [ -z "${CODEX_AGENT_RUN_DIR:-}" ] || [ -z "${KIMI_MAKABE_ROOT:-}" ]; then
  exit 0
fi

pre_head_file="$CODEX_AGENT_RUN_DIR/pre_head.txt"
[ -f "$pre_head_file" ] || exit 0
pre_head="$(cat "$pre_head_file" 2>/dev/null || true)"

current_head="$(git -C "$KIMI_MAKABE_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
if [ -n "$current_head" ] && [ "$current_head" != "$pre_head" ]; then
  exit 0
fi

stuck_file="$CODEX_AGENT_RUN_DIR/stuck.md"
if [ -s "$stuck_file" ]; then
  first_line="$(head -n 1 "$stuck_file" | tr -d '\r')"
  case "$first_line" in
    矛盾*|確認が必要*|届かない*) exit 0 ;;
  esac
fi

echo "checkpoint commit も、停止理由(stuck.md)も無い。git-as makabe commit で commit するか、$stuck_file の 1 行目を「矛盾」「確認が必要」「届かない」のどれかで始めて理由を書いてから終わる(kimi/makabe.md の契約)" >&2
exit 2
