#!/usr/bin/env bash
# Claude Code(claude -p / 対話 claude 両方)の PreToolUse hook。
# 「commit は役名(git-as <役>)、pax は人見本人だけ」(feedback-commit-as-role.md)を
# git hook ではなくこの hook で担保する ── git hook は人見本人の端末 commit まで塞いでしまうため
# 使わない(役員 人見 2026-09-25)。
#
# 対象は Bash tool の command に「plain `git` 経由で commit か annotated tag を作りうる操作」が
# 現れたときだけ。当初は `commit` だけだったが、素の `git merge --no-ff` が pax 名義の merge commit を
# main に入れた(2026-10-09)ので、commit を作る他のサブコマンドまで広げた(大橋[PJM]の依頼)。
#   - commit / commit-tree             : 常に block
#   - merge                            : --ff-only --abort --quit --no-commit --squash のどれかが無ければ block
#   - pull                             : --ff-only が無ければ block(merge か rebase が走るため)
#   - revert / cherry-pick             : --abort --quit -n --no-commit のどれかが無ければ block
#   - rebase                           : --abort --quit --show-current-patch --edit-todo 以外は block
#   - am                               : --abort --quit --show-current-patch 以外は block
#   - tag                              : annotated / signed を作る形(-a -s -u -m -F とその長形・束ね)だけ block、
#                                        lightweight と -l -d -v は通す
# `git-as <役> …` は何でも通す(git-as 自身が内部で `git -c user.name=... <引数>` を exec するが、typed
# command は "git-as" で始まるので判定にはかからない)。迷ったら block(弾きすぎ側)。
# stash / notes も commit を作るが、push されない ref なので射程外。
#
# block の返し方は gate-guard-claude.sh / worktree-guard-claude.sh と同じ実測:
# Claude Code の PreToolUse は --dangerously-skip-permissions(bypass)下では
# exit 2 + stderr でだけ確実に block する(exit 0 + stdout の JSON deny は bypass 下で無視される)。
#
# 判定は python3。command 文字列をクォート・heredoc・`$(…)`・バッククォートを尊重して自前で走査し、
# `; && || | & ( ) 改行` で区切った各セグメントを独立に見る(`git commit -m "a; b"` を割らない、
# `(cd x && git commit)` の括弧も境界)。heredoc の本文は判定から外す(git-as の commit message に
# 「git merge --no-ff で …」と書いても止めない)。セグメントは先頭の env / command / exec / nohup /
# time / sudo 等と `VAR=val` を剥ぎ、先頭語を basename で見る(`/usr/bin/git`)。`-C <path>` `-c k=v`
# 等のグローバルフラグの値を飛ばしてサブコマンドを取るので、`--grep=commit` のような「commit という語を
# 含むだけの引数」は誤検知しない。`bash -c '…'` と `eval` の中身も同じ判定に掛ける。
# パースに失敗した(クォートの閉じ忘れ等)ときは素通りにせず、`git` の後にサブコマンド語が来る形を
# 緩い正規表現で拾って block 側に倒す。

set -u

stdin_json="$(cat 2>/dev/null || true)"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool_name" = "Bash" ] || exit 0

command_str="$(printf '%s' "$stdin_json" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_str" ] || exit 0

violation="$(python3 - "$command_str" <<'PY'
import os
import re
import sys

cmd = sys.argv[1]

COMMIT_SUBS = (
    "commit|commit-tree|merge|pull|revert|cherry-pick|rebase|am|tag"
)
# パース失敗時の保険。`git` の後ろ 8 語以内にサブコマンド語が来る形を拾う(`git-as` は拾わない)。
LOOSE = re.compile(
    r"(?<![\w-])git(?![\w-])(?:\s+\S+){0,8}?\s+(?:%s)(?![\w-])" % COMMIT_SUBS
)

MAX_DEPTH = 5


class ParseError(Exception):
    pass


class Scanner:
    """シェル文字列を、クォート・heredoc・コマンド置換を尊重してセグメント(単語列)に割る。"""

    def __init__(self, s):
        self.s = s
        self.segs = []  # [(words, raw)]

    # "..." の中身。$( ) と `…` はコマンド置換として走査する
    def dquote(self, i, cur):
        s, n = self.s, len(self.s)
        while i < n:
            c = s[i]
            if c == '"':
                return i + 1
            if c == "\\" and i + 1 < n:
                if s[i + 1] == "\n":
                    i += 2
                elif s[i + 1] in '$`"\\':
                    cur.append(s[i + 1])
                    i += 2
                else:
                    cur.append(c)
                    i += 1
                continue
            if c == "$" and s.startswith("$(", i):
                i = self.run(i + 2, nested=True)
                cur.append("SUBST")
                continue
            if c == "`":
                i = self.backtick(i)
                cur.append("SUBST")
                continue
            cur.append(c)
            i += 1
        raise ParseError("unterminated double quote")

    def backtick(self, i):
        s, n = self.s, len(self.s)
        j = i + 1
        while j < n and s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        if j >= n:
            raise ParseError("unterminated backtick")
        sub = Scanner(s[i + 1:j].replace("\\`", "`"))
        sub.run(0)
        self.segs.extend(sub.segs)
        return j + 1

    def run(self, i, nested=False):
        s, n = self.s, len(self.s)
        words = []
        cur = []
        st = {"inword": False, "redir": False, "start": i}
        heredocs = []
        depth = 0

        def flush_word():
            if st["inword"]:
                w = "".join(cur)
                if st["redir"]:
                    st["redir"] = False  # リダイレクト先は単語に数えない
                else:
                    words.append(w)
            cur.clear()
            st["inword"] = False

        def flush_seg(end):
            flush_word()
            st["redir"] = False
            if words:
                self.segs.append((list(words), s[st["start"]:end].strip()))
                words.clear()

        def redirect_prefix():
            # `2>`/`0<<` の fd 数字は単語に数えない
            if st["inword"] and "".join(cur).isdigit():
                cur.clear()
                st["inword"] = False
            else:
                flush_word()

        while i < n:
            c = s[i]
            if c == "\\":
                if i + 1 < n and s[i + 1] == "\n":
                    i += 2
                elif i + 1 < n:
                    cur.append(s[i + 1])
                    st["inword"] = True
                    i += 2
                else:
                    i += 1
                continue
            if c == "'":
                j = s.find("'", i + 1)
                if j < 0:
                    raise ParseError("unterminated single quote")
                cur.append(s[i + 1:j])
                st["inword"] = True
                i = j + 1
                continue
            if c == '"':
                i = self.dquote(i + 1, cur)
                st["inword"] = True
                continue
            if c == "$" and s.startswith("$'", i):
                j = i + 2
                while j < n and s[j] != "'":
                    j += 2 if s[j] == "\\" else 1
                if j >= n:
                    raise ParseError("unterminated $'")
                cur.append(s[i + 2:j])
                st["inword"] = True
                i = j + 1
                continue
            if c == "$" and s.startswith("$(", i):
                i = self.run(i + 2, nested=True)
                cur.append("SUBST")
                st["inword"] = True
                continue
            if c == "`":
                i = self.backtick(i)
                cur.append("SUBST")
                st["inword"] = True
                continue
            if c in " \t":
                flush_word()
                i += 1
                continue
            if c == "#" and not st["inword"]:
                j = s.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "\n":
                flush_seg(i)
                i += 1
                for delim, strip in heredocs:
                    while i < n:
                        j = s.find("\n", i)
                        line = s[i:] if j < 0 else s[i:j]
                        i = n if j < 0 else j + 1
                        if (line.lstrip("\t") if strip else line) == delim:
                            break
                heredocs = []
                st["start"] = i
                continue
            if c == "<" and s.startswith("<<", i) and not s.startswith("<<<", i):
                redirect_prefix()
                j = i + 2
                strip = False
                if j < n and s[j] == "-":
                    strip = True
                    j += 1
                while j < n and s[j] in " \t":
                    j += 1
                delim = []
                while j < n and s[j] not in " \t\n;&|()<>":
                    ch = s[j]
                    if ch in "'\"":
                        k = s.find(ch, j + 1)
                        if k < 0:
                            raise ParseError("unterminated heredoc delimiter")
                        delim.append(s[j + 1:k])
                        j = k + 1
                    elif ch == "\\" and j + 1 < n:
                        delim.append(s[j + 1])
                        j += 2
                    else:
                        delim.append(ch)
                        j += 1
                heredocs.append(("".join(delim), strip))
                i = j
                continue
            if c in "<>" and i + 1 < n and s[i + 1] == "(":
                i = self.run(i + 2, nested=True)  # プロセス置換 <( ) >( )
                cur.append("SUBST")
                st["inword"] = True
                continue
            if c in "<>" or (c == "&" and s.startswith("&>", i)):
                redirect_prefix()
                m = re.compile(r"&>>|&>|>>|>&|<&|>\||<>|>|<").match(s, i)
                i = m.end()
                st["redir"] = True
                continue
            if c in ";|&()":
                flush_seg(i)
                if c == ";":
                    i += 1
                elif c == "|":
                    i += 2 if s.startswith(("||", "|&"), i) else 1
                elif c == "&":
                    i += 2 if s.startswith("&&", i) else 1
                elif c == "(":
                    depth += 1
                    i += 1
                else:  # ")"
                    i += 1
                    if depth > 0:
                        depth -= 1
                    elif nested:
                        return i
                st["start"] = i
                continue
            cur.append(c)
            st["inword"] = True
            i += 1
        flush_seg(n)
        if nested:
            raise ParseError("unterminated command substitution")
        return n


ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
RESERVED = {"{", "}", "!", "if", "then", "else", "elif", "do", "while", "until"}
# 先頭に付く実行ラッパー: 名前 -> 値を取るオプション
WRAPPERS = {
    "env": {"-u", "-C", "-S", "--unset", "--chdir"},
    "command": set(),
    "builtin": set(),
    "exec": {"-a"},
    "nohup": set(),
    "setsid": set(),
    "time": {"-f", "-o", "--format", "--output"},
    "nice": {"-n", "--adjustment"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-I", "-n", "-L", "-P", "-d", "-s", "-E", "-a"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t",
             "--user", "--group", "--host", "--prompt", "--chdir"},
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def strip_prefix(words):
    w = list(words)
    while w:
        h = w[0]
        if ENV_ASSIGN.match(h) or h in RESERVED:
            w = w[1:]
            continue
        b = os.path.basename(h)
        if b in WRAPPERS:
            vflags = WRAPPERS[b]
            w = w[1:]
            while w:
                a = w[0]
                if a == "--":
                    w = w[1:]
                    break
                if a in vflags:
                    w = w[2:]
                elif (a.startswith("-") and a != "-") or ENV_ASSIGN.match(a):
                    w = w[1:]
                else:
                    break
            if b == "timeout" and w:
                w = w[1:]  # 時間指定
            continue
        break
    return w


GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                   "--config-env", "--super-prefix"}


def split_git(args):
    """git のグローバルフラグを飛ばして (サブコマンド, 残りの引数) を返す。"""
    i = 0
    while i < len(args):
        a = args[i]
        if a in GIT_VALUE_FLAGS:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        return a, args[i + 1:]
    return None, []


def options(args, value_flags):
    """-- の手前のオプション語を返す。値を取るフラグの次の語は飛ばす。"""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return
        if a in value_flags:
            i += 2
            continue
        yield a
        i += 1


NO_COMMIT_CLUSTER = re.compile(r"^-[nxes]*n[nxes]*$")  # cherry-pick/revert の -n(束ね含む)


def tag_makes_annotated(args):
    long_names = ("annotate", "sign", "local-user", "message", "file")
    value_long = {"--sort", "--contains", "--no-contains", "--merged", "--no-merged",
                  "--points-at", "--format", "--column"}
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return False
        if a.startswith("--"):
            name = a[2:].split("=", 1)[0]
            if len(name) >= 2 and any(l.startswith(name) for l in long_names):
                return True
            if "=" not in a and a in value_long:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            if any(ch in "asumF" for ch in a[1:]):  # -u -m -F は値を取るが、どのみち block
                return True
        i += 1
    return False


def blocks(sub, args):
    def has(allow, vflags=()):
        return any(o in allow for o in options(args, set(vflags)))

    if sub in ("commit", "commit-tree"):
        return True
    if sub == "merge":
        return not has({"--ff-only", "--abort", "--quit", "--no-commit", "--squash"},
                       {"-m", "-F", "-s", "-X", "--message", "--file", "--strategy",
                        "--strategy-option", "--into-name"})
    if sub == "pull":
        return not has({"--ff-only"}, {"-s", "-X", "--strategy", "--strategy-option",
                                       "--upload-pack"})
    if sub in ("revert", "cherry-pick"):
        vf = {"-m", "--mainline", "-X", "--strategy-option", "--strategy"}
        allow = {"--abort", "--quit", "-n", "--no-commit"}
        return not (has(allow, vf)
                    or any(NO_COMMIT_CLUSTER.match(o) for o in options(args, vf)))
    if sub == "rebase":
        return not has({"--abort", "--quit", "--show-current-patch", "--edit-todo"},
                       {"-s", "-X", "-x", "--exec", "--onto", "-C", "--strategy",
                        "--strategy-option", "--whitespace"})
    if sub == "am":
        return not has({"--abort", "--quit", "--show-current-patch"},
                       {"-p", "-C", "--directory", "--exclude", "--include",
                        "--whitespace", "--patch-format"})
    if sub == "tag":
        return tag_makes_annotated(args)
    return False


def analyze(text, depth=0):
    """違反があれば該当セグメントの文字列、無ければ None。"""
    if depth > MAX_DEPTH:
        return text[:300]
    try:
        sc = Scanner(text)
        sc.run(0)
    except ParseError:
        return text[:300] if LOOSE.search(text) else None
    for words, raw in sc.segs:
        v = check_segment(words, raw, depth)
        if v:
            return v
    return None


def check_segment(words, raw, depth):
    w = strip_prefix(words)
    if not w:
        return None
    name = os.path.basename(w[0])
    if name == "git-as":
        return None  # 正規経路、許可
    if name in SHELLS:
        for k, a in enumerate(w[1:], 1):
            if a.startswith("-") and not a.startswith("--") and "c" in a and k + 1 < len(w):
                return raw if analyze(w[k + 1], depth + 1) else None
        return None
    if name == "eval":
        return raw if analyze(" ".join(w[1:]), depth + 1) else None
    if name == "git":
        sub, args = split_git(w[1:])
    elif name.startswith("git-"):
        sub, args = name[4:], w[1:]
    else:
        return None
    if sub is None:
        return None
    return raw if blocks(sub, args) else None


try:
    v = analyze(cmd)
except Exception:
    v = cmd[:300] if LOOSE.search(cmd) else None

if v:
    print(v)
    sys.exit(0)
sys.exit(1)
PY
)"
python_status=$?

if [ "$python_status" -eq 0 ] && [ -n "$violation" ]; then
  {
    echo "commit か annotated tag を作りうる操作(commit / commit-tree / merge / pull / revert / cherry-pick / rebase / am / tag -a -s -m -u -F)は、素の git で打たない。commit も merge も git-as <役> … を使う。"
    echo "例: git-as 大橋 merge --no-ff <branch> -m \"…\""
    echo "素の git で通るのは commit を作らない形だけ(merge --ff-only / --abort / --quit / --no-commit / --squash、pull --ff-only、revert・cherry-pick・rebase・am の --abort など、lightweight tag)。"
    echo "出典: 役員 人見 2026-09-25。merge 等への拡張は 2026-10-09 大橋[PJM]の依頼。"
    echo "該当セグメント: $violation"
  } >&2
  exit 2
fi

exit 0
