# Codex 委譲プロトコル ── 3人格の主経路

**水無瀬・真壁・柏木の3人は Codex 起動を主経路とし、Claude 内 Agent tool はフォールバックに限る。**調査・設計も水無瀬の Codex 起動を既定とする。実装者とレビュアーを別実行体へ分離し、Claude の5時間窓を実装で食い潰さないための構造。

| 層 | 主経路 | フォールバック |
|---|---|---|
| 調査・設計 | `codex-minase` | Agent tool `minase` / `Explore` |
| 実装・テスト | `codex-makabe` | Agent tool `makabe` |
| レビュー | `codex-kashiwagi` | Agent tool `kashiwagi` |

## 起動コマンド

3人格はシェルからタスク本文を渡して起動する。長い仕様は `-f` でファイルから渡し、複数ファイルも指定順に連結できる。

```bash
codex-minase "認証フローの設計案を比較して仕様へ落とす"
codex-makabe -f docs/spec.md "仕様どおりに実装して検証する"
codex-kashiwagi -f docs/spec.md "現在の差分を仕様と突合する"
```

作業ルートの既定はカレントの git toplevel、git 外ではカレントディレクトリ。明示する場合は `-C <dir>` を使う。ランチャは Codex 本体へ必ず `-C` を渡す。水無瀬・柏木は git 外での起動を拒否し、明示的な `--no-guard` がある場合だけ通す。真壁は git 外でも起動できるが、ガード無効の警告を表示する。

MCP server は速度のためではなく、Windows パスに依存して落ちる `node_repl` と GUI 未起動時に落ちる `blender` を委譲の起動経路から外すため既定で無効。実測では有効時と無効時に有意な速度差は出なかった。必要なタスクだけ `--mcp` でユーザー設定を有効のまま使う。

## 権限セット

権限セットは人格プロンプトで宣言し、実行後ガードで検出可能な逸脱を事後検出する。書き込みが必要な人格は sandbox フラグを緩めているため、ガード自体に操作を止める強制力はない。

| 人格 | 役 | Codex sandbox | 書き込み許可範囲 |
|---|---|---|---|
| 水無瀬 | Planner | `--dangerously-bypass-approvals-and-sandbox` | Markdown のみ。`docs/` / `_sessions/` は途中階層でも照合し、非 Markdown コードは許可しない |
| 真壁 | Implementer | `--dangerously-bypass-approvals-and-sandbox` | リポジトリ配下全般 |
| 柏木 | Reviewer | `--sandbox read-only` | なし |

事後ガードの守備範囲は、作業ルートの git リポジトリと直下サブモジュールの内部だけである。リポジトリ外への書き込み、非 git ルートでの真壁の実行、入れ子サブモジュールは検出できない。別リモート・別 ref への push にもローカル ref が動かない経路があり、完全には検出できない。したがって権限セットは人格プロンプトの宣言と事後ガードによるリポジトリ内逸脱の検出という二段であり、どちらも回避可能である。sandbox で書き込みを物理的に止めているのは柏木の read-only だけで、水無瀬・真壁の権限セットをガードが強制するものではない。

3人とも commit と push を行わない。git 操作は `status`、`diff`、`log` の読み取りに限る。

## 品質ゲートの鎖(裁定 #60、2026-08-24 人見)

**SPEC 起草 → 設計レビュー → 差し戻し → 承認 → 実装 → 実装レビュー → 差し戻し(実装者を exec resume)→ 再提出(同じレビュアーを exec resume)→ レビュアーの承認をもって opus へ返す。**この鎖を省いた委譲は品質ゲートとして不成立。

1. **設計レビューを省かない。**SPEC は実装へ渡す前に柏木の独立レビューを通し、差し戻し→承認を経る。根拠:D6-6 で潰れた P0 の過半は SPEC 側の誤り(節をまたいだ矛盾を3回)── 実装レビューだけでは SPEC の欠陥が実装の指摘に化けて出る分だけ発見が遅く高くつく
2. **ゲートの所有はレビュアー。**レビュー結果を出して抜ける形を取らない ── P0 が残る限り承認は出ず、修正の再提出は同じ柏木セッションへ `--resume` で戻して再検査する。**opus が受け取ってよいのは承認済みの成果だけ。**P0 未修正のままレビュー結果だけを受けて opus が巡ごとの差し戻しを裁く形は、ゲートを opus 側へ漏らす(D6-6 の欠陥、裁定の根拠)
3. **opus の役目は exec の運転と SPEC の改訂。**差し戻しは実装者の session を exec resume で叩く手を打つこと、レビューで割れた SPEC 側欠陥を正典に直すこと。レビューの中身の裁定はしない ── 発注書がレビュー指摘を translating する過程で正典を上書きする事故は D6-6 で実際に起きた

## 差し戻し

修正指示は初回の終了サマリに出た session ID を `--resume` へ渡し、同一セッションで続ける。直前セッションを温存して別案へ分岐する場合は、人が端末で `codex fork --last` を直接実行する。対話 TUI が必要なため、ランチャの機能にはしない。

```bash
codex-makabe --resume 019ff5ae-0000-7000-8000-000000000000 "柏木の指摘を反映する"
codex fork --last
```

## 事後ガード

ランチャはルートと直下のサブモジュールについて、起動前後の `git status --porcelain --ignored=matching` が挙げたパスの状態・内容ハッシュを比較する。さらに `git show-ref --head` の全 ref と HEAD reflog の先頭ハッシュ・行数の変化を検出し、人格の許可範囲を越えた操作を「権限逸脱」として列挙して exit 3 で終了する。違反ファイルは自動で revert せず、処置の判断を鷹野が持つ。意図的にガードを省く場合だけ `--no-guard` を使う。

終了時は session ID、ログ、変更ファイル数と `git diff --stat` を必ず表示する。これは起動の5点セット #5「exit 0 を成功と読まない」の機械化。

## Claude からの起動

Claude からはログパスを先に固定し、Codex と監視タイマーを別々の background task として起動する。

1. `--log <固定パス>` を付けた `codex-minase` / `codex-makabe` / `codex-kashiwagi` を `run_in_background` で起動
2. 並行して `bash .claude/_core/scripts/timer.sh <265|600> <label> <ログpath>` を `run_in_background` で起動
3. timer 側の task を `TaskOutput` の `block=true`、`timeout=duration×1000+60000` で待機
4. Codex 側の TaskOutput と終了サマリ、`git diff --stat`、実ファイルを検算

duration は小タスク 265、大タスク 600。timer は `tokens used` で正常終端を検知し、エラー行累計3または時間切れでも解除する。

## 起動の5点セット

5点すべてを満たしてから委譲を成功と判定する。

1. 人格に対応する sandbox フラグを付ける。水無瀬・真壁は bypass、柏木は実測済みの read-only
2. Claude から呼ぶ場合は `scripts/timer.sh` でログを監視する
3. 仕様をファイルへ落とし、ランチャの `-f` から渡す
4. `--effort high` を明示する。ランチャの既定値も high ── **`-c model_reasoning_effort=...` は通らない。**ランチャが受け取らない option を渡すと usage を出して即座に exit 0 で終わり、何も実行されないまま成功に見える
5. exit code だけで成功とせず、終了サマリ、`git diff --stat`、実ファイルを検算する

前面同期実行は Claude を長時間ブロックし、進捗も見えない。reasoning effort と実変更の検算は「正常終了したが何もしていない」という既発の失敗への対策。

## 起動前のセルフチェック

1. 対象ファイル、変更概要、影響範囲を事前に明示
2. 調査・設計、実装、レビューのどの人格を起動するか明示
3. 仕様ファイルと関連ファイルを委譲先へ供与
4. 完了後、鷹野が独立視点で全体整合を確認し、必要なら同一 session へ差し戻し
5. ドキュメント編集を直接行う場合も、例外使用を明示
6. 実装者からレビュアーへの視点切替を明示

## 認証

Codex auth は local と cloud を同時に active にすると refresh token が競合する([openai/codex#15502](https://github.com/openai/codex/issues/15502))。同時に使わない。

cloud session への持ち込みは `CODEX_AUTH_JSON` を1行 compact JSON で投入する。複数行の raw JSON は保存時に切られる。手順は [consumer_setup.md](consumer_setup.md) §8。
