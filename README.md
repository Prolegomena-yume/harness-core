# harness-core

**再利用可能な Claude Code ハーネス。**consumer リポが `.claude/_core/` へ submodule でマウントして使う。正典は Forgejo の [company/harness-core](https://git.yumemism.com/company/harness-core)。

## このリポが持つもの、持たないもの

**このリポは規範・人格・機構だけを持ち、プロダクト固有の値を持たない。**consumer ごとに変わる値は全て consumer ルートの `.harness.json` から差す ── リポ名、セッション置き場、Neon の接続先、cloud で入れる package、実装層のトークン置き場。

**したがって harness-core を直接編集して consumer を通すことはしない。**足りない設定があれば schema を拡張し、値は consumer 側へ置く。

## 何がどこにあるか

| 位置 | 中身 |
|---|---|
| [docs/harness_constitution.md](docs/harness_constitution.md) | **最上位規範。**harness 上で動く全 AI セッションが従う。規定の欠落・矛盾時の解釈基準 |
| [roles/](roles/README.md) | 8職能ロールと委譲人格3人の**人物像**。会社の組織図そのもの |
| [codex/](codex/README.md) | 委譲人格3人の **Codex 起動定義(主経路)**。人格ごとの sandbox と書き込み範囲 |
| [agents/](agents/README.md) | 同3人の **Claude Agent tool 起動定義(フォールバック)** |
| [docs/codex_delegation.md](docs/codex_delegation.md) | **委譲手順の正典。**起動の5点セット、事後ガードの守備範囲、差し戻し |
| [docs/orchestration.md](docs/orchestration.md) + [orch/](orch/) | **実装層とレビュー層を逐次バトンで回す機構。**claude が叩くのは `orch.sh` 1行 |
| [docs/bg_session_lifecycle.md](docs/bg_session_lifecycle.md) | **bg セッションの終わらせ方。**`kill` では蘇る |
| `hooks/` | SessionStart hook(git / session / mirror / Neon / reminders を注入)と cloud の install |
| `setup/` | cloud setup script、Codex 委譲人格のインストーラ |
| `scripts/` | `timer.sh`(Codex 監視)/ `ctr.sh`(transcript 出力)/ `codex-agent.sh`(git 境界ガード)/ bg TUI 駆動 |
| `schema/harness.schema.json` | **`.harness.json` の正典。**実例は [docs/example.harness.json](docs/example.harness.json) |
| `commands/` | role 切替 slash command の雛形 |
| [docs/consumer_setup.md](docs/consumer_setup.md) | **新規 consumer の起こし方。**手順はここだけが持つ |
| `docs/handoffs/` | 着地済セッションからの handoff 文書 |

## consumer の起こし方

**手順の正典は [docs/consumer_setup.md](docs/consumer_setup.md)。**ここには写さない。要点だけ言うと、submodule をマウントし、`.harness.json` を起草し、`.claude/settings.json` の hook path を `.claude/_core/hooks/` へ向ける。

```bash
git submodule add https://git.yumemism.com/company/harness-core.git .claude/_core
```

## `.harness.json` が全部を駆動する

**hook も setup script も orch も、値は `.harness.json` から読む。**field の一覧は `schema/harness.schema.json` が正典で、ここには写さない。

**不在・parse error でも全 script は compat default で走り exit 0 を保つ。**SessionStart hook を fail させないため。例外は `orch` で、実装層のトークン置き場が引けなければ明示エラーで止まる ── 個人環境のパスを既定値としてこのリポへ焼かないため。

## この層は退役する

**harness-core は Agent SDK 移行完了までの開発時ハーネス**(2026-07-20 人見裁定、`yumemism/harness` の kickoff)。移行後に畳む。したがってここへ長期資産を積まない ── 人物像と規範は残るが、配線は移行先が引き取る。
