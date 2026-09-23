#!/usr/bin/env bash
# usage: stop-hook-terminus-e2e.sh
#
# 「終端の無い turn を Stop hook で止める」の通し試験(役員 人見 2026-09-24)。
# 柏木(claude-kashiwagi.sh、実行経路 C)と真壁(claude-makabe.sh)を実際の `claude` で 1 回ずつ起こし、
# 終端の成果物(柏木 = 判定の一語、真壁 = commit または矛盾/確認が必要の理由)を書かずに終わろうとする
# 最小タスクを与え、hook が block → feedback を注入 → モデルが書き直して終わる、を実測する。
#
# **実 claude を叩く(fake ではない)。**--model claude-sonnet-5 で両方とも起動する(柏木の既定
# claude-opus-5-5 はこの母艦の claude CLI 2.1.246 がまだ対応していない、庵野 2026-09-24 実測。
# opus 側の疎通は CLI 更新後に別途確認する)。1 回あたり数十秒、Claude の枠を実消費する。
#
# 合否は num_turns > 1(hook が最低 1 回は block したことの傍証)と、$CLAUDE_PROJECTS/<session>.jsonl に
# 実際に "Stop hook feedback" の行が入っていることの両方で判定する ── num_turns だけでは
# 「たまたま2回 tool を使った」と区別できないため。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_dir="$(dirname "$(dirname "$script_dir")")"
kashiwagi_launcher="$core_dir/scripts/claude-kashiwagi.sh"
makabe_launcher="$core_dir/scripts/claude-makabe.sh"

command -v claude >/dev/null 2>&1 || { echo "エラー: claude が見つからない。この E2E は実 claude が要る" >&2; exit 2; }

test_root="$(mktemp -d /tmp/stop-hook-terminus-e2e.XXXXXX)"
cleanup() {
  if [[ "$test_root" = /tmp/stop-hook-terminus-e2e.* ]] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
  for jsonl in "${cleanup_jsonl[@]:-}"; do
    [ -n "$jsonl" ] && rm -f -- "$jsonl"
  done
}
cleanup_jsonl=()
trap cleanup EXIT

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); echo "ok $pass_count - $1"; }
fail() { fail_count=$((fail_count + 1)); echo "NG - $1" >&2; }

init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email "e2e@example.invalid"
  git -C "$dir" config user.name e2e
  git -C "$dir" commit -q --allow-empty -m init
}

session_id_from_footer() {
  LC_ALL=C grep -o '^session_id: .*' | sed 's/^session_id: //'
}

echo "== 1. 柏木(実行経路 C)── 判定の一語を書かずに終わろうとする巡は hook が差し戻す =="
kashiwagi_repo="$test_root/kashiwagi"
init_repo "$kashiwagi_repo"
plan_path="$kashiwagi_repo/plan.md"
cat > "$plan_path" <<'EOF'
# plan
やることは特に無い。テストなので「テスト完了」とだけ返してほしい。判定の一語は書かなくてよい。
EOF
kashiwagi_out="$test_root/kashiwagi.out"
CODEX_AGENT_STATE_DIR="$test_root/state" \
  timeout 120 bash "$kashiwagi_launcher" --no-loop -C "$kashiwagi_repo" -f "$plan_path" \
  --model claude-sonnet-5 > "$kashiwagi_out" 2>&1 || true
kashiwagi_session="$(session_id_from_footer < "$kashiwagi_out")"
if [ -z "$kashiwagi_session" ]; then
  fail "柏木: session_id が footer に無い(out: $(cat "$kashiwagi_out"))"
fi
if [ -n "$kashiwagi_session" ]; then
  kashiwagi_jsonl="$(find "$HOME/.claude/projects" -iname "*${kashiwagi_session}*.jsonl" 2>/dev/null | head -1)"
  cleanup_jsonl+=("$kashiwagi_jsonl")
  if [ -n "$kashiwagi_jsonl" ] && [ -f "$kashiwagi_jsonl" ]; then
    if LC_ALL=C grep -q 'Stop hook feedback' "$kashiwagi_jsonl"; then
      pass '柏木: 判定の一語が無い turn を hook が block し feedback を注入した'
    else
      fail "柏木: transcript に Stop hook feedback が無い($kashiwagi_jsonl)"
    fi
    if LC_ALL=C grep -qE '"P0 無し|P0 あり|エスカレーション"' "$kashiwagi_jsonl" \
      || python3 - "$kashiwagi_jsonl" <<'PY'
import json, sys
path = sys.argv[1]
found = False
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        msg = d.get('message')
        if not isinstance(msg, dict) or msg.get('role') != 'assistant':
            continue
        for block in msg.get('content') or []:
            text = block.get('text', '') if isinstance(block, dict) else ''
            if 'P0 無し' in text or 'P0 あり' in text or 'エスカレーション' in text:
                found = True
sys.exit(0 if found else 1)
PY
    then
      pass '柏木: hook の注入後、最終メッセージに判定の一語が書かれた(終端まで届いた)'
    else
      fail "柏木: 判定の一語が最終的にも見当たらない($kashiwagi_jsonl)"
    fi
  else
    fail "柏木: transcript(jsonl)が見つからない(session=$kashiwagi_session)"
  fi
fi

echo "== 2. 真壁(claude 経路)── commit も停止理由も無いまま終わろうとする巡は hook が差し戻す =="
makabe_repo="$test_root/makabe"
init_repo "$makabe_repo"
task_path="$test_root/makabe-task.md"
cat > "$task_path" <<'EOF'
# task
やることは特に無い。ファイルは何も変更しなくてよい。commit もしなくてよい。
テストなので「作業完了」とだけ返してほしい。矛盾や確認が必要とは書かなくてよい。
EOF
makabe_out="$test_root/makabe.out"
CODEX_AGENT_STATE_DIR="$test_root/state" \
  timeout 120 bash "$makabe_launcher" -C "$makabe_repo" -f "$task_path" \
  > "$makabe_out" 2>&1 || true
makabe_session="$(session_id_from_footer < "$makabe_out")"
if [ -z "$makabe_session" ]; then
  fail "真壁: session_id が footer に無い(out: $(cat "$makabe_out"))"
fi
if [ -n "$makabe_session" ]; then
  makabe_jsonl="$(find "$HOME/.claude/projects" -iname "*${makabe_session}*.jsonl" 2>/dev/null | head -1)"
  cleanup_jsonl+=("$makabe_jsonl")
  if [ -n "$makabe_jsonl" ] && [ -f "$makabe_jsonl" ]; then
    if LC_ALL=C grep -q 'Stop hook feedback' "$makabe_jsonl"; then
      pass '真壁: commit も停止理由も無い turn を hook が block し feedback を注入した'
    else
      fail "真壁: transcript に Stop hook feedback が無い($makabe_jsonl)"
    fi
    if LC_ALL=C grep -qE '矛盾|確認が必要' "$makabe_jsonl"; then
      pass '真壁: hook の注入後、最終メッセージに契約既定の停止理由が書かれた(終端まで届いた)'
    else
      fail "真壁: 矛盾/確認が必要のどちらも最終的に見当たらない($makabe_jsonl)"
    fi
  else
    fail "真壁: transcript(jsonl)が見つからない(session=$makabe_session)"
  fi
fi

echo
echo "== summary =="
echo "pass: $pass_count  fail: $fail_count"
[ "$fail_count" -eq 0 ]
