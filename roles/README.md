# ロール定義 ── 人物像の正典

**このディレクトリが持つのは人物像だけ。**誰が居て、誰の配下で、役員と話すのは誰かという**名簿の正典は `company/keiei` の `organization.yml`(`roles:` 節)**にある。下の表は定義ファイルの索引で、所属が食い違ったら `organization.yml` を正とする。

## 役員と話すのはマネージャー3名だけ

**大橋[PJM]・鷹野[PDM]・麻布[BM] の3名だけが役員と話し、Discord の口(自分の bot)を持つ**(役員 人見 2026-09-25)。3名とも決定権は持たない。何を誰が裁定するかは役員3名が領域で分掌していて、その正典は `company/keiei` の `canon/organization.md`。

| 略号 | 名前 | ふりがな | 職能 | 一人称 | 定義 |
|---|---|---|---|---|---|
| PJM | 大橋瑞姫 | おおはし みずき | Project Manager | 私 | [ohashi.md](ohashi.md) |
| PDM | 鷹野 | たかの | プロダクトマネージャー | 俺 | [takano.md](takano.md) |
| BM | 麻布 | あざぶ | ビジネスマネージャー | 俺(対外フォーマル時のみ私) | [azabu.md](azabu.md) |

加賀美[DM]([kagami.md](kagami.md)、一人称「わたし」)は**役員 小高の配下のマネージャー候補で、置き場は未裁定。**接点ができるまで Discord の口は持たない。

## 配下の委譲人格は役員と話さない

マネージャーが自分の作業単位を分割するための人格で、**役員が名前を覚える必要はない。**成果は親のマネージャーへ返り、役員へはマネージャーが上げる。

| 名前 | 役 | 一人称 | 定義 |
|---|---|---|---|
| 浅田 | AA=事務の起草補佐 | 私 | [asada.md](asada.md) |
| 水無瀬澪 | PL=Planner 調査・設計 | 私 | [minase.md](minase.md) |
| 柏木律 | CM レビュー・監査・助言 | 僕 | [kashiwagi.md](kashiwagi.md) |
| 贄川迅 | ORC=Orchestrator 段取り | 自分 | [niekawa.md](niekawa.md) |
| 真壁陸 | IM=Implementer 実装 | 俺 | [makabe.md](makabe.md) |
| 庵野奏 | EXP=Experimenter 道具作り・PoC | あたし | [anno.md](anno.md) |
| 源内詩 | WT=Writer 日本語リライト | わたし | [gennai.md](gennai.md) |

実体のモデルは [../docs/models.md](../docs/models.md)(値は `scripts/models.env`)。

**贄川・庵野・源内の名(下の名前)・一人称・口調は鷹野の仮置き**で、役員 人見が直せば従う。姓と略号だけが裁定済み(2026-09-18)。

## 鷹野のチームの序列は実装ラインだけに立つ

**鷹野 > 柏木 > 贄川 > 真壁。**段取りは贄川が持ち、柏木は贄川から呼ばれるが立場は上、差し戻し権は贄川、承認は鷹野(役員 人見 2026-09-18、裁定の正典は `company/tech/_sessions/2026-09-18_01.md`)。

**水無瀬・庵野・源内は鷹野直属で横並び。**この3人は実装ラインの指揮下に入らず、柏木のゲートも通らない ── 鷹野が直接受ける。例外は Codex 逼迫時に庵野が真壁を代行する場合で、そのときだけゲートを通す。

**起動定義**(tools / model / 起動契約)は [../agents/](../agents/README.md)(Claude)、[../codex/](../codex/README.md)(Codex)、`../kimi/`(Kimi)が持つ。手順の正典は [../docs/delegation.md](../docs/delegation.md)。

## 外したロールは _frozen に置く

**御室[PS]・山下[CR]・桜井[AE] は 2026-09-25 に一度外した**(役員 人見)。実働が無かったため。定義は [_frozen/](_frozen/) に残し、`/role-` コマンドだけを消した。戻すときは `git mv` で戻し、コマンドを足し直す。

**他のロールの人物像に残る3名への言及(呼称マップ・関係)は消さない。**人物像の設定であって、仕事の振り先ではない。

## 正典の系譜

- **大元**:`yumemism/90_role/role_*.md`(Android / Claude.ai 運用時代の原本)
- **現在の正典**:このディレクトリ(`company/harness-core/roles/`)
- `ohashi.md` は設定書 [_bible/ohashi.md](_bible/ohashi.md)(★非公開、`/role-ohashi` では読まない)から起こした実行用の版。食い違ったら設定書が正
- `takano.md` は従来の harness-core 版を維持。他は 90_role 由来

## 置き場と参照

このリポは Forgejo `company/harness-core` が正典、GitHub `Prolegomena-yume/harness-core` はミラー。

経営本部(`company/keiei`)は本リポを **submodule として引く**。組織図は経営本部の管轄だが、人物像の実体はここに置いて一箇所に集約する ── 同じロール定義が複数箇所に存在する状態を作らない。

Claude Code からは `/role-<名前>` で切り替える。consumer リポは本リポを `.claude/_core` に submodule で引き、`.claude/commands` は `_core/commands` への symlink か、同じ内容の写しを置く(`harness` は写し)。Codex 用の skill は `company/tech` の `.agents/skills/role-*`。**ここが正。ロール本文を直すときはここを直し、consumer の submodule を上げ、写しをそろえる。逆はしない。**

## 関連

- AI セッションの最上位規範:[../docs/harness_constitution.md](../docs/harness_constitution.md)
- 会社憲章(未起草、**この規範の上位に立つ**):`company/keiei/constitution/`
