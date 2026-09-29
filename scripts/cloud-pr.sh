#!/usr/bin/env bash
# cloud セッションから Forgejo へ AGit で PR を立てる(push 1 回、branch は作らない)。
#   cloud-pr <tech|musearch|org/repo> <便名> -t <title> [-d <description>] [-C <dir>] [-b <base>] [-f]
# topic = 便名。同じ便名で打ち直せば同じ PR が更新される(履歴を書き換えたなら -f)。
# 認証は cloud 環境の API credential(proxy が Basic を付ける)。URL にも引数にも資格情報を書かない。
# 母艦では動かさない(CLOUD_PR_ALLOW_LOCAL=1 は test 用)。
set -u
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || [ "${CLOUD_PR_ALLOW_LOCAL:-}" = 1 ] || { echo "cloud-pr: cloud セッション専用" >&2; exit 2; }
[ "$#" -ge 2 ] || { echo "使い方: cloud-pr <tech|musearch|org/repo> <便名> -t <title> [-d <desc>] [-C <dir>] [-b <base>] [-f]" >&2; exit 2; }
repo="$1"; topic="$2"; shift 2
title=""; desc=""; dir=""; base=main; force=()
while getopts "t:d:C:b:f" o; do
  case "$o" in t) title="$OPTARG";; d) desc="$OPTARG";; C) dir="$OPTARG";; b) base="$OPTARG";; f) force=(-o force-push=true);; *) exit 2;; esac
done
case "$repo" in
  tech)     slug=company/tech;      dflt="${CLAUDE_PROJECT_DIR:-$HOME/canonical/tech}" ;;
  musearch) slug=business/musearch; dflt="$HOME/yumemism_repo/musearch" ;;
  */*)      slug="$repo";           dflt="$PWD" ;;
  *) echo "cloud-pr: repo は tech / musearch / org/repo" >&2; exit 2 ;;
esac
dir="${dir:-$dflt}"
[ -n "$title" ] || { echo "cloud-pr: -t <title> が要る" >&2; exit 2; }
case "$topic" in *[!A-Za-z0-9._-]*|"") echo "cloud-pr: 便名は英数と . _ - だけ" >&2; exit 2;; esac
[ -z "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ] || echo "cloud-pr: 警告: 未 commit の変更がある(push されるのは commit 済みの HEAD)" >&2
url="${CLOUD_PR_URL:-https://git.yumemism.com/$slug.git}"
exec git -C "$dir" push "$url" "HEAD:refs/for/$base/$topic" -o "title=$title" -o "description=$desc" "${force[@]}"
