# H1 ── 真壁「commit まで届かず起こし直し」の実物、型に分けた表

便 `harness-makabe-commit`(庵野、2026-09-21)。09-20_04 の「真壁が commit まで届かず起こし直し 3 回(贄川の指示書の形、P2)」の実物を、既存の run_dir から事実だけ拾って型に分けた。

## 対象にした run

| 便 | run_dir | エンジン |
|---|---|---|
| musearch-yumemi-1(巡1) | `~/.codex-agents/runs/niekawa-20260920-220459-808462-32554` | kimi |
| yumemi-gen-5 | `~/.codex-agents/runs/niekawa-20260921-014445-1035634-7936` | kimi |

## 型の定義

| 型 | 何 |
|---|---|
| **途中終了** | 指示書は変えず、真壁が完了条件に届く前に(外部要因・turn 切れで)終わり、同じ指示のまま再起動した |
| **指示の差し替え** | 贄川が指示書の中身を書き換えて(要件・規則が変わった)、前の実行を SIGTERM または放棄して再起動した |
| **commit 禁止の継承** | `~/.codex/AGENTS.md` 等の commit 禁止規則が子プロセスへ継承され、真壁が commit そのものを拒否した(memory `project-kashiwagi-promotion-design` に前例、旧 spawn_agent 経路) |

## 表(便 × 回)

| 便 | 回 | 型 | 真壁の最終出力の末尾 | 木の状態 |
|---|---|---|---|---|
| musearch-yumemi-1 | a → a2 | **途中終了**(test PG 55466 が他 worktree の test に占有され migration で停止。a 自体は基線の commit `61bdeae` はあるが本題は未完) | a: `commit: 61bdeae1b6a0c1115f3b0fc4e9657b037e181486`(基線のみ)/ a2: `変更ファイル数: 32`、commit 行なし | a2 終了時点で未 commit の差分が worktree に残存 |
| musearch-yumemi-1 | a2 → a3 | **指示の差し替え**(a.md は 9 手の詳細指示、a3.md は「真壁 A(仕上げ)── build / test / 記録 / commit」に圧縮、既に分かっている基線値を渡して仕上げだけを頼む形に変更) | a3: `変更ファイル数: 4`、commit 行なし(diff-stat のみ) | a3 終了時点でも未 commit |
| musearch-yumemi-1 | a3 → a4 | **途中終了**(a3 と同じ指示 `makabe-a3.md` を再利用、fresh session で再実行) | a4: `commit: a48b4d1`(57 files changed, 5961 insertions, 795 deletions) | a4 で初めて commit に到達。1 回の commit に本題ぜんぶが乗っている(checkpoint 分割なし) |
| yumemi-gen-5 | a → b | **指示の差し替え**(裁定でルールの中核が変わり、贄川が真壁 A を SIGTERM。b.md 冒頭に「引き継ぎ: 前の実行は指示の差し替えのため中断した。worktree に未 commit の変更が残っている」と明記) | a: `変更ファイル数: 41`、commit 行なし / b: `commit: fa3ba6a6238afc5e1d01fe4c87b35350602f6173` | a 終了時点で 41 file 未 commit。b がその差分を読み直して仕上げ、1 commit にまとめて終端 |

## commit 禁止の継承 ── 探したが実物は見つからなかった

上記 6 回分の `.out` を `AGENTS.md` / 「commit 禁止」/ `cannot commit` 等で検索したが、真壁が commit を拒否した形跡は無い。真壁は現行の起動形(`codex exec` のトップレベル session、[../docs/delegation.md](../docs/delegation.md) 「真壁はトップレベル session」節)で動いており、memory の前例(spawn_agent の子として起こしていた旧経路)の欠陥は構造上もう踏まない。**この型はリスクとして残すが、実測では確認できなかった** ── 型として想定はするが、今回の修正の主眼(checkpoint commit + squash + commit sha 判定)は「途中終了」「指示の差し替え」の 2 型を対象にしている。

## 往復の正体

型の割合は「途中終了」2 回・「指示の差し替え」2 回(4 回、便 2 本)。**共通する実害は「未 commit の差分を次の実行が読み直すコスト」** ── a3・a・b はいずれも「前の実行の diff / git status を自分で読んでから続きをやる」導入が要る。commit がもっと細かく(段ごとに)打たれていれば、次の実行は `git log` から読めて `git status` の生差分を追わずに済む。これが今回の修正(段ごとの checkpoint commit + 完了時の squash + ランチャの `makabe_commit_sha:` 機械判定)の狙い。
