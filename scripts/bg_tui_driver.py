#!/usr/bin/env python3
"""claude agents TUI を pty 上で起動し、FIFO 経由でキーを送れるようにする常駐ドライバ。

  起動: python3 tui_driver.py <workdir> -- <cmd> [args...]
  キー送信: printf '<bytes>' > <workdir>/keys.fifo
  生出力:   <workdir>/tui.raw
"""
import os
import pty
import select
import signal
import struct
import sys
import fcntl
import termios

COLS, ROWS = 200, 50


def main():
    workdir = sys.argv[1]
    sep = sys.argv.index("--")
    cmd = sys.argv[sep + 1:]

    os.makedirs(workdir, exist_ok=True)
    raw_path = os.path.join(workdir, "tui.raw")
    fifo_path = os.path.join(workdir, "keys.fifo")
    pid_path = os.path.join(workdir, "driver.pid")
    if not os.path.exists(fifo_path):
        os.mkfifo(fifo_path)

    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = str(COLS)
        env["LINES"] = str(ROWS)
        env.pop("CLAUDECODE", None)
        env.pop("CLAUDE_CODE_ENTRYPOINT", None)
        os.execvpe(cmd[0], cmd, env)
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    with open(pid_path, "w") as f:
        f.write("%d %d\n" % (os.getpid(), pid))

    raw = open(raw_path, "wb", buffering=0)
    # O_RDWR にしておくと writer が居なくても EOF にならない
    fifo = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)

    while True:
        try:
            r, _, _ = select.select([fd, fifo], [], [], 1.0)
        except (OSError, select.error):
            break
        if fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            raw.write(data)
        if fifo in r:
            try:
                keys = os.read(fifo, 4096)
            except OSError:
                keys = b""
            if keys:
                os.write(fd, keys)
        # 子が死んだら終了
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                # 残りを吸い出す
                try:
                    while True:
                        d = os.read(fd, 65536)
                        if not d:
                            break
                        raw.write(d)
                except OSError:
                    pass
                break
        except ChildProcessError:
            break

    raw.close()
    with open(os.path.join(workdir, "exited"), "w") as f:
        f.write("child exited\n")


if __name__ == "__main__":
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    main()
