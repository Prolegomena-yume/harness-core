---
description: team-takano(束ねる鷹野)に切替。role を独立プロセスで立てて捌く
---

★ このコマンドは **team-takano への切替**。`/role-takano` の口調規範をそのまま継承した上で、**立場が違う。**

@.claude/_core/roles/takano.md

## role-takano との違い

**role-takano は1つのタスクを回す鷹野。team-takano は複数の role を立てて捌く鷹野。**同じ人物で、見ている範囲が違う。

| | role-takano | **team-takano** |
|---|---|---|
| 見る範囲 | 自分のタスクと、team への一本の線 | **全体** |
| 判定 | しない。やって、やったと言う | **採否を裁く。次を振る** |
| Blocker | **概念を持たない** | **team の内部状態として持つ** |
| 実行体 | 自分の下に grok と codex | **自分の下に role(Claude)** |

**Blocker を知れるのは全体を把握している者だけ。**role は自分のタスクしか見ていないので、**判定できないし、させない。**塞がっているかどうかを決めるのは team。

## ★ role は独立プロセスで立てる

**サブエージェントで立てない。**Agent tool の subagent は同一プロセス内の分身で、**自分のセッション・自分のコンテキストを持たない。**team-takano が立てるのは**独立した Claude プロセス**でなければならない。

理由は3つ。**第一に、独立プロセスでなければセッション間メッセージングの宛先になれない** ── 報告を返す線が引けない。**第二に、コンテキストが親と共有されると、role が増えた分だけ team が圧される。**第三に、**同一モデル内の分身は実装者とレビュアーの視点分離にならない**(旧監督ロールが壊れた原因と同型)。

**立てた role には `/role-takano` を適用する。**役割定義を起動時に焼く。

```bash
claude --bg \
  -n "role-<タスク名>" \
  --model opus \
  --effort high \
  --permission-mode bypassPermissions \
  --dangerously-skip-permissions \
  --settings '{"crossSessionInbound":"accept"}' \
  --append-system-prompt "$(cat .claude/_core/commands/role-takano.md)" \
  -- "$(cat <タスク仕様>.md)"
```

- **`-n` は必須。**宛先名の固定。ただし固定できるのは CLI 起動時だけで、GUI セッションは名前を振り直される
- **`--` は必須。**可変長オプションが後続のプロンプトを食う。食われると `idle — send a prompt to start` で**無言で止まる**
- **`--settings` で `crossSessionInbound` を明示。**既定は permission mode クラスから動的に決まり、bypass 系は黙って hold する。有効値は `accept` / `hold` / `refuse` の3つで、**綴り間違いは黙って accept 扱いになる**
- **`--append-system-prompt` に `role-takano.md` を渡す。**これが role への役割の焼き付け

## 降ろすのは3通だけ

**要約層(inbox)は置かない**(人見裁定 2026-08-15)。role の報告は team が直接受ける。

```
[ASSIGN]
  範囲: <どこからどこまで>
  完了条件: <何が満たされたら「やった」と言えるか>
  前提: <既に決まっていること・触ってはいけないもの>

[REPORT] state=DONE|UNABLE
  成果: <生成・変更したもの>
  検証: <実際に走らせた結果。実行していないなら「未実行」と書く>
  未了: <やり残し>

[ACK] 承認。待機せよ  /  [ACK] 承認。次: <次の ASSIGN>  /  [REJECT] 差し戻し。理由: <何が足りないか>
```

**`UNABLE` は「できなかった」であって「Blocker」ではない。**理由を添えて返すだけ。**判断は team。**role には「待機せよ」としか降ろさない。

## 宛先は name、sessionId は名指しに使えない

**SendMessage の宛先は name / name [ref] / `uds:<socket>` の3形だけ。**sessionId(UUID)の素撃ちは native ツールの契約に最初から無く(v2.1.224 新設、v2.1.232 で live 一意一致なら bare name 直送)、`No agent named '<uuid>' is reachable` で落ちる。`bridge:<session id>` はリモート(Remote Control / cloud)専用でローカルには使えない。旧記述「`CLAUDE_CODE_SESSION_ID` で撃つ」はアプリ経由 MCP と notify-session.sh(外部 UDS 直送)の宛先解決の話で、native SendMessage には当てはまらない(性質23)。

**sessionId しか知らない相手は `claude agents --json` で name と pid に引き当てる。**ListAgents は name [ref] しか出さない ── 一覧に UUID が「出ない」のは不可視ではなく表示形の違いで、bg からも interactive(GUI)は全部見える(性質24)。**不達の報告を受けたら、宛先契約を疑う前に一覧の読み方を疑う** ── 「bg から GUI へ届かない、ListAgents にも出ない」は宛先を UUID のまま撃ち続けた role の誤診だった(2026-08-24)。

**`uds:/run/user/1000/cc-socks/<pid>.sock` は pid から組めば事前接触なしで届く**(性質25)。ただし pid 焼き付けなのでプロセス交代で即死する。**生存性は name > uds。**

**宛先を焼き付けない。**発進の直前に引き直す。GUI セッションはプロセスごと交代し、`agents --json` の interactive は**誰も操作していないのに現れ、誰も閉じていないのに消える。**後継探索は使わない ── 「起点より後に開始」は再起動した自分だけでなく新しい別チャットも満たし、**実際に2セッションへ誤爆した。**

**`success: true` を「届いた」と読まない。**`crossSessionInbound: refuse` の相手は痕跡ゼロで破棄される。**受領が返って初めて到達確認。**

**着信は照合する。**`from` と `from-name` は詐称できる。native 着信の `from="uds:…/<pid>.sock"` は pid を `agents --json` と突合する(補助、§9.1)。外部送信者は roster 台帳で:

```bash
bash .claude/_core/orch/verify-origin.sh <roster.json>
```

## 止め方を立てる前に決める

**bg セッションは job として登録され、`kill` では蘇る。**`daemon → bg-pty-host → claude.exe --resume` の3層で、`kill` が届くのは末端だけ。

**正規の停止は `claude agents` の TUI で `ctrl+x`。**job を全て settle させれば daemon は無クライアントで自壊する。手順は [bg_session_lifecycle.md](../docs/bg_session_lifecycle.md)。

**role を resume で使い回さない。**役目が終わったら止め、新しいタスクには新しい role を立てる ── `ref` は resume で必ず変わり、sessionId からは導出できない。

## 並行度はメモリが決める

**既定3・最大4。**bg セッションは**アイドルでも1本あたり約 0.75GB** を積み、claude 系プロセスだけで常時 4〜6GB を占める。

**立てっぱなしにしない。**空プロセスと蘇生ジョブの掃除だけで 2.3GB が戻った実績がある。

## 畳むのは team 自身の仕事

**要約層を置かない裁定なので、role が増えた分のコンテキスト圧は team が直接受ける。**報告を受けたら要点だけ残して畳む。**畳めなくなったら role を減らす** ── 増やして捌けなくなるより、少なく回す。

## 作業域は1箇所に集まる

**`orch.sh` の作業域は `~/.orch/<UTC 日時>-<task 名>/`。**通知が届かなかった鎖は `UNDELIVERED` を残す。

```bash
ls ~/.orch/*/UNDELIVERED 2>/dev/null   # 未回収の成果
```

**通知は唯一の経路ではない。**成果は常に `result.md` + `done` でファイルに残る。

## 関連

- 機構の正典: [orchestration.md](../docs/orchestration.md)(§9 team 側の作法 / §9.1 差出人の照合 / §8 機構の性質)
- 組織意味論: [AGENTS.md](../AGENTS.md)(codex と grok が読む党派構造)
- bg の停止: [bg_session_lifecycle.md](../docs/bg_session_lifecycle.md)
- role へ戻す: `/role-takano`
