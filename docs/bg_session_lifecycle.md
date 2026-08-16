# bg セッションの終わらせ方 ── job 登録と respawn、kill が効かない理由

実測・起票: 鷹野[PDM] / 2026-08-16
実測環境: claude 2.1.233、Linux、daemon origin=transient
対象: 2026-08-15 の socket 調査で立てた使い捨て3本(`probe-sender-codex-0816a` / `probe-sink-codex-0816a` / `probe-refuse-codex-0816a`)

## 結論(先に)

**`claude agents` の TUI で対象を選んで `ctrl+x`。これだけが止まる手順。**
`kill -TERM` も `kill -9` も効かない ── 落とせるのは監視されている末端だけで、
監視している側が起こし直す。state.json を手で書き換えても、デーモンが書き戻す。

## 1. bg セッションは job として登録され、デーモンに監視される

**`claude --bg` は単発のプロセスを起こすのではなく、job を登録する。**
job 定義は `~/.claude/jobs/<jobId>/state.json`(+ `timeline.jsonl`)に落ち、
実体は3層のプロセスになる。

```
claude.exe daemon run --json-path ~/.claude/daemon.json   ← 監視役(supervisor)
 └ claude bg-pty-host --bg-pty-host <sock> 200 50 --      ← pty を張る中間層
    └ claude.exe --resume ~/.claude/projects/-tmp/<sessionId>.jsonl  ← 本体
```

**正典はデーモンのメモリ側で、`state.json` はその写し。**
デーモンは制御ソケットを `/tmp/cc-daemon-1000/<hash>/control.sock` に張り、
`state=running` の job を持ち続ける。

**デーモンは transient で、自分の仕事が無くなると自壊する。**
`~/.claude/daemon.log` に挙動が全部出る。

- `bg spawned <id> (shell)` / `bg claimed-spare <id> (shell)` ── job 起動(spare プールから即時払い出し)
- `bg adopt: adopted=N respawned=N dead=N` ── デーモン再起動時に生存 worker を引き取る
- `bg settled <id> (killed|done|stopped)` ── job が終端に落ちた
- `idle 5s with no clients — exiting` ── live worker 0 かつ client 0 で自壊

つまり **job を全部 settle させればデーモンは勝手に消える。**デーモンを狙って落とす必要はない。

## 2. kill だけでは止まらない ── 根拠

**kill が届くのは最下層の `claude.exe --resume` だけで、その上の2層が生きている。**
`bg-pty-host` の親であるデーモンが、落ちた worker を起こし直す。
2026-08-15 の実測では pid が **77507系 → 158767系 → 219983系と3世代蘇生**した。

**`state.json` を手で書き換えても戻される。**
`state` を `completed` にし `respawnFlags` を消して同時に kill しても、
デーモンが `running` へ書き戻した。ファイルは写しなので、写しを直しても意味がない。

**デーモンごと落とす手は有効だが、他の bg job を道連れにする。**
デーモンは全 bg job の共通の親で、job 単位では分かれていない。
今回はデーモン配下が probe 3本 + 遊休 spare 1本だけだと事前に確認できたので使えたはずだが、
TUI で正規に止めたところデーモンは自壊したので、そもそも要らなかった。

**対話セッションはデーモン配下ではない。**
デスクトップアプリから開いた対話セッションは `claude-desktop` の直子で、
bg のデーモンとは無関係 ── デーモンを落としても巻き込まれない。逆も同じ。

## 3. 正しい停止手順

```bash
claude agents
```

1. **引数なしで TTY 上に起動する。**`claude agents --json` は一覧専用で、停止オプションを持たない
2. **↑ で入力欄からリストへフォーカスを移す。**最初の ↑ は最下段(Completed の末尾)に入るので、
   そこから Working セクションまで ↑ で上げる
3. **フッタで選択対象を必ず確認してから押す。**表示が3種類あり、`ctrl+x` の意味が変わる

   | フッタ表示 | 選択しているもの | `ctrl+x` |
   |---|---|---|
   | `enter to open · space to reply · ctrl+x to delete` | 稼働中の1本 | **stop**(`?` を開くと `ctrl+x to stop` と出る) |
   | `enter to resume · space to reply · ctrl+x to delete` | 終了済みの1本 | delete(job 定義を消す) |
   | `enter to collapse · ctrl+x to delete all` | **セクション見出し**(`Working` / `Completed`) | **delete all ── 押すな** |

4. `ctrl+x` で1本ずつ止める。ヘッダの `N working` が `0 working` になるまで繰り返す
5. `esc` で抜ける。live worker が 0 なら約5秒でデーモンが自壊し、`/tmp/cc-daemon-1000/<hash>/` ごと消える

**見出しに乗ったまま `ctrl+x` を押すと全消しになる。**↑ の押しすぎで見出しに乗るのは普通に起きるので、
1回押すごとにフッタを読む。

### 非対話セッションから TUI を開く

**pty が要る。**tmux が無い環境では python の `pty.fork()` で pty を張り、
FIFO からキーを流し込んで、生出力を最小の VT100 エミュレーションで復元する。
本ディレクトリの [bg_tui_driver.py](bg_tui_driver.py)(常駐ドライバ)と
[bg_tui_render.py](bg_tui_render.py)(画面復元)がその実装。

```bash
W=/tmp/bgtui; rm -rf $W
setsid nohup python3 bg_tui_driver.py $W -- claude agents >/dev/null 2>&1 &
python3 bg_tui_render.py $W/tui.raw        # 画面を読む
printf '\033[A' > $W/keys.fifo             # ↑
printf '\030'   > $W/keys.fifo             # ctrl+x
printf '\033'   > $W/keys.fifo             # esc
```

**選択行は SGR 背景色(`\x1b[48;5;237m`)でしか分からない。**
プレーンテキストに落とすと消えるので、生出力から直接拾う。

```bash
python3 - "$W/tui.raw" <<'EOF'
import re,sys
d=open(sys.argv[1],'rb').read()
t=d[[m.start() for m in re.finditer(rb'\x1b\[2J',d)][-1]:]
h=[t[m.end():m.end()+45].decode('utf-8','replace') for m in re.finditer(rb'\x1b\[48;5;237m',t)]
print(repr(h[-1]))
EOF
```

## 4. 止まったことの確認

```bash
claude agents --json | python3 -c "import json,sys;[print(x.get('kind'),x.get('name'))for x in json.load(sys.stdin)]"
pgrep -af "claude.exe --resume"      # 空
pgrep -af "claude.exe daemon run"    # 空(job が全部終端なら自壊している)
tail -5 ~/.claude/daemon.log         # bg settled <id> (killed)
```

**60秒以上あけてもう一度見る。**respawn は即時ではないので、直後だけ見ても足りない。

## 5. 実測値 ── 停止前後のメモリ

| | 停止前 | 停止後 | 差 |
|---|---|---|---|
| claude 系プロセス 合計 RSS | 6.67 GB | 4.35 GB | **−2.32 GB** |
| システム used | 9.2 GB | 7.9 GB | −1.3 GB |
| システム available | 5.5 GB | 6.8 GB | +1.3 GB |

**bg セッション1本あたり約 0.75 GB。**
`bg-pty-host`(約 135 MB)+ `claude.exe --resume`(約 400 MB)+ MCP サーバ群、の合計。
**アイドルでも積む** ── 3本とも `status: idle` のまま2時間放置してこの値だった。
使い捨ての probe を放置するとメモリを直接食うので、実験が終わったらその場で止める。

## 6. 退避

job 定義は消える前に取っておく。TUI の `ctrl+x`(stop)は job を残すが、
終了済みに対する `ctrl+x`(delete)や見出しでの delete all は消す。

```bash
cp -a ~/.claude/jobs/<jobId> ~/.claude/jobs_backup_<date>/
```

今回の3本は `~/.claude/jobs_backup_0816/` に退避済み。
