# 委譲人格の Claude Agent tool 定義

**水無瀬の主経路は Claude(本ディレクトリの `minase`、柏木からは `claude-minase`)。柏木・真壁の主経路は Codex で、本ディレクトリの Agent tool 版はフォールバック。**配線と使い方は [../codex/README.md](../codex/README.md) と [../docs/codex_delegation.md](../docs/codex_delegation.md)。

鷹野(PDM)が Claude 内サブエージェントへフォールバック委譲するときは、ここで定義した人格を明示指定する。生成物を「鷹野推奨」のような匿名帰属にせず、委譲先インスタンスを追跡可能にするための機構。

| 人格 | 役 | `subagent_type` | 用途 | 定義 |
|---|---|---|---|---|
| 水無瀬澪 | Planner | `minase` | 調査・設計案・影響範囲(**主経路**) | [minase.md](minase.md) |
| 真壁陸 | Implementer | `makabe` | 実装・テスト記述(**Codex が使えない場面のフォールバック**) | [makabe.md](makabe.md) |
| 柏木律 | CM | `kashiwagi` | Codex が使えない場面の仕様突合・整合性確認・赤入れ | [kashiwagi.md](kashiwagi.md) |

序列は鷹野 > 水無瀬 = 柏木 > 真壁(2026-09-13 改編)。Codex 側では柏木が真壁を `spawn_agent` で起こす。Agent tool 版は鷹野からの直接委譲だけで、再帰委譲は tools に含めていない。

## 8職能とは別系統である

8職能([../roles/README.md](../roles/README.md))は会社の組織図で、いずれも人見へ上申する。この3人は**鷹野の作業単位を分割するための人格**であって、組織図には乗らない。人物像そのものは `../roles/{minase,makabe,kashiwagi}.md` が持ち、本ディレクトリはその**起動定義**(tools / model / 委譲時の振る舞い)だけを持つ。

## モデルは opus5 を明示指定する

3人とも `model: claude-opus-5`(人見指示、2026-08-11)。**エイリアス `opus` を使わない** ── 世代が上がったときにどの実体を指すか曖昧になるため、モデル ID で固定する。従来の Sonnet 指定はこの指示で失効。

## 柏木・真壁の主経路は Codex、水無瀬は Claude

`makabe`、`kashiwagi` はフォールバック。`minase` は主経路(窓経済 ── Claude が最潤沢、codex Plus が最逼迫、人見 2026-08-18 / 09-13)。委譲手順の正典は [../docs/codex_delegation.md](../docs/codex_delegation.md)。

## consumer からの配線はシンボリックリンク一本

Claude Code は `.claude/agents/` しか探索せず、`.claude/_core/agents/` へは自動で届かない。commands と違い agent 定義は frontmatter(`tools` / `model`)が本体なので、**wrapper を置くと consumer の数だけモデル指定が複製される。**したがってリンクで解決する。

```bash
ln -s _core/agents .claude/agents
```

`/role-minase`(メインセッションを水無瀬へ切り替える経路)だけは commands の規約に従い、consumer 側に thin wrapper を置く。真壁・柏木はコマンド化しない ── 人見からの直接呼び出しを想定しないため。
