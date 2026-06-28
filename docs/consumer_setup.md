# Consumer Setup Guide

新規 consumer リポを harness-core(本リポ)上に構築する手順。**1 時間以内**で動作開始することを目標に設計。

## 0. 前提

- harness-core repo URL: `https://github.com/Prolegomena-yume/harness-core.git`(public)
- consumer リポは GitHub 配置(visibility は任意、private でも OK ── ただし submodule URL 自体は public な harness-core を指すので、consumer 側の private 設定は submodule 自体には影響しない)
- 推奨 OS: Linux / macOS / Windows(Git for Windows + Git Bash)
- 必要ツール: `git` / `python3`(SessionStart hook 用) / Node 20+(cloud session 想定時)

## 1. 経路の選択

新規 consumer 起こしは 2 経路:

| 経路 | 適用 | 工数 |
|---|---|---|
| **(A) harness-starter template clone** | ほぼ空の新規 consumer を素早く起こす | ~5 分 |
| **(B) 既存リポへの submodule mount** | 既存コードベースに harness を後付けする | ~15-30 分(配置・整合) |

両方とも以下 §2 以降の **共通 setup** に合流。

### (A) harness-starter template clone

1. https://github.com/Prolegomena-yume/harness-starter で **「Use this template」**(GitHub Template Repository 機能)から新規 repo 作成
2. visibility(public/private)選択、repo 名を consumer 名で確定
3. local に clone
4. `.harness.json` を **§3 schema** に従って consumer 用に編集
5. (任意)`.claude/commands/role-*.md` の不要分を削除
6. §4 以降は consumer 固有作業

### (B) 既存リポへの submodule mount

```bash
cd <consumer-repo-root>

# 1. harness-core を .claude/_core/ にマウント
git submodule add https://github.com/Prolegomena-yume/harness-core.git .claude/_core

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
│   ├── commands/
│   │   ├── role-takano.md        ── /role-takano wrapper(任意)
│   │   └── role-ohashi.md        ── /role-ohashi wrapper(任意)
│   ├── settings.json             ── hook 登録(§5)
│   └── .linear-token             ── Linear Personal API Key(任意、gitignored)
├── .gitmodules                   ── submodule 定義(git submodule add で自動生成)
├── .harness.json                 ── consumer 設定(§3)
└── (consumer 固有 file...)
```

## 3. `.harness.json` の起草

`.claude/_core/schema/harness.schema.json`(JSON Schema draft-07)に準拠。実例は `.claude/_core/docs/example.harness.json` 参照。

### 最小構成(必須 field のみ)

```json
{
  "$schema": "./.claude/_core/schema/harness.schema.json",
  "project": {
    "name": "your-project-name"
  }
}
```

これだけで SessionStart hook は **graceful default** で動く(全 optional 節は default 値、Linear 節 skip、Cloud Setup は no-op)。

### 標準構成(prolegomena 想定値ベース)

```json
{
  "$schema": "./.claude/_core/schema/harness.schema.json",
  "project": {
    "name": "your-project-name",
    "displayName": "Your Project"
  },
  "linear": {
    "teamName": "YourTeam",
    "tokenSource": {
      "envVar": "LINEAR_TOKEN",
      "fileFallback": ".claude/.linear-token"
    },
    "issueStates": ["backlog", "unstarted", "started"],
    "limit": 30
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
      { "label": "AGENTS.md", "path": "AGENTS.md" }
    ]
  },
  "cloud": {
    "aptPackages": ["build-essential"],
    "nodeMinVersion": 20,
    "requiredEnvVars": [],
    "optionalEnvVars": [],
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
| `linear.teamName` | string | Linear team 名(無ければ Linear 節 skip) |
| `linear.tokenSource.{envVar,fileFallback}` | string | Linear token 取得経路 |
| `linear.issueStates` | string[] | GraphQL `state.type.in` フィルタ |
| `sessions.{dir,dailySummaryFilename}` | string | session_summary 配置 |
| `mirror.{enabled,stateFile}` | bool/string | Drive mirror 設定(consumer 固有、default off) |
| `canonical.links[]` | object[] | 起動チェックリマインダ link |
| `cloud.aptPackages` | string[] | Cloud Setup Phase 1 で apt install するパッケージ |
| `cloud.nodeMinVersion` | number | Node 最小メジャー version(default 20) |
| `cloud.requiredEnvVars` | string[] | Phase 4 で必須チェックする env var |
| `cloud.optionalEnvVars` | string[] | Phase 4 で optional 通知する env var |
| `cloud.npmGlobalPackages` | string[] | Cloud Setup Phase 3 で `npm install -g` する package |
| `cloud.codex.enabled` | boolean | true で session-install.sh が Codex auth bootstrap 実行 |
| `cloud.codex.authEnvVar` | string | auth source env var(default `CODEX_AUTH_JSON`) |
| `cloud.codex.{workspaceWrite,trustRepo}` | boolean | config.toml seed フラグ |
| `install.buildTargets` | string[] | session-install.sh で `npm run build -w` する workspaces |

詳細は [.claude/_core/schema/harness.schema.json](../schema/harness.schema.json) を直接参照。

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

## 7. Linear token 運用

`linear.teamName` を設定した場合、SessionStart hook が Linear GraphQL を直叩きする。token 取得経路:

| 優先度 | 経路 | 設定 |
|---|---|---|
| 1 | env var(default `LINEAR_TOKEN`) | local: シェル env / cloud: cloud session UI Environment variables |
| 2 | file fallback(default `.claude/.linear-token`) | local: plain text file、必ず **`.gitignore` 追加** |

token は https://linear.app/settings/api で Personal API Key(`lin_api_*`)発行。

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

- environment / git / session / mirror / startup reminders / Linear open issues

Anthropic 既知問題で **新規 cloud session の冒頭 context 注入が走らないことあり**([Issue #10373](https://github.com/anthropics/claude-code/issues/10373))、その場合は手動 fallback。

## 9. 動作確認(local mode)

```bash
# .harness.json が読まれて JSON 駆動で動くか確認
bash .claude/_core/hooks/session-init.sh

# stdout に JSON 1 行が出力、hookSpecificOutput.additionalContext 内に
# environment / git / session / mirror / startup reminders / Linear (teamName 設定時) 各節が見える
```

`.harness.json` 不在時は warning section が出るが、graceful default で exit 0、SessionStart hook を fail させない。

## 10. trouble shooting

| 症状 | 原因 / 対処 |
|---|---|
| SessionStart hook 出力 `session-init.sh: no usable python on PATH` | python3 not in PATH。`apt install python3` or `brew install python3` |
| `.harness.json missing` warning が出る | consumer リポ root に `.harness.json` が無い、または `CLAUDE_PROJECT_DIR` 未 set。`cd <repo-root>` で再実行 |
| Linear 取得 fail `token not set` | env var `LINEAR_TOKEN` 未 set かつ `.claude/.linear-token` file 不在 |
| Linear 取得 fail `HTTP 400/401` | token expired or 無効、Linear settings → API で再発行 |
| `npm ci` fail(cloud) | network 問題 or `package-lock.json` 整合性問題、`rm -rf node_modules .claude/.npm-install-hash && npm ci` で recovery |
| Codex auth bootstrap fail | `CODEX_AUTH_JSON` env が空、または invalid JSON。compact 化 + 再投入 |
| submodule fetch fail(`Phase 0`) | network or auth 問題、`git submodule update --init --recursive` 手動再走 |

## 11. 実例

- **prolegomena**(monorepo、npm workspaces、cloud session フル機能):[prolegomena-yume/Prolegomena](https://github.com/Prolegomena-yume/Prolegomena) の `.harness.json` / `.claude/settings.json` / `.claude/commands/role-*.md` 参照
- **stella**(小規模 monorepo、stella 想定値):[prolegomena-yume/stella](https://github.com/Prolegomena-yume/stella) の `.harness.json` 参照(本書整備時 = 2 件目実例として trace)
- **harness-starter**(空骨格 template):[prolegomena-yume/harness-starter](https://github.com/Prolegomena-yume/harness-starter) を template clone

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

各 hook が無くなるだけ、consumer リポ自体は無傷。

---

## 改訂履歴

- 2026-06-28 v0.1-draft 起草(鷹野(PDM))── PRL-30 P6 の最初の deliverable。harness-starter template repo 化(別 deliverable)+ stella 2 件目実例化 trace 反映予定。
