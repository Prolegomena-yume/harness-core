#!/usr/bin/env bash
# kimi-makabe / claude-kashiwagi / claude-niekawa / kimi-niekawa の「run の前後の status 差分」の test。
# claude-makabe.sh の test-claude-makabe.sh と同じ起点(2026-10-03 の事故)── 起動時に作業木が汚れていて run の中で
# 全部 commit して clean に戻すと、`printf '%s\n' "$post" | comm -3` が post 側の空行に tab だけの行を作る。
#   kimi-makabe   : `${line:3}` が空キーになり bash が落ちる(exit 1、footer 無し)。post 側の path は先頭 1 文字欠けも。
#   kashiwagi / niekawa 2 本 : 件数が +1 ずれる(落ちはしない)。改名は 1 本、日本語名は引用符付きの別物。
# 偽 claude / 偽 kimi / 偽 rates を PATH の先頭に置き、実 git の worktree で launcher を実走して footer と changed-files.txt を見る。
# 実 Claude・実 Kimi・実ネットワークには出ない。
# 使い方: bash scripts/test-status-diff.sh
#   STATUS_DIFF_SCRIPTS=<dir> で別の版の scripts/ を試せる(直す前の版で「落ちること」を確かめるのに使う)。
#   STATUS_DIFF_ONLY=<launcher 名> で 1 本だけ(例 kimi-makabe)。
set -uo pipefail
core="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${STATUS_DIFF_SCRIPTS:-$core/scripts}"
GAS="$core/scripts/git-as"
n=0; fail=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); echo "not ok $n - $1"; fail=1; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq が要る(kimi 系の stream-json 解析)"; exit 2; }

sbx="$(mktemp -d)"; trap 'rm -rf "$sbx"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export NIEKAWA_NO_UNIT=1
unset NIEKAWA_INBOX NIEKAWA_UNIT_WRAPPED
mkdir -p "$sbx/bin"
cat >"$sbx/bin/claude" <<'S'
#!/usr/bin/env bash
# 偽の claude -p。cwd(= 作業ルート)で FAKE_SCENARIO を実行して JSON を返すだけ。
bash "$FAKE_SCENARIO" >&2
printf '{"session_id":"fake-session","is_error":false,"result":"fake done"}'
S
cat >"$sbx/bin/kimi" <<'S'
#!/usr/bin/env bash
# 偽の kimi -p。cwd(= 作業ルート)で FAKE_SCENARIO を実行して stream-json を返すだけ。
bash "$FAKE_SCENARIO" >&2
echo '{"role":"assistant","content":"fake done"}'
echo '{"role":"meta","type":"session.resume_hint","session_id":"fake-session"}'
S
printf '#!/bin/sh\nexit 1\n' >"$sbx/bin/rates"
chmod +x "$sbx/bin/claude" "$sbx/bin/kimi" "$sbx/bin/rates"
export PATH="$sbx/bin:$PATH"

# new_case <launcher> <name>: <sbx>/<launcher>-<name>/{base,wt,ext,state}。wt は base から切った impl/x(前 run の commit 1 本つき)
new_case() {
  local d="$sbx/$1-$2"; mkdir -p "$d/ext" "$d/state"
  git init -q -b main "$d/base"
  ( cd "$d/base" && echo base >README.md && git add -A && "$GAS" anno commit -q -m base \
      && git worktree add -q -b impl/x "$d/wt" \
      && cd "$d/wt" && echo prev >prev.txt && echo keep >keep.txt && git add -A && "$GAS" anno commit -q -m prev )
  echo "BRIEF" >"$d/ext/BRIEF.md"
  # kashiwagi はファイル名でゲートを判定する(findings.md = ゲート 2、作業木のレビュー)
  echo "FINDINGS" >"$d/ext/findings.md"
  echo "$d"
}

# run_launcher <launcher> <dir>: 台本は <dir>/scenario.sh。launcher の stdout/err を <dir>/launcher.{out,err}、exit を <dir>/exit に
run_launcher() {
  local l="$1" d="$2"
  local -a argv
  case "$l" in
    kimi-makabe)     argv=(-C "$d/wt" --log "$d/run.log" -f "$d/ext/BRIEF.md") ;;
    claude-kashiwagi) argv=(--no-loop -C "$d/wt" --log "$d/run.log" -f "$d/ext/findings.md") ;;
    claude-niekawa|kimi-niekawa) argv=(--no-loop -C "$d/wt" --log "$d/run.log" -f "$d/ext/BRIEF.md") ;;
  esac
  ( cd "$d/ext" && env CODEX_AGENT_STATE_DIR="$d/state" FAKE_SCENARIO="$d/scenario.sh" \
      bash "$W/$l.sh" "${argv[@]}" >"$d/launcher.out" 2>"$d/launcher.err" </dev/null; echo $? >"$d/exit" )
}
run_dir_of() { local x; for x in "$1"/state/runs/*-*; do [ -d "$x" ] && { echo "$x"; return; }; done; }
count_of() { sed -n 's/^変更ファイル数: \([0-9]*\).*/\1/p' "$1/launcher.out"; }
count_is() { [ "$(count_of "$1")" = "$2" ]; }
exit_is() { [ "$(cat "$1/exit")" = "$2" ]; }
no_bash_error() { ! grep -q '誤った配列の添字\|ソートされていません' "$1/launcher.err" "$1/launcher.out"; }
cf_of() { cat "$(run_dir_of "$1")/changed-files.txt" 2>/dev/null; }
same_set() { local d="$1"; shift; diff <(cf_of "$d" | LC_ALL=C sort) <(printf '%s\n' "$@" | LC_ALL=C sort) >"$d/set.diff"; }

# 期待する件数。kimi-makabe は status 差分 + HEAD 差分の path 集合、残り 3 本は status 差分の record 数だけ
# (kashiwagi は XY つき・niekawa 2 本は path だけ。この test の台本では同じ数になる)
expect() { # <launcher> <case> → 期待件数
  case "$1:$2" in
    kimi-makabe:dirty-clean) echo 4 ;;           # prev leftover 日本語 hello(hello は HEAD 差分)
    *:dirty-clean) echo 3 ;;                     # 起動時の汚れ 3 本が消えた(hello は commit 済みで status に出ない)
    kimi-makabe:untracked) echo 4 ;;
    *:untracked) echo 4 ;;
    *:rename) echo 4 ;;                          # 新旧の path 両方(R. new / R. old を 2 組)
    kimi-makabe:partial) echo 3 ;;               # prev new late
    *:partial) echo 2 ;;                         # prev(pre だけ)・late(post だけ)
    *:nothing) echo 0 ;;
  esac
}

launchers=(kimi-makabe claude-kashiwagi claude-niekawa kimi-niekawa)
[ -z "${STATUS_DIFF_ONLY:-}" ] || launchers=("$STATUS_DIFF_ONLY")

for L in "${launchers[@]}"; do
  echo "# ==== $L ===="

  # 1. 2026-10-03 の事故の形: 起動時に汚れ(tracked 変更・untracked・日本語+空白名)、run の中で全部 commit して clean に戻る
  d="$(new_case "$L" dirty-clean)"
  ( cd "$d/wt" && echo more >>prev.txt && echo left >leftover.txt && echo jp >"日本語 ファイル.txt" )
  cat >"$d/scenario.sh" <<S
echo hello >hello.txt
git add -A
$GAS anno commit -q -m "run commit"
S
  run_launcher "$L" "$d"
  chk "$L 1a 汚れ → clean(commit)で exit 0" exit_is "$d" 0
  chk "$L 1b bash の配列添字エラーが出ない" no_bash_error "$d"
  chk "$L 1c 変更ファイル数 = $(expect "$L" dirty-clean)(空行・tab の 1 本が混ざらない)" count_is "$d" "$(expect "$L" dirty-clean)"
  if [ "$L" = kimi-makabe ]; then
    chk "$L 1d changed-files.txt が実 path の完全一致(先頭欠け・引用符なし)" same_set "$d" prev.txt leftover.txt "日本語 ファイル.txt" hello.txt
  fi

  # 2. 起動時 clean、run が untracked を残す(1 文字名・空白名・日本語名・子ディレクトリ)
  d="$(new_case "$L" untracked)"
  cat >"$d/scenario.sh" <<'S'
echo a >a
echo b >"b c.txt"
echo j >"日本.txt"
mkdir -p sub && echo s >sub/x.md
S
  run_launcher "$L" "$d"
  chk "$L 2a clean → untracked で exit 0" exit_is "$d" 0
  chk "$L 2b 変更ファイル数 = $(expect "$L" untracked)" count_is "$d" "$(expect "$L" untracked)"
  if [ "$L" = kimi-makabe ]; then
    chk "$L 2c 生の path で残る(1 文字名の先頭欠け・引用符なし)" same_set "$d" a "b c.txt" "日本.txt" sub/x.md
  fi

  # 3. 改名(staged の git mv)は新旧の path 両方を 1 本ずつ数える(" -> " 入りの 1 本にならない)
  d="$(new_case "$L" rename)"
  cat >"$d/scenario.sh" <<'S'
git mv keep.txt moved.txt
git mv prev.txt "改名 後.txt"
S
  run_launcher "$L" "$d"
  chk "$L 3a 改名で exit 0" exit_is "$d" 0
  chk "$L 3b 変更ファイル数 = $(expect "$L" rename)(新旧 2 組)" count_is "$d" "$(expect "$L" rename)"
  if [ "$L" = kimi-makabe ]; then
    chk "$L 3c 新旧とも実 path" same_set "$d" keep.txt moved.txt prev.txt "改名 後.txt"
  fi

  # 4. 汚れが run の後も残る(一部だけ commit、post に新しい untracked)
  d="$(new_case "$L" partial)"
  ( cd "$d/wt" && echo more >>prev.txt && echo left >leftover.txt )
  cat >"$d/scenario.sh" <<S
echo n >new.txt
git add new.txt prev.txt
$GAS anno commit -q -m partial
echo late >late.txt
S
  run_launcher "$L" "$d"
  chk "$L 4a 一部だけ commit で exit 0" exit_is "$d" 0
  chk "$L 4b 変更ファイル数 = $(expect "$L" partial)" count_is "$d" "$(expect "$L" partial)"
  if [ "$L" = kimi-makabe ]; then
    chk "$L 4c prev・new・late(leftover は pre・post とも同じで差なし)" same_set "$d" prev.txt new.txt late.txt
  fi

  # 5. 何も変わらない: 0 件(clean のまま)
  d="$(new_case "$L" nothing)"
  : >"$d/scenario.sh"
  run_launcher "$L" "$d"
  chk "$L 5a 何も無しで exit 0" exit_is "$d" 0
  chk "$L 5b 0 件" count_is "$d" 0

  # 6. 起動時に汚れ、run は何もしない(汚れが残ったまま)→ 差が無い = 0 件(clean 側の空行が混ざらない対の形)
  d="$(new_case "$L" dirty-stay)"
  ( cd "$d/wt" && echo more >>prev.txt && echo left >leftover.txt )
  : >"$d/scenario.sh"
  run_launcher "$L" "$d"
  chk "$L 6a 汚れ → 汚れのまま exit 0" exit_is "$d" 0
  chk "$L 6b 0 件" count_is "$d" 0
done

# ---- kimi-makabe の事後ガード(案 A、役員 人見 2026-10-03): launcher の GIT_COMMITTER_EMAIL の reflog エントリがあるときだけ逸脱 ----
# test-claude-makabe.sh の 7〜13 と同じ形を kimi 版に流す。main の checkout は base 側(wt は impl/x)。
if [ -z "${STATUS_DIFF_ONLY:-}" ] || [ "${STATUS_DIFF_ONLY:-}" = kimi-makabe ]; then
  echo "# ==== kimi-makabe の ref 事後ガード ===="
  other_env='GIT_COMMITTER_NAME=other GIT_COMMITTER_EMAIL=other@example.test GIT_AUTHOR_NAME=other GIT_AUTHOR_EMAIL=other@example.test'
  has_violation() { grep -q '権限逸脱' "$1/launcher.out" && grep -q "ref 変化を検出: $2" "$1/launcher.out"; }
  no_violation() { ! grep -q '権限逸脱' "$1/launcher.out"; }
  warned() { grep -q "警告.*$2" "$1/launcher.err"; }
  has_footer() { grep -q '^変更ファイル数: ' "$1/launcher.out" && grep -q '^makabe_commit_sha: ' "$1/launcher.out" && grep -q '^makabe_terminal: ' "$1/launcher.out"; }
  quiet_footer() { no_violation "$1" && has_footer "$1"; }
  master_warned() { exit_is "$1" 0 && warned "$1" refs/heads/master; }

  d="$(new_case kimi-makabe a-foreign)"
  cat >"$d/scenario.sh" <<S
echo hello >hello.txt
git add -A
$GAS anno commit -q -m "run commit"
env $other_env git -C "$d/base" commit -q --allow-empty -m "other window"
S
  run_launcher kimi-makabe "$d"
  chk "kimi-makabe A1 別名義の main の commit は exit 0" exit_is "$d" 0
  chk "kimi-makabe A2 警告 1 行(refs/heads/main)" warned "$d" refs/heads/main
  chk "kimi-makabe A3 権限逸脱を出さない・footer は通常どおり" quiet_footer "$d"

  d="$(new_case kimi-makabe a-makabe)"
  cat >"$d/scenario.sh" <<S
git -C "$d/base" commit -q --allow-empty -m "makabe moves main"
S
  run_launcher kimi-makabe "$d"
  chk "kimi-makabe A4 真壁名義の main の移動は exit 3" exit_is "$d" 3
  chk "kimi-makabe A5 権限逸脱: ref 変化を検出: refs/heads/main" has_violation "$d" refs/heads/main

  d="$(new_case kimi-makabe a-noreflog)"
  git -C "$d/base" config core.logAllRefUpdates false
  rm -f "$d/base/.git/logs/refs/heads/main"
  cat >"$d/scenario.sh" <<S
env $other_env git -C "$d/base" commit -q --allow-empty -m "other window"
S
  run_launcher kimi-makabe "$d"
  chk "kimi-makabe A6 reflog 無しは従来どおり exit 3" exit_is "$d" 3
  chk "kimi-makabe A7 権限逸脱の表示" has_violation "$d" refs/heads/main

  d="$(new_case kimi-makabe a-master)"
  git -C "$d/base" branch master
  "$GAS" anno -C "$d/base" commit -q --allow-empty -m ahead
  cat >"$d/scenario.sh" <<S
env $other_env git -C "$d/base" update-ref refs/heads/master "\$(git -C "$d/base" rev-parse main)"
S
  run_launcher kimi-makabe "$d"
  chk "kimi-makabe A8 別名義の master の移動は exit 0 + 警告" master_warned "$d"
fi

echo "---"; echo "$n tests, fail=$fail"
if [ "$fail" -eq 0 ]; then echo "ALL OK"; else
  echo "FAILED"; for f in "$sbx"/*/set.diff; do [ -s "$f" ] && { echo "== $f"; cat "$f"; }; done; exit 1
fi
