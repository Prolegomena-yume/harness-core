# Codex 委譲プロトコル ── 実装の主経路

**コード本体の実装は Codex Bash 直叩きが主経路。**Claude 内サブエージェント(真壁 `makabe`)はフォールバック。この分離は好みではなく構造で、**実装者とレビュアーを別モデルに置く**ことで鷹野(PDM)の自書きを物理的に抑える。

| 層 | 経路 | 起動 |
|---|---|---|
| 調査・読み取り | Claude 内 Agent tool | `minase` / `Explore` |
| **実装 / テスト(主)** | **Codex Bash 直叩き** | `codex exec` / `codex exec resume <session_id>` |
| 実装 / テスト(フォールバック) | Claude 内サブエージェント | Agent tool `makabe` |
| レビュー | Claude 内サブエージェント | Agent tool `kashiwagi` |

## 起動の5点セットは一つでも欠かすと無言で失敗する

人見指示(2026-07-20)。**5点すべてを満たすまで起動しない。**

1. **`--dangerously-bypass-approvals-and-sandbox` を付ける**(`--sandbox danger-full-access` ではない)。sandbox 制限下では codex の書き込みが握り潰される
2. **`scripts/timer.sh` で監視する** ── codex は `run_in_background` で起動して出力をログファイルへ落とし、並行して `bash .claude/_core/scripts/timer.sh <265|600> <label> <ログpath>` を `run_in_background` で起動、その task を `TaskOutput`(`block=true`、timeout = duration×1000+60000)で待つ。duration は小タスク 265 / 大タスク 600。timer は「tokens used」で正常終端即解除、エラー行累計3で解除、30秒ごとハートビート
3. **仕様はファイルに落とす** ── `codex exec "$(cat spec.md)"`。インライン文字列はクォート崩れで無言死した実績がある
4. **`-c model_reasoning_effort="high"` を明示する** ── 既定は none で、大きめの仕様だと「読んだだけ」で exit 0 して終わる
5. **exit code 0 を成功と読まない** ── `git diff --stat` と要点の `grep` で実変更を検算してから commit する

**Why:** 前面同期実行は Claude が長時間ブロックされ、進捗も見えない。4 と 5 は「正常終了したが何もしていない」という失敗モードへの対策で、いずれも実害が出たあとに追加された。

## 差し戻しは同じセッションで続ける

- 修正 ── `codex exec resume <session_id> "<修正方針>"`(session_id は初回起動時に必ず記録する)
- 別案 ── `codex fork --last "<別案>"` で元を温存して分岐

## 起動前の6項目セルフチェック

1. 対象スコープ事前明示 ── ファイル / ディレクトリ範囲、変更概要、影響範囲を書き出す
2. **どの層で起動するか**を発話で明示宣言する(調査 / 実装主 / フォールバック / レビュー)
3. 層に応じたコンテキスト供与 ── Codex なら仕様ファイル、サブエージェントなら関連ファイルと整合性チェック観点
4. 完了後、鷹野(レビュアー)として独立視点で全体整合をチェックし、必要なら差し戻す
5. ドキュメント編集の例外を使うときも「ドキュメント編集として直接着手」と明示してから手を動かす
6. 「実装者 → レビュアー」の視点切替を発話で明示する

## 認証は local と cloud で排他運用する

Codex auth は local / cloud を同時に active にすると refresh token が競合する([openai/codex#15502](https://github.com/openai/codex/issues/15502))。**同時に使わない。**

cloud session への持ち込みは `CODEX_AUTH_JSON` を **1行 compact JSON** で投入する(複数行の raw JSON は保存時に無言で切られる)。手順は [consumer_setup.md](consumer_setup.md) §8。
