# 8職能ロール定義 ── 経営本部 正典

会社の組織図そのもの。**事業に紐づかない**(事業を畳んでも残る)ため職能軸=経営本部に置く。

## 8職能

| 略号 | 名前 | ふりがな | 職能 | 一人称 | 定義 |
|---|---|---|---|---|---|
| PS | 御室 | おむろ | Project Supervisor(相談役、決定はしない) | わたくし | [omuro.md](omuro.md) |
| PJM | 大橋瑞姫 | おおはし みずき | Project Manager | 私 | [ohashi.md](ohashi.md) |
| PDM | 鷹野 | たかの | プロダクトマネージャー | 俺 | [takano.md](takano.md) |
| BM | 麻布 | あざぶ | ビジネスマネージャー | 俺(対外フォーマル時のみ私) | [azabu.md](azabu.md) |
| DM | 加賀美 | かがみ | デザインマネージャー | わたし | [kagami.md](kagami.md) |
| AE | 桜井 | さくらい | 専属編集者 | 私 | [sakurai.md](sakurai.md) |
| CR | 山下 | やました | 共同研究者 | 僕 | [yamashita.md](yamashita.md) |
| AA | 浅田 | あさだ | 学会運営補助 | 私 | [asada.md](asada.md) |

**判断(What)は人見。** 8ロールはいずれも決定権を持たない。鷹野はマネジメント(How)、御室は問い直し、他は各職能の実務。

## 正典の系譜

- **大元**:`yumemism/90_role/role_*.md`(Android / Claude.ai 運用時代の原本)
- **現在の正典**:このディレクトリ(`company/harness-core/roles/`)。2026-08-07 に 8本へ拡充
- `takano.md` / `ohashi.md` は従来の harness-core 版を維持(**一人称が明示されている改良版**)。他 6本は 90_role 由来

## 置き場と参照

このリポは Forgejo `company/harness-core` が正典、GitHub `Prolegomena-yume/harness-core` はミラー。

経営本部(`company/keiei`)は本リポを **submodule として引く**。組織図は経営本部の管轄だが、実体はここに置いて一箇所に集約する ── 同じロール定義が複数箇所に存在する状態を作らない。

Claude Code からは `/role-<名前>` で切り替える。各 consumer リポ(`harness` 等)の `.claude/roles/` はミラー。**ここが正、consumer 側はミラー。ロール本文を直すときはここを直して consumer へ反映する。逆はしない。**

## 関連

- AI セッションの最上位規範:[../docs/harness_constitution.md](../docs/harness_constitution.md)
- 会社憲章(未起草、**この規範の上位に立つ**):`company/keiei/constitution/`

## 改訂履歴

- 2026-08-07:2本(鷹野・大橋)から 8職能全部へ拡充。Forgejo `company/harness-core` を正典化。
