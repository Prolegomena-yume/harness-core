#!/usr/bin/env bash
# usage: inbox-e2e.sh [--evidence-dir <path>] [--batch <name>]
#
# 鷹野受信箱(便ディレクトリ・to-takano/to-niekawa・--resume-run・trap)の通し E2E。
# 鷹野役を演じて 5 経路(裁定要求 → 裁定を返す → 280秒切片中の指示 → cap到達と張り直し →
# 終端 → SIGTERM 異常終了)を順に通す(BRIEF-inbox-2 D節、2026-09-20)。
#
# 軽量・実処理無し。真壁・柏木は起こさない。kimi-niekawa は毎回 --no-loop(1 巡)で呼ぶので、
# 全体の K3 巡数は run1 + run2 + run3 の 3 巡で止まる。
#
# 再実行可能:箱・run_dir は --batch(既定は時刻+pidから自動生成)で毎回新規になる。
# 既定の状態置き場は $CODEX_AGENT_STATE_DIR(未設定なら ~/.codex-agents、実環境と同じ)。

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
brief1="$script_dir/brief-inbox-e2e.md"
brief3="$script_dir/brief-inbox-e2e-term.md"

evidence_dir="./inbox-evidence-2"
batch=""

usage() {
  echo "usage: inbox-e2e.sh [--evidence-dir <path>] [--batch <name>]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --evidence-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      evidence_dir="$2"
      shift 2
      ;;
    --batch)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      batch="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$batch" ] || batch="e2e-inbox-$(date '+%Y%m%d-%H%M%S')-$$"

mkdir -p "$evidence_dir"
evidence_dir="$(cd "$evidence_dir" && pwd -P)"
workdir="$evidence_dir/workdir"
rm -rf "$workdir"
mkdir -p "$workdir"

agent_state_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}"
batch_dir="$agent_state_dir/batches/$batch"
takano_inbox="$batch_dir/to-takano.tsv"
niekawa_inbox="$batch_dir/to-niekawa.tsv"

log() { echo "[e2e] $(date '+%H:%M:%S') $*"; }

log "便: $batch"
log "便ディレクトリ: $batch_dir"
log "作業ディレクトリ: $workdir"
log "evidence: $evidence_dir"

{
  echo "便: $batch"
  echo "便ディレクトリ: $batch_dir"
  echo "作業ディレクトリ: $workdir"
} > "$evidence_dir/00-meta.txt"

takano_after=0

# from-niekawa --wait を呼び、結果を $1 に保存する。exit code を返す(from.sh の exit をそのまま)。
# 注意: ここで `set -e` を戻さない ── 戻すと呼び出し側の `set +e` を上書きして、この関数が
# 非 0 を return した瞬間に errexit で落ちる(bash の set はシェル全体に効きスコープを持たない)。
# 呼び出し側が status を読んだ後に自分で `set -e` へ戻す契約にする。
call_wait() {
  local out_file="$1" cap="$2" pid_arg="$3"
  local status
  set +e
  if [ -n "$pid_arg" ]; then
    from-niekawa --wait --cap "$cap" --after "$takano_after" --pid "$pid_arg" --inbox "$takano_inbox" > "$out_file" 2>&1
  else
    from-niekawa --wait --cap "$cap" --after "$takano_after" --inbox "$takano_inbox" > "$out_file" 2>&1
  fi
  status=$?
  local new_after
  new_after="$(sed -nE 's/^LINES=//p' "$out_file" | tail -1)"
  if [ -n "$new_after" ]; then
    takano_after="$new_after"
  fi
  return "$status"
}

# ============================================================
# 1. 裁定を求める(run 1) ── 空の hello.txt + verdict: エスカレーション
# ============================================================
log "1. run 1 起動(裁定を求める)"
set +e
kimi-niekawa --no-loop --batch "$batch" -C "$workdir" -f "$brief1" \
  --log "$evidence_dir/run1.launcher.log" > "$evidence_dir/run1.launcher.out" 2>&1
run1_status=$?
set -e
echo "$run1_status" > "$evidence_dir/run1.exit"
run1_dir="$(sed -nE 's/^run_dir: //p' "$evidence_dir/run1.launcher.out" | tail -1)"
echo "$run1_dir" > "$evidence_dir/run1.run_dir"
log "1. run1_status=$run1_status run_dir=$run1_dir"

log "1. from-niekawa --wait(エスカレーション=exit 2 を期待)"
set +e
call_wait "$evidence_dir/wait1.out" 60 ""
wait1_status=$?
set -e
echo "$wait1_status" > "$evidence_dir/wait1.exit"
log "1. wait1_status=$wait1_status LINES=$takano_after"

# ============================================================
# 2. 裁定を返す(新 run 2、--resume-run)
# ============================================================
log "2. 裁定を post: A"
to-niekawa --inbox "$niekawa_inbox" --kind 裁定 -- "A" > "$evidence_dir/post-verdict-A.out" 2>&1

log "2/3. run 2 起動(--resume-run、バックグラウンド)"
kimi-niekawa --no-loop --batch "$batch" --resume-run -C "$workdir" -f "$brief1" \
  --log "$evidence_dir/run2.launcher.log" > "$evidence_dir/run2.launcher.out" 2>&1 &
launcher2_pid=$!
echo "$launcher2_pid" > "$evidence_dir/run2.pid"

# ============================================================
# 3. 280 秒切片の間に指示を post する(run2 の kimi が sleep 280 している間)
# ============================================================
sleep 5
log "3. 指示を post: 末尾に!を足せ"
to-niekawa --inbox "$niekawa_inbox" --kind 指示 -- "末尾に!を足せ" > "$evidence_dir/post-inst-1.out" 2>&1

# ============================================================
# 4. cap 到達 → 張り直し → 終端(exit 0)
# ============================================================
log "4. from-niekawa --wait --cap 120(1 回目、cap 到達 exit 1 を期待)"
set +e
call_wait "$evidence_dir/wait2-a.out" 120 "$launcher2_pid"
wait2a_status=$?
set -e
echo "$wait2a_status" > "$evidence_dir/wait2.exit"
log "4. wait2a_status=$wait2a_status LINES=$takano_after"

log "4. from-niekawa --wait 張り直し(2 回目、終端 exit 0 を期待)"
set +e
call_wait "$evidence_dir/wait2-b.out" 600 "$launcher2_pid"
wait2b_status=$?
set -e
echo "$wait2b_status" >> "$evidence_dir/wait2.exit"
log "4. wait2b_status=$wait2b_status LINES=$takano_after"

set +e
wait "$launcher2_pid" 2>/dev/null
run2_status=$?
set -e
echo "$run2_status" > "$evidence_dir/run2.exit"
run2_dir="$(sed -nE 's/^run_dir: //p' "$evidence_dir/run2.launcher.out" | tail -1)"
echo "$run2_dir" > "$evidence_dir/run2.run_dir"
log "5. run2_status=$run2_status run_dir=$run2_dir"

# ============================================================
# 5. 終端の検算(hello.txt の中身、verdict.md、footer)
# ============================================================
if [ -f "$workdir/hello.txt" ]; then
  cp "$workdir/hello.txt" "$evidence_dir/hello.txt"
  log "5. hello.txt = $(cat "$workdir/hello.txt")"
else
  log "5. hello.txt が無い"
fi

# ============================================================
# 6. 異常終了(SIGTERM)── run 3 を起こし、60 秒後に SIGTERM
# ============================================================
log "6. run 3 起動(異常終了テスト、バックグラウンド)"
kimi-niekawa --no-loop --batch "$batch" -C "$workdir" -f "$brief3" \
  --log "$evidence_dir/run3.launcher.log" > "$evidence_dir/run3.launcher.out" 2>&1 &
launcher3_pid=$!
echo "$launcher3_pid" > "$evidence_dir/run3.pid"

sleep 60
log "6. ランチャ(pid=$launcher3_pid)へ SIGTERM"
kill -TERM "$launcher3_pid" 2>/dev/null || true

log "6. from-niekawa --wait(異常終了=exit 3 を期待)"
set +e
call_wait "$evidence_dir/wait3.out" 60 "$launcher3_pid"
wait3_status=$?
set -e
echo "$wait3_status" > "$evidence_dir/wait3.exit"
log "6. wait3_status=$wait3_status LINES=$takano_after"

set +e
wait "$launcher3_pid" 2>/dev/null
run3_status=$?
set -e
echo "$run3_status" > "$evidence_dir/run3.exit"
run3_dir="$(sed -nE 's/^run_dir: //p' "$evidence_dir/run3.launcher.out" | tail -1)"
echo "$run3_dir" > "$evidence_dir/run3.run_dir"
log "6. run3_status=$run3_status run_dir=$run3_dir"

# ============================================================
# 7. evidence をまとめる(箱2つの全行、各 run_dir、各 wait の stdout)
# ============================================================
[ -f "$takano_inbox" ] && cp "$takano_inbox" "$evidence_dir/box-to-takano.tsv" || : > "$evidence_dir/box-to-takano.tsv"
[ -f "$niekawa_inbox" ] && cp "$niekawa_inbox" "$evidence_dir/box-to-niekawa.tsv" || : > "$evidence_dir/box-to-niekawa.tsv"
[ -f "$batch_dir/runs.tsv" ] && cp "$batch_dir/runs.tsv" "$evidence_dir/box-runs.tsv" || : > "$evidence_dir/box-runs.tsv"

{
  echo "run1_status=$run1_status run1_dir=$run1_dir"
  echo "wait1_status=$wait1_status"
  echo "run2_status=$run2_status run2_dir=$run2_dir"
  echo "wait2a_status=$wait2a_status wait2b_status=$wait2b_status"
  echo "run3_status=$run3_status run3_dir=$run3_dir"
  echo "wait3_status=$wait3_status"
  echo "hello.txt=$(cat "$workdir/hello.txt" 2>/dev/null || echo '(無し)')"
  echo "box-to-takano.tsv 行数=$(wc -l < "$evidence_dir/box-to-takano.tsv" | tr -d ' ')"
  echo "box-to-niekawa.tsv 行数=$(wc -l < "$evidence_dir/box-to-niekawa.tsv" | tr -d ' ')"
  echo "box-runs.tsv 行数=$(wc -l < "$evidence_dir/box-runs.tsv" | tr -d ' ')"
} | tee "$evidence_dir/99-summary.txt"

log "完了。evidence: $evidence_dir"
