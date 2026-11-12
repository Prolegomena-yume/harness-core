#!/usr/bin/env python3
"""契約の MCP(stdio)── 真壁・柏木が brief / result / gate を道具で読み書きするための口。

docs/delegation.md「契約の置き場」の `_contract/yyyy-mm-dd_NN/` を、モデルに path を見せずに触らせる。
path を持つのはこのプロセスだけ(環境変数)で、モデルは道具だけを使う ── だから worktree の外への
書き込みを hook で一律に塞げる(scripts/hooks/write-guard-claude.py)。

環境変数:
  CONTRACT_DIR   契約のフォルダの絶対 path(GOAL.md と <便名>/ がある)。必須
  BATCH          便名。必須。`/` `\\` `..` `:` や空白・制御文字を含むと全ての道具が断る
  CONTRACT_TOOLS 出す道具のカンマ区切り(任意。既定は 5 つ全部)。役ごとに絞る用 ── 真壁は
                 brief_get,result_get,result_put,result_append、柏木は brief_get,result_get,gate_put

道具(5 つ):
  brief_get()          <BATCH>/brief.md を返す(無ければエラー)
  result_get()         <BATCH>/result.md を返す(無ければ空)
  result_put(md)       result.md を丸ごと書く
  result_append(md)    result.md の末尾に足す
  gate_put(md)         gate.md を丸ごと書く
  put / append のときは GOAL.md の、その便の 1 行の進捗も機械が書き換える(下の progress_line)。

書ける先は CONTRACT_DIR/<BATCH>/{result,gate}.md と CONTRACT_DIR/GOAL.md の 1 行だけ。
実体の path は realpath で CONTRACT_DIR の内側かを確かめ、symlink は書かない。

GOAL.md の進捗の行の形(docs/delegation.md に書く):
  - <便名>:brief 有り / result 有り 11-13 04:10 / gate 有り 11-13 05:00
  - 行の頭が `- <便名>:` の行がその便の行。無ければ `## 便の進捗` の節の末尾(節が無ければファイル末尾に節ごと)に足す
  - 部分は ` / ` 区切りで、機械が持つのは `brief` `result` `gate` で始まる部分だけ。人が同じ行に書いた他の部分は残す
  - 時刻は JST の MM-DD HH:MM。put でも append でも「最後に書いた時刻」
  - GOAL.md が無ければ進捗は書かない(GOAL.md は親が作る。機械は作らない)

標準ライブラリだけ。MCP は改行区切りの JSON-RPC(protocolVersion は受けた値を返す)。
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone

SERVER_NAME = "contract"
SERVER_VERSION = "1.0.0"
MAX_BYTES = 2 * 1024 * 1024
JST = timezone(timedelta(hours=9))

ALL_TOOLS = ["brief_get", "result_get", "result_put", "result_append", "gate_put"]

# 便名に許さない文字: path 区切り・コロン(GOAL.md の行の区切り)・空白・制御文字
_BAD_BATCH_CHARS = re.compile(r"[/\\:\x00-\x20\x7f　：]")


class ToolError(Exception):
    pass


def validate_batch(batch: str) -> str:
    if not batch:
        raise ToolError("BATCH が空")
    if _BAD_BATCH_CHARS.search(batch):
        raise ToolError(f"BATCH に使えない文字がある(/ \\ : 空白 制御文字): {batch!r}")
    if ".." in batch or batch.startswith("."):
        raise ToolError(f"BATCH に .. や先頭の . は使えない: {batch!r}")
    if len(batch.encode("utf-8")) > 100:
        raise ToolError("BATCH が長すぎる(100 バイトまで)")
    return batch


def contract_root() -> str:
    raw = os.environ.get("CONTRACT_DIR", "")
    if not raw or not os.path.isabs(raw):
        raise ToolError("CONTRACT_DIR が絶対 path で渡されていない")
    if not os.path.isdir(raw):
        raise ToolError("CONTRACT_DIR が見つからない")
    return os.path.realpath(raw)


def _inside(root: str, path: str) -> bool:
    return path == root or path.startswith(root + os.sep)


def batch_file(name: str, make_dir: bool) -> str:
    """<CONTRACT_DIR>/<BATCH>/<name> の実 path。CONTRACT_DIR の外・symlink なら断る。"""
    root = contract_root()
    batch = validate_batch(os.environ.get("BATCH", ""))
    bdir = os.path.join(root, batch)
    if os.path.islink(bdir):
        raise ToolError("便のフォルダが symlink")
    if make_dir:
        os.makedirs(bdir, exist_ok=True)
    real_dir = os.path.realpath(bdir)
    if not _inside(root, real_dir) or real_dir == root:
        raise ToolError("便のフォルダが CONTRACT_DIR の外")
    target = os.path.join(real_dir, name)
    if os.path.islink(target):
        raise ToolError(f"{name} が symlink")
    return target


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_atomic(path: str, text: str) -> None:
    data = text.encode("utf-8")
    if len(data) > MAX_BYTES:
        raise ToolError(f"本文が大きすぎる({MAX_BYTES} バイトまで)")
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class dir_lock:
    """フォルダ自身に flock を掛ける(鍵ファイルを契約のフォルダに残さない。os.replace で inode が替わっても効く)。"""

    def __init__(self, path: str):
        self.path = path

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDONLY)
        fcntl.flock(self.fd, fcntl.LOCK_EX)

    def __exit__(self, *exc):
        os.close(self.fd)


def _require_md(args: dict) -> str:
    md = args.get("md")
    if not isinstance(md, str):
        raise ToolError("md(文字列)が必要")
    return md


# ---- GOAL.md の進捗の行 ----

PROGRESS_HEADING = "## 便の進捗"
_MACHINE_SEG = re.compile(r"^(brief|result|gate)( |$)")


def progress_segments(existing_rest: str | None, kind: str, stamp: str, batch_dir: str) -> str:
    """既存の行の `:` の後ろを ` / ` で割り、機械が持つ部分(brief・result・gate)だけを更新して返す。"""
    segs = [s for s in (existing_rest or "").split(" / ") if s.strip()] if existing_rest else []
    keep_human = [s for s in segs if not _MACHINE_SEG.match(s.strip())]
    by_key = {}
    for s in segs:
        m = _MACHINE_SEG.match(s.strip())
        if m:
            by_key[m.group(1)] = s.strip()
    if os.path.isfile(os.path.join(batch_dir, "brief.md")):
        by_key["brief"] = "brief 有り"
    by_key[kind] = f"{kind} 有り {stamp}"
    ordered = [by_key[k] for k in ("brief", "result", "gate") if k in by_key]
    return " / ".join(keep_human + ordered)


def update_goal(kind: str) -> str:
    """GOAL.md のその便の行を書き換える。返すのは報告用の 1 行。"""
    root = contract_root()
    batch = validate_batch(os.environ.get("BATCH", ""))
    goal = os.path.join(root, "GOAL.md")
    if os.path.islink(goal):
        raise ToolError("GOAL.md が symlink")
    if not os.path.isfile(goal):
        return "GOAL.md が無いので進捗の行は書かなかった"
    stamp = datetime.now(JST).strftime("%m-%d %H:%M")
    batch_dir = os.path.join(root, batch)
    prefix = f"- {batch}:"
    with dir_lock(root):
        text = read_text(goal)
        lines = text.split("\n")
        idx = next((i for i, ln in enumerate(lines) if ln.startswith(prefix)), None)
        if idx is not None:
            rest = lines[idx][len(prefix):]
            lines[idx] = prefix + progress_segments(rest, kind, stamp, batch_dir)
            new_line = lines[idx]
        else:
            new_line = prefix + progress_segments(None, kind, stamp, batch_dir)
            h = next((i for i, ln in enumerate(lines) if ln.strip() == PROGRESS_HEADING), None)
            if h is None:
                while lines and lines[-1] == "":
                    lines.pop()
                lines += ["", PROGRESS_HEADING, "", new_line, ""]
            else:
                end = h + 1
                while end < len(lines) and not lines[end].startswith("## "):
                    end += 1
                insert_at = end
                while insert_at > h + 1 and lines[insert_at - 1].strip() == "":
                    insert_at -= 1
                lines.insert(insert_at, new_line)
        out = "\n".join(lines)
        if not out.endswith("\n"):
            out += "\n"
        write_atomic(goal, out)
    return f"GOAL.md: {new_line}"


# ---- 道具 ----

def tool_brief_get(_args: dict) -> str:
    path = batch_file("brief.md", make_dir=False)
    if not os.path.isfile(path):
        raise ToolError("brief.md が無い")
    return read_text(path)


def tool_result_get(_args: dict) -> str:
    path = batch_file("result.md", make_dir=False)
    return read_text(path) if os.path.isfile(path) else ""


def tool_result_put(args: dict) -> str:
    md = _require_md(args)
    path = batch_file("result.md", make_dir=True)
    write_atomic(path, md)
    return f"result.md を書いた({len(md.encode('utf-8'))} バイト)。{update_goal('result')}"


def tool_result_append(args: dict) -> str:
    md = _require_md(args)
    path = batch_file("result.md", make_dir=True)
    # 読んで足して置き換えるあいだの競合は、同じ便の MCP が 2 本同時に走らない前提(1 便 = 1 プロセス)でも
    # 起きうるので、便のフォルダの鍵を取る
    with dir_lock(os.path.dirname(path)):
        cur = read_text(path) if os.path.isfile(path) else ""
        if cur and not cur.endswith("\n"):
            cur += "\n"
        write_atomic(path, cur + md)
    return f"result.md に足した({len(md.encode('utf-8'))} バイト)。{update_goal('result')}"


def tool_gate_put(args: dict) -> str:
    md = _require_md(args)
    path = batch_file("gate.md", make_dir=True)
    write_atomic(path, md)
    return f"gate.md を書いた({len(md.encode('utf-8'))} バイト)。{update_goal('gate')}"


_MD_SCHEMA = {
    "type": "object",
    "properties": {"md": {"type": "string", "description": "Markdown の本文"}},
    "required": ["md"],
    "additionalProperties": False,
}
_EMPTY_SCHEMA = {"type": "object", "properties": {}, "additionalProperties": False}

TOOLS = {
    "brief_get": (tool_brief_get, "この便の brief.md(指示書)を返す。最初にこれで読む", _EMPTY_SCHEMA),
    "result_get": (tool_result_get, "この便の result.md を返す(まだ無ければ空)", _EMPTY_SCHEMA),
    "result_put": (tool_result_put, "result.md を丸ごと書く(真壁の終端の報告)。GOAL.md の進捗の行も更新される", _MD_SCHEMA),
    "result_append": (tool_result_append, "result.md の末尾に足す。GOAL.md の進捗の行も更新される", _MD_SCHEMA),
    "gate_put": (tool_gate_put, "gate.md を丸ごと書く(柏木の所見)。GOAL.md の進捗の行も更新される", _MD_SCHEMA),
}


def enabled_tools() -> list[str]:
    raw = os.environ.get("CONTRACT_TOOLS", "").strip()
    if not raw:
        return list(ALL_TOOLS)
    names = [n.strip() for n in raw.split(",") if n.strip()]
    return [n for n in ALL_TOOLS if n in names]


# ---- JSON-RPC(stdio、改行区切り) ----

def reply(msg_id, result=None, error=None) -> None:
    obj = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        obj["error"] = error
    else:
        obj["result"] = result
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(req: dict) -> None:
    method = req.get("method")
    msg_id = req.get("id")
    is_notification = "id" not in req
    if method == "initialize":
        params = req.get("params") or {}
        reply(msg_id, {
            "protocolVersion": params.get("protocolVersion") or "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    elif method == "ping":
        reply(msg_id, {})
    elif method == "tools/list":
        tools = [
            {"name": n, "description": TOOLS[n][1], "inputSchema": TOOLS[n][2]}
            for n in enabled_tools()
        ]
        reply(msg_id, {"tools": tools})
    elif method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        if name not in enabled_tools():
            reply(msg_id, error={"code": -32602, "message": f"道具が無い: {name}"})
            return
        try:
            text = TOOLS[name][0](args)
            reply(msg_id, {"content": [{"type": "text", "text": text}], "isError": False})
        except ToolError as e:
            reply(msg_id, {"content": [{"type": "text", "text": f"断った: {e}"}], "isError": True})
        except OSError as e:
            reply(msg_id, {"content": [{"type": "text", "text": f"書けなかった: {e.strerror or e}"}], "isError": True})
    elif is_notification:
        return
    else:
        reply(msg_id, error={"code": -32601, "message": f"method が無い: {method}"})


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            reply(None, error={"code": -32700, "message": "parse error"})
            continue
        if isinstance(req, dict):
            handle(req)
    return 0


if __name__ == "__main__":
    sys.exit(main())
