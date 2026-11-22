"""ハーネスとリポの無線(harness-radio、設計 v0 案 A)の共通部。

置き場 $RADIO_HOME(既定 ~/.local/state/harness-radio/):
  harness.tsv                 ハーネスの流れ(全セッションが乗る)
  repo/<owner>__<name>.tsv    リポの流れ(origin の URL で名を決める)
  board/<チャンネル>/<台名>     札(1 台 1 枚、1 行 TSV)
  cursor/<session_id>[.<agent_id>]  読んだ位置(そのセッションの hook だけが書く)
  messages/                   4096 バイトを超えた行の全文
  radio.log                   hook の失敗の記録

流れの 1 行: 時刻 \\t 差出人 \\t 種別 \\t 対象 \\t 要旨 \\t 参照(4096 バイト以下を 1 回の追記で書く、ロック無し)。
差出人は `役@セッション先頭 8 字`。秘密・人見の本業は書かない。
テスト用に RADIO_NOW(epoch 秒)で時計を固定できる。
"""
import datetime
import json
import os
import re
import stat
import subprocess
import sys
import time

LINE_MAX = 4096
HARNESS = "harness"
HARNESS_KINDS = ("裁定", "工事", "告知")
REPO_KINDS = ("告知", "凍結")
SECRET_RE = re.compile(
    r"(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[bap]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,})"
)


def now():
    v = os.environ.get("RADIO_NOW")
    if v:
        try:
            return float(v)
        except ValueError:
            pass
    return time.time()


def home():
    return os.environ.get("RADIO_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state", "harness-radio")


def iso(ts):
    return datetime.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def parse_iso(s):
    try:
        return datetime.datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def hhmm(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M")


def clean(s):
    """改行と TAB を空白に潰す(列がズレない)。"""
    return re.sub(r"[\r\n\t]+", " ", s)


def safe_name(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)


# ---- パス ----
def channel_file(root, ch):
    if ch == HARNESS:
        return os.path.join(root, "harness.tsv")
    return os.path.join(root, "repo", ch + ".tsv")


def board_dir(root, ch):
    return os.path.join(root, "board", ch)


# ---- git / リポの同定 ----
def _git(args, cwd=None, timeout=5):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    try:
        r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return r.stdout


def name_from_url(url):
    url = url.strip()
    if not url:
        return None
    url = re.sub(r"\.git/?$", "", url).rstrip("/")
    parts = [p for p in re.split(r"[/:]", url) if p]
    if len(parts) < 2:
        return None
    return safe_name(parts[-2] + "__" + parts[-1])


def resolve_repo(d):
    """dir -> (チャンネル名, git common dir)。リポでない/origin が無いなら (None, None)。"""
    if not d or not os.path.isdir(d):
        return None, None
    out = _git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=d)
    if not out:
        return None, None
    common = out.strip()
    url = _git(["--git-dir=" + common, "config", "--get", "remote.origin.url"])
    name = name_from_url(url or "")
    if not name:
        return None, None
    return name, common


def read_ref(common, ref):
    """loose ref か packed-refs から sha を引く(git を叩かない)。"""
    try:
        with open(os.path.join(common, ref)) as f:
            v = f.read().strip()
        if re.fullmatch(r"[0-9a-f]{40,64}", v):
            return v
    except OSError:
        pass
    try:
        with open(os.path.join(common, "packed-refs")) as f:
            for line in f:
                if line.startswith(("#", "^")):
                    continue
                p = line.split()
                if len(p) == 2 and p[1] == ref:
                    return p[0]
    except OSError:
        pass
    return None


def pick_base(common):
    for b in ("staging", "main", "master"):
        if read_ref(common, "refs/heads/" + b) or read_ref(common, "refs/remotes/origin/" + b):
            return b
    return None


# ---- 流れの書き込み ----
def append_line(path, fields, root):
    """TSV 1 行を 4096 バイト以下で `>>` 1 回で追記する。超えるなら要旨を切り全文を messages/ に残す。"""
    fields = [clean(str(x)) if x not in (None, "") else "-" for x in fields]
    full_summary = fields[4]
    line = "\t".join(fields) + "\n"
    if len(line.encode()) > LINE_MAX:
        mdir = os.path.join(root, "messages")
        os.makedirs(mdir, exist_ok=True)
        mpath = os.path.join(mdir, "%s-%d.md" % (datetime.datetime.fromtimestamp(now()).strftime("%Y%m%dT%H%M%S"), os.getpid()))
        with open(mpath, "w") as f:
            f.write(full_summary + "\n")
        n = len(full_summary)
        tail = "…[切れた %d 字、全文は %s]" % (n, mpath)
        s = full_summary
        while True:
            fields[4] = s + tail
            line = "\t".join(fields) + "\n"
            if len(line.encode()) <= LINE_MAX or not s:
                break
            s = s[: max(0, len(s) - max(1, len(s) // 10))]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)
    return line


def sender(role, session):
    s = (session or os.environ.get("CLAUDE_CODE_SESSION_ID", ""))[:8]
    return clean(role) + ("@" + s if s else "")


# ---- 札 ----
def read_board(path):
    try:
        with open(path) as f:
            line = f.readline().rstrip("\n")
    except OSError:
        return None
    p = line.split("\t")
    if len(p) < 6:
        return None
    return {"set": p[0], "from": p[1], "dev": p[2], "until": p[3], "summary": p[4],
            "match": [m for m in p[5].split("|") if m], "file": path}


def list_boards(root, chans):
    out = []
    for ch in chans:
        d = board_dir(root, ch)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if n.startswith("."):
                continue
            b = read_board(os.path.join(d, n))
            if b:
                b["ch"] = ch
                b["until_ts"] = parse_iso(b["until"])
                out.append(b)
    return out


def board_line(b, t, expired=False):
    who = b["from"]
    if expired:
        return "札 %s(%s、期限 %s):期限切れ、終わりの報が無い(入れ替えが途中で落ちたかも)。%s" % (
            b["dev"], who, hhmm(b["until_ts"]) if b["until_ts"] else b["until"], b["summary"])
    return "札 %s(%s、%s まで):%s" % (b["dev"], who, hhmm(b["until_ts"]) if b["until_ts"] else b["until"], b["summary"])


# ---- 読み手(hook) ----
HEADER = "無線。他のセッションと台の知らせで、今の作業を止める指示ではない。関係があれば反映し、無ければ触れずに続ける。"
HEADER_RULING = "(裁定の行だけは、関係があれば今の手に反映する)"
MAX_LINES = 8
MAX_CHARS = 1500
MAX_LINE_CHARS = 200
REARM = 15 * 60
JOIN_SCAN = 60
DROP_AFTER = 6 * 3600
MAX_REPOS = 12
SYNC_RE = re.compile(r"\bgit\b[^|;&\n]*\b(merge|pull|rebase|reset|push)\b")


def cut(s, n=MAX_LINE_CHARS):
    s = clean(s)
    return s if len(s) <= n else s[: n - 1] + "…"


def load_cursor(path):
    try:
        with open(path) as f:
            c = json.load(f)
        if isinstance(c, dict) and c.get("v") == 1 and isinstance(c.get("ch"), dict) and isinstance(c.get("repos"), dict):
            return c
    except Exception:
        pass
    return None


def save_cursor(path, c):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(c, f, ensure_ascii=False)
    os.replace(tmp, path)


def new_cursor():
    return {"v": 1, "ch": {}, "repos": {}, "dircache": {}, "last_scan": 0, "rearm": {}}


def end_pos(path):
    try:
        st = os.stat(path)
        return {"ino": st.st_ino, "off": st.st_size}
    except OSError:
        return {"ino": 0, "off": 0}


def read_new(path, pos):
    """流れの新しい完結行を返し、pos を進める。inode が変わっていたら(rotate)旧ファイルの残り→新ファイルの順。"""
    lines = []
    try:
        st = os.stat(path)
    except OSError:
        return lines
    chunks = []  # (file, offset)
    if pos.get("ino") and pos["ino"] != st.st_ino:
        base = os.path.basename(path)
        d = os.path.dirname(path)
        try:
            for n in sorted(os.listdir(d)):
                if n.startswith(base + ".") and not n.endswith(".tmp"):
                    p = os.path.join(d, n)
                    try:
                        if os.stat(p).st_ino == pos["ino"]:
                            chunks.append((p, pos["off"], False))
                    except OSError:
                        pass
        except OSError:
            pass
        pos["ino"], pos["off"] = st.st_ino, 0
    elif not pos.get("ino"):
        pos["ino"], pos["off"] = st.st_ino, 0
    chunks.append((path, pos["off"], True))
    for p, off, cur in chunks:
        try:
            with open(p, "rb") as f:
                f.seek(off)
                data = f.read()
        except OSError:
            continue
        if cur:
            k = data.rfind(b"\n")
            data = data[: k + 1] if k >= 0 else b""
            pos["off"] = off + len(data)
        for raw in data.decode("utf-8", "replace").split("\n"):
            if raw.strip():
                lines.append(raw)
    return lines


def fmt_flow(raw, ch):
    p = raw.split("\t")
    if len(p) < 5:
        return None
    ts, frm, kind, target, summ = p[0], p[1], p[2], p[3], p[4]
    ref = p[5] if len(p) > 5 else "-"
    t = ""
    try:
        t = hhmm(parse_iso(ts))
    except Exception:
        pass
    s = "[%s%s] %s %s%s: %s" % (kind, "" if ch == HARNESS else "/" + ch, frm, t, "" if target in ("-", "") else " " + target, summ)
    if ref not in ("-", ""):
        s += " (" + ref + ")"
    return kind, cut(s)


def extract_paths(tool_calls):
    """tool の引数から dir 候補を取る(tool_response は見ない)。"""
    out = []
    for c in tool_calls or []:
        ti = c.get("tool_input") if isinstance(c, dict) else None
        if not isinstance(ti, dict):
            continue
        for k in ("file_path", "path", "notebook_path"):
            v = ti.get(k)
            if isinstance(v, str) and v.startswith("/"):
                out.append(v)
        cmd = ti.get("command")
        if isinstance(cmd, str):
            for m in re.finditer(r"(?:git\s+-C|cd)\s+(?:\"([^\"]+)\"|'([^']+)'|(\S+))", cmd):
                v = m.group(1) or m.group(2) or m.group(3)
                if v:
                    out.append(os.path.expanduser(v))
    res = []
    for p in out:
        d = p if os.path.isdir(p) else os.path.dirname(p)
        while d and d != "/" and not os.path.isdir(d):
            d = os.path.dirname(d)
        if d and d not in res:
            res.append(d)
    return res[:20]


def bundle_has_sync(tool_calls):
    for c in tool_calls or []:
        ti = c.get("tool_input") if isinstance(c, dict) else None
        if isinstance(ti, dict) and isinstance(ti.get("command"), str) and SYNC_RE.search(ti["command"]):
            return True
    return False


def hook_main():
    root = home()
    if not os.path.isdir(root):
        return None
    raw = sys.stdin.read()
    try:
        ev = json.loads(raw)
    except Exception:
        return None
    if not isinstance(ev, dict):
        return None
    event = ev.get("hook_event_name")
    sid = ev.get("session_id")
    if event not in ("UserPromptSubmit", "PostToolBatch", "SessionStart") or not isinstance(sid, str) or not sid:
        return None
    _EVENT[0] = event
    sid = safe_name(sid)
    agent = ev.get("agent_id")
    is_sub = bool(agent)
    role = os.environ.get("RADIO_ROLE", "")
    flows_repo = role not in ("makabe", "kashiwagi")
    flows_kinds = ("裁定", "工事") if not flows_repo else None
    t = now()
    cdir = os.path.join(root, "cursor")
    cpath = os.path.join(cdir, sid + ("." + safe_name(str(agent)) if is_sub else ""))
    cur = load_cursor(cpath)
    first = cur is None
    dirty = first
    if first:
        cur = new_cursor()
    my8 = sid[:8]
    source = ev.get("source") if event == "SessionStart" else None
    boards_only = event == "SessionStart" and source in ("resume", "compact")
    tool_calls = ev.get("tool_calls") if event == "PostToolBatch" and isinstance(ev.get("tool_calls"), list) else []
    cwd = ev.get("cwd") if isinstance(ev.get("cwd"), str) else None

    items = []      # (優先, 文字列)  0=札/裁定 1=その他の流れ 2=base 進み
    # 加入の更新(サブエージェントは自分では持たない。親の cursor を読むだけ)
    parent = None
    if is_sub:
        parent = load_cursor(os.path.join(cdir, sid)) or new_cursor()
        repos = parent["repos"]
    else:
        repos = cur["repos"]
        due = first or t - cur.get("last_scan", 0) >= JOIN_SCAN
        if due:
            dirs = []
            if cwd:
                dirs.append(cwd)
            dirs += extract_paths(tool_calls)
            dc = cur["dircache"]
            for d in dirs:
                if d in dc:
                    name = dc[d] or None
                    common = repos.get(name, {}).get("common") if name else None
                    if name and not common:
                        name2, common = resolve_repo(d)
                        name = name2
                else:
                    name, common = resolve_repo(d)
                    if len(dc) > 200:
                        dc.clear()
                    dc[d] = name or ""
                if not name:
                    continue
                r = repos.get(name)
                if r is None:
                    base = pick_base(common)
                    ch_path = channel_file(root, name)
                    r = {"common": common, "base": base, "last_touch": t, "wt": d}
                    if base:
                        r["local"] = read_ref(common, "refs/heads/" + base)
                        r["origin"] = read_ref(common, "refs/remotes/origin/" + base)
                        r["reported"] = r["local"] or r["origin"]
                    repos[name] = r
                    cur["ch"][name] = end_pos(ch_path)   # 乗った時点の末尾から(昔の流れを浴びせない)
                r["last_touch"] = t
                r["wt"] = d
            cur["last_scan"] = t
            dirty = True
        # 6 時間触らなければ降りる / 12 本まで
        for n in [n for n, r in repos.items() if t - r.get("last_touch", 0) > DROP_AFTER]:
            repos.pop(n, None)
            cur["ch"].pop(n, None)
            dirty = True
        while len(repos) > MAX_REPOS:
            n = min(repos, key=lambda k: repos[k].get("last_touch", 0))
            repos.pop(n, None)
            cur["ch"].pop(n, None)
            dirty = True

    chans = [HARNESS] + ([n for n in repos] if not is_sub else [n for n in repos])
    if not flows_repo:
        chans = [HARNESS]
    flow_wanted = not is_sub and not boards_only
    # ---- 流れ ----
    if flow_wanted:
        if HARNESS not in cur["ch"] and first:
            cur["ch"][HARNESS] = end_pos(channel_file(root, HARNESS))
            # 初めて読む: 24 時間以内の裁定を 5 行まで
            try:
                with open(channel_file(root, HARNESS), "rb") as f:
                    f.seek(max(0, cur["ch"][HARNESS]["off"] - 200000))
                    rows = f.read().decode("utf-8", "replace").split("\n")
                rulings = []
                for r_ in rows:
                    p = r_.split("\t")
                    if len(p) >= 5 and p[2] == "裁定":
                        ts = parse_iso(p[0])
                        if ts and t - ts <= 86400 and not p[1].endswith("@" + my8):
                            f_ = fmt_flow(r_, HARNESS)
                            if f_:
                                rulings.append(f_[1])
                for s in rulings[-5:]:
                    items.append((0, s))
            except OSError:
                pass
        elif HARNESS not in cur["ch"]:
            cur["ch"][HARNESS] = {"ino": 0, "off": 0}
        for ch in chans:
            if ch not in cur["ch"]:
                continue
            path = channel_file(root, ch)
            pos = cur["ch"][ch]
            try:
                st = os.stat(path)
            except OSError:
                continue
            if pos.get("ino") == st.st_ino and pos.get("off", 0) >= st.st_size:
                continue                                  # 静かなとき: 大きさの比較だけで済む
            before = dict(pos)
            for raw_ in read_new(path, pos):
                p = raw_.split("\t")
                if len(p) >= 2 and p[1].endswith("@" + my8):
                    continue                              # 自分の行は出さない
                f_ = fmt_flow(raw_, ch)
                if not f_:
                    continue
                if flows_kinds and f_[0] not in flows_kinds:
                    continue
                items.append((0 if f_[0] == "裁定" else 1, f_[1]))
            if pos != before:
                dirty = True

    # ---- base の進み ----
    if flow_wanted and flows_repo and repos:
        sync_touch = set()
        if bundle_has_sync(tool_calls):
            for d in ([cwd] if cwd else []) + extract_paths(tool_calls):
                n_ = cur["dircache"].get(d)
                if n_:
                    sync_touch.add(n_)
        for name, r in repos.items():
            base, common = r.get("base"), r.get("common")
            if not base or not common:
                continue
            loc = read_ref(common, "refs/heads/" + base)
            ori = read_ref(common, "refs/remotes/origin/" + base)
            if loc == r.get("local") and ori == r.get("origin"):
                continue                                   # 静かなとき: ref の比較だけ
            r["local"], r["origin"] = loc, ori
            dirty = True
            if name in sync_touch:                         # 自分で merge した分は出さない
                r["reported"] = loc or ori
                continue
            rep = r.get("reported")
            if not rep:
                r["reported"] = loc or ori
                continue
            subjects, authors, files = [], set(), set()
            moved = False
            for c in (ori, loc):
                if not c or c == rep:
                    continue
                if _git(["--git-dir=" + common, "merge-base", "--is-ancestor", c, rep]) is not None:
                    continue                               # 巻き戻り側は黙る
                out = _git(["--git-dir=" + common, "log", "--format=%an%x09%s", "%s..%s" % (rep, c)])
                if out is None:                            # 付け替え(祖先でない)
                    subjects.append("(枝が付け替わった)")
                else:
                    for l in out.splitlines():
                        a, _, s = l.partition("\t")
                        authors.add(a)
                        subjects.append(s)
                fo = _git(["--git-dir=" + common, "diff", "--name-only", rep, c])
                if fo:
                    files |= set(fo.split())
                rep = c
                moved = True
            r["reported"] = rep
            if not moved:
                continue
            msg = "%s の %s が %d commit 進んだ(%s): %s" % (
                name, base, len(subjects) or 1, "・".join(sorted(authors)) or "?", " / ".join(subjects[:3]))
            if len(subjects) > 3:
                msg += " ほか"
            wt = r.get("wt")
            if wt and files and os.path.isdir(wt):
                mine = set()
                for args in (["diff", "--name-only", "HEAD"], ["diff", "--name-only", "%s...HEAD" % rep]):
                    o = _git(["-C", wt] + args)
                    if o:
                        mine |= set(o.split())
                inter = sorted(files & mine)
                if inter:
                    msg += "。重なり: " + " ".join(inter[:3]) + (" ほか" if len(inter) > 3 else "")
                else:
                    msg += "。重なりなし"
            items.append((2, cut(msg)))

    # ---- 札 ----
    board_chans = chans if not is_sub else [HARNESS] + (list(repos) if flows_repo else [])
    show_all_boards = first or boards_only
    boards = list_boards(root, board_chans) if os.path.isdir(os.path.join(root, "board")) else []
    if boards:
        step_text = ""
        if event == "PostToolBatch" and tool_calls:
            try:
                step_text = json.dumps(tool_calls, ensure_ascii=False)[:400000].lower()
            except Exception:
                step_text = ""
        for b in boards:
            key = b["ch"] + "/" + b["dev"]
            expired = b["until_ts"] is not None and b["until_ts"] < t
            if show_all_boards and not is_sub:
                items.insert(0, (0, cut(board_line(b, t, expired))))
                cur["rearm"][key] = t
                dirty = True
            elif not expired and step_text:
                matches = b["match"] or [b["dev"]]
                if any(m.lower() in step_text for m in matches):
                    if t - cur["rearm"].get(key, 0) >= REARM:
                        items.insert(0, (0, cut(board_line(b, t))))
                        cur["rearm"][key] = t
                        dirty = True

    if dirty:
        try:
            os.makedirs(cdir, exist_ok=True)
            save_cursor(cpath, cur)
        except Exception as e:
            log(root, "cursor 書けない: %s" % e)
    if not items:
        return None
    items.sort(key=lambda x: x[0])           # 安定ソート: 0 → 1 → 2、同順位は流れた順
    lines = [s for _, s in items]
    has_ruling = any(p == 0 and s.startswith("[裁定") for p, s in items)
    head = HEADER + (HEADER_RULING if has_ruling else "")
    out = []
    budget = MAX_CHARS - len(head) - 1
    shown = 0
    for s in lines:
        if shown >= MAX_LINES:
            break
        reserve = 40 if shown < len(lines) - 1 else 0
        if len(s) + 1 + reserve > budget:
            break
        out.append(s)
        budget -= len(s) + 1
        shown += 1
    rest = len(lines) - shown
    if rest > 0:
        out.append("ほか %d 行は `radio tail`" % rest)
    return head + "\n" + "\n".join(out)


def log(root, msg):
    try:
        with open(os.path.join(root, "radio.log"), "a") as f:
            f.write("%s %s\n" % (iso(now()), clean(msg)[:300]))
    except Exception:
        pass


def hook_entry():
    """hook の入口。何があっても exit 0、壊れたら何も出さず radio.log に 1 行。"""
    try:
        text = hook_main()
        if text:
            sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": _EVENT[0], "additionalContext": text}}, ensure_ascii=False))
    except BaseException as e:   # noqa: B902
        try:
            log(home(), "hook 失敗: %r" % (e,))
        except Exception:
            pass
    return 0


_EVENT = ["UserPromptSubmit"]
