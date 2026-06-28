#!/bin/bash
# ============================================================================
# prolegomena Cloud SessionStart install hook
#   Target: Claude Code on the web(cloud session のみ発火、local は no-op)
#   Canonical: PRL-25 / CLAUDE.md § Cloud
#   2026-06-27 鷹野(PDM)起草、Setup script から repo dependency install を分離
#
# 役割: cloud session で repo dependency(npm ci)を冪等実行
#   - local(CLAUDE_CODE_REMOTE 未設定 or false)は no-op で exit 0
#   - 初回 + package-lock.json hash 変化時のみ npm ci 実行
#   - 2 回目以降は node_modules 存在 + hash 一致で skip(~0 秒)
#
# 環境前提:
#   - cloud: root user、Node 20+ install 済(Setup script Phase 2 で確認済)
#   - $CLAUDE_PROJECT_DIR = repo root(SessionStart hook では確実に set)
#
# settings.json での登録:
#   .claude/settings.json の hooks.SessionStart 配列に session-init.sh と並列で追加
#   matcher: "startup|resume|clear|compact"、timeout: 180(初回 npm ci ~60 秒、余裕)
#
# Hash file: .claude/.npm-install-hash(.gitignore 済、cloud container 内のみ存在)
# ============================================================================

set -eu

# cloud session 限定発火、local は no-op
if [ "${CLAUDE_CODE_REMOTE:-false}" != "true" ]; then
  exit 0
fi

REPO_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$REPO_ROOT" ] || [ ! -f "$REPO_ROOT/package.json" ]; then
  echo "[session-install] CLAUDE_PROJECT_DIR not set or package.json missing, skip" >&2
  exit 0
fi

cd "$REPO_ROOT"

# 冪等性チェック: node_modules 存在 + package-lock.json hash 一致なら skip
HASH_FILE=".claude/.npm-install-hash"
LOCK_HASH="$(sha256sum package-lock.json 2>/dev/null | awk '{print $1}')"
LAST_HASH="$(cat "$HASH_FILE" 2>/dev/null || echo '')"

if [ -d node_modules ] && [ -n "$LOCK_HASH" ] && [ "$LOCK_HASH" = "$LAST_HASH" ]; then
  echo "[session-install] node_modules + lock hash unchanged, skip npm ci" >&2
else
  echo "[session-install] npm ci start (lock hash changed or first run)" >&2
  npm ci --loglevel=warn
  echo "$LOCK_HASH" > "$HASH_FILE"
  echo "[session-install] npm ci complete, hash saved" >&2
fi

# Phase 2: packages build(iceml-core / commit-handler、Vite resolve に dist/ 必須)
# turbo cache 効く ── 変更なければ ~0 秒、初回 ~10-30 秒。
# turbo dev task は ^build 待たないため、Vite が dist/ 不在 = workspace import resolve fail。
# 2026-06-27 v4(cloud 検証で iceml-block-detection.ts 解決 fail 判明、PRL-25 v4)。
echo "[session-install] building required packages (iceml-core / commit-handler)" >&2
npm run build -w @prolegomena/iceml-core -w @prolegomena/commit-handler 2>&1 | tail -3 >&2
echo "[session-install] packages build done" >&2

exit 0
