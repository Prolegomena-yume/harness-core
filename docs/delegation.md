# 委譲プロトコル ── 鷹野 → 贄川[ORC] → 真壁、柏木はゲート

**鷹野[PDM]は要件(BRIEF)を書き、贄川[ORC]が段取り・起動・巡のレビュー・差し戻しを持ち、真壁[IM]が実装し、柏木[CM]が 2 つのゲートで監査する。**鷹野の Claude 窓を人見との要件定義に使い、作業の往復を贄川 ↔ 真壁に閉じるための形(役員 人見 裁定 2026-09-18、裁定の正典は `company/tech/_sessions/2026-09-18_01.md`、調査は同 `_drafts/orchestration/13-org-change-0918.v0.md`)。

| 人格 | 実体 | model | 職務 | 起こし方 |
|---|---|---|---|---|
| 鷹野[PDM] | Claude(GUI) | Fable | 人見との要件定義、BRIEF 起草、終端の受領と独立検算、merge / push | ── |
| 水無瀬[PL] | Claude | `claude-opus-5` | 調査、設計案、影響範囲。鷹野直属 | Agent tool `subagent_type: minase` |
| 贄川[ORC] | Kimi K3 | `kimi-code/k3-256k` | 段取り(plan)、真壁の起動と差し戻し、巡ごとのレビュー、鷹野への納品 | `kimi-niekawa -f <BRIEF>`(枠切れは `codex-niekawa`、sol) |
| 柏木[CM] | Codex | `gpt-6-astra` | レビュー・監査・助言。ゲート 1(plan 後)とゲート 2(納品前) | 贄川が `codex-kashiwagi --no-loop` |
| 真壁[IM] | Codex | `gpt-5.6-luna` | 実装、テスト、実測 | 贄川が `codex-makabe` を Bash / exec から |
| 庵野[EXP] | Claude | `claude-sonnet-5` | 道具作り、Playwright、PoC、検証しながらの実装。鷹野直属 | Agent tool `subagent_type: anno` |
| 源内[WT] | Gemini 3.8 Flash (High) | `gemini-3.8-flash-high` | 納品物の日本語調整・リライト。commit しない | `genai <in.md> <out.md>`(枠切れは `--k3`) |

**序列は実装ラインだけに立つ ── 鷹野 > 柏木 > 贄川 > 真壁。**柏木は贄川から起こされるが立場は上で、**承認権は持たない**(納品先は鷹野)。**差し戻し権は贄川**(真壁を起こし直すのは贄川)。**水無瀬・庵野・源内は鷹野直属で横並び**、柏木のゲートを通らない ── 例外は Codex 逼迫時に庵野が真壁を代行する場合だけ。

判断(What)は人見、要件は鷹野、段取り(How)は贄川、手は真壁、目は柏木。**鷹野は段取りを書かず、巡ごとの中継もしない。**

## BRIEF ── 鷹野が書くのは「現在地」「どこまで」「失敗例」の3節

**BRIEF は手順を持たない。**手順・作業域の切り方・検収の手・成果物の形は贄川の plan に移る。長さは 30〜40 行が目安。

| 節 | 何を書くか |
|---|---|
| 親ゴール + 障害 | 1 行 + 箇条書き(`company/keiei` の書き方の規約) |
| 現在地 | 動いているもの(sha)、未完のもの、正典の所在、既に決まった裁定 |
| どこまで | 完了の定義(外から見える状態で番号付き)、しないこと、触らない領域 |
| 失敗例 | 過去に踏んだ穴、同型の作業で出た誤り |

## 1 便の流れ ── ゲートは 2 回、巡は贄川が回す

1. **鷹野が BRIEF を書く**(ファイル)
2. **贄川が plan を書く** ── 作業域(worktree / branch)、真壁ごとの担当、完了条件、検収の手、並列の割り付け。置き場は作業木でなく贄川の run_dir(`~/.codex-agents/runs/niekawa-<run_id>/plan.md`)── 同じ木で動く真壁に検収の手を見せないため
3. **柏木のゲート 1** ── 贄川が `codex-kashiwagi --no-loop -C <run_dir> -f <run_dir>/plan.md` で起こす。**所見は柏木の footer の `^run_dir:` の行から run_dir を取り、`<run_dir>/last-message.md` を読む。**反映してから次へ
4. **真壁が実装する** ── 贄川が `codex-makabe` を起こす。指示書は run_dir のファイル、渡すのはパス 1 行。中身は plan のうち真壁の分だけ
5. **贄川が巡ごとに検収する** ── `git diff` と実ファイル。P0 があれば `verdict: 継続` で真壁を起こし直す。P2 は自分で直して commit、P1 は記録
6. **柏木のゲート 2** ── 「どこまで」が埋まり、P0 が無く、P2 を直し終えたら `codex-kashiwagi --no-loop -C <作業木> -f <run_dir>/findings.md`。柏木が P0 を出したら 4 へ戻る。**ゲート 2 は便に 1 回。**直ったかは 5 で贄川が検算して 7 へ、柏木を呼び直さない(1 ゲート 1 回、役員 人見 2026-09-18 / 09-20 ── gen-3 巡 5 で gate2b を通したのは逸脱)
7. **鷹野へ納品** ── 贄川の `verdict: 承認`。鷹野が独立検算(diff、test、実測の再現)をして merge / push

**水無瀬の plan 赤入れは無い**(2026-09-18 に廃止、ゲート 1 が代替)。**柏木は真壁を起こさない**、巡も回さない。

## 起動コマンド

仕様はファイルで渡す。贄川と柏木は `-f`、真壁は贄川が書いた指示書のパス。

```bash
kimi-niekawa -f docs/BRIEF-15.md                 # 贄川が plan → ゲート1 → 真壁 → 巡レビュー → ゲート2 → verdict
kimi-niekawa --rounds 6 -f docs/BRIEF-15.md      # 巡数上限を変える(既定 12)。--no-loop で 1 session だけ
codex-niekawa -f docs/BRIEF-15.md                # kimi weekly < 30% のフォールバック(sol)
codex-kashiwagi --no-loop -C <run_dir> -f <run_dir>/plan.md "この plan を監査する"   # 贄川が呼ぶ
codex-makabe -f docs/spec.md "仕様どおりに実装する"   # 贄川を通さない小作業だけ
genai draft.md out.md                            # 源内。--k3 で Kimi フォールバック
harness-route                                    # 今日の配役表(read-only、起動しない)
```

作業ルートの既定はカレントの git toplevel。`-C <dir>` で明示できる。ランチャは Codex 本体へ必ず `-C` を渡す。MCP server は既定で無効(`--mcp` で有効)。**model は persona 別の既定で決まる** ── `--model` を手で足さない。

## 枠の規則 ── `rates` の週間残量で振り先を替える

**潤沢度は Claude > Codex > Kimi > Agy。**照会は `rates claude` / `rates codex` / `rates kimi` / `rates agy`(JSON、`remaining.weekly` が百分率)。**`null` は「不明」であって 0 でも 100 でもない** ── 切替しない。

| 条件(weekly) | 切替 |
|---|---|
| agy < 20% | 源内を K3 で動かす(`genai --k3`) |
| kimi < 30% | 贄川を Codex sol で動かす(`codex-niekawa`) |
| claude < 20% | Claude は鷹野の窓だけに絞る。庵野を使わず真壁へ。K3 は Fable の代替として温存し、段取りは sol |
| codex < 20% | 実装は庵野(この時だけ柏木のゲートを通す)。段取りは bg の Claude Code で水無瀬が持ち、鷹野とはメッセージで連絡 |

**閾値の判定はランチャに入れない。**起こされた後のランチャに選択肢は無く、ランチャが別のランチャを起こす形は自己参照の事故に近づく。代わりに 2 つ ── 鷹野が起動前に `harness-route` を 1 回打って配役表を見る(read-only、起動しない)、各ランチャは起動時に自サービスの `rates` を 1 回だけ叩いて `<run_dir>/rates.json` に残す(失敗は警告だけで続行)。

**Kimi の cached は枠を食わない**(09-18 実測、cached 914K で 5h の単位が動かない)。cold start が 1 単位で、5h ≈ 3.65M / 7d ≈ 18M uncached。段取り 1 便の消費は 0.3〜0.5M uncached の見込みで、**律速は 7d 窓**。

## 権限 ── 常に開ける、縛りは文で

**権限は常に開ける。書かせたくない巡は指示文に「書くな」と書く**(人見 2026-09-13)。Codex の人格は全部 `--dangerously-bypass-approvals-and-sandbox`、Kimi の贄川は `-p`(print モード、Bash は承認なしに走る)。

| 人格 | 書く範囲(契約) | commit | push |
|---|---|---|---|
| 水無瀬 | Markdown(docs / plan / spec) | 可(水無瀬名義) | 不可 |
| 贄川 | リポ全域。ただし**実装しない** ── 書くのは P2 の赤入れだけ | 可(贄川名義) | 不可 |
| 柏木 | リポ全域(P2 の赤入れ、Doc) | 可(柏木名義) | 不可 |
| 真壁 | 指示された worktree | 可(真壁名義、作業 branch) | 不可 |
| 庵野 | リポ全域 | 可(庵野名義、作業 branch) | 不可 |
| 源内 | **書かない**(整えた本文を返すだけ) | ── | ── |

**`main` / `master` への直接 commit と push は全員不可。**外へ出る境界は鷹野の merge と push で越える。事後ガードは真壁・水無瀬に既定 on(現 branch への commit は逸脱にしない ── `main` の HEAD 移動・他 ref の移動・remote-tracking ref の移動・水無瀬の非 Markdown 書き込みだけを逸脱とする)、柏木と贄川は既定 off(自分で木を動かすため)。

## 真壁はトップレベル session ── codex 組み込みの子にしない

**贄川は真壁を `codex-makabe` で起こす。**Kimi に codex 組み込みの子を起こす手段は無く、sol の贄川も形を揃えて使わない。真壁はトップレベルの codex session になるので、**外から `--resume <session_id>` が効く**(子の thread は外から resume できなかった、09-13 の制約が消えた)。

```bash
setsid nohup codex-makabe --log "$RUN/makabe-a.log" -C "$WT" -f "$RUN/makabe-a.md" \
  > "$RUN/makabe-a.out" 2>&1 < /dev/null &
```

**`setsid nohup` で切り離す** ── 素の `&` は不定に死ぬ。**出力は `--log` に流し、`tail` / `rg` で読む** ── `codex-makabe` の stdout は真壁の exec 出力ごと返るので、そのまま贄川の文脈に入れない。`.codex/agents/makabe.toml`(codex 組み込みの子として起こす旧経路)は残してある。

## 並列は worktree、担保は 2 つ

**並列してよい**(役員 人見 2026-09-18、09-13 の「2 本禁止」は解除)。ファイルの隔離は worktree ── **同じ木に真壁を 2 本入れない。**

1. **並列起動の前に 1 本だけ先に走らせる。**codex の access token は 10 日有効で、競合(openai/codex#10332)が起きる窓は「並列中に期限が切れて 2 本が同時に refresh する」時だけ。先に 1 本走らせて refresh を済ませてから残りを起こす
2. **同 persona の起動は 2 秒ずらす。**同秒起動で run_dir が衝突し `prompt.md` が上書きされる(09-13 の実測)

ランチャに分岐は入れない。担保は契約(本節)に焼く。

## 1 巡 = 1 session ── 贄川の文脈を巡ごとに捨てる

**贄川は 1 session で 1 巡だけを担う。**巡 = 真壁を起こす → 待つ → diff と実ファイルで検収 → `verdict.md` を書く。ランチャが `<run_dir>/verdict.md` の 1 行目を読み、`verdict: 継続` なら**新しい session** で次の巡を起こす(前巡までの `plan.md` / `findings.md` / 前巡の `verdict.md` をプロンプト末尾に写す)。`verdict: 承認` / `verdict: エスカレーション` で終端。verdict が無い・不正なら exit 4、巡数上限(既定 12)で exit 5。巡ごとの prompt / log / last-message / session_id は `<run_dir>/rounds/r<N>/` に残る。

**1 巡は 256K 以内**(役員 人見 2026-09-18)。BRIEF・plan・真壁の出力・柏木の所見を合わせた数で、超えそうなら検収を切り上げて次の巡へ送る。Kimi では `--agent-file` が `--session` / `--continue` と併用できないので、1 巡 = 1 session は構造で決まる。

**checkpoint が贄川の記憶のすべて。**判定に使った事実・P0 の一覧・充足表・自前修正の sha は `findings.md` に無ければ次の巡に届かない。**巡ごとに鷹野へ報告する**(余分な文脈を次の巡へ持ち越さない)。

| ファイル | 何を |
|---|---|
| `plan.md` | 作業域の切り方、手順、検収の手、成果物の形、並列の割り付け |
| `findings.md` | 真壁の commit sha、「どこまで」の充足(○ / × / 未)、P0 / P1 / P2 の一覧、自前修正の sha、走らせた検証と結果 |
| `verdict.md` | 1 行目が `verdict: 継続` / `verdict: 承認` / `verdict: エスカレーション`。エスカレーションは見出し 3 本固定 ── `## 問い`(矛盾の所在、選択肢、贄川の推奨)/ `## 現在地`(どこまで終わりどこで止まったか、sha、真壁の状態)/ `## 裁定別の次の一手` |

**エスカレーションで巡は必ず閉じる。裁定を session 内で待たない。**受信箱(`to-takano`)で鷹野を起こしてよいが、その session は `verdict.md` を書いて終わる。裁定は鷹野が `to-niekawa --kind 裁定` で便の箱(`<run_dir>/to-niekawa.tsv`)に書き、別巡として起こす。**鷹野は贄川の checkpoint(plan / findings / verdict)に書かない、箱に書く** ── checkpoint は贄川の記憶媒体で、他人が書いても差出人も位置も無く贄川には見えない(2b-2 の事故、2026-09-20)。理由:K3 の prefix cache は 14 分で消え、待ってから続けると全文が uncached で枠を食う(役員 人見 2026-09-20)。

## 待ちは 280 秒の切片(kimi の tool 上限 300 秒の内側)

**真壁と柏木を待つ Bash / exec は 280 秒で必ず返す。**

```bash
sleep 280; tail -n 5 "$RUN/makabe-a.out"; rg -n '^変更ファイル数:' "$RUN/makabe-a.out" || echo まだ
```

- 終端の印は `^変更ファイル数:` の行。`^session_id:` は巡ごとに出るので終端の印にしない
- **280 秒は固定(kimi -p の tool 上限が 300 秒、09-18 通し試験で実測)、契約の数字。**縮めない ── 短くしても真壁は速くならず、起きるたびに全文脈が再送される(柏木が 60 秒に縮めて 22 / 23 回 timeout、役員 人見 2026-09-16)。伸ばさない ── K3 の prefix cache は sliding(公称 5〜10 分 idle)で、切れると巡の途中で cold prefill を払う。**切片ごとの turn そのものが keepalive で、cached の turn は枠を食わない**
- pid で待たない ── 起動直後の pid は一時プロセスを掴む。`--resume` を打って `already has an active writer` で弾かれたら生きている
- 待ちの間に用の無い exec(`stat`、`date`、`ls`)をしない

## 判定は P0 / P1 / P2 の 3 値

| 札 | 何 | 誰がどうする |
|---|---|---|
| **P0** | 不可逆な欠陥 ── データの形(表・一意・FK・key)、入口の配線と検査の順序、所有と認可の穴、同時実行で不正な状態が残る競合、外から見える契約(URL・応答・cookie)、後の便に ALTER を強いる構造 | **差し戻し。**贄川が `verdict: 継続` で真壁を起こし直す。柏木は指摘して贄川へ返す |
| **P1** | 技術的負債 ── 後のリファクタリングで返せる前借り | 直さない。`findings.md` に記録し、**鷹野へのサマリに必ず残す**(後のリファクタリングで使う) |
| **P2** | 不整合・追従漏れ ── 表現・命名・import・注記・件数・文面の揺れ・Doc の未更新 | **自分で直して commit する**(贄川も柏木も)。指摘として書き残さない |

**贄川は「P0 が無く、P2 は直した」状態で柏木へ持っていく。**柏木は P0 の有無の確認、P2 の追加発見と修正、P1 の補足をする(役員 人見 2026-09-18)。**根本的に崩れていて修正がレビュアーの範囲を越えるものは、柏木が直さずに指摘して戻す。**

技術的負債は借金でありキャッシュで、必ずしも悪くない(人見 2026-09-12)。**判定の物差しは BRIEF の「どこまで」で、完璧ではない。****レビューは報告文でなく `git diff` と実ファイルから始める** ── exit 0 と完了報告は根拠にしない。空レビュー(exec 0 本のまま判定を書く)は exec ブロック数で検出する。

## 出力の上限は上位モデルにだけ効く、evidence は repo に置いてよい

**真壁(luna)の exec 出力が 10KB を超えるのは構わない。**luna は枠にほぼ計上されず、真壁の transcript は贄川に流れない。ダメなのは贄川(K3)と柏木(astra)がそれを読むこと ── 読むのは真壁の報告(2KB)、`results.md`、diff だけ。真壁 toml の「10KB 以内」は真壁自身の文脈を守る目安で、超えた件数を違反として数えない(役員 人見 2026-09-16)。

**検証の evidence(test の全出力、tail など)は repo の `docs/evidence/` に置いてよい。**誰も全文を読まず、必要な行を `rg` / `sed -n` で参照する運用なら量は問題にならない。要約 + パスへの圧縮は要らない。

## exec の作法 ── 出力を文脈に溜めない

exec / Bash の出力はそのまま文脈に載り、以後の全 turn で再送される。

- **`cat` でファイル全文を取らない。**`rg -n` / `sed -n 'a,bp'` / `head` / `tail` / `jq` で必要範囲だけ
- **1 回の tool 出力は 10KB 以内**(真壁を除く)。test・build・型検査は `> <run_dir>/evidence/<name>.txt 2>&1` へ流し、`tail -n 30` と `rg -n 'FAIL|error'` で読む
- `git diff` は `--stat` を先に、本文はファイル単位で `git diff -- <path>`
- 検証の結果は数字と該当行だけを checkpoint に写す。transcript は記憶媒体でない
- 真壁の worktree 外への誤書き込み(10d・10c で計 4 回)は毎巡 `git -C <基点> status --short` で確かめる

## 終端 ── 鷹野へ返るのは承認かエスカレーションの 2 種

**贄川から鷹野へ返るのは「承認(最終 sha 名指し)」と「エスカレーション(要件の矛盾・裁定が要る)」だけ。**柏木の「P0 無し」は終端ではない ── 柏木に承認権は無い。

本命はファイル(`~/.codex-agents/runs/<贄川の run>/verdict.md` は巡ごとに `rounds/r<N>/` へ退避、最終巡の `last-message.md` は run_dir 直下にも写す)とランチャの footer(`run_dir:` `巡数:` `verdict:` `session_ids:` `変更ファイル数:`)、通知は補助。**承認のサマリには P1 を必ず載せる。**鷹野は受領後に独立検算(diff、test、実測の再現)をしてから merge する。

**エスカレーションの受け方(鷹野)。**自分で裁けるもの(How ── 既裁定の適用、実装の選択、優先順位)はその場で裁定を書き、別巡を起こす。人見の裁定が要るもの(要件の矛盾、新しい要件、不可逆 ── データの形・外向きの契約・課金)は問いをチャットに出し、30 分の見張り(`from-niekawa --wait --cap 1800`)を張って待つ。**30 分で返答が無ければ「未裁定、便途中」で close session** ── summary に問いと再開の手を書く。人見が戻ったら新 session を summary から始める。理由:Claude の prompt cache は 60 分。30 分で見切れば close の turn まで cache 内に収まり、resume の uncached 再送を構造で作らない(役員 人見 2026-09-20)。

## commit ── author も committer も役、trailer 4 本

**commit の author と committer は役名(日本語)+ `<persona>@ai.yumemism.dev`。**`paxyuraranica` は人見本人の手の commit だけ。`git-as <役>` を使う(`--author` だけでは committer が残る)。リポの `git config user.*` は触らない。役は `minase` / `niekawa` / `kashiwagi` / `makabe` / `anno`(源内は commit しない)。

```
docs: 何をしたか(1 行目)

Role: 贄川[ORC]
Model: kimi-code/k3-256k
Session: <session id>
Brief: <BRIEF のパス>
```

`Co-Authored-By: Claude …` は書かない(人見 2026-09-13)。model は `Model:` の 1 本。

## Claude からの起動と待ち方

贄川を `run_in_background` で起動し、ランチャの出力に `^変更ファイル数:` の footer が出るまで待つ(`until grep -q "^変更ファイル数:" launcher.out`)。`^session_id:` は巡ごとに出るので終端の印にしない。巡の進みは `^巡 [0-9]+ session_id:` の行で見える。**footer の語は `kimi-niekawa` と `codex-agent.sh` で同じ** ── 待ち方を経路で変えないため。

```bash
kimi-niekawa --log <固定パス> -f <BRIEF> > launcher.out 2>&1 &
```

長時間の見張りは `timer.sh 1800` を bg で張り直す(ScheduleWakeup は使わない、人見 2026-09-17)。

## 起動の5点セット

1. bypass で起動する(ランチャが付ける)
2. 仕様をファイルへ落とし `-f` で渡す。**`kimi -p` の argv は 128KB で落ちる**(09-18 実測、exit 126)ので、100KB を超える prompt はファイル経由にする
3. reasoning effort はランチャの既定 ── 柏木(astra)・贄川・水無瀬は high、真壁(luna)は max(役員 人見 09-13)。`-c model_reasoning_effort=...` を手で足さない
4. exit code だけで成功とせず、footer・`git diff --stat`・実ファイルを検算する
5. 同じ persona を同じ秒に 2 本起動しない(run_dir は pid と乱数で一意化済みだが、ログの読み違いを避ける)

## 射程 ── harness は Claude だけが触る、鷹野直接は不可逆だけ

**codex / kimi の人格が触るのは consumer のプロダクト作業だけ。harness-core(本 submodule)と `~/.codex` `~/.claude` `~/.kimi-code` の設定は Claude 側が直す**(役員 人見 2026-09-13)。理由は 2 つ ── ランチャを直す便で走行中のランチャ自身が書き換えられ bash の逐次読みが壊れた(自己参照)、harness-core は 10 consumer が共有し codex の「正常終了したが何もしていない」失敗モードを全 consumer に効く場所で受けない。ハーネスの便は独立セッション(チップ)で切って回してよい。

**鷹野が自分の手で直接やるのは不可逆の作業だけ**(push、merge、`~/.codex` `~/.claude` `~/.kimi-code` の設定、削除)。細かい作業は庵野 / 水無瀬に振ってよい ── **振ったら必ず検収する**(diff と実ファイル、test の出力)(役員 人見 2026-09-18)。

## 旧形 ── orch.sh の逐次バトンと、柏木が段取りを持っていた期間

[orchestration.md](orchestration.md) の `orch.sh` / `run_turn.sh`(1 段 = 1 プロセスの逐次バトン)は旧形。**2026-09-13〜09-18 の「柏木[CM]が codex 組み込みの子として真壁を起こし、水無瀬に plan を赤入れさせ、巡を回す」形も旧形** ── 段取りは贄川へ移り、柏木はゲートに戻った。裁定 #60 の「ゲートはレビュアー所有」「P0 が残る限り承認しない」「鷹野は承認済み成果だけ受ける」は残る。

## 認証

Codex auth は local と cloud を同時に active にすると refresh token が競合する([openai/codex#15502](https://github.com/openai/codex/issues/15502))。並列の `codex exec` も同じ競合を踏む([openai/codex#10332](https://github.com/openai/codex/issues/10332))── 担保は上の「並列は worktree、担保は 2 つ」。cloud session への持ち込みは [consumer_setup.md](consumer_setup.md) §8。
