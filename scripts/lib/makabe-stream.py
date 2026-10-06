#!/usr/bin/env python3
"""claude-makabe.sh の stream-json 駆動役(庵野 2026-10-07)。

claude -p --input-format stream-json --output-format stream-json の標準入力を開いたまま持ち、
最初の発言(prompt)を流し、run_dir の FIFO(inbox.fifo)に makabe-send が書いた 1 行 JSON を
そのまま claude の標準入力へ中継する。type=result を受けて新しい発言が残っていなければ標準入力を
閉じて終わる(1 起動 = 1 session。終わり方は従来の --output-format json と同じ)。

  - FIFO は O_RDWR で自分が書き側を 1 本持つので、makabe-send の書き手が居なくても EOF にならない。
  - 終端の競合: result を受けたとき、makabe-send と同じ flock を取り、closed を置いてから FIFO を
    空にする。空にして中継した発言があれば閉じずに次の result まで待つ。closed が置かれた後の
    makabe-send は書かずにエラーで返る(送った発言が黙って捨てられない)。
  - result.queued_turn_count > 0 の間も閉じない(claude が次の turn を持っているとき)。
  - last.json は最後の result 行(--output-format json の単一オブジェクトと同じ形: session_id・is_error・result)。
    stream.jsonl が全行。result が 1 件も来なかったときの last.json は空で、後段は is_error=1 に倒す。

使い方(launcher 専用):
  makabe-stream.py --cwd D --fifo F --lock L --closed C --pidfile P --stream S --last-json J \
      --stderr-log E --first-prompt-file PF -- claude ...
"""
import argparse
import fcntl
import json
import os
import select
import signal
import subprocess
import sys
import threading
import time

CLOSE_WAIT_SEC = 30  # result 後に標準入力を閉じてから、claude が自分で終わるのを待つ秒数


def user_line(text):
    return json.dumps(
        {"type": "user", "message": {"role": "user", "content": text}, "parent_tool_use_id": None},
        ensure_ascii=False,
    ) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cwd", required=True)
    ap.add_argument("--fifo", required=True)
    ap.add_argument("--lock", required=True)
    ap.add_argument("--closed", required=True)
    ap.add_argument("--pidfile", required=True)
    ap.add_argument("--stream", required=True)
    ap.add_argument("--last-json", required=True)
    ap.add_argument("--stderr-log", required=True)
    ap.add_argument("--first-prompt-file", required=True)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        print("claude のコマンドが無い", file=sys.stderr)
        return 2

    with open(a.first_prompt_file, encoding="utf-8") as f:
        first_prompt = f.read()

    # 書き側を自分で 1 本持つ(O_RDWR)。makabe-send が居なくても read は EOF にならない。
    fifo_fd = os.open(a.fifo, os.O_RDWR | os.O_NONBLOCK)
    lock_fd = os.open(a.lock, os.O_RDWR | os.O_CREAT, 0o600)

    stderr_f = open(a.stderr_log, "ab")
    try:
        proc = subprocess.Popen(cmd, cwd=a.cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr_f)
    except OSError as e:
        print(f"claude を起動できない: {e}", file=sys.stderr)
        return 91

    with open(a.pidfile, "w") as f:
        f.write(str(os.getpid()))

    def on_term(signum, _frame):
        try:
            proc.terminate()
        except OSError:
            pass
        os._exit(128 + signum)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    stdin_mu = threading.Lock()
    fifo_mu = threading.Lock()
    stdin_closed = threading.Event()
    stop = threading.Event()
    state = {"buf": b""}

    def send_to_claude(line):
        with stdin_mu:
            if stdin_closed.is_set():
                return False
            try:
                proc.stdin.write(line.encode("utf-8") if isinstance(line, str) else line)
                proc.stdin.flush()
                return True
            except (BrokenPipeError, OSError, ValueError):
                return False

    def pump_fifo(timeout):
        """FIFO から読める分を読んで完結した行を claude へ中継する。中継した件数を返す。"""
        n = 0
        with fifo_mu:
            while True:
                r, _, _ = select.select([fifo_fd], [], [], timeout)
                if not r:
                    break
                try:
                    chunk = os.read(fifo_fd, 65536)
                except BlockingIOError:
                    break
                if not chunk:
                    break
                state["buf"] += chunk
                while b"\n" in state["buf"]:
                    raw, state["buf"] = state["buf"].split(b"\n", 1)
                    if not raw.strip():
                        continue
                    try:
                        obj = json.loads(raw.decode("utf-8"))
                        assert isinstance(obj, dict) and obj.get("type") == "user"
                    except Exception:
                        print("[makabe-stream] inbox の不正な行を捨てた", file=sys.stderr)
                        continue
                    if send_to_claude(raw + b"\n"):
                        n += 1
                timeout = 0
        return n

    def pump_loop():
        while not stop.is_set():
            pump_fifo(0.2)

    pump_thread = threading.Thread(target=pump_loop, daemon=True)

    send_to_claude(user_line(first_prompt))
    pump_thread.start()

    stream_f = open(a.stream, "ab")
    got_result = False
    closed_by_us_at = None
    killed_by_us = False

    def watchdog():
        nonlocal killed_by_us
        while proc.poll() is None:
            if closed_by_us_at is not None and time.time() - closed_by_us_at > CLOSE_WAIT_SEC:
                print(f"[makabe-stream] result 後 {CLOSE_WAIT_SEC} 秒で claude が終わらない、SIGTERM", file=sys.stderr)
                killed_by_us = True
                proc.terminate()
                return
            time.sleep(0.5)

    threading.Thread(target=watchdog, daemon=True).start()

    for raw in proc.stdout:
        stream_f.write(raw)
        stream_f.flush()
        if closed_by_us_at is not None:
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("type") != "result":
            continue
        got_result = True
        tmp = a.last_json + ".tmp"
        with open(tmp, "wb") as f:
            f.write(raw if raw.endswith(b"\n") else raw + b"\n")
        os.replace(tmp, a.last_json)
        if d.get("queued_turn_count"):
            continue  # claude が次の turn を持っている
        # makabe-send と同じ flock を取り、closed を置いてから FIFO を空にする
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            with open(a.closed, "w") as f:
                f.write(str(time.time()))
            forwarded = pump_fifo(0)
            if forwarded > 0:
                os.unlink(a.closed)  # まだ続く
                got_result = False
                continue
            stop.set()
            with stdin_mu:
                stdin_closed.set()
                try:
                    proc.stdin.close()
                except OSError:
                    pass
            closed_by_us_at = time.time()
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)

    rc = proc.wait()
    stop.set()
    if not os.path.exists(a.closed):
        with open(a.closed, "w") as f:
            f.write(str(time.time()))
    if not os.path.exists(a.last_json):
        open(a.last_json, "w").close()
    try:
        os.unlink(a.pidfile)
    except OSError:
        pass
    if killed_by_us and got_result:
        return 0
    return rc


if __name__ == "__main__":
    sys.exit(main())
