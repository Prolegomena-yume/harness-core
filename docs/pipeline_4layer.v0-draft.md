# 4層パイプライン v0(草案)── Fable 統括 + Opus 設計 + grok 実装 + codex 検証

**1 run で「Opus設計 → codex設計レビュー → Fable DAG/割付 → Opus実装設計 → grok実装 → codex品質ゲート → Opus意味論レビュー → Fable統合」を回す設計。**2026-08-18 鷹野起草、人見裁定待ち。根拠は bench v1 の層別適性判定(claude=設計適 / grok=実装最有力 / codex=ゲート最有力、いずれも条件付き)と team-takano v2 草案の認知プロファイル。

## 構成 ── 誰が何をどの資源で

| 層 | 実行体 | 起動形 | 消費する窓 |
|---|---|---|---|
| 統括(DAG・割付・認知管理・統合) | **Fable** | メインセッション(本体) | Claude |
| ドメイン設計・実装設計 | **Opus** | Agent tool、persona=水無瀬、model=opus。**ドメインごとに1体を持続させ、段1と段4を同一 agent の継続で回す**(SendMessage) | Claude |
| 意味論レビュー | **Opus** | Agent tool、persona=柏木、model=opus。**設計した agent とは別体**(自己レビュー禁止) | Claude |
| 実装 | **grok** | `cursor-agent --trust -p`(worktree cwd、無状態) | Cursor |
| 設計レビュー・品質ゲート | **codex** | `codex-kashiwagi`(5点セット= codex_delegation.md) | OpenAI |

**窓の構造が本設計の肝。**Claude 窓を食うのは Fable(統括)と Opus(設計系)だけ。実装と検証は別サブスクの窓で走るため、Claude 窓は「判断と設計」に温存される ── CLAUDE.md の委譲原則をパイプラインとして固定した形。

## 作業域と成果物の契約

**成果はすべてファイル。**通知は経路であって正本ではない(team-takano v1 の原則を継承)。

```
~/.orch/<UTC>-<task>/
  state.json                     # DAG 状態。書くのは Fable のみ
  requirements.md                # 原要件(人見の依頼を Fable が固定)
  domains/<d>/
    design.md                    # 段1: Opus。必須節=「原要件の字義→設計判断」突合表
    design-review.md             # 段2: codex verdict(P0/P1)
    impl-spec.md                 # 段4: Opus。必須節=DB制約DoD / reject・report再実行セマンティクス / 検証射程の定義
    impl-report.md               # 段5: grok の完了報告(検証射程の明記を義務化)
    gate.md                      # 段6: codex verdict
  semantics-review.md            # 段7: Opus(別体)。ドメイン間整合
  result.md + done               # 段8: Fable
```

worktree はドメイン単位:`git worktree add .claude/worktrees/<d> -b pipeline/<d>`。grok は自分の worktree しか見えない。統合は Fable が sequential merge。

## 段の定義と差し戻し線

| 段 | 実行体 | 完了条件 | 差し戻し先と方法 |
|---|---|---|---|
| 0 割付 | Fable | requirements.md 固定、domains + DAG を state.json に | ── |
| 1 ドメイン設計 | Opus(水無瀬) | design.md(選択肢+推奨+突合表) | ── |
| 2 設計レビュー | codex(柏木) | design-review.md。**観点=「仕様 vs 原要件」**(claude 系の美学>字義癖への対抗検査) | P0 あり → 段1 の同一 agent へ SendMessage で差し戻し。2巡で収束しなければ人見へ Escalation |
| 3 DAG 更新 | Fable | 承認済み design から実装順序確定、worktree 作成 | ── |
| 4 実装設計 | Opus(同一 agent 継続) | impl-spec.md。**bench の共通盲点を必須節で外部固定**(下記) | ── |
| 5 実装 | grok | worktree に code + tests + impl-report.md | 無状態のため **spec + gate 指摘を束ねて再発行**(resume 不可を前提に、差し戻しは常に「全文再供与」) |
| 6 品質ゲート | codex(柏木) | gate.md。観点=実装 vs impl-spec 突合 / **実体名の無断改名検出** / テスト自己完結性 / 検証射程の過大申告検出 | REJECT → 段5 再発行。2巡で収束しなければ Fable が切り分け(spec 欠陥なら段4 へ) |
| 7 意味論レビュー | Opus(別体・柏木 persona) | semantics-review.md。ドメイン間の契約整合・命名・組織意味論(AGENTS.md)適合 | ドメイン起因 → 該当ドメインの段4 へ。横断起因 → Fable が裁く |
| 8 統合 | Fable | merge + 統合テスト実行 + result.md。conflict が非自明なら段5 へ差し戻し | ── |

**impl-spec.md の必須節(bench 9/9 全滅への対策、層の重ね掛けでは検出できないため仕様側で固定):**

1. reject / report の再実行セマンティクス ──「再実行で行が増えてよい表/いけない表」の列挙
2. 冪等性の定義に bookkeeping 系を明示的に含める
3. report の正典2型(ファイル出力 or fingerprint 再利用)のどちらかを指定
4. DB 制約(CHECK / NOT NULL / UNIQUE)の DoD チェックリスト
5. 仕様外論点の扱い ──「独断で埋めず設計層へ差し戻す」

## 認知管理(Fable 統括の運転規則)

- **Opus へは3通形式で枠を与える**(ASSIGN/REPORT/ACK)。長走で視点が流れる型への対症
- **grok は成果物のみで採否。**自己申告の「検証した」は gate.md の裏取りがあるまで未検証として扱う
- **codex(柏木)の P0/P1 は毎回出る前提で受ける。**実機検証不可(DB・CLI・netlink)は Fable が引き取る
- **褒めは根拠付きで、差し戻しゼロ通過時のみ。**手離れの良い報告には ACK を省く
- **codex 実行中に commit しない**(事後ガードの ref 変化誤検知)。commit は各段の完了通知後、Fable のみが行う

## 資源予算

- **並行度:ドメイン2並列まで。**Opus 持続 agent はドメイン数ぶん立つが、稼働は2本に絞る(Claude 窓保護。Fable サブエージェント実測 6〜8万 token/体、Opus も同程度と仮置き)
- v0 試走はドメイン数 **≤3**。1ドメインの1巡(段1→8)で Claude 窓 ~20〜30万 token 見込み
- grok / codex の失敗リトライは各2回まで。超えたら人見へ

## 既知の摩擦と対処(bench・HUB 実測から)

1. **Opus の文脈継続** ── 段1と段4を同一 agent 継続で回すことで再供与コストを消す。agent が死んだら design.md から新体を再構成(ファイルが正本なので復元可能)
2. **grok の無状態性** ── 差し戻しは常に全文再発行。`--trust` 必須、stream-json の嘘(stderr 平文死)前提で outer parse を守る
3. **codex ガード誤発火** ── 実行中 commit 禁止(上記)
4. **自系びいき** ── 段7(Opus が claude 系設計を裁く)に同系バイアスが残る。段6 の codex ゲートが先に立つことで部分相殺。完全に消すなら段7 の実行体を codex に替える選択肢があるが、意味論・文脈把握は Claude 系が強く、trade-off として現行案を推す

## 裁定事項(人見)

1. v0 試走の題材(bench stage1 の再走をパイプラインで、が計測上は最良 ── 単独完遂 run との差分がそのまま分業の価値測定になる)
2. 段7 の実行体(推奨=Opus 別体。代替=codex)
3. ドメイン並列数と窓予算の上限
4. 成果物置き場(推奨=~/.orch。代替=対象リポ内 .pipeline/)
