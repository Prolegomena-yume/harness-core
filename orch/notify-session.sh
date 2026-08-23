#!/usr/bin/env bash
# notify-session.sh <roster.json> <body>
#
# 生フレーム・鍵・socket を全部この中に閉じ込める。codex/grok は本スクリプトを叩くだけ。
# 宛先は roster.json が持つ(origin_session_id / origin_name / origin_started / origin_cwd)。
#
# 解決は3段。claude は割り込みや再起動で pid も sessionId も name も振り直される
# (2026-08-16 実測)。逆に「同じ cwd の最新セッション」を自分だと決めつけると
# 別チャットへ誤爆する(これも実際に踏んだ)。
#   1. sessionId 一致 ── 最も確実。起点が生きていればここで終わる
#   2. name 一致    ── sessionId が変わって name が残る場合の保険
#   3. 後継探索      ── 既定で無効。ALLOW_SUCCESSOR=1 のときだけ働く
#
# 後継探索を既定で切る理由: 同じ cwd に人見の別チャットが並ぶと、「起点より後に
# 開始」は再起動した自分だけでなく新しい別チャットも満たす。socket 側の情報では
# 区別が付かず、実際に2回誤爆した(2026-08-16)。届かないことより、違う相手に
# 届くことの方が悪い。届かなければ UNDELIVERED を残し、claude 側が後で拾う。
set -euo pipefail
roster="${1:?usage: notify-session.sh <roster.json> <body>}"
body="${2:?usage: notify-session.sh <roster.json> <body>}"
allow_successor="${ALLOW_SUCCESSOR:-0}"

# 事前解決(rulings #59)── roster が origin_socket を持ち、それが実在する socket なら
# claude agents の全 socket 走査を跳ばす。sandbox 側の穴を宛先1本に絞るための口。
# socket が消えていたら(プロセス交代)従来の3段解決へ落ちる。
resolved=""
presock="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("origin_socket") or "")' "$roster" 2>/dev/null || true)"
if [ -n "$presock" ]; then
  prebase="$(basename "$presock")"
  # sandbox 内からは hardlink 側(codex-notify の穴)しか connect できない ── 穴があればそちらを優先
  hole="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/codex-notify/${prebase%.sock}-d/$prebase"
  for cand in "$hole" "$presock"; do
    if [ -S "$cand" ]; then
      resolved="$(printf 'roster-socket\t%s\t%s' "${prebase%.sock}" "$cand")"
      break
    fi
  done
fi

[ -z "$resolved" ] && resolved="$(claude agents --json 2>/dev/null | ROSTER="$roster" ALLOW_SUCCESSOR="$allow_successor" python3 -c '
import json,sys,os
r=json.load(open(os.environ["ROSTER"]))
allow=os.environ.get("ALLOW_SUCCESSOR")=="1"
sid=r.get("origin_session_id") or ""
name=r.get("origin_name") or ""
started=int(r.get("origin_started") or 0)
cwd=r.get("origin_cwd") or ""
rows=json.load(sys.stdin)

def sock_of(pid):
    p=os.path.expanduser("~/.claude/sessions/%s.json" % pid)
    sp=""
    if os.path.exists(p):
        sp=json.load(open(p)).get("messagingSocketPath","")
    return sp or "/run/user/%d/cc-socks/%s.sock" % (os.getuid(), pid)

def emit(how,row):
    sys.stdout.write("%s\t%s\t%s" % (how, row["pid"], sock_of(row["pid"])))
    sys.exit(0)

if sid:
    for row in rows:
        if row.get("sessionId")==sid: emit("session",row)
if name:
    for row in rows:
        if row.get("name")==name: emit("name:"+name,row)
if cwd and allow:
    c=[row for row in rows
       if row.get("cwd")==cwd
       and row.get("kind")=="interactive"
       and row.get("sessionId")!=sid
       and int(row.get("startedAt") or 0) > started]
    if c:
        c.sort(key=lambda row:int(row.get("startedAt") or 0), reverse=True)
        emit("successor:"+str(c[0].get("name")), c[0])
')"

[ -z "$resolved" ] && { echo "notify: 宛先を解決できない(session/name/後継 いずれも該当なし)" >&2; exit 1; }
how="${resolved%%	*}"; rest="${resolved#*	}"; pid="${rest%%	*}"; sock="${rest#*	}"

SOCK="$sock" BODY="$body" ROSTER="$roster" python3 -c '
import datetime,json,os,socket,stat,sys,uuid
sock=os.environ["SOCK"]; body=os.environ["BODY"]
roster=os.path.abspath(os.environ["ROSTER"])
record={"pid":os.getpid(),
        "ts":datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "label":os.environ.get("ORCH_SENDER_LABEL", ""),
        "roster":roster}
ledger=os.path.join(os.path.dirname(roster), "senders.jsonl")
try:
    fd=os.open(ledger, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o666)
    try:
        os.write(fd, (json.dumps(record, ensure_ascii=False)+"\n").encode())
    finally:
        os.close(fd)
except Exception as e:
    print("notify: 台帳を書けない: %s" % e, file=sys.stderr)
try:
    if not stat.S_ISSOCK(os.stat(sock).st_mode):
        raise FileNotFoundError(sock)
except OSError:
    raise SystemExit("notify: socket が無い: %s" % sock)
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sock)
content=("<cross-session-message from=\"uds:/tmp/notify-relay.sock\" "
         "from-name=\"notify-relay\" from-mode=\"prompting\">\n"+body+"\n</cross-session-message>")
s.sendall((json.dumps({"type":"auth","token":"x"*32})+"\n").encode())
s.sendall((json.dumps({"msgV":1,"msg_id":str(uuid.uuid4()),"type":"user",
    "message":{"role":"user","content":content},
    "priority":"next","from":"uds:/tmp/notify-relay.sock"})+"\n").encode())
s.close()
'
echo "notify: delivered to pid=$pid via $how"
