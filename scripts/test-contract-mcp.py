#!/usr/bin/env python3
"""契約の MCP(lib/contract-mcp.py)の単体 test。stdio の JSON-RPC をそのまま叩く。実 Claude は使わない。
使い方: python3 scripts/test-contract-mcp.py   (scripts/test-contract-mcp.sh から呼ばれる)
MCP を差し替えて落ちを見る:CONTRACT_MCP_UNDER_TEST=<path>
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MCP = os.environ.get("CONTRACT_MCP_UNDER_TEST", os.path.join(HERE, "lib", "contract-mcp.py"))
n = 0
failed = 0


def check(desc, cond, extra=""):
    global n, failed
    n += 1
    if cond:
        print(f"ok {n} - {desc}")
    else:
        failed += 1
        print(f"not ok {n} - {desc} {extra}")


class Server:
    def __init__(self, contract_dir, batch, tools=None):
        env = {k: v for k, v in os.environ.items() if k not in ("CONTRACT_DIR", "BATCH", "CONTRACT_TOOLS")}
        if contract_dir is not None:
            env["CONTRACT_DIR"] = contract_dir
        if batch is not None:
            env["BATCH"] = batch
        if tools:
            env["CONTRACT_TOOLS"] = tools
        self.p = subprocess.Popen([sys.executable, "-I", MCP], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env, text=True)
        self.i = 0
        self.init = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params=None):
        self.i += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.i, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def call(self, name, **args):
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        if "error" in r:
            return True, r["error"]["message"]
        res = r["result"]
        return res.get("isError", False), res["content"][0]["text"]

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=5)


def tree(root):
    out = []
    for d, _dirs, files in os.walk(root):
        for f in files:
            out.append(os.path.relpath(os.path.join(d, f), root))
    return sorted(out)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


with tempfile.TemporaryDirectory() as tmp:
    tmp = os.path.realpath(tmp)

    def new_contract(name, goal=None):
        d = os.path.join(tmp, name)
        os.makedirs(os.path.join(d, "b1"))
        with open(os.path.join(d, "b1", "brief.md"), "w", encoding="utf-8") as f:
            f.write("# brief\nやること\n")
        if goal is not None:
            with open(os.path.join(d, "GOAL.md"), "w", encoding="utf-8") as f:
                f.write(goal)
        return d

    # ---- 1. プロトコルと 5 つの道具 ----
    c = new_contract("c1", "# GOAL\n\n## 便\n\n- b1 の配置\n")
    s = Server(c, "b1")
    r = s.rpc("tools/list")
    names = [t["name"] for t in r["result"]["tools"]]
    check("1a tools/list が 5 つ", names == ["brief_get", "result_get", "result_put", "result_append", "gate_put"], names)
    check("1b initialize が受けた protocolVersion と serverInfo.name=contract を返し、ping に答える",
          s.init["result"]["protocolVersion"] == "2025-06-18" and s.init["result"]["serverInfo"]["name"] == "contract" and s.rpc("ping")["result"] == {})
    err, text = s.call("brief_get")
    check("1c brief_get が brief.md を返す", not err and text == "# brief\nやること\n", text)
    err, text = s.call("result_get")
    check("1d result_get は result.md が無ければ空", not err and text == "", text)
    err, text = s.call("result_put", md="# result\n1 行目\n")
    check("1e result_put が result.md を丸ごと書く", not err and read(f"{c}/b1/result.md") == "# result\n1 行目\n", text)
    err, text = s.call("result_append", md="2 行目\n")
    check("1f result_append が末尾に足す", not err and read(f"{c}/b1/result.md") == "# result\n1 行目\n2 行目\n", text)
    err, text = s.call("result_put", md="置き換え")
    check("1g result_put は丸ごと置き換える(末尾に改行が無くてもよい)", not err and read(f"{c}/b1/result.md") == "置き換え")
    err, text = s.call("result_append", md="足す")
    check("1h 改行で終わっていない result.md への append は改行を挟む", read(f"{c}/b1/result.md") == "置き換え\n足す")
    err, text = s.call("result_get")
    check("1i result_get が書いた中身を返す", text == "置き換え\n足す")
    err, text = s.call("gate_put", md="# gate\nP0 無し\n")
    check("1j gate_put が gate.md を書く", not err and read(f"{c}/b1/gate.md") == "# gate\nP0 無し\n")
    check("1k 触ったのは b1/{brief,result,gate}.md と GOAL.md だけ(鍵・一時ファイルが残らない)",
          tree(c) == ["GOAL.md", "b1/brief.md", "b1/gate.md", "b1/result.md"], tree(c))
    err, text = s.call("nonexistent")
    check("1l 知らない道具は断る", err)
    err, text = s.call("result_put")
    check("1m md 無しの result_put は断る", err and "md" in text, text)
    err, text = s.call("result_put", md="x" * (2 * 1024 * 1024 + 1))
    check("1n 2MB 超は断る", err and "大きすぎる" in text, text[:80])
    s.close()

    # ---- 2. GOAL.md の行 ----
    goal = read(f"{c}/GOAL.md")
    lines = goal.split("\n")
    check("2a 行が無ければ `## 便の進捗` の節ごと末尾に足す", "## 便の進捗" in lines, goal)
    pline = [ln for ln in lines if ln.startswith("- b1:")]
    check("2b その便の行は 1 本だけ", len(pline) == 1, goal)
    import re
    check("2c 行の形が `- b1:brief 有り / result 有り MM-DD HH:MM / gate 有り MM-DD HH:MM`",
          re.fullmatch(r"- b1:brief 有り / result 有り \d\d-\d\d \d\d:\d\d / gate 有り \d\d-\d\d \d\d:\d\d", pline[0]) is not None, pline)
    check("2d 親が書いた他の行(- b1 の配置)は触らない", "- b1 の配置" in lines)

    # 人が書いた行に足す・人の部分を残す・節に足す
    c2 = new_contract("c2", "# GOAL\n\n## 便の進捗\n\n- b0:result 有り 11-12 10:00\n- b1:真壁 sonnet、api の便 / result 有り 01-01 00:00\n\n## 次\n\n- なにか\n")
    s = Server(c2, "b1")
    s.call("result_put", md="r")
    g = read(f"{c2}/GOAL.md")
    check("2e 既存の行は同じ位置で書き換え、人の部分(真壁 sonnet、api の便)を残し、古い時刻を直す",
          "- b1:真壁 sonnet、api の便 / brief 有り / result 有り " in g and "01-01 00:00" not in g and g.count("- b1:") == 1, g)
    check("2f 他の便の行(b0)は触らない", "- b0:result 有り 11-12 10:00" in g)
    s.close()
    os.makedirs(f"{c2}/b2")
    open(f"{c2}/b2/brief.md", "w").write("b2")
    s = Server(c2, "b2")
    s.call("result_put", md="r2")
    g = read(f"{c2}/GOAL.md")
    gl = g.split("\n")
    i_b1, i_b2, i_next = (next(i for i, ln in enumerate(gl) if ln.startswith(p)) for p in ("- b1:", "- b2:", "## 次"))
    check("2g 行の無い便は既存の `## 便の進捗` の節の末尾(次の節の前)に足す", i_b1 < i_b2 < i_next, g)
    s.close()
    s = Server(c2, "b1")
    s.call("gate_put", md="g")
    g = read(f"{c2}/GOAL.md")
    check("2h gate の行を足しても result の部分は残る(brief / result / gate の順)",
          re.search(r"- b1:真壁 sonnet、api の便 / brief 有り / result 有り \d\d-\d\d \d\d:\d\d / gate 有り \d\d-\d\d \d\d:\d\d", g) is not None, g)
    s.close()

    # GOAL.md が無い
    c3 = new_contract("c3")
    s = Server(c3, "b1")
    err, text = s.call("result_put", md="r")
    check("2i GOAL.md が無くても result は書け、GOAL.md は作らない", not err and not os.path.exists(f"{c3}/GOAL.md") and "GOAL.md が無い" in text, text)
    s.close()
    # GOAL.md が symlink
    c4 = new_contract("c4")
    outside = os.path.join(tmp, "outside-goal.md")
    open(outside, "w").write("外\n")
    os.symlink(outside, f"{c4}/GOAL.md")
    s = Server(c4, "b1")
    err, text = s.call("result_put", md="r")
    check("2j GOAL.md が symlink なら断り、外のファイルは変わらない", err and read(outside) == "外\n", text)
    s.close()

    # ---- 3. 外への書きと BATCH の検査 ----
    c5 = new_contract("c5", "# GOAL\n")
    sentinel_before = tree(tmp)
    bad_batches = ["..", "../x", "a/b", "/etc", "a/../../x", ".hidden", "a..b", "", "x\ny", "a b", "a:b", "a\\b", "b1/../../c1"]
    for b in bad_batches:
        s = Server(c5, b)
        res = [s.call("result_put", md="pwn"), s.call("gate_put", md="pwn"), s.call("result_append", md="pwn"),
               s.call("brief_get"), s.call("result_get")]
        s.close()
        check(f"3 BATCH={b!r} は 5 つの道具すべてが断る", all(e for e, _ in res), res)
    check("3x 断った BATCH でフォルダも外のファイルも増えない", tree(tmp) == sentinel_before and sorted(os.listdir(c5)) == ["GOAL.md", "b1"],
          (sorted(os.listdir(c5)), [t for t in tree(tmp) if t not in sentinel_before]))
    for cd in (None, "relative/dir", os.path.join(tmp, "no-such-dir")):
        s = Server(cd, "b1")
        err, text = s.call("result_put", md="pwn")
        check(f"3 CONTRACT_DIR={cd!r} は断る", err, text)
        s.close()
    s = Server(c5, None)
    err, text = s.call("result_put", md="pwn")
    check("3 BATCH 未設定は断る", err, text)
    s.close()

    # symlink で外へ出る
    ext = os.path.join(tmp, "external-dir")
    os.makedirs(ext)
    os.symlink(ext, f"{c5}/linkbatch")
    s = Server(c5, "linkbatch")
    err, text = s.call("result_put", md="pwn")
    check("3 便のフォルダが外への symlink なら断り、外に書かない", err and os.listdir(ext) == [], (text, os.listdir(ext)))
    s.close()
    os.makedirs(f"{c5}/b9")
    os.symlink(outside, f"{c5}/b9/result.md")
    s = Server(c5, "b9")
    err1, _ = s.call("result_put", md="pwn")
    err2, _ = s.call("result_append", md="pwn")
    check("3 result.md が symlink なら put も append も断り、外のファイルは変わらない", err1 and err2 and read(outside) == "外\n")
    s.close()
    os.symlink(outside, f"{c5}/b9/gate.md")
    s = Server(c5, "b9")
    err, _ = s.call("gate_put", md="pwn")
    check("3 gate.md が symlink なら断る", err and read(outside) == "外\n")
    s.close()

    # ---- 4. CONTRACT_TOOLS(役ごとの絞り) ----
    s = Server(c5, "b1", tools="brief_get,result_get,gate_put")
    names = [t["name"] for t in s.rpc("tools/list")["result"]["tools"]]
    err, text = s.call("result_put", md="pwn")
    check("4a CONTRACT_TOOLS で柏木用(brief_get,result_get,gate_put)に絞ると tools/list も呼びも絞られる",
          names == ["brief_get", "result_get", "gate_put"] and err and not os.path.exists(f"{c5}/b1/result.md"), (names, text))
    s.close()

    # ---- 5. 並行 put の GOAL.md の行が壊れない ----
    c6 = new_contract("c6", "# GOAL\n")
    for b in ("p1", "p2", "p3", "p4"):
        os.makedirs(f"{c6}/{b}")
        open(f"{c6}/{b}/brief.md", "w").write(b)
    servers = [Server(c6, b) for b in ("p1", "p2", "p3", "p4")]
    for rnd in range(5):
        for sv in servers:
            sv.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 100 + rnd, "method": "tools/call",
                                         "params": {"name": "result_append", "arguments": {"md": f"r{rnd}\n"}}}) + "\n")
            sv.p.stdin.flush()
        for sv in servers:
            sv.p.stdout.readline()
    for sv in servers:
        sv.close()
    g = read(f"{c6}/GOAL.md")
    check("5 4 便が同時に append しても GOAL.md に便ごとの行が 1 本ずつ(取りこぼし・重複なし)",
          all(g.count(f"- {b}:") == 1 for b in ("p1", "p2", "p3", "p4")), g)

print(f"1..{n}")
sys.exit(1 if failed else 0)
