#!/bin/bash
set -euo pipefail

# ============================================================================
# prolegomena Cloud Setup Script(v2、Setup script 公式責務範囲に修正)
#   Target: Claude Code on the web(Ubuntu 24.04 LTS、4vCPU/16GB/30GB)
#   Canonical: PRL-25 / CLAUDE.md § Cloud / .claude/README.md § Cloud
#   2026-06-27 鷹野(PDM)起草、初版 v1 [40aeb7b] の責務誤認を修正
#
# v1 → v2 修正:
#   - npm ci を削除(repo path 参照に依存、Setup script 公式責務外)
#   - npm ci は SessionStart hook(.claude/hooks/session-install.sh)に分離
#   - Setup script は global 環境構築(apt + Node check)+ env check のみ
#
# 役割(global 環境構築のみ、cache 対象):
#   1. apt 必須パッケージ install(build-essential / libpq-dev / postgresql-client)
#   2. Node 20+ 確認(手動 upgrade 指示、auto なし)
#   3. env vars 状態確認 + 次手案内
#
# 環境前提:
#   - root user で実行(cloud 公式)── sudo 不要
#   - git / python3 / node / npm / docker pre-installed
#   - $CLAUDE_CODE_REMOTE=true(cloud session、公式 env、Setup script でも利用可)
#   - $LINEAR_TOKEN, $DATABASE_URL = cloud session UI Environment variables
#   - $CLAUDE_PROJECT_DIR は Setup script では明記なし(参照しない設計に修正)
#
# 実行時間: ~1-2 分
# Cache: 初回 + ~7 日 expiry / script edit 後 rebuild、毎 session は走らない
#
# 使い方:
#   cloud session UI の「セットアップスクリプト」入力欄に本ファイル全文を貼付。
#   local 取得: `cat .claude/cloud_setup_script.sh`
# ============================================================================

trap 'echo "ERROR: Setup failed at line $LINENO"; exit 1' ERR

echo "=== prolegomena Cloud Setup: START ==="
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# cloud session 限定(local Setup script 実行時は no-op)
if [ "${CLAUDE_CODE_REMOTE:-false}" != "true" ]; then
  echo "Not a cloud session (CLAUDE_CODE_REMOTE != 'true'), exiting"
  exit 0
fi

# ────────────────────────────────────────
# [Phase 1] System packages (apt)
# ────────────────────────────────────────
echo ""
echo "--- [Phase 1] apt packages ---"
apt-get update -qq
apt-get install -y build-essential libpq-dev postgresql-client
echo "OK: build-essential / libpq-dev / postgresql-client installed"

# ────────────────────────────────────────
# [Phase 2] Node version check (auto-upgrade なし、手動指示)
# ────────────────────────────────────────
echo ""
echo "--- [Phase 2] Node version ---"
NODE_RAW="$(node --version 2>/dev/null || echo '')"
NODE_MAJOR="$(echo "$NODE_RAW" | sed 's/^v//' | cut -d. -f1)"
echo "Current Node: ${NODE_RAW:-none}"

if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt 20 ]; then
  echo ""
  echo "ERROR: Node 20+ required but found '${NODE_RAW:-none}'"
  echo "Manual upgrade required:"
  echo "  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
  echo "  apt-get install -y nodejs"
  exit 1
fi
echo "OK: Node ${NODE_RAW}, npm $(npm --version)"

# ────────────────────────────────────────
# [Phase 3] env vars 状態確認
# ────────────────────────────────────────
echo ""
echo "--- [Phase 3] Environment vars check ---"

check_required() {
  if [ -z "${!1:-}" ]; then
    echo "  [X] $1 NOT SET (REQUIRED for runtime)"
    return 1
  else
    echo "  [v] $1 set"
    return 0
  fi
}

check_optional() {
  if [ -z "${!1:-}" ]; then
    echo "  [-] $1 unset (optional)"
  else
    echo "  [v] $1 set"
  fi
}

echo "Required (cloud session UI Environment variables に投入必須):"
check_required LINEAR_TOKEN || true
check_required DATABASE_URL || true

echo ""
echo "Optional (Vite frontend / Cognito):"
check_optional VITE_AWS_REGION
check_optional VITE_COGNITO_HOSTED_UI_DOMAIN
check_optional VITE_OWNER_CLIENT_ID
check_optional VITE_MCP_API_URL

# ────────────────────────────────────────
# [Phase 4] 完了 + 次の手順
# ────────────────────────────────────────
echo ""
echo "=== Setup complete: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""
echo "Next: Claude Code launch 後、SessionStart hook が自動発火:"
echo "  - .claude/hooks/session-init.sh     ── context 注入(~2 秒)"
echo "  - .claude/hooks/session-install.sh  ── npm ci 冪等(初回 ~60 秒、2 回目以降 skip)"
echo ""
echo "Manual steps after first session boot:"
echo "  1. (初回) Neon DDL apply:  psql \"\$DATABASE_URL\" < apps/prolegomena/party/persist/schema.sql"
echo "  2. Migrations:             npm run migrate -w @prolegomena/migrations -- status"
echo "  3. Dev server:             npm run dev    (organ:5173 / prolegomena:5174 / partykit:1999)"
echo "  4. Test / typecheck / lint: npm run test / typecheck / lint"
echo ""
echo "Notes:"
echo "  - amplify_outputs.json は local Windows sandbox + git commit 経由(cloud では sandbox 不可)"
echo "  - AWS credentials は cloud env に入れない(deploy / production は local 経路)"
echo ""

exit 0
