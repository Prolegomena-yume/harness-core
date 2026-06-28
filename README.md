# harness-core

Reusable Claude Code harness ── SessionStart hook、Cloud Setup script、role 切替 slash command 雛形を汎用 layer として切り出した repo。consumer リポは git submodule で `.claude/_core/` にマウントして使う。

## 現状(2026-06-28)

- **初版骨格 commit 着地済**(P0)── 現 prolegomena の `.claude/` 配下を未変数化のまま 1:1 copy
- **`.harness.json` schema 確定 + 3 script JSON 駆動化 着地済**(P1+P2)── `schema/harness.schema.json` / `docs/example.harness.json` / `hooks/session-init.sh` / `hooks/session-install.sh` / `setup/cloud_setup_script.sh`、graceful fallback 動作確認済
- **Codex auth portable JSON 駆動化 着地済**(P1+P2 ext、2026-06-28)── `cloud.npmGlobalPackages` + `cloud.codex.{enabled,authEnvVar,workspaceWrite,trustRepo}` schema 拡張、cloud_setup_script.sh に Phase 3 npm global install + Phase 番号スライド、session-install.sh 末尾に Codex auth bootstrap phase 追加(`~/.codex/auth.json` 冪等 + `config.toml` seed、JWT 値は log 非露出)
- **第 1 consumer 化(prolegomena)着地済**(P3、2026-06-28)── prolegomena に `.claude/_core/` submodule マウント + `.harness.json` 起草 + 旧 .claude/hooks/cloud_setup_script/roles 削除 + CLAUDE.md 改訂、local mode 動作確認 pass(`.harness.json` 駆動で Linear/sessions/mirror/canonical 全節 OK)、cloud verify 別 session で実施予定
- **submodule fetch 吸収 + bubblewrap apt 追加 着地済**(P4、2026-06-28)── cloud_setup_script.sh に Phase 0 = `git submodule update --init --recursive` 追加(consumer 側で `git clone --recurse-submodules` 漏れた場合の保険、冪等)、example.harness.json の `cloud.aptPackages` に `bubblewrap` 追加(Codex CLI の cosmetics warning 解消、cloud Linux Codex 実体験 = handoff [pr-cloud-codex-verification.md](docs/handoffs/pr-cloud-codex-verification.md) で確認)
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
    ├── handoffs/              ── 着地済 session/PR からの handoff 文書群(cloud verification 等)
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
