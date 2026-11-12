#!/usr/bin/env bash
# Claude Code の Stop hook。手を離したまま idle になって放置されるのを止める
# (役員 人見 2026-11-13、形は鷹野が決定、実装は庵野)。
#
# turn が終わるとき、次のどれかを満たしていなければ turn end を弾く(exit 2、
# stderr の文が Claude に返って続きを促す)。
#   1. このセッションの claude のプロセスの子孫として `scripts/timer.sh` が生きている
#      (bg の便を見るなら `timer.sh 1800 <label> <log>`、人見の答えを待つなら
#       `timer.sh 3000 wait-hitomi`。run_in_background の Bash で張る)
#   2. この turn の中(transcript の最後の本物の user の発言より後)で Skill の
#      tool_use `close-session` を使った(本物の user が打った /close-session も数える)
# 外すもの(通す):
#   - 入力 JSON の stop_hook_active が true(2 回目は通す。弾き続ける輪を作らない)
#   - headless(`claude -p` / `--print`)。祖先の claude のプロセスの引数で見る。
#     Desktop の対話のセッションも --output-format stream-json で起きているので、
#     それでは判別しない
#   - このセッションの claude の pid が引けないとき、transcript が読めないとき
#     (fail open、理由を stderr に 1 行)
#
# 「本物の user の発言」は message を持つ type=user の行のうち、isMeta でなく(Skill の
# 本文・Stop hook の返し文は isMeta)、tool_result でなく、origin.kind が
# task-notification / peer でないもの。timer の鳴り(task-notification)は境にしない。
#
# 速さ:網に出ない。/proc を舐めるだけ。transcript は大きいので末尾から読み、
# tool_result の巨大な行は parse しない。
#
# block は exit 2 + stderr(Claude Code の Stop は JSON の decision を無視する。
# hooks/session-post-guard.sh のコメント)。

set -u

stdin_json="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0

exec python3 -I - "$stdin_json" <<'PY'
import json
import os
import sys

BLOCK_MSG = (
    "turn を終える前に、timer.sh を張るか close-session で締める。"
    "bg の便を見るなら timer.sh 1800、人見の答えを待つなら timer.sh 3000 wait-hitomi。"
    "鳴って答えが無ければ close-session。"
)
CLOSE_TAG = "<command-name>/close-session</command-name>"


def fail_open(why):
    print("turn-end-guard: " + why + "(判定できないので通す)", file=sys.stderr)
    sys.exit(0)


def read_stat(pid):
    """(ppid, state) を返す。引けなければ None。comm に ')' や空白があっても最後の ')' で切る。"""
    try:
        with open("/proc/%d/stat" % pid, "rb") as f:
            s = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    rest = s[s.rfind(")") + 1:].split()
    if len(rest) < 2:
        return None
    try:
        return int(rest[1]), rest[0]
    except ValueError:
        return None


def read_argv(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            raw = f.read()
    except OSError:
        return []
    return [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a != b""]


def read_comm(pid):
    try:
        with open("/proc/%d/comm" % pid, "rb") as f:
            return f.read().decode("utf-8", "replace").strip()
    except OSError:
        return ""


def is_claude(pid):
    argv = read_argv(pid)
    if read_comm(pid) == "claude":
        return True
    if argv:
        if os.path.basename(argv[0]) == "claude":
            return True
        if os.path.basename(argv[0]) in ("node", "bun") and len(argv) > 1 \
                and os.path.basename(argv[1]) == "claude":
            return True
    return False


def ancestors(pid):
    """pid から親を辿った pid 列(自身を含む)。"""
    chain = []
    seen = set()
    while pid and pid > 1 and pid not in seen:
        seen.add(pid)
        chain.append(pid)
        st = read_stat(pid)
        if st is None:
            break
        pid = st[0]
    return chain


def is_timer(pid, state):
    """`bash .../timer.sh ...`(stdbuf の exec 後もこの形)。zombie は数えない。"""
    if state == "Z":
        return False
    argv = read_argv(pid)
    if len(argv) < 2 or os.path.basename(argv[0]) not in ("bash", "sh", "dash"):
        return False
    for a in argv[1:]:
        if a.startswith("-"):
            continue
        return os.path.basename(a) == "timer.sh"
    return False


def live_timer_under(root):
    children = {}
    states = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        st = read_stat(pid)
        if st is None:
            continue
        children.setdefault(st[0], []).append(pid)
        states[pid] = st[1]
    stack = list(children.get(root, []))
    seen = set()
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        if is_timer(pid, states.get(pid, "")):
            return True
        stack.extend(children.get(pid, []))
    return False


def is_real_user(row):
    """本物の user の発言か。"""
    if row.get("type") != "user" or row.get("isMeta") or row.get("isSidechain"):
        return False
    origin = row.get("origin")
    if isinstance(origin, dict) and origin.get("kind") in ("task-notification", "peer"):
        return False
    if row.get("turnOrigin") in ("task_notification", "peer", "system"):
        return False
    content = (row.get("message") or {}).get("content")
    texts = []
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for b in content:
            if isinstance(b, dict):
                if b.get("type") == "tool_result":
                    return False
                if isinstance(b.get("text"), str):
                    texts.append(b["text"])
    else:
        return False
    if not texts:
        return False
    head = texts[0].lstrip()
    if head.startswith("<task-notification>") or head.startswith("This session is being continued"):
        return False
    return True


def user_text(row):
    content = (row.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    out = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and isinstance(b.get("text"), str):
                out.append(b["text"])
    return "\n".join(out)


def is_close_skill(row):
    if row.get("type") != "assistant" or row.get("isSidechain"):
        return False
    content = (row.get("message") or {}).get("content")
    if not isinstance(content, list):
        return False
    for b in content:
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Skill":
            skill = str((b.get("input") or {}).get("skill") or "")
            if skill.split(":")[-1] == "close-session":
                return True
    return False


def reverse_lines(path, chunk=1 << 20):
    """末尾から 1 行ずつ(bytes)返す。"""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        pos = f.tell()
        tail = b""
        while pos > 0:
            step = min(chunk, pos)
            pos -= step
            f.seek(pos)
            buf = f.read(step) + tail
            parts = buf.split(b"\n")
            tail = parts[0]
            for line in reversed(parts[1:]):
                if line.strip():
                    yield line
        if tail.strip():
            yield tail


def closed_in_this_turn(path):
    """最後の本物の user の発言より後(その発言自体を含む)に close-session があるか。"""
    for raw in reverse_lines(path):
        # tool_result の行は user の発言でも close-session の tool_use でもない。巨大なので parse しない
        if b'"type":"tool_result"' in raw:
            continue
        has_close = b"close-session" in raw
        has_user = b'"user"' in raw
        if not (has_close or has_user):
            continue
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        if has_close and is_close_skill(row):
            return True
        if has_user and is_real_user(row):
            # 打たれた /close-session はこの発言自体で締めた扱い
            return CLOSE_TAG in user_text(row)
    return False  # 本物の user の発言が見つからない=turn の始まりまで close は無かった


stdin_json = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    hook_input = json.loads(stdin_json)
except ValueError:
    fail_open("入力 JSON を読めない")
if not isinstance(hook_input, dict):
    fail_open("入力 JSON が object でない")

if hook_input.get("stop_hook_active") is True:
    sys.exit(0)

chain = ancestors(os.getpid())
claudes = [p for p in chain if is_claude(p)]
if not claudes:
    fail_open("このセッションの claude の pid が引けない")
session_pid = claudes[0]

for p in claudes:
    if any(a in ("-p", "--print") for a in read_argv(p)[1:]):
        sys.exit(0)  # headless

if live_timer_under(session_pid):
    sys.exit(0)

transcript = hook_input.get("transcript_path") or ""
if not transcript:
    fail_open("transcript_path が無い")
try:
    ok = closed_in_this_turn(transcript)
except OSError:
    fail_open("transcript を読めない")
if ok:
    sys.exit(0)

print(BLOCK_MSG, file=sys.stderr)
sys.exit(2)
PY
