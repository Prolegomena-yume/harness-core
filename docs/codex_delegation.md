# Codex 委譲プロトコル ── 鷹野 → 柏木[CM] → 真壁、水無瀬は Claude

**鷹野[PDM]は要件(BRIEF)を書き、柏木[CM]が段取り・起動・レビュー・赤入れを持ち、真壁[IM]が柏木の子として実装し、水無瀬[PL]は Claude 側で鷹野と柏木の両方から使う。**鷹野の Claude 窓を人見との要件定義に使い、作業の往復を柏木 ↔ 真壁に閉じるための形(役員 人見 裁定 2026-09-13、設計の意図は `company/tech` の `_drafts/orchestration/10-kashiwagi-promotion.v0.md`)。

| 人格 | 実体 | model | 職務 | 起こし方 |
|---|---|---|---|---|
| 鷹野[PDM] | Claude(GUI) | Fable | 人見との要件定義、BRIEF 起草、終端の受領と独立検算、merge / push | ── |
| 水無瀬[PL] | Claude | claude-opus-5 | 調査、設計案、plan の赤入れ、実装レビューの第二の目 | 鷹野からは Agent tool `minase`、柏木からは `claude-minase` |
| 柏木[CM] | Codex | gpt-6-astra | 段取り(plan)、真壁の起動と差し戻し、レビュー、赤入れ、Doc 品質、並列の合流 | `codex-kashiwagi -f <BRIEF>` |
| 真壁[IM] | Codex(柏木の子) | gpt-5.6-luna | 実装、テスト、実測 | 柏木が `spawn_agent(agent_type="makabe", fork_turns="none")` |

序列は鷹野 > 水無瀬 = 柏木 > 真壁。判断(What)は人見、要件は鷹野、段取り(How)は柏木、手は真壁。**鷹野は段取りを書かず、巡ごとの中継もしない。**受けるのは終端 2 種(承認 / エスカレーション)だけ。

## BRIEF ── 鷹野が書くのは「現在地」「どこまで」「失敗例」の3節

**BRIEF は手順を持たない。**手順・作業域の切り方・検収の手・成果物の形は柏木の plan に移る。長さは 30〜40 行が目安。

| 節 | 何を書くか |
|---|---|
| 親ゴール + 障害 | 1 行 + 箇条書き(`company/keiei` の書き方の規約) |
| 現在地 | 動いているもの(sha)、未完のもの、正典の所在、既に決まった裁定 |
| どこまで | 完了の定義(外から見える状態で番号付き)、しないこと、触らない領域 |
| 失敗例 | 過去に踏んだ穴、同型の作業で出た誤り |

**柏木は BRIEF を受けて plan を書き、水無瀬に赤入れさせてから真壁を起こす。**plan の赤入れは 1 巡で閉じる(差し戻しは無い)。軽インフラ級の突貫は plan の赤入れを省いてよい(人見 2026-08-31 の射程限定)。plan の置き場は作業木でなくランチャの run_dir(`~/.codex-agents/runs/<run_id>/plan.md`、ランチャが `CODEX_AGENT_RUN_DIR` とプロンプト末尾の「plan の置き場:」の行で渡す)── 同じ木で動く真壁に検収の手を見せないため。水無瀬の赤入れは `claude-minase -C <run_dir> -f <run_dir>/plan.md`。

## 起動コマンド

柏木は BRIEF をファイルで受ける。水無瀬は鷹野からは Agent tool、柏木のシェルからは `claude-minase`。真壁を人が直接起こすのは、柏木を通さない小作業だけ。

```bash
codex-kashiwagi -f docs/BRIEF-11.md            # 柏木が plan → 水無瀬 → 真壁 → レビュー → verdict。「継続」ならランチャが次の巡を新 session で起こす
codex-kashiwagi --rounds 6 -f docs/BRIEF-11.md # 巡数上限を変える(既定 12)。--no-loop で 1 session だけ
claude-minase -f plan.md "この plan を赤入れする"   # 柏木のシェルから(JSON の session_id で --resume)
codex-makabe -f docs/spec.md "仕様どおりに実装する"  # 柏木を通さない小作業だけ
```

作業ルートの既定はカレントの git toplevel。`-C <dir>` で明示できる。ランチャは Codex 本体へ必ず `-C` を渡す。MCP server は既定で無効(`--mcp` で有効)。

## 権限 ── 常に開ける、縛りは文で

**権限は常に開ける。書かせたくない巡は指示文に「書くな」と書く**(人見 2026-09-13)。3 人格とも `--dangerously-bypass-approvals-and-sandbox`。水無瀬の `claude -p` は Read / Glob / Grep / Edit / Write / git(status・diff・log・add・commit)を常に渡し、push は渡さない。

| 人格 | 書く範囲(契約) | commit | push |
|---|---|---|---|
| 水無瀬 | Markdown(docs / plan / spec) | 可(水無瀬名義) | 不可 |
| 柏木 | リポ全域(赤入れ、Doc) | 可(柏木名義) | 不可 |
| 真壁 | リポ全域 | 可(真壁名義、作業 branch) | 不可 |

**`main` / `master` への直接 commit と push は全員不可。**外へ出る境界は鷹野の merge と push で越える。事後ガードは真壁・水無瀬に既定 on(現 branch への commit は逸脱にしない ── `main` の HEAD 移動・他 ref の移動・remote-tracking ref の移動・水無瀬の非 Markdown 書き込みだけを逸脱とする)、柏木は既定 off(柏木自身が真壁を起こして木を動かす)。

## 真壁は柏木の子 ── codex 組み込みの `spawn_agent`

**柏木は真壁を `spawn_agent` で起こす。**consumer の `.codex/agents/makabe.toml`(installer の `--consumer` が生成)が真壁の人格・model・sandbox を持ち、`agent_type="makabe"` で参照する。`fork_turns="none"` で柏木の文脈を渡さない ── 測る物差しを被測定者に見せない。同じ理由で plan は run_dir に置き、真壁の message には plan のうち真壁の分(作業域・完了条件・手順の真壁担当分)だけを写す。差し戻しは `followup_task`、待ちは `wait_agent`(1 回 1 時間まで)、並列は真壁を複数 spawn して別 worktree で走らせる(同じ木に 2 本入れない)。

**子の thread は外から `codex exec resume` できない**(`resume the parent first`)。1 巡 = 1 session の形(下記)では次の巡の柏木は別 session なので、差し戻しは `followup_task` でなく新しい真壁を spawn する。柏木の session が途中で落ちたときだけ `--resume` を使う。

**待ちは `wait_agent(timeout_ms=1200000)`、固定。**柏木が 60 秒などに縮めるのは禁止(10g 巡 1 で 22 / 23 回 timeout、役員 人見 2026-09-16)。codex 0.153.4 の既定 timeout は 30 秒で(openai/codex#36379、未修正)、省略すると親が 30 秒ごとに起きて全文脈を再送する。ランチャは柏木に `-c features.multi_agent_v2.default_wait_timeout_ms=1200000` を渡し、`~/.codex/config.toml` にも同値を置く。

## 出力の上限は柏木にだけ効く、evidence は repo に置いてよい(役員 人見 2026-09-16)

**真壁(luna)の exec 出力が 10KB を超えるのは構わない。**luna は枠にほぼ計上されず、真壁の transcript は柏木に流れない。ダメなのは柏木(astra)がそれを読むこと ── 柏木が読むのは真壁の報告(2KB)、`results.md`、diff だけ。真壁 toml の「10KB 以内」は真壁自身の文脈を守る目安で、超えた件数を違反として数えない(10g の実測では真壁 21 / 16 件、柏木 6 / 4 件)。

**検証の evidence(test の全出力、tail など)は repo の `docs/evidence/` に置いてよい。**誰も全文を読まず、必要な行を `rg` / `sed -n` で参照する運用なら量は問題にならない(10g は 46 ファイル 13K 行)。要約 + パスへの圧縮は要らない。

## 1 巡 = 1 session ── 柏木の文脈を巡ごとに捨てる(役員 人見 2026-09-16)

**柏木は 1 session で 1 巡だけ担う。**巡 = 真壁を起こす → 待つ → diff と実ファイルで検収 → `verdict.md` を書く。ランチャが `<run_dir>/verdict.md` の 1 行目を読み、`verdict: 継続` なら**新しい session** で次の巡を起こす(前巡までの `plan.md` / `findings.md` / 前巡の `verdict.md` をプロンプト末尾に写す)。`verdict: 承認` / `verdict: エスカレーション` で終端。verdict が無い・不正なら exit 4、巡数上限(既定 12)で exit 5。巡ごとの prompt / log / last-message / session_id は `<run_dir>/rounds/r<N>/` に残る。

理由: astra は turn ごとに全文脈を再送して枠を減らす。09-13〜14 の 5 GOAL は柏木 1 本で 170〜383 turn、context 360〜560K、1 GOAL 40〜60pt。1 巡 25〜40 turn で session を切ると 1/4〜1/5 になる(B 表からの模擬)。真壁(luna)は枠にほぼ計上されない(sol の 1/20)ので、子を巡ごとに起こし直す費用は無い。auto compact は文脈が消えるので使わない。

**checkpoint が柏木の記憶のすべて。**判定に使った事実・P0 の一覧・充足表・自前修正の sha は `findings.md` に無ければ次の巡に届かない。柏木・真壁とも exec の出力を文脈に溜めない(`cat` 全文禁止、1 回 10KB 以内、build / test はファイルへ redirect して `tail` / `rg` で読む)。

**git identity は `git-as <役>` で焼く。**柏木と真壁は同じ環境変数を継ぐので、契約に `git-as makabe commit ...` を書く。ランチャは自分の人格の `GIT_AUTHOR_*` / `GIT_COMMITTER_*` を export する。

## レビュー ── 差し戻すのは critical だけ、非 critical は直す、巡数は決めない

**柏木の判定は「承認 / 条件付き承認 / 差し戻し」の 3 値、差し戻しは P0(critical)が 1 件でもあるときだけ**(人見 2026-09-12)。critical = 実装した後にリファクタリングで直せないもの ── データの形、入口の配線と検査の順序、所有と認可の穴、同時実行で不正な状態が残る競合、外から見える契約、後の便に ALTER を強いる構造。技術的負債は後で返せる前借りでありキャッシュで、必ずしも悪くない。

**非 critical は柏木が赤入れで直して commit する。**表現・命名・import・注記・件数・文面の揺れ・Doc の未更新は指摘として書かず、直す。直さないなら P2 として results に記録して次便へ。**判定の物差しは BRIEF の「どこまで」で、完璧ではない。**

**巡数の上限は置かない**(人見 2026-09-13)。柏木は内容を見てゲートの役目を果たす。回る理由(非 critical の差し戻し、直せないレビュアー、要件の欠陥の往復)を消してある。要件が曖昧・矛盾なら往復させず鷹野へ上げる。ランチャの `--rounds`(既定 12)は暴走止めで、当たったら鷹野が checkpoint を見て起こし直す。

**レビューは報告文でなく `git diff` と実ファイルから始める。**exit 0 と完了報告は根拠にしない。空レビュー(shell 0 本のまま判定を書く)は exec ブロック数で検出する。

## 終端 ── 鷹野へ返るのは承認かエスカレーションの 2 種

**柏木から鷹野へ返るのは「承認(最終 sha 名指し)」と「エスカレーション(要件の矛盾・裁定が要る)」だけ。**本命はファイル(`~/.codex-agents/runs/<柏木の run>/verdict.md` は巡ごとに `rounds/r<N>/` へ退避、最終巡の `last-message.md` は run_dir 直下にも写す)とランチャの footer(`巡数:` `verdict:` `session_ids:`)、通知は補助。鷹野は受領後に独立検算(diff、test、実測の再現)をしてから merge する。

## commit ── author も committer も役、trailer 4 本

**commit の author と committer は役名(日本語)+ `<persona>@ai.yumemism.dev`。**`paxyuraranica` は人見本人の手の commit だけ。`git-as <役>` を使う(`--author` だけでは committer が残る)。リポの `git config user.*` は触らない。

```
docs: 何をしたか(1 行目)

Role: 柏木[CM]
Model: gpt-6-astra
Session: <codex session id>
Brief: <BRIEF のパス>
```

`Co-Authored-By: Claude …` は書かない(人見 2026-09-13)。model は `Model:` の 1 本。

## Claude からの起動と待ち方

柏木を `run_in_background` で起動し、ランチャの出力に `^変更ファイル数:` の footer が出るまで待つ(`until grep -q "^変更ファイル数:" launcher.out`)。`^session_id:` は巡ごとに出るので終端の印にしない。巡の進みは `^巡 [0-9]+ session_id:` の行で見える。pid で待たない ── 起動直後の pid は一時プロセスを掴む。`--resume` を打って `already has an active writer` で弾かれたら生きている。

```bash
codex-kashiwagi --log <固定パス> -f <BRIEF> > launcher.out 2>&1 &
```

## 起動の5点セット

1. bypass で起動する(ランチャが付ける)
2. 仕様をファイルへ落とし `-f` で渡す
3. reasoning effort はランチャの既定 ── 柏木(astra)と水無瀬は high、真壁(luna)は max(役員 人見 09-13)。spawn_agent の真壁は `.codex/agents/makabe.toml` の `model_reasoning_effort = "max"`。`-c model_reasoning_effort=...` を手で足さない
4. exit code だけで成功とせず、footer・`git diff --stat`・実ファイルを検算する
5. 同じ persona を同じ秒に 2 本起動しない(run_dir は pid と乱数で一意化済みだが、ログの読み違いを避ける)

## 旧形 ── orch.sh の逐次バトンと鷹野の中継

[orchestration.md](orchestration.md) の `orch.sh` / `run_turn.sh`(1 段 = 1 プロセスの逐次バトン)と、柏木 read-only + 鷹野の中継配送(裁定 #60 の 08-26 / 08-27 精緻化)は**旧形**。2026-09-13 の改編で柏木が施工管理を持ち、ドライバは柏木の中に消えた。#60 の「ゲートはレビュアー所有」「P0 が残る限り承認しない」「鷹野は承認済み成果だけ受ける」は残る。

## 射程 ── codex はプロダクト作業だけ、harness は Claude だけが触る

**codex の 3 人格が触るのは consumer のプロダクト作業だけ。harness-core(本 submodule)と `~/.codex` `~/.claude` の設定は鷹野[PDM]が直接直し、手が要れば Claude の Agent tool(`makabe` / `kashiwagi`、claude-opus-5)を使う**(役員 人見 2026-09-13)。理由は 2 つ ── ランチャを直す便で走行中のランチャ自身が書き換えられ bash の逐次読みが壊れた(自己参照)、harness-core は 10 consumer が共有し codex の「正常終了したが何もしていない」失敗モードを全 consumer に効く場所で受けない。ハーネスの便は独立セッション(チップ)で切って回してよい。

## 認証

Codex auth は local と cloud を同時に active にすると refresh token が競合する([openai/codex#15502](https://github.com/openai/codex/issues/15502))。並列の `codex exec` も同じ競合を踏む([openai/codex#10332](https://github.com/openai/codex/issues/10332))── 真壁を組み込み子にする理由の 1 つ。cloud session への持ち込みは [consumer_setup.md](consumer_setup.md) §8。
