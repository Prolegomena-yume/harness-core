# 委譲プロトコル ── 鷹野が真壁を直に起こし、柏木はゲート 1 回

**鷹野[PDM]が BRIEF を書いて真壁[IM]を起こし、真壁が実装し、終端で柏木[CM]がゲート 2 を 1 回だけ監査し、鷹野が検収して merge する。**段取りに専任の人格を置かない。一番足りない予算は壁時計で、贄川[ORC]が段取りを持っていた頃は段取りの代金が実装を上回っていた(F4 で $48.6 対 $24.8)。直書きの最初の 2 便は見積の 1/7〜1/5 で閉じた(役員 人見 2026-09-25 に始め、2026-10-17 に全便へ。形の正典は `company/tech/_drafts/plan/61-stage-baton-7.md`「直書きの形」)。**贄川[ORC]の経路は使わない。**

| 人格 | 実体 | model | 職務 | 起こし方 |
|---|---|---|---|---|
| 鷹野[PDM] | Claude(GUI) | Fable | 人見との要件定義、BRIEF 起草、真壁と柏木の起動、検収、merge / push | ── |
| 水無瀬[PL] | Claude | `claude-opus-5-5` | 調査、設計案、影響範囲。鷹野直属 | Agent tool `subagent_type: minase` |
| 柏木[CM] | **Claude opus(effort xhigh)= 実行経路 C、既定** / Codex `gpt-6.1-sol`(`KASHIWAGI_ROUTE=codex`、astra は既定から退役、役員 人見 2026-09-24) | レビュー・監査・助言。ゲート 2(便の終端)を便に 1 回。worktree の中だけ書ける(P2 の自己 commit) | 鷹野が `KASHIWAGI_ROUTE=opus claude-kashiwagi --no-loop -C <worktree> --gate 2 -f gate2-<便>.md` ── 役員 人見 2026-09-21 23:55(PoC:Opus 5 / 5、K3 2 / 5、`_sessions/2026-09-21_09`)。cloud セッションでは鷹野が Agent tool `subagent_type: kashiwagi`(1 便 1 回、読み取り専用、cloud 専用) |
| 真壁[IM] | **Claude sonnet(effort high)= 既定、ゲート 2 の P0 を直すラウンドは opus(high)** / Opus の上書き(`MAKABE_CLAUDE_MODEL=claude-opus-5-5`)/ Codex `gpt-6-luna`(`MAKABE_ROUTE=codex`、effort max)。既定にしたのは 役員 人見 2026-10-11、根拠は tech の `_drafts/bench/luna-max-vs-haiku-xhigh/results.md` | `claude-sonnet-5-5` | 実装、テスト、実測 | 鷹野が `claude-makabe -C <worktree> -f <BRIEF>` を bg で。どの model で起こすかは下の「真壁の model は便で選ぶ」。cloud セッションでは鷹野が Agent tool `subagent_type: makabe`(Sonnet 5.5、cloud 専用、[cloud-session.md](cloud-session.md)。役員 人見 2026-09-30) |
| 庵野[EXP] | Claude | `claude-sonnet-5-5` | 道具作り、Playwright、PoC、検証しながらの実装。鷹野直属 | Agent tool `subagent_type: anno` |
| 源内[WT] | Gemini 3.8 Flash (High) | `gemini-3.8-flash-high` | 納品物の日本語調整・リライト。commit しない | `genai <in.md> <out.md>`(K3 のフォールバックは使わない) |

model と effort の値は `scripts/models.env`、モデルの特性と配役の理由、プロンプトの書き方は [models.md](models.md)。

**序列は実装ラインだけに立つ ── 鷹野 > 柏木 > 真壁。**柏木は鷹野から起こされ、**承認権は持たない**(承認は鷹野の検収)。**差し戻し権は鷹野**(真壁を起こし直すのは鷹野)。**水無瀬・庵野・源内は鷹野直属で横並び**、柏木のゲートを通らない ── 例外は Codex 逼迫時に庵野が真壁を代行する場合だけ。

判断(What)は人見、要件と段取りは鷹野、手は真壁、目は柏木。**鷹野はラウンドごとの中継をしない** ── 手は起動、終端の受領、柏木の起動、検収、merge の 5 つだけ。

## BRIEF ── 「現在地」「どこまで」「失敗例」の 3 節と止め線

**BRIEF は段取りの専任がいない前提で書く。**真壁が BRIEF 1 本で作業域・完了条件・検収の手を読み取れること。長さは真壁の model で変える ── Sonnet には 1〜2 画面に刻み、api と画面を分ける(Sonnet は戻りが多かった、09-25)。Opus には刻まず、親の設計書と「どこまで」を渡して細かい設計を任せる(役員 人見 2026-10-12)。

| 節 | 何を書くか |
|---|---|
| 親ゴール + 障害 | 1 行 + 箇条書き(`company/keiei` の書き方の規約) |
| 便 | `便: <名>` の 1 行。柏木の依頼文の名(`gate2-<便>.md`)と記録が辿れるように |
| 現在地 | 動いているもの(sha)、未完のもの、正典の所在、既に決まった裁定 |
| どこまで | 完了の定義(外から見える状態で番号付き)、しないこと、触らない領域 |
| 失敗例 | 過去に踏んだ穴、同型の作業で出た誤り |
| 止め線 | 経過時間で書く。大きい便で 2 時間、面だけなら 1 時間が上限(実測:便 V 86 分、面だけ約 25 分。役員 人見 2026-10-13)。撮る page は 4〜6 枚に絞り、全 page の見た目は鷹野が撮る |

## 真壁の model は便で選ぶ

**既定は Sonnet 5.5(`claude-makabe` を上書きなしで)。前面(フロント)の便も Sonnet。**枠の規則で替えるほか、便の性格で選ぶ。**K3(`kimi-makabe`)は当面使わない**(役員 人見 2026-10-17)。

- **Opus 5.5** ── 設計を真壁に任せる便(`MAKABE_CLAUDE_MODEL=claude-opus-5-5 claude-makabe …`。models.env の既定は触らない。役員 人見 2026-10-12)
- **タイムアウトで止まった便の引き継ぎ** ── 書きかけを `git-as 真壁` で commit に残し、Opus の真壁に「読んで、合っていれば使い、違えば直す」の引き継ぎ BRIEF で渡す(10-13)
- **ゲート 2 の P0 を直すラウンド** ── `claude-makabe --p0`(opus high、値は models.env の `MAKABE_CLAUDE_P0_MODEL` / `_EFFORT`。役員 人見 2026-10-11)

## 1 便の流れ ── ゲートは 1 回、検収は鷹野

1. **鷹野が BRIEF を書く**(ファイル)。worktree は基点(多くは main)から鷹野が切る ── claude-makabe は main / master の上では起動しない
2. **真壁を bg で起こす** ── `claude-makabe -C <worktree> -f <BRIEF>`。**真壁の便どうしは並べて起こす**(壁時計が一番貴重、役員 人見 2026-10-17)。走っている間の訂正は `makabe-send`(下の「走っている真壁に訂正を送る」)
3. **終端を受ける** ── footer の `makabe_commit_sha:` で commit まで届いたかを見る。`(無し)` なら同じ BRIEF で起こし直す
4. **柏木のゲート 2** ── 依頼文 `gate2-<便>.md` を scratchpad に書き(run_dir の下に置かない)、`KASHIWAGI_ROUTE=opus claude-kashiwagi --no-loop -C <worktree> --gate 2 -f <scratchpad>/gate2-<便>.md`。依頼文の file を渡さないと「タスク本文が空白のみ」で起きない(10-12)。所見は柏木の footer の `^run_dir:` の行から run_dir を取り、`<run_dir>/last-message.md` を読む。所要は 7〜10 分
5. **P0 があれば真壁を新しい session で 1 回** ── `claude-makabe --p0 -C <worktree> -f <BRIEF-r2>`(所見のパスを BRIEF-r2 に書く)。**柏木は呼び直さない**(ゲートは便に 1 回、役員 人見 2026-09-18 / 09-20)。直ったかは鷹野の検収で閉じる
6. **鷹野が検収する** ── 報告文でなく `git diff` と実ファイル、test、Playwright。P1 は記録して後のリファクタリングへ、P2 は柏木が直している
7. **merge / push** ── 鷹野。worktree の片付けは「並列は worktree」の節の `wt-sweep`

**ゲートの「便に 1 回」はランチャが縛らない。**ランチャの `gates.tsv` の判定は `NIEKAWA_INBOX`(贄川の子として起こされたとき)が無いと働かず、直書きでは鷹野の規律だけが担保になる。**ゲート 1(plan の監査)は既定で置かない。**設計の要る便だけ、BRIEF の前に柏木へ設計を見せる(musearch 2d-1 の例)。

**品質ゲートの鎖(裁定 #60)のうち「ゲートはレビュアー所有」「P0 が残る限り承認しない」「鷹野は承認済み成果だけ受ける」は残る。**フロントだけの便にゲートは要らない ── api・検査・DDL に触れたら掛ける。

## cloud の直書き便 ── 鷹野が 1 セッションの中で真壁・柏木を Agent で起こす

**cloud セッション(`CLAUDE_CODE_REMOTE=true`)では、直書きの形を Claude のサブエージェント 2 人で再現する。**母艦の規則(Claude に真壁・柏木の Agent tool 版を置かない)は崩さず、cloud だけを例外にする(役員 人見 2026-09-30)。起動と PR は [cloud-session.md](cloud-session.md)。

- **起動:** 鷹野が `subagent_type: makabe`(Sonnet 5.5)に BRIEF と worktree のパスを渡す。worktree は鷹野が `git -C ~/yumemism_repo/musearch worktree add` で切る
- **終端:** ランチャが無いので、真壁は最終応答の末尾に footer(`persona:` / `verdict:` / `変更ファイル数:` / `makabe_commit_sha:`)を自分で書き、鷹野が `git -C <worktree> log` で独立に検証する
- **ゲートは便に 1 回:** 柏木(Opus、読み取り専用)をプロンプト 1 行目 `便: <id>` で呼ぶ。P2 も所見として返り、直すのは鷹野が起こす新しい真壁。P0 のときも柏木は呼び直さず、新しい真壁を所見のパス付きで 1 回
- **使用量上限:** サブエージェントも同じアカウントの weekly を食う。`rates` は cloud で動かない見込みなので、起こす前に鷹野が `/usage` を見る(cloud で使えるかは未測)
- **母艦に残る:** codex の経路、源内、DDL・deploy・DNS・印刷・Discord・メールなど母艦の secrets が要る作業

## 起動コマンド

仕様はファイルで渡す。真壁も柏木も `-f`。

```bash
claude-makabe -C <worktree> -f <BRIEF>                                   # 真壁(Sonnet、既定)
MAKABE_CLAUDE_MODEL=claude-opus-5-5 claude-makabe -C <worktree> -f <BRIEF> # 真壁(Opus に上書き)
claude-makabe --p0 -C <worktree> -f <BRIEF-r2>                           # ゲート 2 の P0 を直すラウンド(opus)
KASHIWAGI_ROUTE=opus claude-kashiwagi --no-loop -C <worktree> --gate 2 -f <scratchpad>/gate2-<便>.md   # 柏木のゲート 2
makabe-send <run_dir> "<本文>"                                            # 走っている真壁に訂正を送る
genai draft.md out.md                                                    # 源内。--k3 のフォールバックは使わない
harness-route                                                            # 今日の配役表(read-only、起動しない)
```

作業ルートの既定はカレントの git toplevel。`-C <dir>` で明示できる。MCP server は既定で無効(`--mcp` で有効)。**model は persona 別の既定で決まる** ── `--model` を手で足さない(claude-makabe の `--model` は記録だけで model は変わらない)。

**起動は Bash の `run_in_background` で。**シェルの `&` は不定に死ぬ。終わりは通知で受け、途中の進みは worktree の commit と `<run_dir>/stream.jsonl` で見る。待ちを `while pgrep -f` で書かない(自己一致する)。

## 枠の規則 ── `rates` の消費ペースで振り先を替える

**潤沢度は Claude > Codex > Kimi > Agy。**照会は `rates claude` / `rates codex` / `rates kimi` / `rates agy`(JSON)。見るのは `verdict.weekly` ── レートリミットの経過率(壁掛け時計、`elapsed`)に対して残量(`remaining`)が線形消費の期待より 10pt 以上少なければ「減りすぎ」、10pt 以上多ければ「残り気味」、差が `pace`(役員 人見 2026-09-21、残量 % の絶対閾値から置換)。**null は「無印(±10pt 以内)」か「不明(残量かリセット時刻が取れない)」で、どちらも切替しない** ── 0 でも 100 でもない。

| 条件(`verdict.weekly`) | 切替 |
|---|---|
| agy が減りすぎ | 源内を止める。日本語の調整は待たせる(K3 のフォールバックは使わない、役員 人見 2026-10-17) |
| claude が減りすぎ | Claude は鷹野のセッションと柏木だけに絞る。庵野を使わず真壁へ ── 真壁は codex 経路(`MAKABE_ROUTE=codex`、luna max)で起こす |
| codex が減りすぎ | 真壁の経路は替えない(既定の claude のまま、`MAKABE_ROUTE=codex` を渡さない) |

**Claude の weekly か Fable のどちらかが 3% 以下になったら、新しい便を起こさない。**走っている便の終端で記録して閉じる(役員 人見 2026-09-22)。

**閾値の判定はランチャに入れない。**起こされた後のランチャに選択肢は無く、ランチャが別のランチャを起こす形は自己参照の事故に近づく。代わりに 2 つ ── 鷹野が起動前に `harness-route` を 1 回打って配役表を見る(read-only、起動しない)、各ランチャは起動時に自サービスの `rates` を 1 回だけ叩いて `<run_dir>/rates.json` に残す(失敗は警告だけで続行)。

## 権限 ── 常に開ける、縛りは文で

**権限は常に開ける。書かせたくないラウンドは指示文に「書くな」と書く**(人見 2026-09-13)。Codex の人格は全部 `--dangerously-bypass-approvals-and-sandbox`、claude-makabe は `--dangerously-skip-permissions` で、worktree の外への書き込みは PreToolUse hook(`worktree-guard-claude-makabe.sh`)が止める。

| 人格 | 書く範囲(契約) | commit | push |
|---|---|---|---|
| 水無瀬 | Markdown(docs / plan / spec) | 可(水無瀬名義) | 不可 |
| 柏木 | worktree の中(P2 の赤入れ、Doc) | 可(柏木名義) | 不可 |
| 真壁 | 指示された worktree | 可(真壁名義、作業 branch) | 不可 |
| 庵野 | リポ全域 | 可(庵野名義、作業 branch) | 不可 |
| 源内 | **書かない**(整えた本文を返すだけ) | ── | ── |

**`main` / `master` への直接 commit と push は全員不可。**外へ出る境界は鷹野の merge と push で越える。事後ガードは真壁・水無瀬に既定 on(現 branch への commit は逸脱にしない ── `main` の HEAD 移動・他 ref の移動・remote-tracking ref の移動・水無瀬の非 Markdown 書き込みだけを逸脱とする)、柏木は既定 off(自分で worktree を動かすため)。

**同じリポの他 worktree が動かしている作業 branch は「他 ref の移動」に数えない。**`git worktree list` で他 worktree の branch を除外してから判定する(BRIEF-inbox-limits、2026-09-21 ── 並列真壁が別 worktree で自分の branch に commit すると、もう一方の真壁の事後ガードが「権限逸脱: ref 変化」と誤記録した事故の再発防止)。`main` / `master` / remote-tracking の移動は worktree 経由でも引き続き逸脱。

**claude-makabe・kimi-makabe の `main` / `master` の移動は reflog の名義で見分ける。**worktree は refs を共有し、別セッション(鷹野・人見)の `main` への commit・merge・pull でも値が動くため、run の間に積まれた reflog に真壁名義(launcher の `GIT_COMMITTER_EMAIL`)の更新があるときだけ逸脱にし、別名義だけなら警告で通す。reflog で見分けられなければ従来どおり逸脱。claude-makabe は `main` / `master` の上では起動しない(役員 人見 2026-10-03 の裁定 案 A+C、判定は `scripts/lib/git-run-diff.sh`)。**ゲートの間は main を動かさない** ── 柏木の終端が権限逸脱で落ちる(10-14)。

## 走っている真壁に訂正を送る

**bg で起こした claude-makabe には、走っている間に訂正を送れる。**`makabe-send <run_dir> "<本文>"`(`scripts/makabe-send.sh`、`~/bin` に symlink)が `<run_dir>/inbox.fifo` へ書き、駆動役 `scripts/lib/makabe-stream.py` が claude の標準入力(stream-json)へ中継する ── 止めて起こし直さない。走っていない run(result 済み)には書かずエラーで返り、送った本文は `<run_dir>/sent/` に時刻付きで残る。**宛先の run_dir は便名を見てフルパスで渡す** ── 「最新」で決め打ちすると並べた便の別の真壁に届く。本文は長ければファイル経由。`last.json`・`parse.env`・`last-message.md`・footer は従来どおり、全行は `<run_dir>/stream.jsonl`。run が `CODEX_AGENT_STATE_DIR` を替えて起こされているときは送る側にも同じ env を渡す。

## 真壁の終端は commit sha

**`.out` の footer の `makabe_commit_sha:` 行で「commit まで届いたか」を判定する。**`codex-agent.sh` / `claude-makabe.sh` が起動時と終了時の HEAD を比較して機械的に出し、モデルの報告文はパースしない。`(無し)` は起こし直し(指示は差し替えない)、届いていれば検収へ(役員 人見 2026-09-21、H1 ── 真壁は完了条件ごとに checkpoint commit を打ち、全部満たしたら 1 本へ squash する。詳細は [../codex/makabe.md](../codex/makabe.md))。claude 経路は `--resume` が無く、続きは新しい BRIEF(前 run の sha を明記)で起こし直す([../claude/makabe.md](../claude/makabe.md))。

## 並列は worktree、担保は 3 つ

**並列してよい**(役員 人見 2026-09-18、09-13 の「2 本禁止」は解除)。ファイルの隔離は worktree ── **同じ worktree に真壁を 2 本入れない。**

1. **同 persona の起動は 2 秒ずらす。**同秒起動で run_dir が衝突し `prompt.md` が上書きされる(09-13 の実測)
2. **検収の build は 1 つずつ、`systemd-run --user -p MemoryMax=…` で。**真壁が走る間に並べると OOM で desktop の scope ごと落ちる(10-14)。長い CI の置き場を tmpfs(scratchpad の /tmp)にしない
3. **codex 経路を並べる前に 1 本だけ先に走らせる。**codex の access token は 10 日有効で、競合(openai/codex#10332)が起きる時間窓は「並列中に期限が切れて 2 本が同時に refresh する」時だけ

ランチャに分岐は入れない。担保は契約(本節)に焼く。

**便の worktree の片付けは、鷹野が便を merge した後に `scripts/wt-sweep.sh --only <worktree> --apply` を手で呼ぶ。**溜まりは引数なしの dry-run(何も消さない)で見て、一覧を検収してから `--apply` する。消すのは「HEAD が main(または origin/main)に merge 済み」「`git status --porcelain` が空(submodule 込み)」「cwd・引数にその worktree を持つプロセスが無い」「`.git/worktrees/<name>/HEAD` が 12 時間より古い」を全部満たす worktree だけで、reflog と index の mtime は判定に使わない(全 worktree が同時刻に書き換わる / `git status` が書く)。リポ本体・locked・`*/.claude/worktrees/*`(Claude のアプリが持つ worktree)・`~/.codex` などは対象外。ランチャの終端には入れない ── ランチャの cwd が worktree の中にあり、自分を使用中と判定して必ず残すか、判定を緩めて走る真壁・柏木の worktree を巻き込むかになるため。

## 判定は P0 / P1 / P2 の 3 値

| 区分 | 何 | 誰がどうする |
|---|---|---|
| **P0** | 不可逆な欠陥 ── データの形(表・一意・FK・key)、入口の配線と検査の順序、所有と認可の脆弱性、同時実行で不正な状態が残る競合、外から見える契約(URL・応答・cookie)、後の便に ALTER を強いる構造 | **差し戻し。**柏木が指摘し、鷹野が真壁を `--p0` で新しい session に 1 回起こす |
| **P1** | 技術的負債 ── 後のリファクタリングで返せる前借り | 直さない。柏木の所見に記録し、**鷹野が便の記録(results.md か `_sessions`)に必ず残す**(後のリファクタリングで使う) |
| **P2** | 不整合・追従漏れ ── 表現・命名・import・注記・件数・文面の揺れ・Doc の未更新 | **柏木が自分で直して commit する**。指摘として書き残さない |

**根本的に崩れていて修正がレビュアーの範囲を越えるものは、柏木が直さずに指摘して戻す。**柏木の差し戻しは critical(P0)だけ(役員 人見 2026-09-18)。

技術的負債は借金でありキャッシュで、必ずしも悪くない(人見 2026-09-12)。**判定の物差しは BRIEF の「どこまで」で、完璧ではない。****レビューは報告文でなく `git diff` と実ファイルから始める** ── exit 0 と完了報告は根拠にしない。空レビュー(exec 0 本のまま判定を書く)は exec ブロック数で検出する。

## 出力の上限は上位モデルにだけ効く、evidence は repo に置いてよい

**真壁の exec 出力が 10KB を超えるのは構わない。**真壁の transcript は鷹野にも柏木にも流れない。ダメなのは柏木と鷹野がそれを読むこと ── 読むのは真壁の報告、`results.md`、diff だけ。真壁の「10KB 以内」は真壁自身の文脈を守る目安で、超えた件数を違反として数えない(役員 人見 2026-09-16)。

**検証の evidence(test の全出力、tail など)は repo の `docs/evidence/` に置いてよい。**誰も全文を読まず、必要な行を `rg` / `sed -n` で参照する運用なら量は問題にならない。要約 + パスへの圧縮は要らない。

## exec の作法 ── 出力を文脈に溜めない

exec / Bash の出力はそのまま文脈に載り、以後の全 turn で再送される。

- **`cat` でファイル全文を取らない。**`rg -n` / `sed -n 'a,bp'` / `head` / `tail` / `jq` で必要範囲だけ
- **1 回の tool 出力は 10KB 以内**(真壁を除く)。test・build・型検査は `> <run_dir>/evidence/<name>.txt 2>&1` へ流し、`tail -n 30` と `rg -n 'FAIL|error'` で読む
- `git diff` は `--stat` を先に、本文はファイル単位で `git diff -- <path>`
- 検証の結果は数字と該当行だけを記録に写す。transcript は記憶媒体でない
- 真壁の worktree 外への誤書き込み(10d・10c で計 4 回)は検収で `git -C <基点> status --short` を見る

## 終端 ── 真壁の footer と柏木の所見、承認は鷹野の検収

**真壁の終端は footer(`変更ファイル数:` / `makabe_commit_sha:`)、柏木の終端は所見(`<run_dir>/last-message.md`)。**どちらも承認ではない ── 柏木の「P0 無し」も終端ではなく、承認は鷹野の独立検証(diff、test、実測の再現)で決まる。**便の記録には P1 を必ず載せる。**

**裁定の要る問いに当たったら、真壁は止まって終端に書く。**鷹野は自分で裁けるもの(How ── 既裁定の適用、実装の選択、優先順位)はその場で裁き、BRIEF に書き足して新しい session で起こす。人見の裁定が要るもの(要件の矛盾、新しい要件、不可逆 ── データの形・外向きの契約・課金)は問いをチャットに出す。**30 分で返答が無ければ「未裁定、便途中」で close session** ── summary に問いと再開の手を書く。理由:Claude の prompt cache は 60 分。30 分で見切れば close の turn まで cache 内に収まる(役員 人見 2026-09-20)。裁定は BRIEF に commit する。

## DDL は鷹野専管 ── 便の results.md に「DDL」の項を必ず置き、当てるのは承認後に鷹野

**DDL(migration と schema の差分)は不可逆なので、staging / production に当てるのは鷹野だけ。**真壁は書くだけで当てない(local の test DB は除く)。便の `results.md` に `## DDL` の項を必ず置く ── 便が書いた migration の path、変える表・列・制約・索引の要旨、schema の全体像(musearch は `db/schema.sql`)への追随の有無。DDL の無い便も `## DDL` に「無し」の 1 行を書く。鷹野は検収で `git diff --stat <基点> -- <DDL の置き場>`(musearch は `db/`)と照らし、差分があるのに項が無い・項と差分が食い違うなら差し戻す(P0 ── データの形は不可逆)。承認後、鷹野がその項を起点に migration をレビューして当て、証跡を `docs/evidence/` に残す(役員 人見 2026-09-20)。

**Why:** schema と migration の二本立ては手の規律だけで揃っていた(musearch 2b-2 の差分は schema.sql に未追随)。項を必須にすると、抜けた便はその項が書けないので抜けが見える。置き場は musearch `db/migrations/README.md`。

## commit ── author も committer も役、trailer 4 本

**commit の author と committer は役名(日本語)+ `<persona>@ai.yumemism.dev`。**`paxyuraranica` は人見本人の手の commit だけ。`git-as <役>` を使う(`--author` だけでは committer が残る)。リポの `git config user.*` は触らない。役は `minase` / `kashiwagi` / `makabe` / `anno`(源内は commit しない)。

```
feat: 何をしたか(1 行目)

Role: 真壁[IM]
Model: claude-sonnet-5-5
Session: <session id>
Brief: <BRIEF のパス>
```

`Co-Authored-By: Claude …` は書かない(人見 2026-09-13)。model は `Model:` の 1 本。

## 起動の5点セット

1. bypass で起動する(ランチャが付ける)
2. 仕様をファイルへ落とし `-f` で渡す。**`kimi -p` の argv は 128KB で落ちる**(09-18 実測、exit 126)ので、100KB を超える prompt はファイル経由にする
3. reasoning effort はランチャの既定(値は `scripts/models.env`)。`-c model_reasoning_effort=...` を手で足さない
4. exit code だけで成功とせず、footer・`git diff --stat`・実ファイルを検証する
5. 同じ persona を同じ秒に 2 本起動しない(run_dir は pid と乱数で一意化済みだが、ログの読み違いを避ける)

## 射程 ── harness は Claude だけが触る、鷹野直接は不可逆だけ

**codex / kimi の人格が触るのは consumer のプロダクト作業だけ。harness-core(本 submodule)と `~/.codex` `~/.claude` `~/.kimi-code` の設定は Claude 側が直す**(役員 人見 2026-09-13)。理由は 2 つ ── ランチャを直す便で走行中のランチャ自身が書き換えられ bash の逐次読みが壊れた(自己参照)、harness-core は 10 consumer が共有し codex の「正常終了したが何もしていない」失敗モードを全 consumer に効く場所で受けない。ハーネスの便は独立セッション(チップ)で切って回してよい。

**鷹野が自分の手で直接やるのは不可逆の作業だけ**(push、merge、`~/.codex` `~/.claude` `~/.kimi-code` の設定、削除)。細かい作業は庵野 / 水無瀬に振ってよい ── **振ったら必ず検収する**(diff と実ファイル、test の出力)(役員 人見 2026-09-18)。

## 旧形 ── 贄川の段取り、orch.sh の逐次バトン、柏木が段取りを持っていた期間

**贄川[ORC]が plan・真壁の起動・ラウンドのレビュー・差し戻しを持つ形(2026-09-18〜)は旧形で、使わない(役員 人見 2026-10-17)。**`kimi-niekawa` / `claude-niekawa` / `codex-niekawa`、`from-niekawa` / `to-niekawa` の箱、kimi の Stop / PreToolUse hook はランチャとして残っているが起こさない。手順は git の履歴にある。[orchestration.md](orchestration.md) の `orch.sh` / `run_turn.sh`(1 段 = 1 プロセスの逐次バトン)と、2026-09-13〜09-18 の「柏木[CM]が真壁を起こしラウンドを回す」形も旧形。

## 認証

Codex auth は local と cloud を同時に active にすると refresh token が競合する([openai/codex#15502](https://github.com/openai/codex/issues/15502))。並列の `codex exec` も同じ競合を踏む([openai/codex#10332](https://github.com/openai/codex/issues/10332))── 担保は上の「並列は worktree、担保は 3 つ」。cloud session への持ち込みは [consumer_setup.md](consumer_setup.md) §8。
