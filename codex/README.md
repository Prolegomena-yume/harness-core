# Codex 委譲人格

**柏木・贄川・真壁・水無瀬を人格付きの Codex 実行体として起動する定義。**主経路は 贄川[ORC]の段取り → 真壁[IM]の実装で、柏木[CM]はレビュー専任として贄川から 2 回呼ばれる(2026-09-18 改編、役員 人見。手順の正典は [../docs/delegation.md](../docs/delegation.md))。

**贄川の主経路は Kimi K3、水無瀬の主経路は Claude。**ここの `codex-niekawa` と `codex-minase` はそれぞれ枠切れ時の副経路。

## 人格一覧

4人格とも bypass で起動する。権限は常に開け、書く範囲は契約で決める(指示に「書くな」とあれば書かない)。

| 人格 | 役 | コマンド | 既定 model | 権限 | 起動定義 |
|---|---|---|---|---|---|
| 柏木律 | CM(レビュー・監査・助言) | `codex-kashiwagi` | `gpt-6-astra` | bypass。リポジトリ配下全般(P2 の赤入れ・Doc)。事後ガードは既定 off | [kashiwagi.md](kashiwagi.md) |
| 贄川迅 | ORC(段取り、副経路) | `codex-niekawa` | `gpt-5.6-sol` | bypass。リポジトリ配下全般。事後ガードは既定 off | [niekawa.md](niekawa.md) |
| 真壁陸 | IM(実装) | `codex-makabe` | `gpt-5.6-luna` | bypass。リポジトリ配下全般へ書き込み可 | [makabe.md](makabe.md) |
| 水無瀬澪 | PL(調査・設計、副経路) | `codex-minase` | (指定なし) | bypass。Markdown のみ。`docs/` / `_sessions/` は途中階層でも照合し、非 Markdown コードは不可 | [minase.md](minase.md) |

**model は persona 別の既定で決まる。**`--model` を手で足さない(足すと persona と model の対応が呼び出し側に散る)。

4人とも commit は `git-as <役>` で自分の名義・作業 branch にだけ。push、`main` 直接 commit、`.git/` の直接操作を禁止する。

## 柏木は巡ループを持たない、贄川が持つ

**柏木は `--no-loop` で 1 ゲート 1 session。**巡ループ(`verdict.md` を読んで次の巡を新 session で起こす形)は贄川の側にある ── 段取りが贄川へ移ったため(2026-09-18)。柏木の巡ループは `--rounds` を明示したときだけ立つ。

**真壁を起こすのは贄川で、`spawn_agent` を使わず `codex-makabe` を Bash / exec から叩く。**トップレベル session になるので `--resume` が効き、並列は worktree で切る。`.codex/agents/makabe.toml`(installer の `--consumer` が生成)は spawn_agent 経路のために残してある。

## 事後ガードの守備範囲

守備範囲の正典は [委譲プロトコル](../docs/delegation.md)。現 branch への commit は逸脱にしない。`main` の HEAD 移動・他 ref の移動・remote-tracking ref の移動・水無瀬の非 Markdown 書き込みだけを逸脱とする。柏木は既定 off。

## 定義の分離

人物像は `../roles/*.md` だけが持つ。`../agents/` は Claude Agent tool の起動定義(水無瀬・庵野の 2 人だけ)、`../kimi/` は Kimi の運用契約、本ディレクトリは Codex の運用契約で、同じ人物像を共有する。

委譲手順の正典は [../docs/delegation.md](../docs/delegation.md)。各起動定義へ人物像や手順をコピーしない。

## インストール

consumer のリポジトリルートで installer を実行する。`~/bin/codex-minase`、`~/bin/codex-makabe`、`~/bin/codex-kashiwagi`、`~/bin/codex-niekawa`、`~/bin/kimi-niekawa`、`~/bin/genai`、`~/bin/harness-route` が冪等に上書き配置される。

```bash
bash .claude/_core/setup/install-codex-agents.sh
```

wrapper は `CODEX_AGENT_CORE`、カレントリポジトリの `.claude/_core`、`$HOME/canonical/tech/.claude/_core` の順にランチャを解決する。

## MCP 無効化の実測

2026-08-12、`/tmp/codex-agents-measure.rkSH5o` 配下の捨てリポを `-C` に指定し、同じ最小タスクと `model_reasoning_effort="low"` で計測した。ユーザー設定を有効にした起動は 12.76秒、`node_repl` と `blender` を個別に `enabled=false` とした起動は 13.57秒。この1回では有意な速度差は出なかった。

`-c 'mcp_servers={}'` は構文上通るが既存設定へマージされ、`codex mcp list` では2 server とも enabled のまま残った。ランチャは `config.toml` の server 名を列挙し、各 server に `-c mcp_servers.<name>.enabled=false` を付ける。個別指定後は2 server が disabled になったことを `codex mcp list` で確認済み。MCP 無効を既定にする理由は速度ではなく、Windows パスに依存して落ちる `node_repl` と GUI 未起動時に落ちる `blender` を委譲の起動経路から外すためである。

## read-only sandbox の実測

2026-08-12、同じ捨てリポで `--sandbox read-only`、MCP 個別無効化、`model_reasoning_effort="low"` を指定し、ファイル作成を指示した。Codex は 8.75秒で起動し、patch を read-only sandbox が拒否したあと「読み取り専用のため、ファイルは作成できませんでした」と報告した。対象ファイルは存在せず、`git status --porcelain` も空だった。

判定は「起動する」「書き込みを拒否する」の両方を満たした。**ただし 2026-08-27 以降、母艦の `apparmor_restrict_unprivileged_userns=1` で read-only sandbox(bwrap)が起動せず空レビューを吐く問題があり、2026-09-13 の改編で柏木は bypass に移った。**この節は実測の記録として残す。
