# harness-core

Reusable Claude Code harness ── SessionStart hook、Cloud Setup script、role 切替 slash command 雛形を汎用 layer として切り出した repo。consumer リポは git submodule で `.claude/_core/` にマウントして使う。

## 現状(2026-06-28)

- **初版骨格 commit 着地済**(P0)── 現 prolegomena の `.claude/` 配下を未変数化のまま 1:1 copy
- **`.harness.json` schema 確定 + JSON 駆動化**(P1+P2)── 次 commit
- **第 1 consumer 化(prolegomena)**(P3)── 別 Linear issue、別 session
- **submodule fetch 吸収 / consumer_setup.md / template repo 化**(P4+P6)── 別 Linear issue

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
