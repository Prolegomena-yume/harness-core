#!/usr/bin/env bash
# cloud 環境の道具と分類器の文脈を入れる。冪等(揃っていれば数十 ms で抜ける)。
# 2 つの入口から同じ中身が走る:
#   (1) cloud 環境の setup script(root、Claude Code の起動前、終わった状態がスナップショットになる)。
#       本文をそのまま画面に貼る。setup script には API credential が付かず Forgejo が読めないので、
#       このファイルを取りに行く形にはしない(docs/cloud-session.md)
#   (2) cloud-bootstrap.sh の最後(setup script を貼っていない環境、スナップショットが古い環境の保険)
#
#   1. gleam(GLEAM_VERSION に固定、GitHub の release から .sha256 を照合して /usr/local/bin へ)
#   2. Erlang(erl が無ければ apt の erlang-nox。Ubuntu 24.04 は OTP 25。gleam の JS target は要らないが
#      Erlang target と yumemi の生成器・test のため)
#   3. ~/.claude/settings.json の autoMode.environment に自社の source control と ymos を書く(分類器は project の
#      .claude/settings.json の autoMode を読まない、公式)。他の key は触らない
#   4. ymos(社内 CLI)。Forgejo の satellite/yumemism-os を ~/yumemism_repo/yumemism-os へ浅く clone(あれば pull)、
#      cli/ を npm ci && npm run build、PATH 上の ymos に YMOS_CREDENTIAL=proxy を export して cli/dist/index.js を
#      exec する wrapper を置く。認証ヘッダは CLI が付けず、cloud 環境の API credential(dispatch.yumemism.com)を
#      agent proxy が VM の外で付ける(docs/cloud-session.md)。**CLAUDE_CODE_REMOTE=true のときだけ**(母艦では何も
#      しない)。setup script の入口には API credential が付かず Forgejo が読めないので、そこでは clone が落ちて
#      飛ばされ、bootstrap 経由の 2 回目で入る(clone の中身をスナップショットに固めないので、それでよい)
#
# 標準出力は使わない(bootstrap から呼ばれるとき session-init の JSON を壊すため)。落ちても exit 0。
# test 用: CLOUD_SETUP_SKIP_TOOLS=1 で 1・2 を飛ばす、CLOUD_SETUP_SETTINGS で 3 の書き先を替える、
#   CLOUD_SETUP_SKIP_YMOS=1 で 4 を飛ばす、CLOUD_YMOS_URL / CLOUD_YMOS_DIR / CLOUD_BIN_DIR で 4 の取り先・置き場・wrapper の置き場を替える。

set -u
exec 1>&2
GLEAM_VERSION="${GLEAM_VERSION:-1.18.1}"
log() { echo "[cloud-setup] $*"; }
SUDO=""; [ "$(id -u)" = 0 ] || { command -v sudo >/dev/null 2>&1 && SUDO="sudo -n"; }

if [ "${CLOUD_SETUP_SKIP_TOOLS:-}" != 1 ]; then
  # 1. gleam
  have="$(gleam --version 2>/dev/null | awk '{print $2}')"
  if [ "$have" = "$GLEAM_VERSION" ]; then log "gleam $have ok"
  else
    case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) arch="" ;; esac
    if [ -n "$arch" ]; then
      t="$(mktemp -d)"; f="gleam-v${GLEAM_VERSION}-${arch}-unknown-linux-musl.tar.gz"
      u="https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/$f"
      if curl -fsSL --retry 2 -o "$t/$f" "$u" && curl -fsSL --retry 2 -o "$t/$f.sha256" "$u.sha256" \
         && [ "$(awk '{print $1}' "$t/$f.sha256")" = "$(sha256sum "$t/$f" | awk '{print $1}')" ] \
         && tar -xzf "$t/$f" -C "$t" && $SUDO install -m 0755 "$t/gleam" /usr/local/bin/gleam; then
        log "gleam $GLEAM_VERSION installed"
      else log "gleam install FAILED ($u)"; fi
      rm -rf "$t"
    else log "gleam: unknown arch $(uname -m)"; fi
  fi
  # 2. Erlang
  if command -v erl >/dev/null 2>&1; then log "erlang ok"
  elif DEBIAN_FRONTEND=noninteractive $SUDO apt-get update -qq >/dev/null \
       && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends erlang-nox >/dev/null; then
    log "erlang installed (OTP $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null))"
  else log "erlang install FAILED"; fi
fi

# 3. 分類器の文脈(prose。$defaults の後ろに足す)
settings="${CLOUD_SETUP_SETTINGS:-$HOME/.claude/settings.json}"
mkdir -p "$(dirname "$settings")"
python3 - "$settings" <<'PY' && log "autoMode.environment written: $settings" || log "autoMode.environment FAILED"
import json, os, sys
p = sys.argv[1]
ours = [
    "$defaults",
    "Organization: yumemism, the user's own company. Claude Code is used for software development of the company's own products (e.g. MuseArch) and its development harness.",
    "Source control: the company's own Forgejo at git.yumemism.com and every repository under it (orgs company, business, satellite and the rest), plus the company's own GitHub copies under github.com/Prolegomena-yume and github.com/canon-ical. Cloning, fetching, building, testing and running code from any of these is internal code, not an external source. In particular satellite/yumemi (GitHub copy canon-ical/yumemi) is the company's own Gleam framework and code generator that business/musearch depends on; cloning it next to musearch and running its generator is routine work.",
    "Internal package registry: the Hex package `yumemi` on hex.pm is published by the company from satellite/yumemi. Other hex.pm and npm packages are public registries reached by ordinary installs.",
    "Internal CLI: `ymos` (installed by the cloud setup from satellite/yumemism-os at ~/yumemism_repo/yumemism-os) is the company's own CLI. `ymos cal`, `ymos discord` and `ymos kb` call the company's own dispatch service at dispatch.yumemism.com; the cloud environment's proxy attaches the credential outside the VM (the wrapper sets YMOS_CREDENTIAL=proxy), so no token appears in commands or environment variables. Calling it is routine work, not an external service.",
    "Key internal services: Forgejo at git.yumemism.com. Cloud sessions push there only as AGit (`git push <url> HEAD:refs/for/main/<topic>`, via the `cloud-pr` command) and memory-only commits to main; the cloud environment's proxy attaches the `cloud-bridge` credential outside the VM, so no credential appears in commands.",
]
try:
    d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
except Exception:
    sys.exit(1)
am = d.setdefault("autoMode", {})
env = am.get("environment") or []
keep = [e for e in env if e != "$defaults" and not any(e.split(":", 1)[0] == o.split(":", 1)[0] for o in ours[1:])]
new = ours + keep
if new != env:
    am["environment"] = new
    tmp = p + ".tmp"
    json.dump(d, open(tmp, "w"), ensure_ascii=False, indent=2)
    os.replace(tmp, p)
PY

# 4. ymos(cloud だけ。落ちても他を止めない)
if [ "${CLAUDE_CODE_REMOTE:-}" = true ] && [ "${CLOUD_SETUP_SKIP_YMOS:-}" != 1 ]; then
  ydir="${CLOUD_YMOS_DIR:-$HOME/yumemism_repo/yumemism-os}"
  yurl="${CLOUD_YMOS_URL:-https://git.yumemism.com/satellite/yumemism-os.git}"
  if [ -d "$ydir/.git" ]; then
    git -C "$ydir" pull --ff-only --quiet </dev/null 2>/dev/null && log "ymos pulled: $ydir" || log "ymos pull skipped (今ある版を使う)"
  else
    mkdir -p "$(dirname "$ydir")"
    git clone --quiet --depth 1 "$yurl" "$ydir" </dev/null 2>/dev/null && log "ymos cloned: $ydir" \
      || log "ymos clone FAILED (setup script の入口では API credential が付かず取れない。bootstrap 経由で再度入る)"
  fi
  if [ -d "$ydir/cli" ]; then
    rev="$(git -C "$ydir" rev-parse HEAD 2>/dev/null)"; stamp="$ydir/.git/cloud-built-rev"
    if [ -f "$ydir/cli/dist/index.js" ] && [ -n "$rev" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$rev" ]; then
      log "ymos built ($rev) ok"; built=1
    elif command -v npm >/dev/null 2>&1 \
         && (cd "$ydir/cli" && npm ci --include=dev --no-audit --no-fund --loglevel=error </dev/null >/dev/null && npm run build --silent </dev/null >/dev/null) \
         && [ -f "$ydir/cli/dist/index.js" ]; then
      echo "$rev" >"$stamp"; log "ymos built ($rev)"; built=1
    else log "ymos build FAILED (npm が無い、または npm ci / build が落ちた)"; built=0; fi
    if [ "${built:-0}" = 1 ]; then
      bindir="${CLOUD_BIN_DIR:-/usr/local/bin}"
      if ! mkdir -p "$bindir" 2>/dev/null || [ ! -w "$bindir" ]; then
        bindir="$HOME/.local/bin"; mkdir -p "$bindir"
        if [ -n "${CLAUDE_ENV_FILE:-}" ] && ! grep -qsF "$bindir" "$CLAUDE_ENV_FILE"; then echo "export PATH=\"$bindir:\$PATH\"" >>"$CLAUDE_ENV_FILE"; fi
      fi
      w="$bindir/.ymos.$$"
      printf '#!/usr/bin/env bash\n# cloud/setup.sh が置いた wrapper。認証ヘッダは CLI が付けず、cloud 環境の agent proxy が VM の外で付ける。\nexport YMOS_CREDENTIAL=proxy\nexec node %q "$@"\n' "$ydir/cli/dist/index.js" >"$w" \
        && chmod 0755 "$w" && mv -f "$w" "$bindir/ymos" && log "ymos wrapper -> $bindir/ymos" || { rm -f "$w"; log "ymos wrapper FAILED"; }
    fi
  else log "ymos: cli/ が無い ($ydir)"; fi
fi
exit 0
