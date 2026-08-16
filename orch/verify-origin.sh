#!/usr/bin/env bash
# verify-origin.sh <roster.json> [--transcript <path>]
# 最後の attachment.origin の verifiedPeerPid を送信側台帳と照合する。
set -euo pipefail

roster="${1:-}"
[ -n "$roster" ] || { echo "usage: verify-origin.sh <roster.json> [--transcript <path>]" >&2; exit 2; }
shift

transcript=""
while [ $# -gt 0 ]; do
  case "$1" in
    --transcript)
      [ $# -ge 2 ] || { echo "verify-origin: --transcript に path が必要" >&2; exit 2; }
      transcript="$2"; shift 2;;
    *) echo "verify-origin: unknown arg: $1" >&2; exit 2;;
  esac
done

python3 - "$roster" "$transcript" <<'PY'
import json
import os
import sys


def fail(message):
    print("verify-origin: " + message, file=sys.stderr)
    raise SystemExit(2)


roster_path = os.path.abspath(os.path.expanduser(sys.argv[1]))
try:
    with open(roster_path, encoding="utf-8") as f:
        roster = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    fail("roster.json を読めない: %s" % e)

transcript_path = sys.argv[2]
if transcript_path:
    transcript_path = os.path.abspath(os.path.expanduser(transcript_path))
else:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not session_id:
        fail("CLAUDE_CODE_SESSION_ID が無い")
    origin_cwd = roster.get("origin_cwd") or ""
    if not origin_cwd:
        fail("roster.json に origin_cwd が無い")
    project = origin_cwd.replace("/", "-").replace(".", "-")
    transcript_path = os.path.expanduser(
        "~/.claude/projects/%s/%s.jsonl" % (project, session_id)
    )

try:
    with open(transcript_path, encoding="utf-8") as f:
        lines = f.readlines()
except OSError as e:
    fail("transcript を読めない: %s" % e)

origin = None
for line in reversed(lines):
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    attachment = row.get("attachment")
    if isinstance(attachment, dict) and isinstance(attachment.get("origin"), dict):
        origin = attachment["origin"]
        break

if origin is None:
    print("origin none ── attachment.origin を持つレコードが無い")
    raise SystemExit(4)

peer_pid = origin.get("verifiedPeerPid")
ledger_path = os.path.join(os.path.dirname(roster_path), "senders.jsonl")
matched = None
try:
    with open(ledger_path, encoding="utf-8") as f:
        ledger_lines = f.readlines()
except FileNotFoundError:
    ledger_lines = []
except OSError as e:
    fail("senders.jsonl を読めない: %s" % e)

for line in reversed(ledger_lines):
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    if record.get("pid") == peer_pid:
        matched = record
        break

if matched is not None:
    print("origin ok pid=%s label=%s sent=%s" %
          (peer_pid, matched.get("label", ""), matched.get("ts", "")))
    raise SystemExit(0)

print("origin UNKNOWN pid=%s name=%s ── 台帳に無い差出人" %
      (peer_pid, origin.get("name") or ""))
raise SystemExit(3)
PY
