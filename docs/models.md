# モデルの特性、役との対応、プロンプトの書き方

**モデルの ID と persona 別の model / effort は [../scripts/models.env](../scripts/models.env) だけが持つ。**本書は値を写さず、各モデルの特性(出典付き)、役とモデルを対応させた理由、プロンプトの書き方の規則を持つ。手順の正典は [delegation.md](delegation.md)。

出典の記号は 3 つ。**[A]** = Anthropic「Prompting Claude Opus 5.5」、**[O]** = OpenAI「Introducing GPT-6 Sol and Luna」、**[H]** = 役員 人見のモデル観(2026-09-24、鷹野経由)。実測は delegation.md とハーネスの各 SPEC にあり、引くときは所在を書く。

## モデル表は models.env にだけ置く

**世代が変わったら直すのは `scripts/models.env` の 1 ファイルだけ。**ランチャはこれを source し、`agents/*.md` の frontmatter と `codex/agents/*.toml.tmpl` の model は同じ値に揃える。別名(`opus` / `sonnet`)は使わず ID で固定する(人見指示 2026-08-11)。退役 ID と別名の残りは `scripts/test-agent-wrappers.py` が検査する。プロンプト本文にも ID を書かない ── 書いてよいのは `--model gpt-6-sol` のように、モデルがコマンドとして打つ文字列だけ。

## Claude Opus 5.5 ── effort で深さを決める、無人 run は報告で止まりやすい

- [A] thinking は常に on で、**思考量の主な制御は effort。**既定は `medium`。Opus 5.5 の `medium` は coding と knowledge work で Opus 5 の `high` に並ぶか上回る。同じ level でも Opus 5 より 1 turn の思考が多く、`xhigh` / `max` で顕著
- [A] 実リポでの多段作業、並列の subagent を使う長時間の自律作業に強い。コードレビューは Opus 5 より検出が増え誤検知が減った
- [A] 長い無人 run では、進み具合の報告を text だけで書いて turn を閉じることがある。閉じてほしくない型と閉じてよい場面を名指しすると減る
- [A] 推論を本文に再現させる指示は `reasoning_extraction` で拒否されうる。この拒否はフォールバックで再試行されない
- [A] 経過時間の情報によく反応する。`elapsed 340s / 1200s` の形で予算を渡すと並列が進んで早く終わり、たいてい予算より前に終わる。予算は助言で止めはしない。時間の圧で探索と検証がやや減りうる
- [H] エージェンティック。全体を見て統合するのが得意
- 実測(`claude/makabe.md` の由来、2026-09-22 F4 巡 2):`claude -p` は Bash の `run_in_background` の完了通知で起きない。背景に回して「通知を待つ」で turn を閉じると session が閉じ、変更 0 で終わった(21 turn を空費)

## Claude Fable ── ハーネスに入れない

- [H] 意図を汲みやすい
- **ハーネスの役には使わない。**weekly と Fable の枠の両方を食う。GUI の鷹野専用(役員 人見 2026-09-24)

## Claude Sonnet 5

- 本書の 3 つの出典に記述が無い。庵野と、真壁の claude 経路(`MAKABE_ROUTE=claude`)に使っている

## GPT-6 Sol

- [O] GPT-5.6 Sol から API 価格が半額。社内の事実性評価で誤りが前世代の約半分。FrontierCode(merge できる変更か)で 5.6 Sol から大きく改善
- [H] 5.6 sol は細部を検証して細かい不整合を見抜く ── codex をゲートに置いたのはそのため。ただし「直せば終わる」ものを差し戻しがちで、「P0 のみ見よ」「P2 は自分で直せ」を後から足した。GPT-6 Sol でも同じ傾向かは未観測

## GPT-6 Luna

- [O] GPT-5.6 Luna から半額。`max` で DeepSWE 66.6%、Opus 5 / Fable 5 の `medium` 並み。高い effort で事実性が 5.6 Sol に並ぶ
- 枠への計上がほぼ無い(delegation.md「出力の上限は上位モデルにだけ効く」)

## GPT-6 の共通点 ── 返答が短く、確かめたかを言う

- [O] 返答がやや短く、言い回しが具体的になった。何を確かめ、何を確かめていないかを言うようになった(Sol の例示)
- [O] coding の仕事について誤解を招く主張が 5.6 より減った
- [O] reasoning effort と tool の切替が prompt cache を壊さない
- **GPT-6 向けの公式のプロンプト指針は見つかっていない**(人見 2026-09-24)

## GPT-6 Astra ── 柏木の既定から退役

- [O] GPT-6 の最上位
- 柏木の codex 経路の既定から退役した(役員 人見 2026-09-24)。ID は models.env の `CODEX_ASTRA_MODEL` に残る

## Kimi K3 と Gemini 3.8 Flash (High)

- K3:cached の turn は枠を食わず、巡の頭の cold start が 1 単位(delegation.md、09-18 実測)。`kimi -p` は argv 128KB、tool 上限 300 秒(同)。書き方は [../kimi/niekawa.md](../kimi/niekawa.md) のまま変えない
- Gemini 3.8 Flash (High):人見の実読で 3.1 Pro(です / ます に化ける)と 3.6 Flash(語を替え括弧で原文を添える)を退けた(2026-09-18)

## 役とモデルの対応

**配役は「何が得意か」と「どの枠を食うか」の 2 つで決めている。**値は models.env、枠の規則による切替は delegation.md。

- **鷹野 = Fable(GUI)。**意図を汲む力を人見との要件定義に使う
- **水無瀬 = Opus 5.5。**全体を見て統合する力を調査・設計に使う
- **贄川 = 主は K3、枠切れは Sol。**段取りは待ちが長く、K3 は待ちの turn が cached で枠を食わない。`tech/_drafts/plan/58-task-dag.v0.md` の工程に限っては Opus 5.5 が主(役員 人見 2026-09-21、effort `medium` は 2026-09-24)。段 7〜段 10 は kimi が減りすぎになるまで K3 で回す(役員 人見 2026-09-24)
- **柏木 = 既定は Opus 5.5(経路 C、effort `xhigh`)、codex 経路は Sol。**経路 C は 2026-09-21 の PoC(Opus 5 件中 5 件、K3 2 件)による。Sol は細部の不整合を見抜く [H]。**どちらをゲートに置くかは Opus 5.5 と gpt-6-sol の PoC で決める(未決)**
- **真壁 = Luna `max`、差し戻し後の P0 巡は Sol。**Luna は枠にほぼ載らず、DeepSWE で Opus 5 の `medium` 並み [O]。ゲート 2 の P0 は Luna の理解で漏れた箇所なので、同じ水準でやり直すより Sol で 1 巡で済ませる(役員 人見 2026-09-20、GPT-6 の ID で 2026-09-24 に再裁定)。codex が減りすぎのときは claude 経路(Sonnet 5)
- **庵野 = Sonnet 5。源内 = Gemini 3.8 Flash (High)、agy が減りすぎなら K3**
- **モデル分離は鷹野の検算が担保する。**実装・段取り・ゲート・検算のモデルを分け、鷹野が納品物を独立に検算する配置そのものが分離で、柏木は分離の検査項目を持たない

## Claude 向けの書き方 ── 深さは effort、止まり方は名指し

**深さはプロンプトの言葉でなく effort で決める。**これは Anthropic の資料の言明で、人見の裁定ではない ── [A] effort が思考量の主な制御で、思考を減らすなら prompt の指示より effort を下げる方が確実。chat の system prompt から「答える前によく考えて」の類を外しても品質の低下ははっきりしなかった。

1. **「慎重に」「よく考えて」「徹底的に」を書かない。**深さを変えるなら models.env の effort を変える
2. **`xhigh` / `max` は品質差を測ってから** [A]。柏木の `xhigh` は 2026-09-21 の裁定で、Opus 5.5 での `medium` / `high` との差はまだ測っていない。値を変えるのは別の裁定
3. **推論を本文に書かせない。**「考えた過程を書け」は `reasoning_extraction` で拒否されうる [A]。書かせてよいのは成果物の一部としての根拠 ── P0 の「なぜ不可逆か」、エスカレーションの推奨の理由
4. **止まってよい場面を名指しする** [A]。無人の契約(`claude/*.md`)は末尾に「止まり方」の節を置く ── 止まってよいのは終端の種類だけ(贄川 = `verdict.md` の 3 種、柏木 = 判定の一語、真壁 = commit か「矛盾」「確認が必要」)。しない型は 4 つ ── 報告だけの turn、次の手を予告して終わる turn、裁定の要らない問いで止まる turn、区切りがいいから報告する turn。進み具合の注記は次の tool call と同じ message に書かせる。資料は system prompt の末尾に置くことを勧める
5. **Stop hook が機械の担保。**資料は自動の続行を 2〜3 回で打ち切ることを勧めるが、ハーネスの Stop hook は回数の上限を置かない(役員 人見 2026-09-24)。詰まった run の打ち切りはランチャの巡数上限と待ちの切片が持つ
6. **経緯を本文に置かない。**規則と短い理由 1 句まで。経緯は delegation.md、本書、`_sessions/`、git
7. **時間の信号を渡す** [A]。贄川にはランチャが巡ごとに prompt 冒頭へ `時間: elapsed <秒>s / <秒>s` を出す(分母は鷹野が起動時に与える予算、無ければ行を出さない)。受け皿は `claude/niekawa.md` と `kimi/niekawa.md` の「時間の信号」で同じ形。資料は予算を実際に使いたい時間より少し上に置くことを勧める。ランチャ側は別便
8. **待ちは前景で。**`claude -p` は背景タスクの通知で起きない(上の実測)。贄川は `setsid nohup` で切り離して `sleep 280` の切片で待ち、真壁は `run_in_background` を使わない

## GPT-6 向けの書き方 ── 公式の指針が無いので、短く具体的に、書式を固定する

1. **短く具体的に書く。**何を・どこに・いつ終わるか。心構えは書かない
2. **完了条件と footer の書式を固定する。**ランチャと hook が読む行(`makabe_commit_sha:`、`変更ファイル数:`、`verdict:`、判定の一語)は変えない
3. **「確かめたこと / 確かめていないこと」の欄を報告に置く。**GPT-6 がもともと出しやすい情報の受け皿 [O]。真壁の出力契約にある
4. **Sol をゲートに置くときは、頭に P0 の定義と「直せば終わるものは P0 にしない、P2 として自分で直す」を置く** [H]
5. **深さの言葉を書かない。**effort は models.env の reasoning effort で決める。GPT-6 で測った根拠は無く、Claude の資料に揃えた方針

## 出典

- [A] Anthropic, Prompting Claude Opus 5.5 ── https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5 (2026-09-24 に参照)
- [O] OpenAI, Introducing GPT-6 Sol and Luna ── https://openai.com/index/introducing-gpt-6-sol-and-luna/ (2026-09-24 に参照。WebFetch は 403、ブラウザで読める)
- [H] 役員 人見のモデル観と裁定(2026-09-24、鷹野からの BRIEF 経由)
