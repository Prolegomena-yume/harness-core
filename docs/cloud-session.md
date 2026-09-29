# cloud セッションの起動と PR の出し方

**cloud セッション(CLAUDE_CODE_REMOTE=true)では、tech を 1 リポで起こし、musearch は起動処理が Forgejo から clone し、成果は Forgejo へ AGit で PR にする。**GitHub には push せず、PR も立てない(役員 人見 2026-09-30、設計の経緯は `company/tech` の `_drafts/claude-remote/`)。

## 起動処理は tech の SessionStart の最初の command で、母艦では何もしない

tech の `.claude/settings.json` の SessionStart の最初の command が、`CLAUDE_CODE_REMOTE=true` のときだけ `git submodule update --init .claude/_core`(`_core` が無いと hook 自体が呼べないので、ここだけ consumer 側に書く)→ [../hooks/cloud-bootstrap.sh](../hooks/cloud-bootstrap.sh) を走らせ、そのあと `session-init.sh` を走らせる(memory の索引を文脈に入れるのは別の 3 本の hook、下の節)。**cloud-bootstrap.sh は標準出力を空に保ち、どの段が落ちても exit 0。**

- `git-as` と `cloud-pr` を PATH に置く(`/usr/local/bin`、書けなければ `~/.local/bin`)
- `~/canonical/tech` を clone への symlink にする ── tech の `autoMemoryDirectory` と commit guard の母艦の絶対パスを、設定を書き換えずに生かすため。clone の名前は起動経路で変わる(CLI は `repo`、GUI はリポ名)ので、`$CLAUDE_PROJECT_DIR` を指す
- `~/.claude/agents/{makabe,kashiwagi}.md` を [../cloud/agents/](../cloud/agents/) への symlink にする(母艦の `.claude/agents` からは見えない)
- keiei を `~/canonical/keiei` へ浅く clone する(MEMORY.md を文脈に入れるため、下の節)。終わりに `bootstrap-done` の印を置く。memory の同期の起点を置いて 1 回走らせる(下の節)
- musearch を `~/yumemism_repo/musearch` へ clone する。**母艦の置き場と同じパスにしたのは、BRIEF や docs の絶対パスと「tech の兄弟」という形をそのまま通すため。**clone は hook の中でする ── setup script には API credential が付かず、Forgejo の private が取れない

キャッシュされる setup script には何も置かない(スナップショットで古い中身が固まるため)。

## PR は tech と musearch で 2 本、topic は便名

**`cloud-pr <tech|musearch> <便名> -t <title> -d <本文>` を打つ。**中身は `git push <Forgejo の URL> HEAD:refs/for/main/<便名>` に title と description を付けたもの。branch は作られない。同じ便名で打ち直せば同じ PR が更新される(履歴を書き換えたら `-f`)。merge か close された便名は新しい PR になる。

- tech と musearch の両方に変更が出る便は、**同じ便名で 2 本**立て、各本文に相手の PR の URL を書く。束ねる仕組みは無いので、merge の順は BRIEF に書く
- commit は `git-as <役> commit`。作者が職能の顔になるのは、Forgejo が作者のメールで顔を決めるため(push した主体は `cloud-bridge`)
- 認証は cloud 環境の API credential で、URL にも引数にも資格情報を書かない。**書くと母艦の credential store に混ざる事故がある**
- musearch の作業木は `git -C ~/yumemism_repo/musearch worktree add ../musearch-<便> -b <便>`、cloud-pr は `-C` でその木を指す
- merge は主管が Forgejo の Web でする。cloud の鷹野は merge しない

## memory は Forgejo の main で母艦と cloud を同じにする

**tech の Stop hook が [../hooks/memory-sync.sh](../hooks/memory-sync.sh) を走らせ、`.claude/memory/` の差分だけを Forgejo の main へ直接 push し、Forgejo 側の差分を手元へ取り込む**(役員 人見 2026-09-30)。母艦と cloud は同じ処理で、違いは取り先の URL と作業木のつなぎ方だけ。

- **memory 以外に触れない。**作業木の index・HEAD・他のファイルは触らず、一時 index と plumbing で「Forgejo の main の tree の memory だけを差し替えた commit」を作って push する。tech の main の保護は `unprotected_file_patterns: .claude/memory/**` があり、write 権限のある `cloud-bridge` でも memory だけの commit しか通らない(satellite/cloud-poc に同じ保護を張って実測: memory だけ○、memory と他の混在×、他だけ×)。session の branch の他の変更は載らない
- **母艦は追加条件つき。**作業木が `main` で、HEAD が今回の commit の祖先で、差分が memory だけのときだけ push し、HEAD と memory の index だけを進める。未 push の commit が有る・main 以外・HEAD が他の path で遅れているときは push せず次回に回す(作業木は壊さない)
- **遅くしない。**前景は「memory に新しいファイルが有るか・前回の fetch から 10 分たったか」を見るだけ(約 10 ms)。有れば worker を切り離す(母艦)。cloud は VM が消えるので前景で timeout 付き。同時に走るのは flock で 1 本、取れなければ黙って次回。index.lock で落ちたら次回
- **cloud は起動時にも同じ処理を 1 回走らせる**(cloud-bootstrap.sh)。cloud の clone は GitHub の写しで古いことがあるため、Forgejo の main の memory を先に取り込む。`refs/memory-sync/base` に「前回同期した commit」を持ち、これが 3 者比較の base になる

**衝突はファイル単位の 3 者比較(base / 手元 / Forgejo)で決める。**片側だけが変えたファイルはそのまま採り、両側が違う中身に変えたファイルだけが衝突。`MEMORY.md`(索引)は行の和集合(`git merge-file --union`)、それ以外の topic file は**同期を打った側の後勝ち**。負けた版は Forgejo の履歴に残り、commit message に衝突した path を書く。手元の memory が空なのに base に有るときは、消えたのではなく取り違えを疑って何もしない。

## cloud の最初の文脈には memory を 3 本の hook が入れる

**cloud では auto memory も CLAUDE.md の `@import` も SessionStart hook より先に解決され、symlink が張られる前なので載らない**(役員 人見の実測 2026-09-30)。setup script で symlink を張る手は採らない ── setup script はスナップショットにキャッシュされ、環境ごとに中身が固まる。代わりに tech の SessionStart が、cloud のときだけ [../hooks/cloud-memory-inject.sh](../hooks/cloud-memory-inject.sh) を 3 本の hook で呼び、tech と keiei の `MEMORY.md` を `additionalContext` に入れる。

**`additionalContext` は hook ごと・欄ごとに 10,000 字が上限で、超えると Claude Code が退避ファイルと先頭 2,000 字のプレビューに差し替える**(公式の hooks の仕様、上限は変えられない)。人見の実測(2026-09-30)では、tech(9,116 字)と keiei(2,351 字)と session-init(1,558 字)を 1 本の欄に足して 10,000 字を超え、keiei 分が文脈に見えなかった。そこで **1 本の hook の出力を 9,500 字以下に保つ**(`CTX_MAX_CHARS`、字数は UTF-16 の単位で数える)。

- **SessionStart の hook は 5 本。**(a) 今までの cloud 分岐(submodule 取得 → cloud-bootstrap.sh → session-init.sh。memory は足さない)、session-install.sh、(b1) `cloud-memory-inject.sh tech-1`、(b2) `tech-2`、(c) `keiei`。母艦では (b)(c) は `CLAUDE_CODE_REMOTE` を見て何も出さず exit 0(約 1 ms)
- **tech の索引は 1 本で 9,500 字を超えうる(増える)ので、行単位で前半・後半に割る。**割れ目は `## ` 見出しのうち前半と後半の長い方が最短になるもの。見出しで収まらなければ任意の行で割る。枠の半分に収まる小さな索引なら前半 1 本に全部入れて後半は空。割り方は決定的で、tech-1 と tech-2 は同じ入力から同じ割れ目を計算する(2026-09-30 の実物は 4,759 字 / 4,749 字)
- **3 本目が要る大きさ**(どちらかの hook の枠を超える)になったら、両方の頭に「索引が大きすぎる、整理が要る」を出し、枠に収まらない行は載せずに「N 行を載せていない」と書く。そのときは MEMORY.md を整理する(古い項目を畳む)
- **`cloud-memory-inject.sh` は待つ。**同じ matcher の hook は並列に走るので、(1) `_core` が現れるまで(submodule 取得は (a) の中)を settings の command が最長 60 秒(`# END` の行が読めるまで。書きかけを実行しない)、(2) cloud-bootstrap.sh の完了を最長 90 秒待つ。完了は bootstrap が終わりに置く `~/.cache/harness-cloud/bootstrap-done` の mtime が、この hook の起動時刻以降であることで読む(resume / compact で前回の印が残っていても素通りしない)。**keiei を自分で clone せず待つ方を採ったのは、bootstrap の clone と同じ dir に 2 本走ると半端な clone を読みうるため、また tech の索引を Forgejo の main の memory を取り込んだ後で読むためにも同じ印が使えるため。**待ちきれなければ「間に合わなかった」旨を 1 行添え、手元にあるものだけを出す(exit 0)
- 書き込み先は tech 側(`~/canonical/tech/.claude/memory`、clone への symlink 経由)。keiei の memory は cloud から書かない
- **cloud のセッションは自分の branch に `.claude/memory` を commit しない**(Stop の memory-sync が main に上げる。混ぜると PR に memory が入る)

## 真壁・柏木は cloud だけのサブエージェント

定義は [../cloud/agents/](../cloud/agents/)。**母艦では呼べない** ── tech の PreToolUse(matcher `Agent`)の [cloud-agent-guard.sh](../scripts/hooks/cloud-agent-guard.sh) が止める。柏木は 1 行目が `便: <id>` のときだけ通り、同じ便の 2 回目は止める(記録は VM の中で、VM が回収されると消える)。柏木は読み取り専用で、P2 も所見として返す(ゲート 2 の自己 commit は cloud では無い)。guard は字面の検査で、封じ込めではない。

test は `bash scripts/test-cloud-bootstrap.sh`(母艦の SessionStart が前後で変わらないこと、注入 3 本の字数が上限以下であること、`_core` と bootstrap の完了を待つことを見る)と `bash scripts/test-memory-sync.sh`。どちらも母艦で走る。
