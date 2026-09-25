# 委譲人格の Claude Agent tool 定義

**Claude Agent tool の人格は、鷹野配下の水無瀬(opus)と庵野(sonnet)、大橋配下の浅田(opus)の 3 人。**柏木と真壁はランチャ(`claude-kashiwagi` / `codex-kashiwagi`、`codex-makabe`)でだけ起こし(実体のモデルは [../docs/models.md](../docs/models.md))、Agent tool 版は 2026-09-18 に削除した(役員 人見。裁定の正典は `company/tech/_sessions/2026-09-18_01.md`)── 同じ役が 2 つのモデルに跨がると、どちらが正か決まらないため。配線と使い方は [../codex/README.md](../codex/README.md) と [../docs/delegation.md](../docs/delegation.md)。

マネージャー(鷹野・大橋)が Claude 内サブエージェントへ委譲するときは、ここで定義した人格を明示指定する。生成物を「鷹野推奨」のような匿名帰属にせず、委譲先インスタンスを追跡可能にするための機構。

| 人格 | 役 | `subagent_type` | model | 用途 | 定義 |
|---|---|---|---|---|---|
| 水無瀬澪 | PL=Planner | `minase` | `claude-opus-5-5` | 調査・設計案・影響範囲 | [minase.md](minase.md) |
| 庵野奏 | EXP=Experimenter | `anno` | `claude-sonnet-5` | 道具作り・Playwright・PoC・検証しながらの実装 | [anno.md](anno.md) |
| 浅田 | AA=事務の起草補佐 | `asada` | `claude-opus-5-5` | 規約・同意文言・ポリシーの起草、法令と規程の読み | [asada.md](asada.md) |

**浅田は大橋(PJM)直属で、鷹野のチームの外にいる**(役員 人見 2026-09-25)。技術の調査は水無瀬、事務の起草は浅田と持ち場を分ける。浅田のモデルは仮置きで、配役表([../docs/models.md](../docs/models.md))への記載は鷹野の確認待ち。

**水無瀬と庵野は鷹野直属で横並び**(源内も同列だが Agent tool を持たず `genai` で呼ぶ)。実装ラインの序列は 鷹野 > 柏木 > 贄川 > 真壁 で、この 2 人はその指揮下に入らない。**Claude 側の実装の手は庵野、Claude 側の第二の目は水無瀬。**再帰委譲(Agent tool の入れ子呼び出し)は tools に含めていない。

## 委譲人格は役員と話さない

役員と話すのはマネージャー3名(大橋・鷹野・麻布)だけで、名簿の正典は `company/keiei` の `organization.yml`。委譲人格は**マネージャーの作業単位を分割するための人格**であって、成果は親のマネージャーへ返る。人物像そのものは `../roles/*.md` が持ち、本ディレクトリはその**起動定義**(tools / model / 委譲時の振る舞い)だけを持つ。

## モデル ID を明示指定する

**エイリアス(`opus` / `sonnet`)を使わない** ── 世代が上がったときにどの実体を指すか曖昧になるため、モデル ID で固定する(人見指示 2026-08-11)。水無瀬は `claude-opus-5-5`、庵野は `claude-sonnet-5`。

## tools 行は必ず書く

**人格定義は `tools` 行で絞られる。**汎用 agent では Browser ペイン(`mcp__Claude_Browser__*`)が継承されるが、人格を指定した agent では継承されないことを実測済み(2026-09-16、d77d8e2 / a8013e5)。Browser ペインを使わせるなら `mcp__Claude_Browser__*` を、curl で本文を取らせるなら `Bash` を、明示的に並べる。

## consumer からの配線はシンボリックリンク一本

Claude Code は `.claude/agents/` しか探索せず、`.claude/_core/agents/` へは自動で届かない。commands と違い agent 定義は frontmatter(`tools` / `model`)が本体なので、**wrapper を置くと consumer の数だけモデル指定が複製される。**したがってリンクで解決する。

```bash
ln -s _core/agents .claude/agents
```

`/role-minase`(メインセッションを水無瀬へ切り替える経路)だけは commands の規約に従い、consumer 側に thin wrapper を置く。**`/role-anno` と `/role-asada` は作らない** ── 人見からの直接呼び出しを想定しないため。
