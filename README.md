# harness-core

Reusable Claude Code harness ── SessionStart hook、Cloud Setup script、role 切替 slash command 雛形を汎用 layer として切り出した repo。consumer リポは git submodule で `.claude/_core/` にマウントして使う。

## 現状(2026-06-28)

- **初版骨格 commit 着地済**(P0)── 現 prolegomena の `.claude/` 配下を未変数化のまま 1:1 copy
- **`.harness.json` schema 確定 + 3 script JSON 駆動化 着地済**(P1+P2)── `schema/harness.schema.json` / `docs/example.harness.json` / `hooks/session-init.sh` / `hooks/session-install.sh` / `setup/cloud_setup_script.sh`、graceful fallback 動作確認済
- **第 1 consumer 化(prolegomena)**(P3)── 別 Linear issue、別 session
- **submodule fetch 吸収 / consumer_setup.md / template repo 化**(P4+P6)── 別 Linear issue

## .harness.json schema 概要

詳細は `schema/harness.schema.json`(JSON Schema draft-07)、実例は `docs/example.harness.json`。主要 field:

| field | 型 | 用途 |
|---|---|---|
| `project.name` | string (required) | 内部識別子 |
| `linear.teamName` | string | Linear team 名(無ければ Linear 節 skip) |
| `linear.tokenSource.{envVar,fileFallback}` | string | Linear token 取得経路 |
| `linear.issueStates` | string[] | GraphQL state.type.in フィルタ |
| `sessions.{dir,dailySummaryFilename}` | string | session_summary 配置 |
| `mirror.{enabled,stateFile}` | bool/string | Drive mirror 設定 |
| `canonical.links[]` | object[] | 起動チェックリマインダ link |
| `cloud.{aptPackages,nodeMinVersion,requiredEnvVars,optionalEnvVars}` | array/num | Cloud Setup script 駆動値 |
| `cloud.npmGlobalPackages` | string[] | Phase 3 で `npm install -g` する package list |
| `cloud.codex.enabled` | boolean | true で Codex auth bootstrap 実行 |
| `cloud.codex.authEnvVar` | string | auth.json source env var 名(default `CODEX_AUTH_JSON`) |
| `cloud.codex.{workspaceWrite,trustRepo}` | boolean | config.toml seed フラグ |
| `install.buildTargets` | string[] | session-install.sh の `npm run build -w` workspaces |

`.harness.json` 不在 / parse error 時は全 script が compat default で graceful fallback、exit 0 維持(SessionStart hook を fail させない)。

## ファイル構造

```
harness-core/
├── hooks/
│   ├── session-init.sh        ── SessionStart hook: git/session/mirror/Linear/reminders 注入
│   └── session-install.sh     ── cloud session の npm ci + packages build(冪等)
├── setup/
│   └── cloud_setup_script.sh  ── Cloud Setup script: apt / Node check / env check
├── scripts/
│   └── timer.sh               ── background timer + log 監視(Codex session watch 用)
├── commands/
│   ├── role-takano.md         ── /role-takano slash command 雛形
│   └── role-ohashi.md         ── /role-ohashi slash command 雛形
├── roles/
│   ├── takano.md              ── 鷹野(PDM)ロール定義(yumemism 大元 canonical の中継地)
│   └── ohashi.md              ── 大橋(PJM)ロール定義(同上)
├── schema/
│   └── harness.schema.json    ── .harness.json schema(JSON Schema draft-07)
└── docs/
    ├── example.harness.json   ── prolegomena 想定値の参考実装
    └── consumer_setup.md      ── consumer 起こし手順(P6 で本格化)
```

## consumer 側使い方(P3+ で確定、現状は雛形)

```bash
# 1. consumer リポで submodule add
git submodule add https://github.com/prolegomena-yume/harness-core.git .claude/_core

# 2. consumer リポ root に .harness.json 起草(schema/harness.schema.json 準拠)
$EDITOR .harness.json

# 3. .claude/settings.json で hook path を .claude/_core/hooks/*.sh に
$EDITOR .claude/settings.json

# 4. SessionStart hook が .harness.json 駆動で動く
```

## 関連

- Epic: [PRL-30](https://linear.app/prolegomena/issue/PRL-30) ハーネス再利用化
- P0: [PRL-31](https://linear.app/prolegomena/issue/PRL-31)
- P1: [PRL-32](https://linear.app/prolegomena/issue/PRL-32)
- P2: [PRL-33](https://linear.app/prolegomena/issue/PRL-33)
- P3: [PRL-34](https://linear.app/prolegomena/issue/PRL-34)
- P4: [PRL-35](https://linear.app/prolegomena/issue/PRL-35)
- P6: [PRL-36](https://linear.app/prolegomena/issue/PRL-36)

## 第 1 consumer

- [prolegomena-yume/Prolegomena](https://github.com/Prolegomena-yume/Prolegomena)(P3 で着地予定)
