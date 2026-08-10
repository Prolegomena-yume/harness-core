# 委譲人格(サブエージェント定義)── 正典

**鷹野(PDM)がサブエージェントへ委譲するとき、必ずここで定義した人格を明示指定する。**生成物を「鷹野推奨」のような匿名帰属にせず、委譲先インスタンスを追跡可能にするための機構。

| 人格 | 役 | `subagent_type` | 用途 | 定義 |
|---|---|---|---|---|
| 水無瀬澪 | Planner | `minase` | 設計案の複数提示、仕様分解、影響範囲の洗い出し | [minase.md](minase.md) |
| 真壁陸 | Implementer | `makabe` | 実装・テスト記述(**Codex が使えない場面のフォールバック**) | [makabe.md](makabe.md) |
| 柏木律 | Reviewer | `kashiwagi` | 仕様突合、エッジケース、既存コードとの整合性 | [kashiwagi.md](kashiwagi.md) |

序列は鷹野 >>> 水無瀬 > 真壁・柏木。現行運用は鷹野が三者へ直接委譲するフラット構成で、水無瀬から真壁/柏木への再帰委譲は tools に含めていない。

## 8職能とは別系統である

8職能([../roles/README.md](../roles/README.md))は会社の組織図で、いずれも人見へ上申する。この3人は**鷹野の作業単位を分割するための人格**であって、組織図には乗らない。人物像そのものは `../roles/{minase,makabe,kashiwagi}.md` が持ち、本ディレクトリはその**起動定義**(tools / model / 委譲時の振る舞い)だけを持つ。

## モデルは opus5 を明示指定する

3人とも `model: claude-opus-5`(人見指示、2026-08-11)。**エイリアス `opus` を使わない** ── 世代が上がったときにどの実体を指すか曖昧になるため、モデル ID で固定する。従来の Sonnet 指定はこの指示で失効。

## 実装の主経路は Codex であって真壁ではない

`makabe` はフォールバック。実装をサブエージェントへ流す前に、Codex Bash 直叩きで足りないかを必ず確認する。手順の正典は [../docs/codex_delegation.md](../docs/codex_delegation.md)。

## consumer からの配線はシンボリックリンク一本

Claude Code は `.claude/agents/` しか探索せず、`.claude/_core/agents/` へは自動で届かない。commands と違い agent 定義は frontmatter(`tools` / `model`)が本体なので、**wrapper を置くと consumer の数だけモデル指定が複製される。**したがってリンクで解決する。

```bash
ln -s _core/agents .claude/agents
```

`/role-minase`(メインセッションを水無瀬へ切り替える経路)だけは commands の規約に従い、consumer 側に thin wrapper を置く。真壁・柏木はコマンド化しない ── 人見からの直接呼び出しを想定しないため。
