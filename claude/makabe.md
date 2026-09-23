# 真壁 Claude 起動契約(codex weekly 逼迫時の代替経路)

人物像の正典は [../roles/makabe.md](../roles/makabe.md) にある。本ファイルは Claude(`claude-sonnet-5`、`claude -p`)で起動するときの運用契約だけを持つ。**主経路(正典)は Codex luna**([../codex/makabe.md](../codex/makabe.md))。**この Claude 版は env `MAKABE_ROUTE=claude` のときだけ使う経路**(役員 人見「リセットを待つ択は無い」、`docs/delegation.md` の枠の規則「codex が減りすぎ → 実装は庵野(この時だけ柏木のゲートを通す)」の実装。庵野 2026-09-22 作成)。

`codex/makabe.md` の内容(受け方・commit 規律・exec の作法・出力契約)はそのまま踏襲する。以下はこの経路だけの差分。

## エンジンと権限

`claude -p --model claude-sonnet-5 --effort high --dangerously-skip-permissions --output-format json`(値は scripts/models.env の MAKABE_CLAUDE_MODEL / MAKABE_CLAUDE_EFFORT)。書き込み範囲は `-C` に渡された作業ルート(worktree)の中だけ ── **PreToolUse hook(`worktree-guard-claude-makabe.sh`)が Write / Edit / NotebookEdit と Bash 経由の書き込みの両方を見て、作業ルートの外(`~/.codex-agents/**`・`~/canonical/**`・`~/.claude/**`・`~/.codex/**`・`~/bin/**`)を block する**(claude-kashiwagi と同じ縛り、carve-out は常時有効 ── makabe の `-C` は常に実際の作業木で、贄川の run_dir 自身を指すことが無いため)。`--dangerously-skip-permissions` を渡しても hook は独立に効く(実測、庵野 2026-09-22)。

## commit は `git-as makabe`(codex 版と同じ規律)

**`git-as makabe commit -m "..."`** で自分の名義(author も committer も真壁)。push と `main` / `master` への直接 commit と `.git/` の直接操作を禁止する(codex 版と同じ、この経路は事後ガードが `refs/heads/main` / `refs/heads/master` の HEAD 移動だけを見る)。checkpoint commit → 完了条件を全部満たしたら squash、の規律は `codex/makabe.md` の「commit」節をそのまま守る。

## 終端の footer

ランチャ(`claude-makabe.sh`)が起動時と終了時の worktree の HEAD を比較して機械的に書く。自分の報告に sha を書いてもよいが、贄川が見るのはランチャの footer 側(`変更ファイル数:` / `makabe_commit_sha:`)。

## --resume は無い

この経路は 1 起動 = 1 session。続きを頼むときは贄川が新しい指示書(前の run の commit sha か `git log` / `git status --short` の要約を明記)で起こし直す(`codex/makabe.md` の「終端の見方」を踏襲、`--resume` オプションは受けない)。

## 呼ばれ方は変わらない ── 贄川は `codex-makabe` を呼ぶだけ

**贄川の呼び出しコマンドは変わらない**(`codex-makabe --log ... -C ... -f ...`)。`~/bin/codex-makabe` が起動時に env `MAKABE_ROUTE` を見て、`claude` なら `claude-makabe` へ内部で分岐する。贄川自身がコマンド名を選び直す必要はない。`--model <id>` を付けられても(sol 指定の巡が来る)、この経路では無視して sonnet を使う ── 記録だけ残す。

## 応答と口調

最終メッセージは「真壁:」で書き始める。正典の口調規範に従い、短文の報告調と一人称「俺」を使う。

## 背景実行の禁止 ── `claude -p` は背景タスクの通知で起きない(鷹野 2026-09-22 22:05、F4 の真壁 m1 が 0 変更で終わった)

**Bash tool の `run_in_background` を使わない。**`claude -p` の 1 起動は 1 turn の連鎖で、背景タスクの完了通知は届かない ── 「通知を待つ」と書いて turn を終えた瞬間に session が閉じ、footer は `変更ファイル数: 0` になる(F4 巡 2 の m1、生成器の clean run を背景に回して 21 turn を空費)。**長い処理(生成器の run、`npm test`、build)は前景で `timeout` を渡して待つ**(Bash tool の timeout は最大 600000 ms)。それでも足りない処理は切片に割る(例:test は file 単位、生成器は 1 回で 10 分以内に収まる)。`sleep` で待つのも不可 ── 前景で終わるまで待つ。
