#!/usr/bin/env bash
# claude-kashiwagi.sh(Opus 柏木、実行経路C)専用の PreToolUse hook。
#
# 役員 人見 2026-09-22 00:0x の訂正: 「レビュアーは書き込み無し」は締めすぎ。
# **柏木は作業木(cwd = 贄川が渡す -C の先)の中では Write / Edit / git commit ができる**
# (P2 の自己 commit は残す、delegation.md:147 のまま)。**禁じるのは作業木の外への書き込みだけ**
# ── 例: ~/.codex-agents/runs/**(自分の run_dir も他の run_dir も)、~/canonical/**、~/.claude/**、
# ~/.codex/**、~/bin/**。
#
# Write/Edit/NotebookEdit は `--permission-mode acceptEdits` が「cwd 内は自動承認、cwd 外は拒否」を
# 素の挙動として持つ(実測、庵野 2026-09-22。--disallowedTools の path 付き rule は
# --dangerously-skip-permissions 下で完全に無視されるため使わない。acceptEdits は skip-permissions では
# ないので disallowedTools 自体は効くはずだが、そもそも acceptEdits の cwd スコープだけで十分だった)。
#
# **Bash は acceptEdits でもスコープが掛からない**(実測: cwd 外へのリダイレクト書き込み・rm が
# 無条件で成功した)。この hook はその Bash 経路を塞ぐ ── 書き込み系コマンドで、対象パスが
# 上記の禁止プレフィックスに該当するときだけ block する。
#
# **root 配下を常に許可する例外(carve-out)は env CLAUDE_KASHIWAGI_GATE=2 のときだけ有効**
# (役員 人見 2026-09-22 の指摘)。ゲート1(`-f plan.md`)は `-C` が贄川の run_dir 自身(=
# `~/.codex-agents/runs/**` の中)なので、carve-out を効かせると「作業木の外は禁止」のはずが
# 「run_dir(plan.md・他ゲートの所見)への書き込み許可」になってしまう ── PoC の事故
# (閉じた run の gate2.md 上書き)と同じ穴。ゲート1・ゲート番号不明の呼び出しは carve-out 無し
# (root 自身が禁止プレフィックス配下なら、root 配下への書き込みも block される)。ゲート2
# (`-f findings.md`、`-C` は作業木)だけ root 配下を許可する。
#
# **相対パスは hook 入力の cwd(無ければ $PWD)から解決してから判定する**(庵野 2026-10-07、ゲート1の cwd は
# run_dir 自身なので `echo x > plan2.md` が絶対パスしか見ない旧 hook をすり抜けて run_dir に書けた)。
# **新しい判定は許可リスト方式**(鷹野の裁定 2026-10-07: `cd ..` で作業木の親・~ に書けた穴を塞ぐ)。解決した先が
# /tmp 以下・/dev/null・/dev/stdout・/dev/stderr・/dev/fd/*・/dev/tty、ゲート2だけ加えて root 以下、のどれかでなければ block
# (ゲート1・番号不明は root も許可しない)。/tmp は柏木の一時出力を止めないためで、harness の状態・リポのどちらでもない。
# 書き込み先として読むのは リダイレクト(> >> >| &> >&)・tee・rm/mv/cp/ln/mkdir/touch/truncate/chmod 等の引数・
# dd of=・sed -i・find -delete/-exec/-fprint の起点・`bash -c`/`eval` の中身。`cd` を挟んだ複合コマンドは
# cd 先を追う(cd 先が変数・`cd -`・サブシェル・パイプ内などで決まらなければ cwd 不明)。**判定が付かないもの
# (変数展開・コマンド置換・ブレース展開・ディレクトリ部分の glob・cwd 不明での相対パス・xargs 経由)は
# 安全側で block する**(ゲート2でも)。絶対パス・~ のトークンを丸ごと見る従来の判定はそのまま残す。
#
# block の返し方は gate-guard-claude.sh と同じ実測(Claude Code は exit 2 + stderr でだけ block)。

set -u

stdin_json="$(cat 2>/dev/null || true)"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool_name" = "Bash" ] || exit 0

command_str="$(printf '%s' "$stdin_json" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_str" ] || exit 0

hook_cwd="$(printf '%s' "$stdin_json" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$hook_cwd" ] || hook_cwd="$PWD"

root="${CLAUDE_KASHIWAGI_ROOT:-}"
[ -n "$root" ] || exit 0
gate="${CLAUDE_KASHIWAGI_GATE:-}"

block() {
  echo "作業木の外への書き込みを検出(claude-kashiwagi): $1" >&2
  exit 2
}

# 書き込み系コマンドかどうかの判定(P2 の自己 commit は許すので git commit/add 単体は書き込み扱いに含めない
# ── 対象パス次第で下の python チェックに掛かる。push/reset --hard/checkout -- は不可逆側なので含める)。
is_write=0
if printf '%s' "$command_str" | grep -Eq '(^|[^0-9&])>>?[^&]'; then
  if ! printf '%s' "$command_str" | grep -Eq '^\s*[^>]*>\s*/dev/null\s*$'; then
    is_write=1
  fi
fi
if printf '%s' "$command_str" | grep -Eq '\btee\b'; then
  case "$command_str" in
    *"tee /dev/null"*|*"tee -a /dev/null"*) ;;
    *) is_write=1 ;;
  esac
fi
if printf '%s' "$command_str" | grep -Eq '\b(rm|mv|cp|ln|mkdir|touch)[[:space:]]'; then
  is_write=1
fi
if printf '%s' "$command_str" | grep -Eq '\b(sed[[:space:]]+-i|truncate[[:space:]]|dd[[:space:]]+of=|chmod[[:space:]]+\+w|git[[:space:]]+(commit|add|push|reset[[:space:]]+--hard|checkout[[:space:]]+--))'; then
  is_write=1
fi

# 上の is_write は従来の判定(絶対パス・~ のトークンを丸ごと見る走査を掛けるかどうか)。読み取りコマンドが
# 禁止プレフィックスを読むのを止めないよう、この走査は is_write=1 のときだけ。相対パス・変数・cd・`N>file`・
# `&>`・`dd if=… of=…`・`find -delete`・xargs の判定は、書き込み先として読めた語だけを見るので常に掛ける
# (is_write の正規表現は `2>file` `&>file` を除外していて、ここが相対パスの穴の入口でもあった)。
violation="$(python3 - "$root" "$command_str" "$gate" "$hook_cwd" "$is_write" <<'PY'
import os
import re
import sys

root = os.path.realpath(os.path.expanduser(sys.argv[1]))
cmd = sys.argv[2]
gate = sys.argv[3]
root_carve_out = (gate == "2")

forbidden_prefixes = [
    os.path.realpath(os.path.expanduser("~/.codex-agents")),
    os.path.realpath(os.path.expanduser("~/canonical")),
    os.path.realpath(os.path.expanduser("~/.claude")),
    os.path.realpath(os.path.expanduser("~/.codex")),
    os.path.realpath(os.path.expanduser("~/bin")),
]

# 絶対パス・~ 始まりのトークンを抽出(空白・引用符・パイプ・リダイレクト記号で区切る簡易抽出)。
old_pass = len(sys.argv) > 5 and sys.argv[5] == "1"
tokens = re.findall(r'(?:~|/)[^\s\'"|;&<>]+', cmd) if old_pass else []
for tok in tokens:
    tok = tok.rstrip(").,;")
    path = os.path.expanduser(tok)
    if not os.path.isabs(path):
        continue
    norm = os.path.normpath(path)
    if root_carve_out and (norm == root or norm.startswith(root + os.sep)):
        continue
    for prefix in forbidden_prefixes:
        if norm == prefix or norm.startswith(prefix + os.sep):
            print(norm)
            sys.exit(0)

# ── 相対パス・変数・cd を挟んだ書き込み先の判定(2026-10-07 追加) ──
# 上の絶対パス・~ のトークン走査(禁止プレフィックス)は従来のまま二重の網として残す。ここでは書き込み先として
# 読めた語を、hook 入力の cwd から解決して**許可リスト**と突き合わせる(/tmp 以下・/dev/null 等・ゲート2は root 以下)。
# 判定が付かないものは安全側で違反扱いにする。
import shlex

cwd_arg = sys.argv[4] if len(sys.argv) > 4 else ""
start_cwd = os.path.realpath(cwd_arg) if cwd_arg else os.path.realpath(os.getcwd())
home = os.path.expanduser("~")
home_expandable = re.search(r"\bHOME=", cmd) is None

PUNCT = set(";&|<>()\n")
OPRE = re.compile(r"&>>|&>|>>|>\||>&|<<<|<<|<&|;;|&&|\|\||\|&|;|&|\||<|>|\(|\)|\n")
WRITE_CMDS = {
    "rm", "rmdir", "unlink", "shred", "touch", "mkdir", "truncate", "tee", "chmod", "chown",
    "mv", "cp", "ln", "install", "rsync", "dd", "sed", "find",
}
SHELLS = {"sh", "bash", "dash", "zsh"}
WRAPPERS = {
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"},
    "env": {"-u", "-C", "-S"},
    "nice": {"-n"},
    "ionice": {"-c", "-n", "-p"},
    "timeout": {"-s", "-k"},
    "nohup": set(), "setsid": set(), "stdbuf": set(), "command": set(), "builtin": set(),
    "exec": set(), "time": set(),
}
KEYWORDS = {"{", "}", "!", "then", "do", "else", "elif", "if", "while", "until"}
SAFE_FDS = re.compile(r"\d+|-")


def strip_heredocs(s):
    out, pending = [], []
    for line in s.split("\n"):
        if pending:
            delim, tabs = pending[0]
            if (line.lstrip("\t") if tabs else line) == delim:
                pending.pop(0)
            continue
        out.append(line)
        for m in re.finditer(r"(?<!<)<<(-?)[ \t]*(?:'([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))", line):
            pending.append((m.group(2) or m.group(3) or m.group(4), m.group(1) == "-"))
    return "\n".join(out)


def tokenize(s):
    lex = shlex.shlex(strip_heredocs(s), posix=True, punctuation_chars=";&|<>()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    items = []
    for t in lex:
        if t and set(t) <= PUNCT:
            items.extend(("op", op) for op in OPRE.findall(t))
        else:
            items.append(("w", t))
    return items


def resolve(word, cwd):
    """(norm, last_glob) を返す。静的に決まらなければ (None, 理由)。"""
    w = word
    if home_expandable:
        w = re.sub(r"\$\{HOME\}|\$HOME(?![A-Za-z0-9_])", home, w)
    if "$" in w or "`" in w:
        return None, "変数展開・コマンド置換を含む"
    if re.search(r"\{[^{}]*(,|\.\.)[^{}]*\}", w):
        return None, "ブレース展開を含む"
    if w.startswith("~") and w != "~" and not w.startswith("~/"):
        return None, "~user 形式"
    comps = w.split("/")
    if any(re.search(r"[*?\[]", c) for c in comps[:-1]):
        return None, "ディレクトリ部分に glob を含む"
    p = os.path.expanduser(w)
    if not os.path.isabs(p):
        if cwd is None:
            return None, "cd 後の cwd が判定できない"
        p = os.path.join(cwd, p)
    return os.path.realpath(p), bool(re.search(r"[*?\[]", comps[-1]))


SAFE_DEVICES = re.compile(r"/dev/(null|stdout|stderr|tty)|/dev/fd/[0-9]+")
tmp_real = os.path.realpath("/tmp")


def violation_of(word, cwd):
    """許可リスト方式(鷹野の裁定 2026-10-07): 書き込み先として読めた語は、解決した先が
    /tmp 以下・/dev/null 等の端末系・(ゲート2だけ)root 以下のどれかでなければ違反。
    ゲート1・ゲート番号不明は root(= 贄川の run_dir)も許可しない。"""
    if SAFE_DEVICES.fullmatch(word):
        return None
    norm, extra = resolve(word, cwd)
    if norm is None:
        return f"書き込み先を静的に判定できない({extra}): {word}。絶対パスで書き直す"
    if norm == tmp_real or norm.startswith(tmp_real + os.sep):
        return None
    if root_carve_out and (norm == root or norm.startswith(root + os.sep)):
        return None
    where = "作業木(root)の外" if root_carve_out else "ゲート1・不明は /tmp と /dev/null 等以外"
    for prefix in forbidden_prefixes:
        if norm == prefix or norm.startswith(prefix + os.sep):
            where = f"禁止プレフィックス {prefix} 配下"
            break
    return f"{norm}({where}、書き込み先の語: {word})"


def positional(args):
    """オプション(-x / --x)を除いた引数。--x=値 の値と -- 以降は含める。"""
    out, rest = [], False
    for a in args:
        if rest:
            out.append(a)
        elif a == "--":
            rest = True
        elif a.startswith("--") and "=" in a:
            out.append(a.split("=", 1)[1])
        elif a.startswith("-") and len(a) > 1:
            continue
        else:
            out.append(a)
    return out


def command_index(words):
    i = 0
    while i < len(words):
        w = words[i]
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", w) or w in KEYWORDS:
            i += 1
        elif w in WRAPPERS:
            i += 1
            while i < len(words) and words[i].startswith("-") and len(words[i]) > 1:
                i += 2 if words[i] in WRAPPERS[w] else 1
            if w == "timeout" and i < len(words):
                i += 1
        else:
            return i
    return None


def write_targets(name, args, problems, cwd, depth):
    if name in ("cp", "ln", "install", "rsync"):
        # 書かれるのは宛先だけ(コピー元は読むだけ)。-t DIR / --target-directory=DIR があればそれ、無ければ最後の引数。
        for k, a in enumerate(args):
            if a in ("-t", "--target-directory") and k + 1 < len(args):
                return [args[k + 1]]
            if a.startswith("--target-directory="):
                return [a.split("=", 1)[1]]
            if re.fullmatch(r"-[A-Za-z]*t.+", a) and name != "rsync":
                return [a.split("t", 1)[1]]
        pos = positional(args)
        return pos[-1:]
    if name in ("rm", "rmdir", "unlink", "shred", "touch", "mkdir", "truncate", "tee", "chmod", "chown", "mv"):
        return positional(args)
    if name == "dd":
        return [a[3:] for a in args if a.startswith("of=")]
    if name == "sed":
        if not any(re.fullmatch(r"-[A-Za-z]*i[^ ]*", a) or a == "--in-place" or a.startswith("--in-place=") for a in args):
            return []
        pos, script_given, skip = [], False, False
        for a in args:
            if skip:
                skip = False
            elif a in ("-e", "-f", "--expression", "--file"):
                script_given, skip = True, True
            elif a.startswith("-") and len(a) > 1:
                continue
            else:
                pos.append(a)
        return pos if script_given else pos[1:]
    if name == "find":
        # -exec / -ok は実行する側が書き込みコマンドのときだけ(-exec cat {} は読み取り)。
        execs_write = any(a in ("-exec", "-execdir", "-ok", "-okdir") and os.path.basename(args[k + 1]) in WRITE_CMDS
                          for k, a in enumerate(args[:-1]))
        if not (execs_write or any(a in ("-delete", "-fls") or a.startswith("-fprint") for a in args)):
            return []
        roots = []
        for a in args:
            if a.startswith("-") or a in ("(", "!", ")"):
                break
            roots.append(a)
        outs = [args[k + 1] for k, a in enumerate(args[:-1]) if a.startswith("-fprint") or a == "-fls"]
        return roots + outs
    if name == "xargs":
        for a in args:
            if os.path.basename(a) in WRITE_CMDS:
                problems.append(f"xargs 経由の書き込み({a})は対象を判定できない")
        return []
    if name in SHELLS or name == "eval":
        inner = None
        if name == "eval":
            inner = " ".join(args)
        else:
            for k, a in enumerate(args[:-1]):
                if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", a):
                    inner = args[k + 1]
                    break
        if inner is not None:
            if depth >= 3:
                problems.append("bash -c / eval の入れ子が深く判定できない")
            else:
                problems.extend(analyze(inner, cwd, depth + 1))
    return []


def analyze(s, cwd, depth=0):
    problems = []
    try:
        items = tokenize(s)
    except ValueError:
        # 従来から書き込み扱いだった(is_write=1)ものだけ止める。読み取りは構文が崩れていても巻き込まない。
        return ["コマンドを構文解析できない(引用符の対応など)"] if old_pass else []
    state = {"cwd": cwd}
    seg_words, seg_redirs = [], []
    ctx = {"prev": None, "paren": 0}

    def flush(sep):
        cur = state["cwd"]
        for target in seg_redirs:
            problems.append(violation_of(target, cur))
        ci = command_index(seg_words)
        if ci is not None:
            name = os.path.basename(seg_words[ci])
            args = seg_words[ci + 1:]
            if name == "cd":
                piped = ctx["prev"] in ("|", "|&") or sep in ("|", "|&", "&") or ctx["paren"] > 0
                pos = positional(args)
                target = pos[0] if pos else "~"
                new, _ = resolve(target, cur) if target != "-" else (None, "")
                if piped or new is None or not os.path.isdir(new):
                    state["cwd"] = None
                else:
                    state["cwd"] = new
            elif name in ("pushd", "popd"):
                state["cwd"] = None
            else:
                for target in write_targets(name, args, problems, cur, depth):
                    problems.append(violation_of(target, cur))
        seg_words.clear()
        seg_redirs.clear()
        ctx["prev"] = sep

    i, n = 0, len(items)
    while i < n:
        kind, v = items[i]
        nxt = items[i + 1] if i + 1 < n else None
        if kind == "w":
            seg_words.append(v)
            i += 1
        elif v in (">", ">>", ">|", "&>", "&>>", ">&"):
            if nxt and nxt[0] == "w":
                if not (v == ">&" and SAFE_FDS.fullmatch(nxt[1])):
                    seg_redirs.append(nxt[1])
                i += 2
            else:
                if nxt == ("op", "("):
                    problems.append("プロセス置換 >( ) への書き込みは判定できない")
                i += 1
        elif v in ("<", "<<", "<<<", "<&"):
            i += 2 if nxt and nxt[0] == "w" else 1
        else:
            flush(v)
            if v == "(":
                ctx["paren"] += 1
            elif v == ")":
                ctx["paren"] = max(0, ctx["paren"] - 1)
            i += 1
    flush(None)
    return problems


found = [p for p in analyze(cmd, start_cwd) if p]
if found:
    print(found[0])
    sys.exit(0)
sys.exit(1)
PY
)"
python_status=$?

if [ "$python_status" -eq 0 ] && [ -n "$violation" ]; then
  block "$violation(コマンド: $command_str)"
fi

exit 0
