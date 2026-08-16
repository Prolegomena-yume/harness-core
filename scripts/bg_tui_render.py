#!/usr/bin/env python3
"""tui.raw を最小の VT100 エミュレーションで画面へ復元する。"""
import re
import sys

COLS, ROWS = 200, 50


class Screen:
    def __init__(self, cols=COLS, rows=ROWS):
        self.cols, self.rows = cols, rows
        self.buf = [[" "] * cols for _ in range(rows)]
        self.cx = self.cy = 0

    def _clamp(self):
        self.cx = max(0, min(self.cx, self.cols - 1))
        self.cy = max(0, min(self.cy, self.rows - 1))

    def put(self, ch):
        if self.cx >= self.cols:
            self.cx = 0
            self.nl()
        self.buf[self.cy][self.cx] = ch
        self.cx += 1

    def nl(self):
        self.cy += 1
        if self.cy >= self.rows:
            self.buf.pop(0)
            self.buf.append([" "] * self.cols)
            self.cy = self.rows - 1

    def erase_display(self, mode):
        if mode == 2 or mode == 3:
            self.buf = [[" "] * self.cols for _ in range(self.rows)]
        elif mode == 0:
            for x in range(self.cx, self.cols):
                self.buf[self.cy][x] = " "
            for y in range(self.cy + 1, self.rows):
                self.buf[y] = [" "] * self.cols
        elif mode == 1:
            for y in range(0, self.cy):
                self.buf[y] = [" "] * self.cols
            for x in range(0, self.cx + 1):
                self.buf[self.cy][x] = " "

    def erase_line(self, mode):
        if mode == 0:
            for x in range(self.cx, self.cols):
                self.buf[self.cy][x] = " "
        elif mode == 1:
            for x in range(0, self.cx + 1):
                self.buf[self.cy][x] = " "
        else:
            self.buf[self.cy] = [" "] * self.cols

    def dump(self):
        return "\n".join("".join(r).rstrip() for r in self.buf)


CSI = re.compile(rb"\x1b\[([0-9;?]*)([@-~])")
OSC = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
ESC_SIMPLE = re.compile(rb"\x1b[()][0-9A-Za-z]|\x1b[=>MDE78]")


def run(data):
    s = Screen()
    i = 0
    n = len(data)
    while i < n:
        b = data[i:i + 1]
        if b == b"\x1b":
            m = OSC.match(data, i)
            if m:
                i = m.end()
                continue
            m = CSI.match(data, i)
            if m:
                params, final = m.group(1), m.group(2)
                ps = [int(p) for p in params.split(b";") if p.isdigit()]
                f = final.decode()
                if f == "H" or f == "f":
                    s.cy = (ps[0] - 1) if len(ps) > 0 else 0
                    s.cx = (ps[1] - 1) if len(ps) > 1 else 0
                    s._clamp()
                elif f == "A":
                    s.cy -= ps[0] if ps else 1
                    s._clamp()
                elif f == "B":
                    s.cy += ps[0] if ps else 1
                    s._clamp()
                elif f == "C":
                    s.cx += ps[0] if ps else 1
                    s._clamp()
                elif f == "D":
                    s.cx -= ps[0] if ps else 1
                    s._clamp()
                elif f == "G":
                    s.cx = (ps[0] - 1) if ps else 0
                    s._clamp()
                elif f == "d":
                    s.cy = (ps[0] - 1) if ps else 0
                    s._clamp()
                elif f == "J":
                    s.erase_display(ps[0] if ps else 0)
                elif f == "K":
                    s.erase_line(ps[0] if ps else 0)
                i = m.end()
                continue
            m = ESC_SIMPLE.match(data, i)
            if m:
                i = m.end()
                continue
            i += 1
            continue
        if b == b"\r":
            s.cx = 0
            i += 1
            continue
        if b == b"\n":
            s.nl()
            i += 1
            continue
        if b == b"\b":
            s.cx = max(0, s.cx - 1)
            i += 1
            continue
        if b in (b"\x07", b"\x00"):
            i += 1
            continue
        if b == b"\t":
            s.cx = min(s.cols - 1, (s.cx // 8 + 1) * 8)
            i += 1
            continue
        # UTF-8 の先頭バイトから長さを決める
        c = data[i]
        ln = 1
        if c >= 0xF0:
            ln = 4
        elif c >= 0xE0:
            ln = 3
        elif c >= 0xC0:
            ln = 2
        chunk = data[i:i + ln]
        try:
            ch = chunk.decode("utf-8")
        except UnicodeDecodeError:
            ch = "?"
            ln = 1
        if ch:
            s.put(ch)
        i += ln
    return s


if __name__ == "__main__":
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    print(run(data).dump())
