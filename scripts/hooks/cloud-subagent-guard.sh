#!/usr/bin/env bash
# cloud 専用の真壁・柏木の定義(cloud/agents/*.md)の frontmatter hooks から呼ぶ PreToolUse guard。
#   cloud-subagent-guard.sh makabe     ── git push を止める。Edit / Write は ~/.claude ~/.config ~/.git-credentials を止め、
#                                         ~/.cache/harness-cloud/makabe-root があればその配下(と /tmp)だけ許す
#   cloud-subagent-guard.sh kashiwagi  ── 読み取り専用。Bash の書き込み系(リダイレクト・rm・mv・cp・tee・sed -i・
#                                         git の書き込み系・push・curl の書き込み系)と Edit / Write を止める
# 字面の検査なので抜け穴はある(python -c の中の書き込みなど)。「うっかり」を止める柵で、封じ込めではない。
# block は exit 2 + stderr(bypass 下でも効く形)。
set -u
mode="${1:-}"
in="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || exit 0
tool="$(printf '%s' "$in" | jq -r '.tool_name // empty')"
deny() { echo "cloud-$mode: $1" >&2; exit 2; }
case "$tool" in
  Edit|Write|NotebookEdit)
    [ "$mode" = kashiwagi ] && deny "柏木は読むだけ(Edit / Write 不可)。所見は最終応答に書く"
    path="$(printf '%s' "$in" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    python3 - "$path" "$HOME" <<'PY' || deny "書けない場所: $path"
import os, sys
p = os.path.realpath(os.path.expanduser(sys.argv[1])); home = sys.argv[2]
for d in (".claude", ".config", ".git-credentials", ".ssh", ".cache/harness-cloud"):
    b = os.path.realpath(os.path.join(home, d))
    if p == b or p.startswith(b + os.sep):
        sys.exit(1)
rf = os.path.join(home, ".cache/harness-cloud/makabe-root")
if os.path.exists(rf):
    root = os.path.realpath(open(rf).read().strip())
    if not (p == root or p.startswith(root + os.sep) or p.startswith("/tmp/")):
        sys.exit(1)
sys.exit(0)
PY
    exit 0 ;;
  Bash) ;;
  *) exit 0 ;;
esac
cmd="$(printf '%s' "$in" | jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0
why="$(python3 - "$mode" "$cmd" <<'PY'
import re, shlex, sys
mode, cmd = sys.argv[1], sys.argv[2]
def bad(m): print(m); sys.exit(0)
GIT_RO = {"status","diff","log","show","blame","ls-files","ls-tree","cat-file","rev-parse","rev-list","grep","merge-base","describe","shortlog","name-rev","show-ref","for-each-ref","diff-tree","diff-index","help","version"}
MUT = {"rm","rmdir","mv","cp","tee","touch","mkdir","chmod","chown","dd","truncate","ln","install","patch","unlink","shred","rsync","git-as"}
VALUE_FLAGS = {"-C","-c","--git-dir","--work-tree","--namespace"}
for seg in re.split(r'&&|\|\||;|\||\n', cmd):
    seg = seg.strip()
    if not seg: continue
    try: t = shlex.split(seg)
    except ValueError: continue
    while t and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', t[0]): t = t[1:]
    if not t: continue
    if t[0] == "git-as": t = ["git"] + t[2:]
    if t[0] == "git":
        i = 1
        while i < len(t):
            if t[i] in VALUE_FLAGS: i += 2; continue
            if t[i].startswith("-"): i += 1; continue
            break
        sub = t[i] if i < len(t) else ""
        if sub == "push": bad("git push は使えない(PR は鷹野が cloud-pr で立てる)")
        if mode == "kashiwagi" and sub not in GIT_RO: bad(f"git {sub} は読み取り専用の外")
        continue
    if mode != "kashiwagi": continue
    if t[0] in MUT: bad(f"{t[0]} は書き込み系")
    if t[0] == "sed" and any(a == "-i" or a.startswith("-i") or a == "--in-place" for a in t[1:]): bad("sed -i は書き込み")
    if t[0] in ("curl","wget") and any(a in ("-X","-d","--data","--data-raw","-T","-F","-o","-O","--upload-file","--output") for a in t[1:]): bad(f"{t[0]} の書き込み系オプション")
    if t[0] in ("npm","pnpm","yarn") and len(t) > 1 and t[1] in ("install","i","ci","add","remove","publish","link"): bad(f"{t[0]} {t[1]} は書き込み")
if mode == "kashiwagi":
    # リダイレクト: > / >> のうち /dev/null と fd 複製(>&2)以外
    stripped = re.sub(r"'[^']*'|\"[^\"]*\"", "''", cmd)
    for m in re.finditer(r'(\d*)>>?(&?)\s*(\S*)', stripped):
        if m.group(2) == "&": continue
        if m.group(3) == "/dev/null": continue
        bad("リダイレクトでの書き込み")
sys.exit(0)
PY
)"
[ -z "$why" ] || deny "$why"
exit 0
