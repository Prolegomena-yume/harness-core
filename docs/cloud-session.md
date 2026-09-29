# cloud セッションの起動と PR の出し方

**cloud セッション(CLAUDE_CODE_REMOTE=true)では、tech を 1 リポで起こし、musearch は起動処理が Forgejo から clone し、成果は Forgejo へ AGit で PR にする。**GitHub には push せず、PR も立てない(役員 人見 2026-09-30、設計の経緯は `company/tech` の `_drafts/claude-remote/`)。

## 起動処理は tech の SessionStart 1 本で、母艦では何もしない

tech の `.claude/settings.json` の SessionStart の最初の command が、`CLAUDE_CODE_REMOTE=true` のときだけ `git submodule update --init .claude/_core`(`_core` が無いと hook 自体が呼べないので、ここだけ consumer 側に書く)→ [../hooks/cloud-bootstrap.sh](../hooks/cloud-bootstrap.sh) を走らせ、そのあと `session-init.sh` を走らせる。**cloud-bootstrap.sh は標準出力を空に保ち、どの段が落ちても exit 0。**

- `git-as` と `cloud-pr` を PATH に置く(`/usr/local/bin`、書けなければ `~/.local/bin`)
- `~/canonical/tech` を clone への symlink にする ── tech の `autoMemoryDirectory` と commit guard の母艦の絶対パスを、設定を書き換えずに生かすため。clone の名前は起動経路で変わる(CLI は `repo`、GUI はリポ名)ので、`$CLAUDE_PROJECT_DIR` を指す
- `~/.claude/agents/{makabe,kashiwagi}.md` を [../cloud/agents/](../cloud/agents/) への symlink にする(母艦の `.claude/agents` からは見えない)
- musearch を `~/yumemism_repo/musearch` へ clone する。**母艦の置き場と同じパスにしたのは、BRIEF や docs の絶対パスと「tech の兄弟」という形をそのまま通すため。**clone は hook の中でする ── setup script には API credential が付かず、Forgejo の private が取れない

キャッシュされる setup script には何も置かない(スナップショットで古い中身が固まるため)。

## PR は tech と musearch で 2 本、topic は便名

**`cloud-pr <tech|musearch> <便名> -t <title> -d <本文>` を打つ。**中身は `git push <Forgejo の URL> HEAD:refs/for/main/<便名>` に title と description を付けたもの。branch は作られない。同じ便名で打ち直せば同じ PR が更新される(履歴を書き換えたら `-f`)。merge か close された便名は新しい PR になる。

- tech と musearch の両方に変更が出る便は、**同じ便名で 2 本**立て、各本文に相手の PR の URL を書く。束ねる仕組みは無いので、merge の順は BRIEF に書く
- commit は `git-as <役> commit`。作者が職能の顔になるのは、Forgejo が作者のメールで顔を決めるため(push した主体は `cloud-bridge`)
- 認証は cloud 環境の API credential で、URL にも引数にも資格情報を書かない。**書くと母艦の credential store に混ざる事故がある**
- musearch の作業木は `git -C ~/yumemism_repo/musearch worktree add ../musearch-<便> -b <便>`、cloud-pr は `-C` でその木を指す
- merge は主管が Forgejo の Web でする。cloud の鷹野は merge しない

## 真壁・柏木は cloud だけのサブエージェント

定義は [../cloud/agents/](../cloud/agents/)。**母艦では呼べない** ── tech の PreToolUse(matcher `Agent`)の [cloud-agent-guard.sh](../scripts/hooks/cloud-agent-guard.sh) が止める。柏木は 1 行目が `便: <id>` のときだけ通り、同じ便の 2 回目は止める(記録は VM の中で、VM が回収されると消える)。柏木は読み取り専用で、P2 も所見として返す(ゲート 2 の自己 commit は cloud では無い)。guard は字面の検査で、封じ込めではない。

test は `bash scripts/test-cloud-bootstrap.sh`(母艦で走り、母艦の SessionStart が前後で変わらないことも見る)。
