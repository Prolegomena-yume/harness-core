# cloud セッションの起動と PR の出し方

**cloud セッション(CLAUDE_CODE_REMOTE=true)では、tech を 1 リポで起こし、musearch は起動処理が Forgejo から clone し、成果は Forgejo へ AGit で PR にする。**GitHub には push せず、PR も立てない(役員 人見 2026-09-30、設計の経緯は `company/tech` の `_drafts/claude-remote/`)。

## 起動処理は tech の SessionStart の最初の command で、母艦では何もしない

tech の `.claude/settings.json` の SessionStart の最初の command が、`CLAUDE_CODE_REMOTE=true` のときだけ `git submodule update --init .claude/_core`(`_core` が無いと hook 自体が呼べないので、ここだけ consumer 側に書く)→ [../hooks/cloud-bootstrap.sh](../hooks/cloud-bootstrap.sh) を走らせ、そのあと `session-init.sh` を走らせる(memory の索引を文脈に入れるのは別の 3 本の hook、下の節)。**cloud-bootstrap.sh は標準出力を空に保ち、どの段が落ちても exit 0。**

- `git-as` と `cloud-pr` を PATH に置く(`/usr/local/bin`、書けなければ `~/.local/bin`)
- `~/canonical/tech` を clone への symlink にする ── tech の `autoMemoryDirectory` と commit guard の母艦の絶対パスを、設定を書き換えずに生かすため。clone の名前は起動経路で変わる(CLI は `repo`、GUI はリポ名)ので、`$CLAUDE_PROJECT_DIR` を指す
- `~/.claude/agents/{makabe,kashiwagi}.md` を [../cloud/agents/](../cloud/agents/) への symlink にする(母艦の `.claude/agents` からは見えない)
- keiei を `~/canonical/keiei` へ浅く clone する(MEMORY.md を文脈に入れるため、下の節)。終わりに `bootstrap-done` の印を置く。memory の同期の起点を置いて 1 回走らせる(下の節)
- musearch を `~/yumemism_repo/musearch` へ clone する。**母艦の置き場と同じパスにしたのは、BRIEF や docs の絶対パスと「tech の兄弟」という形をそのまま通すため。**clone は hook の中でする ── setup script には API credential が付かず、Forgejo の private が取れない

- yumemi を `~/yumemism_repo/yumemi` へ Forgejo の `satellite/yumemi` から clone する(musearch の兄弟、生成器の在処)。`cloud-bridge` は yumemi に read。**GitHub の写し `canon-ical/yumemi` は手動 push で遅れることがあり(2026-09-30 に 0.11.6 で止まっていた)、使わない**
- **tech と musearch の作業木に Forgejo の remote `forgejo`(`https://git.yumemism.com/company/tech.git`、`business/musearch.git`)を足す(fetch はしない、冪等、push 先は変えない ── cloud-pr は URL を直に指す)。**cloud の tech の origin は GitHub の写しで、`discord/session-post` が git.yumemism.com の remote を見て #session の URL の repo path を決めるため、無いと `Prolegomena-yume/tech` に崩れる(2026-10-01 実機)
- **`CLAUDE_ENV_FILE` に `export TZ=Asia/Tokyo` を足す**(zoneinfo が無い VM では `JST-9`)。cloud の VM は TZ が UTC で、締めのサマリ名の日付が JST とずれる(JST 10-01 02:16 が `2026-09-30_08` になった)。**効くのは Claude の Bash tool の各コマンドだけで、hook と MCP には渡らない(公式)**が、日付を決めるのは close-session の Bash で、hook の `date` は epoch と `-u` だけ。母艦では `CLAUDE_CODE_REMOTE` が真のときしか走らないので何も変わらない
- 最後に、完了の印を置いてから [../cloud/setup.sh](../cloud/setup.sh) を走らせる(下の節)

## 道具と分類器の文脈は cloud/setup.sh が入れ、setup script にも同じ本文を貼る

**cloud の既定のイメージには gleam も Erlang も無い。[../cloud/setup.sh](../cloud/setup.sh) が gleam(版を固定、release の sha256 を照合)と Erlang(apt の `erlang-nox`、Ubuntu 24.04 で OTP 25)を入れ、`~/.claude/settings.json` の `autoMode.environment` に自社の source control と `ymos` を書く**(役員 人見 2026-09-30)。冪等で、揃っていれば数十 ms で抜ける。

- **入口は 2 つで中身は同じ。**cloud 環境の setup script に本文をそのまま貼る(スナップショットに道具が載り、次回から入れ直さない)。貼っていない環境・古いスナップショットの環境では、cloud-bootstrap.sh の最後が同じ本文を走らせる(apt が走ると数十秒。完了の印の後なので memory の注入は待たない)
- **setup script に置くのは clone の中身に依存しないものだけ。**道具と設定の文面は置く。clone の中身のコピーや symlink は置かない(スナップショットで古い中身が固まるため)。setup script はこのファイルを取りに行かない ── setup script には API credential が付かず Forgejo が読めない。本文を変えたら画面の setup script も貼り直す
- **分類器の文脈は `~/.claude/settings.json` にしか書けない。**auto mode の分類器は project の `.claude/settings.json` の `autoMode` を読まない(公式)。書くのは `$defaults` の後ろに、自社の source control(git.yumemism.com の全リポ、GitHub の Prolegomena-yume・canon-ical)、Hex の `yumemi` が自社のものであること、Forgejo へは AGit だけで押すこと。書く前は yumemi の clone が「信頼できない依存」で止まった。分類器は CLAUDE.md も読むので、tech の CLAUDE.md にも同じ旨を 1 行置く

## ymos は cloud/setup.sh が入れ、認証は API credential で agent proxy が VM の外で付ける

**cloud でも `ymos cal` / `ymos discord` / `ymos kb` ほか口を叩く動詞が使え、close-session の `discord/session-post` も `#session` に流れる。秘密は VM に入らない**(役員 人見 2026-10-01。設計は `company/tech` の `_drafts/claude-remote/02-ymos-cloud.v0.md`)。cloud 環境の API credential に service token を置き、agent proxy が `dispatch.yumemism.com` 行きの要求にだけ付ける。値は Claude にもコマンドにも環境変数にも出ない。

- **[../cloud/setup.sh](../cloud/setup.sh) の 4 段目が入れる。**`CLAUDE_CODE_REMOTE=true` のときだけ ── Forgejo の `satellite/yumemism-os` を `~/yumemism_repo/yumemism-os` へ浅く clone(あれば pull)、`cli/` を `npm ci && npm run build`、PATH 上の `ymos` に wrapper を置く(`/usr/local/bin`、書けなければ `~/.local/bin`)。wrapper は `YMOS_CREDENTIAL=proxy` を export して `cli/dist/index.js` を exec するだけで、CLI は認証ヘッダを一切付けない。母艦では何もしない。同じ rev のときは build を飛ばす(`.git/cloud-built-rev`)
- **入口は bootstrap 経由の 1 つ。**setup script には API credential が付かず Forgejo の private が clone できないので、setup script に本文を貼っても 4 段目は clone が落ちて飛ばされる(害は無い)。clone の中身をスナップショットに固めないので、それでよい。`cloud-bridge` は `satellite/yumemism-os` に read
- **Node の fetch は `HTTPS_PROXY` を読まず、proxy を通らないのでヘッダが付かず Access が 401 を返す(2026-10-01 実機、ymos はそれを `response.invalid` と読んだ)。**wrapper が `NODE_USE_ENV_PROXY=1` を立てて読ませ、出る `UNDICI-EHPA` の警告だけ `node --disable-warning=UNDICI-EHPA` で消す(`--no-warnings` にはしない、`NODE_OPTIONS` は触らない)。CA は既存の `NODE_EXTRA_CA_CERTS` で足り、`--use-system-ca` は要らない。wrapper は build の印に関わらず毎回書き直す
- **この CLI は `YMOS_CREDENTIAL=proxy` を解する版(便 ymos-cloud-1、`satellite/yumemism-os` の main)が要る。**main に入る前は wrapper を置いても CLI が `auth.json` を探して落ちる
- **`discord/discord-as` は `.discord-tokens/<役>` が無く `ymos` があるとき、`ymos discord <役> <動詞> ...` に委ねる**(`company/tech` の `discord.md`)。cloud の VM に bot の token は無い
- **cloud の VM は使い捨てで、`~/.config/harness/discord/session-posted.tsv`(二重防止)も VM ごとに空から始まる**

**人見の GUI の手順(cloud 環境の設定、1 回だけ)。**値は画面にも会話にも出さない。

1. 母艦で値をクリップボードへ写す: `DISPLAY=:0 xclip -selection clipboard < ~/.config/harness/claude-cloud-ymos.header-value.json`(母艦のデスクトップは X11。`wl-copy` は Wayland の口が無く落ちる)。貼ったら `printf '' | DISPLAY=:0 xclip -selection clipboard` で消す。ファイルは開かない・`cat` しない
2. cloud 環境の設定画面(tech を起こす環境)で「API credentials」に 1 本足す。**名前**: `ymos-dispatch`(何でもよい。git.yumemism.com 用の既存の 1 本とは別)。**Allowed websites**: `dispatch.yumemism.com`。**Custom headers**: 名前 `Authorization`、**Prefix は空**、値はクリップボードの中身をそのまま貼る(1 行の JSON `{"cf-access-client-id":…,"cf-access-client-secret":…}`)
3. 保存する。**保存後は編集できず、差し替えは削除して登録し直す**(公式)。値を替えるとき(token の Refresh・失効のあと)はこの手順を繰り返す。環境変数は足さない(`YMOS_CREDENTIAL=proxy` は wrapper が持つ)
4. 新しいセッションを起こし、cloud の端末で `ymos whoami` が `via: proxy` を返し、`ymos cal` が通ることを確かめる。`session-post` の実投稿はその後(本物の #session に流れる)

**Authorization は git.yumemism.com 用の credential とはホストが違うので重ならない。**同じホストに 2 本足すと片方しか送られない(公式)。

## PR は tech と musearch で 2 本、topic は便名

**`cloud-pr <tech|musearch> <便名> -t <title> -d <本文>` を打つ。**中身は `git push <Forgejo の URL> HEAD:refs/for/main/<便名>` に title と description を付けたもの。branch は作られない。同じ便名で打ち直せば同じ PR が更新される(履歴を書き換えたら `-f`)。merge か close された便名は新しい PR になる。

- tech と musearch の両方に変更が出る便は、**同じ便名で 2 本**立て、各本文に相手の PR の URL を書く。束ねる仕組みは無いので、merge の順は BRIEF に書く
- commit は `git-as <役> commit`。作者が職能の顔になるのは、Forgejo が作者のメールで顔を決めるため(push した主体は `cloud-bridge`)
- 認証は cloud 環境の API credential で、URL にも引数にも資格情報を書かない。**書くと母艦の credential store に混ざる事故がある**
- musearch の作業木は `git -C ~/yumemism_repo/musearch worktree add ../musearch-<便> -b <便>`、cloud-pr は `-C` でその木を指す
- merge は主管が Forgejo の Web でする。cloud の鷹野は merge しない

## memory は Forgejo の main で母艦と cloud を同じにする

**tech の Stop hook が [../hooks/memory-sync.sh](../hooks/memory-sync.sh) を走らせ、`.claude/memory/` の差分(cloud はそれに `_sessions/` のサマリ、次の節)だけを Forgejo の main へ直接 push し、Forgejo 側の差分を手元へ取り込む**(役員 人見 2026-09-30)。母艦と cloud は同じ処理で、違いは取り先の URL と作業木のつなぎ方だけ。

- **memory 以外に触れない。**作業木の index・HEAD・他のファイルは触らず、一時 index と plumbing で「Forgejo の main の tree の memory だけを差し替えた commit」を作って push する。tech の main の保護は `unprotected_file_patterns: .claude/memory/**` があり、write 権限のある `cloud-bridge` でも memory だけの commit しか通らない(satellite/cloud-poc に同じ保護を張って実測: memory だけ○、memory と他の混在×、他だけ×)。session の branch の他の変更は載らない
- **母艦は追加条件つき。**作業木が `main` で、HEAD が今回の commit の祖先で、差分が memory だけのときだけ push し、HEAD と memory の index だけを進める。未 push の commit が有る・main 以外・HEAD が他の path で遅れているときは push せず次回に回す(作業木は壊さない)
- **遅くしない。**前景は「memory に新しいファイルが有るか・前回の fetch から 10 分たったか」を見るだけ(約 10 ms)。有れば worker を切り離す(母艦)。cloud は VM が消えるので前景で timeout 付き。同時に走るのは flock で 1 本、取れなければ黙って次回。index.lock で落ちたら次回
- **cloud は起動時にも同じ処理を 1 回走らせる**(cloud-bootstrap.sh)。cloud の clone は GitHub の写しで古いことがあるため、Forgejo の main の memory を先に取り込む。`refs/memory-sync/base` に「前回同期した commit」を持ち、これが 3 者比較の base になる

**衝突はファイル単位の 3 者比較(base / 手元 / Forgejo)で決める。**片側だけが変えたファイルはそのまま採り、両側が違う中身に変えたファイルだけが衝突。`MEMORY.md`(索引)は行の和集合(`git merge-file --union`)、それ以外の topic file は**同期を打った側の後勝ち**。負けた版は Forgejo の履歴に残り、commit message に衝突した path を書く。手元の memory が空なのに base に有るときは、消えたのではなく取り違えを疑って何もしない。

## cloud の締めはサマリも Forgejo の main へ直接上げ、作業木を Anthropic の Stop 検査に通る形に揃える

**cloud の `_sessions/` のサマリは memory と同じ `memory-sync.sh` が Forgejo の tech の main へ直接 push し、PR にしない**(役員 人見 2026-10-01「A で」)。tech の main の `unprotected_file_patterns` は `.claude/memory/**;_sessions/**` で、`cloud-bridge` でサマリだけ・サマリ+memory は通り、サマリ+他の path は弾かれることを cloud-poc で実測済み(鷹野)。母艦の対象は今までどおり memory だけ(サマリは鷹野が push する)。

- **足すだけで、上書きしない。**手元に無いサマリの削除は流さない。同じ名前(連番 NN)を別の中身で並行セッションが先に上げていたら、Forgejo の版も手元の版も上書きせず、`~/.cache/harness-memory-sync/sync.log` に `conflict: _sessions/...` を残す(close-session は NN を決める前に Forgejo の main を見る)。混在の commit は作らない(対象の path しか載せない)
- **Anthropic の Stop の git 検査が何を見ているか(分かった範囲)。**VM の `~/.claude/stop-hook-git-check.sh` は Claude Code on the web が session ごとに入れる。本文は文書に無く、`anthropics/claude-code` の issue #86379・#86018・#96137・#96145 が引く形では、(a) `git diff` / `git diff --cached` が差分を持つか、ファイルが untracked なら「commit して push せよ」で exit 2、(b) `origin/<branch>`(無ければ `origin/HEAD`)より HEAD が進んでいる commit があれば「unpushed」で exit 2。**origin は GitHub の写しで、うちの push(Forgejo)を知らない**ので、サマリも memory も push 済みなのに毎回止まる。VM の実物は未読(issue の引用からの推測)
- **Stop の hook は並列に走る**(公式「All matching hooks run in parallel」)。うちの memory-sync と Anthropic の検査に順序は付かず、Stop で初めて push すると、その回の検査は push 前の作業木を見る。**なので close-session の中で `memory-sync.sh` を前景で先に走らせる**(commands/close-session.md)。memory だけを書いた普通の turn の Stop では 1 回止まりうる(push 済みになった次の Stop から通る)
- **push が通った後、`memory-sync.sh` の `realign_cloud` が作業木を揃え、origin が追いつくのを待つ。**手元の差分が全部「対象の path(`.claude/memory/**`・`_sessions/**`)で、中身が今回 Forgejo の main に載せたものと同じ」のときだけ、session の branch を Forgejo の main へ `reset --hard` する(branch 名は保つ)。**session の branch に本物の作業(対象外の path の変更・untracked・push していない commit)が 1 本でも残っていれば何もせず、警告も残す**(本物の未保存を隠さない)。submodule `.claude/_core` の指す commit が HEAD と main で違うときも揃えない。起動時の取り込み(cloud-bootstrap、`MEMSYNC_NO_REALIGN=1`)と、差分も push も無い Stop では動かさない
- **origin の追跡 ref は書き換えない**(鷹野の裁定 2026-10-01、検査が見る「origin にあるか」を偽にしないため)。GitHub の写し(`Prolegomena-yume/tech`)は Forgejo の push mirror(sync_on_commit)で、Forgejo の main に push すれば数秒で GitHub の main も同じ commit になる。揃えた後に `git fetch origin` を 2 秒おきに最長 20 秒(`MEMSYNC_ORIGIN_WAIT` / `MEMSYNC_ORIGIN_INTERVAL`)繰り返し、origin の追跡先(`origin/<branch>`、無ければ `origin/HEAD`、それも無ければ `origin/main`)が HEAD を含んだら終える。**間に合わなければ何もせず `sync.log` に `did not reach HEAD` を残す**(その回の検査は警告が出てよい。次に worker が走る Stop で、HEAD が Forgejo の main のままなら同じ待ちをもう一度する)。**`origin/<branch>` が GitHub に在って HEAD を含まないとき(古い commit を指す)は、書き換えず待たず `sync.log` に残す**(扱いは実物を見てから裁く)
- **母艦は pull するまで memory も上げない。**cloud が上げたサマリが main に入ると、HEAD..main に memory 以外の path が入り、母艦の既存の条件(差分が memory だけ)で止まる。鷹野の「セッション開始時 pull」で解ける

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

test は `bash scripts/test-cloud-bootstrap.sh`(母艦の SessionStart が前後で変わらないこと、注入 3 本の字数が上限以下であること、`_core` と bootstrap の完了を待つことを見る。ymos は sandbox の bare repo と偽の npm で、clone・build・wrapper・冪等・母艦で何もしないことを見る)と `bash scripts/test-memory-sync.sh`。どちらも母艦で走る。
