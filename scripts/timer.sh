#!/usr/bin/env bash
# usage: bash scripts/timer.sh <duration_seconds> [label] [log1 log2 ...]
#   duration: 整数秒(例: 265, 600)
#   label:    出力に乗せる識別子(任意、既定 "timer")
#   log...:   監視する codex .session.log path を 1 つ以上(任意、可変長)
#
# log を 1 つ以上渡すと、起動時点の行数を 0 起点として新規追記行のみ判定し、
# 下記マーカーを検出した時点で stdout に日本語通知する:
#   正常終端       : "tokens used"        → 即解除(累計 1 回)
#   着地報告(継続) : "[impl-done]"        → 記録のみ、解除しない
#   エラー         : "^Error:" | "^FAILED" | "^panic" | "Connection reset" | "^ERR_"
#                                          → 全 log 累計 3 回で解除
# log 無指定なら pure sleep(ハートビートのみ)。
#
# 30 秒ごとに「監視中 経過=N秒 残=N秒」ハートビート行を吐く(両モード共通)。
# これにより動作中も .output に内容が積まれ続け、バックグラウンドタスク欄の
# トグルが count 中から開けるようになる。
#
# Claude Code は Bash tool で run_in_background: true で起動し、その task_id に
# 対して即座に TaskOutput(block=true, timeout=duration*1000+60000) で wait する
# 前提。これにより:
#   - 動作中もバックグラウンドタスク欄の UI トグルで進捗(起動通知 / ハートビート
#     / hit 行)が随時見える
#   - Claude も TaskOutput でブロックされ、timer 終了で即座に unblock → 次手
#   - TaskOutput は出力ファイル監視ベースのため、harness の event 配信通知落ち
#     (run_in_background completion 通知の取りこぼし)の影響を受けない

# stdbuf -oL で stdout を line-buffered に強制(Git Bash の block buffer 回避、
# TaskOutput / .output ファイルへの即時 flush 保証)。stdbuf 未導入環境では no-op。
if [ -z "${TIMER_SH_LINEBUF:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export TIMER_SH_LINEBUF=1
  exec stdbuf -oL bash "$0" "$@"
fi

set -euo pipefail

dur="${1:?duration required (integer seconds, e.g. 265, 600)}"
label="${2:-timer}"
shift $(( $# >= 2 ? 2 : $# ))
logs=("$@")

PAT_DONE='tokens used'
PAT_NOTE='\[impl-done\]'
PAT_ERR='^Error:|^FAILED|^panic|Connection reset|^ERR_'
ERR_THRESHOLD=3
HEARTBEAT_INTERVAL=30

ts() { date '+%H:%M:%S'; }
start=$(date -Iseconds)
start_epoch=$(date +%s)

# pure sleep モード(log 無指定)
if [ ${#logs[@]} -eq 0 ]; then
  echo "[$label] [$(ts)] タイマー起動 残=${dur}秒 モード=純sleep"
  last_heartbeat=$start_epoch
  while :; do
    now_epoch=$(date +%s)
    elapsed=$((now_epoch - start_epoch))
    if [ "$elapsed" -ge "$dur" ]; then
      break
    fi
    # 最後の heartbeat から HEARTBEAT_INTERVAL 秒以上経ったら出力
    if [ $((now_epoch - last_heartbeat)) -ge "$HEARTBEAT_INTERVAL" ]; then
      echo "[$label] [$(ts)] 監視中 経過=${elapsed}秒 残=$((dur - elapsed))秒"
      last_heartbeat=$now_epoch
    fi
    # 残時間と heartbeat 間隔の小さい方だけ sleep(終了時刻を超えない)
    remain=$((dur - elapsed))
    next_hb=$((HEARTBEAT_INTERVAL - (now_epoch - last_heartbeat)))
    step=$(( remain < next_hb ? remain : next_hb ))
    [ "$step" -lt 1 ] && step=1
    sleep "$step"
  done
  end=$(date -Iseconds)
  echo "[$label] [$(ts)] タイマー終了 理由=純sleep完了 開始=$start 終了=$end 経過=$(($(date +%s) - start_epoch))秒"
  exit 0
fi

# log 監視モード
echo "[$label] [$(ts)] タイマー起動 残=${dur}秒 監視log=${logs[*]}"

declare -A read_lines
for log in "${logs[@]}"; do
  if [ -f "$log" ]; then
    read_lines["$log"]=$(wc -l < "$log" | tr -d ' ')
  else
    read_lines["$log"]=0
  fi
done

err_count=0
last_heartbeat=$start_epoch

while :; do
  now_epoch=$(date +%s)
  elapsed=$((now_epoch - start_epoch))

  for log in "${logs[@]}"; do
    [ -f "$log" ] || continue
    cur=$(wc -l < "$log" | tr -d ' ')
    prev="${read_lines[$log]}"
    if [ "$cur" -le "$prev" ]; then
      continue
    fi
    new_block=$(tail -n +"$((prev + 1))" "$log" | head -n "$((cur - prev))")
    read_lines["$log"]=$cur

    [ -n "$new_block" ] || continue

    while IFS= read -r line; do
      if printf '%s\n' "$line" | grep -qE "$PAT_DONE"; then
        echo "[$label] [$(ts)] 正常終端を検知 log=$log 内容=\"$line\""
        end=$(date -Iseconds)
        echo "[$label] [$(ts)] タイマー終了 理由=正常終端解除 開始=$start 終了=$end 経過=$(($(date +%s) - start_epoch))秒 log=$log"
        exit 0
      elif printf '%s\n' "$line" | grep -qE "$PAT_NOTE"; then
        echo "[$label] [$(ts)] 着地報告を捕捉(継続中) log=$log 内容=\"$line\""
      elif printf '%s\n' "$line" | grep -qE "$PAT_ERR"; then
        err_count=$((err_count + 1))
        echo "[$label] [$(ts)] エラー検知 累計=$err_count log=$log 内容=\"$line\""
        if [ "$err_count" -ge "$ERR_THRESHOLD" ]; then
          end=$(date -Iseconds)
          echo "[$label] [$(ts)] タイマー終了 理由=エラー累計閾値到達 開始=$start 終了=$end 経過=$(($(date +%s) - start_epoch))秒 累計エラー=$err_count"
          exit 0
        fi
      fi
    done <<< "$new_block"
  done

  # heartbeat: 実時間ベース、最後の heartbeat から HEARTBEAT_INTERVAL 秒経過で出力
  if [ "$elapsed" -ge "$dur" ]; then
    break
  fi

  now_epoch=$(date +%s)
  elapsed=$((now_epoch - start_epoch))
  if [ $((now_epoch - last_heartbeat)) -ge "$HEARTBEAT_INTERVAL" ] && [ "$elapsed" -lt "$dur" ]; then
    echo "[$label] [$(ts)] 監視中 経過=${elapsed}秒 残=$((dur - elapsed))秒 累計エラー=$err_count"
    last_heartbeat=$now_epoch
  fi

  sleep 1
done

end=$(date -Iseconds)
echo "[$label] [$(ts)] タイマー終了 理由=時間切れ 開始=$start 終了=$end 経過=$(($(date +%s) - start_epoch))秒 累計エラー=$err_count"
