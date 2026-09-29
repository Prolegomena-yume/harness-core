#!/usr/bin/env bash
# cloud の SessionStart で、MEMORY.md を additionalContext として注入する。1 本 = 1 つの hook = 1 つの欄。
#   使い方: cloud-memory-inject.sh <tech-1|tech-2|keiei>
#     tech-1 / tech-2 ── tech の .claude/memory/MEMORY.md を行単位で 2 つに割った前半 / 後半(割れ目は `## ` 見出し優先)
#     keiei           ── keiei の .claude/memory/MEMORY.md(読むだけ)
# 母艦(CLAUDE_CODE_REMOTE が true でない)では何も出さず exit 0(cloud でだけ何かを出す)。
#
# なぜ 3 本に分けたか ── additionalContext は hook ごと・欄ごとに 10,000 字が上限で、超えると Claude Code が
# 退避ファイル + 先頭 2,000 字のプレビューに差し替える(上限は変えられない。人見の実測 2026-09-30、tech + keiei を
# 1 本にしたら 10,000 字を超え keiei 分が文脈に見えなかった)。各 hook の出力を CTX_MAX_CHARS(既定 9,500)以下に保つ。
# 字数は UTF-16 の単位で数える(上限の数え方が JS の length だった場合に、絵文字などで超えないため)。
#
# なぜ待つか ── 同じ matcher の hook は並列に走る。この hook は
#   (1) submodule の取得(_core が現れる)と (2) cloud-bootstrap.sh(keiei の clone と memory の取り込み)の後でないと、
#   keiei の索引が無く、tech の索引も GitHub の古い写しのまま読むことになる。
# 待つのは bootstrap が終わりに置く印(~/.cache/harness-cloud/bootstrap-done)で、この hook の起動時刻以降の
# mtime のものだけを「今回のもの」と読む(resume / compact で前回の印が残っていても素通りしない)。
# 最長 CTX_WAIT_SEC(既定 90)秒。keiei を自分で clone しないのは、bootstrap の clone と同じ dir に 2 本走ると
# 半端な clone を読みうるため。待ちきれなければ、その旨を 1 行添えて手元にあるものを出す。
# tech の索引の割り方は決定的(同じ入力なら tech-1 と tech-2 が同じ割れ目を計算する)。
#
# 出力は JSON 1 個(何も出すものが無ければ空)。どこが落ちても exit 0。
# test 用の上書き: CTX_TECH_MEM CTX_KEIEI_MEM CTX_MAX_CHARS CTX_WAIT_SEC CLOUD_HOOK_T0 CLOUD_STATE_DIR

[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0
part="${1:-}"
case "$part" in tech-1|tech-2|keiei) ;; *) echo "usage: $0 <tech-1|tech-2|keiei>" >&2; exit 0;; esac

core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
proj="${CLAUDE_PROJECT_DIR:-$(cd -P "$core/../.." && pwd)}"
tech_mem="${CTX_TECH_MEM:-$proj/.claude/memory}"
keiei_mem="${CTX_KEIEI_MEM:-$HOME/canonical/keiei/.claude/memory}"
state="${CLOUD_STATE_DIR:-$HOME/.cache/harness-cloud}"
wait_sec="${CTX_WAIT_SEC:-90}"
t0="${CLOUD_HOOK_T0:-$(date +%s)}"
command -v python3 >/dev/null 2>&1 || exit 0

# bootstrap の完了待ち(印の mtime が t0 以上になるまで)
waited=ok
deadline=$(( $(date +%s) + wait_sec ))
until m="$(stat -c %Y "$state/bootstrap-done" 2>/dev/null)" && [ "${m:-0}" -ge "$t0" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then waited=timeout; break; fi
  sleep 0.5
done

PART="$part" TECH_MEM="$tech_mem" KEIEI_MEM="$keiei_mem" WAITED="$waited" WAIT_SEC="$wait_sec" \
LIMIT="${CTX_MAX_CHARS:-9500}" python3 - <<'PY'
import json, os

part = os.environ["PART"]
limit = int(os.environ["LIMIT"])
timed_out = os.environ["WAITED"] == "timeout"

def L(s):  # UTF-16 の単位数
    return len(s.encode("utf-16-le")) // 2

def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None

def emit(text):
    if L(text) > limit:  # 最後の安全網。ここに来る設計ではない
        while L(text) > limit - 40:
            text = text[: int(len(text) * 0.95)]
        text += "\n…(上限で切った)"
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}},
                     ensure_ascii=False))
    raise SystemExit(0)

WAITNOTE = ("(cloud の起動処理の完了を %s 秒待ったが間に合わなかった。取り込みが未了かもしれない)\n"
            % os.environ["WAIT_SEC"])
TOO_BIG = "**tech の memory 索引が大きすぎる。整理が要る(2 本の hook に載る上限を超えた。載っていない行がある)。**\n"

if part == "keiei":
    text = read(os.path.join(os.environ["KEIEI_MEM"], "MEMORY.md"))
    head = "## memory(cloud、hooks/cloud-memory-inject.sh が注入)\n### keiei の memory 索引(~/canonical/keiei/.claude/memory/、読むだけ)\n"
    if text is None:
        if timed_out:
            emit(head + "keiei の clone が起動に間に合わなかった。~/canonical/keiei/.claude/memory/MEMORY.md が現れたら直接読む。"
                 " ~/.cache/harness-cloud/bootstrap.log に理由がある。")
        raise SystemExit(0)
    head += ("tech の CLAUDE.md の @import が cloud では展開されないので、その索引を hook が入れた。"
             "本文は上の dir の <file>.md。\n" + (WAITNOTE if timed_out else "") + "\n")
    budget = limit - L(head) - 200
    if L(text) > budget:
        lines = text.splitlines(keepends=True); out = []; n = 0
        for ln in lines:
            if n + L(ln) > budget: break
            out.append(ln); n += L(ln)
        text = "".join(out) + "\n…(この hook の上限で切った。続きは MEMORY.md を直接読む。索引が大きすぎる、整理が要る)\n"
    emit(head + text)

# --- tech ---
text = read(os.path.join(os.environ["TECH_MEM"], "MEMORY.md"))
if text is None:
    raise SystemExit(0)
lines = text.splitlines(keepends=True)
sz = [L(x) for x in lines]
total = sum(sz)
head1 = ("## memory(cloud、hooks/cloud-memory-inject.sh が注入)\n### tech の memory(~/canonical/tech/.claude/memory/)前半\n"
         "cloud では auto memory が自動で載らないので、その索引を hook が入れた(長いので前半・後半の 2 本に割って入れる)。"
         "各項目の本文は上の dir の <file>.md。"
         "**書くのもこの dir(tech 側の symlink 経由)。書けば Stop hook が Forgejo の main に memory だけ送る。**\n")
head2 = "## memory(cloud、hooks/cloud-memory-inject.sh が注入)\n### tech の memory(~/canonical/tech/.claude/memory/)後半(続き)\n"
budget = limit - max(L(head1), L(head2)) - L(TOO_BIG) - L(WAITNOTE) - 300   # 300 は「載せていない」注記などの余裕

def split_at(cands):
    """part 2 の先頭行の index を返す。max(前半, 後半) が最小になるもの"""
    best = None; acc = 0; pre = [0]
    for s in sz: acc += s; pre.append(acc)
    for i in cands:
        m = max(pre[i], total - pre[i])
        if best is None or m < best[0]: best = (m, i)
    return best

if total <= budget // 2:          # 半分に収まる小ささなら 1 本(後半は空)。端に張り付かないための余裕
    cut = len(lines)
else:
    heads = [i for i, x in enumerate(lines) if x.startswith("## ") and i > 0]
    b = split_at(heads) if heads else None
    if b is None or b[0] > budget:   # 見出しの割れ目では収まらない → 任意の行で割る
        b2 = split_at(range(1, len(lines)))
        if b2 is not None and (b is None or b2[0] < b[0]): b = b2
    cut = b[1] if b else len(lines)

def fit(seg):
    """seg(行の list)を budget に収める。溢れたら行単位で切り、(text, 切ったか)"""
    out = []; n = 0
    for k, ln in enumerate(seg):
        if n + L(ln) > budget:
            return "".join(out) + "\n…(この hook の上限で %d 行を載せていない。MEMORY.md を直接読む)\n" % (len(seg) - k), True
        out.append(ln); n += L(ln)
    return "".join(out), False

overflow = any(sum(sz[a:b]) > budget for a, b in ((0, cut), (cut, len(lines))))
warn = TOO_BIG if overflow else ""
note = WAITNOTE if timed_out else ""
if part == "tech-1":
    body, _ = fit(lines[:cut])
    emit(head1 + warn + note + "\n" + body)
else:
    if cut >= len(lines):
        raise SystemExit(0)
    body, _ = fit(lines[cut:])
    emit(head2 + warn + note + "\n" + body)
PY
exit 0
# END
