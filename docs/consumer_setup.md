# Consumer Setup Guide

新規 consumer リポを harness-core(本リポ)上に構築する手順。**1 時間以内**で動作開始することを目標に設計。

## 0. 前提

- harness-core 正典リモート: `https://git.yumemism.com/company/harness-core.git`
- consumer リポは Forgejo 配置(visibility は任意、private の場合は clone と submodule 取得に認証が必要)
- 推奨 OS: Linux / macOS / Windows(Git for Windows + Git Bash)
- 必要ツール: `git` / `python3`(SessionStart hook 用) / Node 20+(cloud session 想定時)

## 1. 経路は submodule mount の1本

**新規・既存を問わず、consumer リポへ harness-core を submodule で足す。**空リポでも手順は同じで、工数は15〜30分(配置と整合)。

**template repo 経由の経路は廃した。**雛形の `harness-starter` は GitHub にしか無く、正典が Forgejo へ移った時点で入口として成立しない。

以下 §2 以降が共通 setup。

```bash
cd <consumer-repo-root>

# 1. harness-core を .claude/_core/ にマウント
git submodule add https://git.yumemism.com/company/harness-core.git .claude/_core

# 2. .harness.json を repo root に起草(§3 参照)
$EDITOR .harness.json

# 3. .claude/settings.json を配置(§5 参照)
$EDITOR .claude/settings.json

# 4. (任意)role 切替 slash command wrapper を配置(§6 参照)
$EDITOR .claude/commands/role-takano.md

# 5. commit + push
git add -A
git commit -m "feat(harness): adopt harness-core as submodule"
git push
```

## 2. ディレクトリ構成(共通)

setup 完了後の consumer 配下:

```
<consumer-root>/
├── .claude/
│   ├── _core/                    ── harness-core submodule(commit pin)
│   ├── agents -> _core/agents    ── 委譲人格 symlink(§6.1、任意)
│   ├── commands/
│   │   ├── role-takano.md        ── /role-takano wrapper(任意)
│   │   └── role-ohashi.md        ── /role-ohashi wrapper(任意)
│   ├── settings.json             ── hook 登録(§5)
├── .gitmodules                   ── submodule 定義(git submodule add で自動生成)
├── .harness.json                 ── consumer 設定(§3)
└── (consumer 固有 file...)
```

## 3. `.harness.json` の起草

[schema/harness.schema.json](../schema/harness.schema.json)(JSON Schema draft-07)に準拠。実例は [example.harness.json](example.harness.json) 参照。

### 最小構成(必須 field のみ)

```json
{
  "$schema": "./.claude/_core/schema/harness.schema.json",
  "project": {
    "name": "your-project-name"
  }
}
```

これだけで SessionStart hook は **graceful default** で動く。`neon.urlFile` 未指定時は Neon 参照なし、Cloud Setup は no-op。`orch/` を使わない consumer は `orch` セクションごと省略可能で、hook と setup script も `orch` を参照しない。

### 標準構成(全節を使う場合)

```json
{
  "$schema": "./.claude/_core/schema/harness.schema.json",
  "project": {
    "name": "your-project-name",
    "displayName": "Your Project"
  },
  "neon": {
    "urlFile": "~/.ssh/neon-harness-index-url.txt",
    "limit": 10
  },
  "sessions": {
    "dir": "docs/_sessions",
    "dailySummaryFilename": "daily_summary.md"
  },
  "mirror": {
    "enabled": false
  },
  "canonical": {
    "links": [
      { "label": "CLAUDE.md", "path": "CLAUDE.md" },
      { "label": "AGENTS.md", "path": "AGENTS.md" },
      {
        "label": "Harness Constitution",
        "path": ".claude/_core/docs/harness_constitution.md"
      }
    ]
  },
  "orch": {
    "defaultRounds": 3,
    "implementer": {
      "command": "cursor-agent",
      "model": "cursor-grok-4.6-high-fast",
      "tokenFile": "~/.ssh/cursor-api-key.txt",
      "tokenEnvVar": "CURSOR_API_KEY",
      "workerPattern": "cursor-agent/versions/.*worker-server"
    },
    "reviewer": {
      "command": "codex",
      "effort": "high"
    }
  },
  "cloud": {
    "aptPackages": ["build-essential"],
    "nodeMinVersion": 20,
    "requiredEnvVars": [],
    "optionalEnvVars": ["FORGEJO_TOKEN"],
    "npmGlobalPackages": [],
    "codex": {
      "enabled": false
    }
  },
  "install": {
    "buildTargets": []
  }
}
```

### 主要 field 早見表

| field | 型 | 用途 |
|---|---|---|
| `project.name` | string (required) | 内部識別子(英数 + `-`) |
| `neon.urlFile` | string | Neon 接続 URL を書いた file への path。未指定時は SessionStart の Neon 参照なし |
| `neon.limit` | integer | SessionStart に出す Neon の最新 document 件数(default 10) |
| `sessions.{dir,dailySummaryFilename}` | string | session_summary 配置 |
| `mirror.{enabled,stateFile}` | bool/string | Drive mirror 設定(consumer 固有、default off) |
| `canonical.links[]` | object[] | 起動チェックリマインダ link |
| `orch.defaultRounds` | integer | 実装・レビュー往復の既定上限(default 3) |
| `orch.implementer.tokenFile` | string (orch 使用時 required) | 実装担当 token file の path。既定値なし |
| `orch.implementer.{command,model,tokenEnvVar,workerPattern}` | string | 実装担当の起動・認証・worker 終了条件 |
| `orch.reviewer.{command,effort}` | string | レビュー担当の実行体と reasoning effort |
| `cloud.aptPackages` | string[] | Cloud Setup Phase 1 で apt install するパッケージ |
| `cloud.nodeMinVersion` | number | Node 最小メジャー version(default 20) |
| `cloud.requiredEnvVars` | string[] | Phase 4 で必須チェックする env var |
| `cloud.optionalEnvVars` | string[] | Phase 4 で optional 通知する env var |
| `cloud.npmGlobalPackages` | string[] | Cloud Setup Phase 3 で `npm install -g` する package |
| `cloud.codex.enabled` | boolean | true で session-install.sh が Codex auth bootstrap 実行 |
| `cloud.codex.authEnvVar` | string | auth source env var(default `CODEX_AUTH_JSON`) |
| `cloud.codex.{workspaceWrite,trustRepo}` | boolean | config.toml seed フラグ |
| `install.buildTargets` | string[] | session-install.sh で `npm run build -w` する workspaces |

field の全量と制約は [schema/harness.schema.json](../schema/harness.schema.json)、機構と起動手順は [orchestration.md](orchestration.md) を直接参照。

## 4. submodule の運用

```bash
# 初回 clone 後(--recurse-submodules 漏れた場合)
git submodule update --init --recursive

# harness-core upstream 追従
git submodule update --remote .claude/_core
git add .claude/_core
git commit -m "chore(harness): submodule bump"
```

cloud session では Cloud Setup script の **Phase 0** が `git submodule update --init --recursive` を冪等実行するため、clone 直後でも自動 populate される(`.gitmodules` 不在時は skip)。

## 5. `.claude/settings.json` 配置

SessionStart hook を core 配下に向ける:

```json
{
  "$schema": "https://docs.claude.com/schemas/claude-code/settings.json",
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/_core/hooks/session-init.sh\"",
            "timeout": 20
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/_core/hooks/session-install.sh\"",
            "timeout": 180
          }
        ]
      }
    ]
  }
}
```

`session-init.sh` は毎 SessionStart で `.harness.json` 駆動の context を注入(~2 秒)、`session-install.sh` は cloud session 限定で `npm ci` + workspaces build + Codex auth bootstrap(~60 秒、冪等 skip 可)。

## 6. role 切替 slash command(任意)

`/role-takano` / `/role-ohashi` を使う場合、consumer 側に **thin wrapper** を配置(Claude Code の commands は `.claude/commands/` 規約で、`.claude/_core/commands/` は自動 reach しないため)。

`.claude/commands/role-takano.md`:

```markdown
---
description: 鷹野(PDM)ロールに即時切替、口調規範を強制適用
---

★ このコマンドは **鷹野(PDM)ロールへの強制切替**。

@.claude/_core/roles/takano.md

(以下、強制適用ルール本体は core の roles/ に書かれている。
 必要なら consumer 固有の追加ルールを書く。)
```

最小 wrapper としては `@.claude/_core/roles/takano.md` の 1 行 import だけで動く。強制適用ルールも consumer 側に展開したい場合は harness-core の `commands/role-takano.md` を参照 + 必要部分を copy。

## 6.1 委譲人格 agent の配線(symlink)

鷹野(PDM)がサブエージェントへ委譲する人格(水無瀬 / 真壁 / 柏木)を使う場合、`.claude/agents/` を core へ向ける:

```bash
cd <consumer-repo-root>
ln -s _core/agents .claude/agents
git add .claude/agents && git commit -m "feat(harness): 委譲人格 agent を core へ配線"
```

**wrapper ではなく symlink を使う。**agent 定義は frontmatter(`tools` / `model`)が本体なので、wrapper を置くと consumer の数だけモデル指定が複製され、モデル世代を上げるときに全 consumer を触ることになる。

配線後、Agent tool から `subagent_type: minase` / `makabe` / `kashiwagi` が解決する。**反映は次回セッション開始時**(agent 定義はセッション開始時に読まれる)。一覧と方針は [../agents/README.md](../agents/README.md)、実装委譲の手順は [codex_delegation.md](codex_delegation.md)。

## 7. Neon 接続先の運用

SessionStart hook の Neon 参照は `neon.urlFile` と `neon.limit` の2値だけで制御する。進行管理は Forgejo issues、Neon(`harness_index_db`)は直近の索引 document を起動 context へ出す経路。

| field | 運用 |
|---|---|
| `neon.urlFile` | 接続 URL を1行目に書いた file への path。`~` 展開あり。接続情報を `.harness.json` へ直書きせず、リポジトリ外または gitignored file に配置 |
| `neon.limit` | `documents.updated_at` 降順で出す件数。1以上の integer、未指定時 10 |

この tech consumer の設定例は `~/.ssh/neon-harness-index-url.txt` / `10`。file は利用者だけが読める権限で作成し、PostgreSQL 接続 URL を1行で保存する。SessionStart 実行環境には `psql` が必要。`urlFile` 未指定時は Neon 節を出力せず、file 不在・空・接続失敗時は context 内へ失敗理由を出して hook 自体は継続。

## 8. cloud session 想定時の追加 setup

cloud session(claude.ai/code、Ubuntu 24.04 LTS、`CLAUDE_CODE_REMOTE=true`)で動かす場合:

### (a) Cloud Setup script 全文を貼付

```bash
# local で
cat .claude/_core/setup/cloud_setup_script.sh
```

cloud session UI の「セットアップスクリプト」欄に全文貼付。Phase 0(submodule fetch)→ Phase 1(apt)→ Phase 2(Node check)→ Phase 3(npm global packages)→ Phase 4(env vars check)→ Phase 5(完了案内)が走る。

### (b) Environment variables 投入(cloud session UI)

`.harness.json` の `cloud.requiredEnvVars` 各 var をすべて投入。`optionalEnvVars` も必要に応じて。

`CODEX_AUTH_JSON`(`cloud.codex.enabled=true` 時)は **1 行 compact JSON 必須**:

```powershell
# local Windows PowerShell
(Get-Content $env:USERPROFILE\.codex\auth.json -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress) | Set-Clipboard
```

★ cloud UI に secret 専用欄は無い(2026-06-28 時点、anthropics/claude-code#32733 feature request 段階)、環境変数欄が唯一の投入経路。collaborator 共有可視。

★ multi-line raw JSON を環境変数欄に貼ると保存時 silently truncate される。`-Compress` で 1 行化必須。

★ Codex auth は **local/cloud 同時 active で refresh token 競合**(openai/codex#15502)、排他運用必須。

### (c) cloud session 起動 → SessionStart hook 確認

cloud session 起動後、最初の発話で context に下記が注入されているか確認(または手動 `bash .claude/_core/hooks/session-init.sh` 実行):

- environment / git / session / mirror / startup reminders / Neon recent documents(設定時)

Anthropic 既知問題で **新規 cloud session の冒頭 context 注入が走らないことあり**(claude-code Issue #10373)、その場合は手動 fallback。

## 9. 動作確認(local mode)

```bash
# .harness.json が読まれて JSON 駆動で動くか確認
bash .claude/_core/hooks/session-init.sh

# stdout に JSON 1 行が出力、hookSpecificOutput.additionalContext 内に
# environment / git / session / mirror / startup reminders と
# Neon recent documents (neon.urlFile 設定時) の各節が見える
```

`.harness.json` 不在時は warning section が出るが、graceful default で exit 0、SessionStart hook を fail させない。

## 10. trouble shooting

| 症状 | 原因 / 対処 |
|---|---|
| SessionStart hook 出力 `session-init.sh: no usable python on PATH` | python3 not in PATH。`apt install python3` or `brew install python3` |
| `.harness.json missing` warning が出る | consumer リポ root に `.harness.json` が無い、または `CLAUDE_PROJECT_DIR` 未 set。`cd <repo-root>` で再実行 |
| Neon 参照 `urlFile not found` / `urlFile is empty` | `neon.urlFile` の path 誤り、file 不在、または1行目が空。接続 URL file を修正 |
| Neon 参照 `psql not found on PATH` | PostgreSQL client 未導入。`apt install postgresql-client` or `brew install libpq` |
| Neon 参照 `fetch failed` | 接続 URL、network、DB 権限、`harness_index_db` の状態を確認 |
| `npm ci` fail(cloud) | network 問題 or `package-lock.json` 整合性問題、`rm -rf node_modules .claude/.npm-install-hash && npm ci` で recovery |
| Codex auth bootstrap fail | `CODEX_AUTH_JSON` env が空、または invalid JSON。compact 化 + 再投入 |
| submodule fetch fail(`Phase 0`) | network or auth 問題、`git submodule update --init --recursive` 手動再走 |

## 11. 実例

現行値の実例は Forgejo の [company/tech](https://git.yumemism.com/company/tech) と、そのリポ root の `.harness.json`。`neon.urlFile` は `~/.ssh/neon-harness-index-url.txt`、`neon.limit` は `10`、`orch` は実装担当とレビュー担当を明示、cloud の任意環境変数は `FORGEJO_TOKEN`。

consumer ごとの差は `.harness.json` だけに置き、SessionStart hook / Cloud Setup script 本体は core 共通。

## 12. 退役 / 切戻し

harness-core を使うのを止める場合:

```bash
# submodule deinit
git submodule deinit -f .claude/_core
git rm -f .claude/_core
rm -rf .git/modules/.claude/_core

# .harness.json / .claude/settings.json / .claude/commands/role-*.md を削除 or 編集
git rm .harness.json .claude/settings.json .claude/commands/role-*.md

git commit -m "chore(harness): remove harness-core submodule"
```

各 hook が無くなるだけで、consumer リポ自体は無傷。
