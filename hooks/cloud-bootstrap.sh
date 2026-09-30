#!/usr/bin/env bash
# cloud セッション(CLAUDE_CODE_REMOTE=true)でだけ動く起動処理。母艦では何もせず exit 0。
# tech の SessionStart hook が、submodule を取った後にこれを呼ぶ(_core が無い間は呼べないので、
# submodule の取得だけは consumer 側の settings.json に 1 行で書く)。
#
# 標準出力は空に保つ(同じ hook 鎖の session-init.sh が JSON を 1 個返すため)。記録は標準エラーと
# ~/.cache/harness-cloud/bootstrap.log へ。どの段が落ちても exit 0(cloud の起動を止めない)。
#
#   1. git-as / cloud-pr を PATH に(/usr/local/bin、書けなければ ~/.local/bin + CLAUDE_ENV_FILE)
#   2. ~/canonical/tech を clone への symlink に ── tech の settings.json が持つ母艦の絶対パス
#      (autoMemoryDirectory、commit guard)を書き換えずに生かす
#   3. ~/.claude/agents/{makabe,kashiwagi}.md を cloud/agents/ への symlink に(cloud だけで効く)
#   4. musearch を Forgejo から clone して ~/yumemism_repo/musearch に置く
#      (母艦の置き場と同じパス。BRIEF・docs が書く絶対パスがそのまま通り、tech の兄弟という形も同じ)
#   5. keiei を Forgejo から clone して ~/canonical/keiei に置く(tech の CLAUDE.md が @import する索引の在処。
#      cloud では @import が展開されないので、cloud-memory-inject.sh が MEMORY.md を additionalContext に入れる)
#   6. memory の同期の起点を置く(refs/memory-sync/base = いまの HEAD)→ Forgejo の main の memory を手元に取り込む
#      (GitHub の写しが古いことがあるため。hooks/memory-sync.sh、Stop hook と同じ処理)
#   7. yumemi を Forgejo(satellite/yumemi)から clone して ~/yumemism_repo/yumemi に置く(musearch の兄弟、生成器の在処。
#      GitHub の写し canon-ical/yumemi は手動 push で古いことがあるので使わない)
#   1b・4b. 日本時間(CLAUDE_ENV_FILE に TZ を足す。Claude の Bash の各コマンドにだけ効く、hook には効かない)と、
#      tech・musearch の作業木に Forgejo の remote `forgejo` を足す(cloud の tech の origin は GitHub の写しで、
#      discord/session-post が git.yumemism.com の remote を見て #session の URL の repo path を決めるため。
#      fetch はしない、push 先は変えない ── cloud-pr は URL を直に指す)。どちらも冪等
#   8. cloud/setup.sh(gleam・Erlang・分類器の文脈)。setup script を貼った環境では揃っていて数十 ms で抜ける。
#      apt が長いので bootstrap-done の印を置いた後に走らせる(注入 hook を待たせない)
#   6 の後(どの段が落ちても)に ~/.cache/harness-cloud/bootstrap-done を touch する ── 並列に走る
#   cloud-memory-inject.sh(keiei の索引・取り込み後の tech の索引を注入する hook)が、これを待つ印。
#
# test 用の上書き: CLOUD_BIN_DIR CLOUD_MUSEARCH_URL CLOUD_MUSEARCH_DIR CLOUD_KEIEI_URL CLOUD_KEIEI_DIR
#   CLOUD_YUMEMI_URL CLOUD_YUMEMI_DIR CLOUD_SETUP_SKIP_TOOLS CLOUD_SETUP_SETTINGS(cloud/setup.sh へ)

[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

set -u
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
proj="${CLAUDE_PROJECT_DIR:-$(cd -P "$core/../.." && pwd)}"
state="$HOME/.cache/harness-cloud"
mkdir -p "$state" 2>/dev/null
trap 'touch "$state/bootstrap-done" 2>/dev/null' EXIT
log() { echo "[cloud-bootstrap] $*" >&2; echo "$(date -u +%FT%TZ) $*" >>"$state/bootstrap.log" 2>/dev/null; }

# 1. PATH
bindir="${CLOUD_BIN_DIR:-/usr/local/bin}"
if ! mkdir -p "$bindir" 2>/dev/null || [ ! -w "$bindir" ]; then
  bindir="$HOME/.local/bin"; mkdir -p "$bindir"
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then echo "export PATH=\"$bindir:\$PATH\"" >>"$CLAUDE_ENV_FILE"; fi
fi
ln -sfn "$core/scripts/git-as" "$bindir/git-as" && log "git-as -> $bindir"
ln -sfn "$core/scripts/cloud-pr.sh" "$bindir/cloud-pr" && log "cloud-pr -> $bindir"

# 1b. 日本時間。cloud の VM は TZ が UTC で、締めのサマリ名の日付が JST とずれる(2026-10-01 実機: JST 10-01 02:16 が 09-30)。
#     CLAUDE_ENV_FILE は SessionStart 等の hook が Bash tool の各コマンドへ環境を渡す口(公式)で、hook・MCP には渡らない。
#     zoneinfo が無い VM では TZ=Asia/Tokyo が黙って UTC になるので、POSIX 形の JST-9(同じ +0900、日本に DST は無い)にする
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  if grep -qs '^export TZ=' "$CLAUDE_ENV_FILE"; then log "TZ already in CLAUDE_ENV_FILE (skip)"
  else
    tz=Asia/Tokyo; [ -e /usr/share/zoneinfo/Asia/Tokyo ] || tz=JST-9
    echo "export TZ=$tz" >>"$CLAUDE_ENV_FILE" && log "TZ=$tz -> CLAUDE_ENV_FILE"
  fi
fi

# 2. 母艦の絶対パス
if [ ! -e "$HOME/canonical/tech" ] || [ -L "$HOME/canonical/tech" ]; then
  mkdir -p "$HOME/canonical" && ln -sfn "$proj" "$HOME/canonical/tech" && log "~/canonical/tech -> $proj"
fi

# 3. cloud 専用の真壁・柏木
mkdir -p "$HOME/.claude/agents"
for a in makabe kashiwagi; do
  ln -sfn "$core/cloud/agents/$a.md" "$HOME/.claude/agents/$a.md" && log "agents/$a.md linked"
done

# 4. musearch(Forgejo、API credential は VM の外の proxy が付ける。URL に資格情報は書かない)
mdir="${CLOUD_MUSEARCH_DIR:-$HOME/yumemism_repo/musearch}"
murl="${CLOUD_MUSEARCH_URL:-https://git.yumemism.com/business/musearch.git}"
if [ -d "$mdir/.git" ]; then
  log "musearch exists: $mdir (skip)"
else
  mkdir -p "$(dirname "$mdir")"
  if git clone --quiet "$murl" "$mdir" 2>>"$state/bootstrap.log"; then
    log "musearch cloned: $mdir"
    git -C "$mdir" submodule update --init --recursive >/dev/null 2>>"$state/bootstrap.log" \
      && log "musearch submodules ok" || log "musearch submodules FAILED (see bootstrap.log)"
  else
    log "musearch clone FAILED (see bootstrap.log)"
  fi
fi

# 4b. Forgejo の remote(名前 forgejo、URL は cloud-pr.sh の slug と同じ。あれば URL だけ直す、fetch しない)
add_forgejo_remote() { # <作業木> <slug>
  local d="$1" url="https://git.yumemism.com/$2.git" cur
  git -C "$d" rev-parse -q --git-dir >/dev/null 2>&1 || return 0
  cur="$(git -C "$d" remote get-url forgejo 2>/dev/null)"
  if [ -z "$cur" ]; then git -C "$d" remote add forgejo "$url" 2>>"$state/bootstrap.log" && log "remote forgejo added: $d -> $url" || log "remote forgejo FAILED: $d"
  elif [ "$cur" != "$url" ]; then git -C "$d" remote set-url forgejo "$url" && log "remote forgejo fixed: $d -> $url"
  else log "remote forgejo ok: $d"; fi
}
add_forgejo_remote "$proj" company/tech
[ -d "$mdir/.git" ] && add_forgejo_remote "$mdir" business/musearch

# 5. keiei(読むだけ)
kdir="${CLOUD_KEIEI_DIR:-$HOME/canonical/keiei}"
kurl="${CLOUD_KEIEI_URL:-https://git.yumemism.com/company/keiei.git}"
if [ -d "$kdir/.git" ]; then
  log "keiei exists: $kdir (skip)"
else
  mkdir -p "$(dirname "$kdir")"
  if git clone --quiet --depth 1 "$kurl" "$kdir" 2>>"$state/bootstrap.log"; then log "keiei cloned: $kdir"
  else log "keiei clone FAILED (see bootstrap.log)"; fi
fi

# 6. memory 同期の起点 → Forgejo main の memory を取り込む(memory-sync.sh は cloud のとき前景・timeout 付き)
if git -C "$proj" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  git -C "$proj" rev-parse -q --verify refs/memory-sync/base >/dev/null 2>&1 || git -C "$proj" update-ref refs/memory-sync/base HEAD
  MEMSYNC_REPO="$proj" bash "$core/hooks/memory-sync.sh" </dev/null >/dev/null 2>>"$state/bootstrap.log" \
    && log "memory sync ran (see ~/.cache/harness-memory-sync/sync.log)" || log "memory sync FAILED"
fi

# 7. yumemi(読むだけ。cloud-bridge は satellite/yumemi に read)
ydir="${CLOUD_YUMEMI_DIR:-$HOME/yumemism_repo/yumemi}"
yurl="${CLOUD_YUMEMI_URL:-https://git.yumemism.com/satellite/yumemi.git}"
if [ -d "$ydir/.git" ]; then
  log "yumemi exists: $ydir (skip)"
else
  mkdir -p "$(dirname "$ydir")"
  if git clone --quiet "$yurl" "$ydir" 2>>"$state/bootstrap.log"; then log "yumemi cloned: $ydir"
  else log "yumemi clone FAILED (see bootstrap.log)"; fi
fi
touch "$state/bootstrap-done" 2>/dev/null

# 8. 道具と分類器の文脈(印の後。apt が走ると数十秒かかる)
bash "$core/cloud/setup.sh" </dev/null >/dev/null 2>>"$state/bootstrap.log" && log "cloud setup ran" || log "cloud setup FAILED"
exit 0
