#!/usr/bin/env bash
# 便のランチャ(claude-niekawa.sh / kimi-niekawa.sh / codex-agent.sh)を Claude デスクトップの
# scope から切り離し、独立した systemd --user の service に載せ直す(案 A、役員 人見 裁定 2026-09-25、
# `company/tech/_sessions/` 09-25 の事故を受ける)。
#
# 事故の経緯: 2026-09-25 05:46、IME の便のゲートの python が 16.8GB に膨らんで OOM kill された。
# systemd の既定 DefaultOOMPolicy=stop によって、その python を含んでいた
# `app-com.anthropic.Claude-*.scope`(Claude デスクトップの scope)が丸ごと止まり、便 2 本
# (贄川・真壁・柏木)・鷹野の Claude・test 用の PG が全部道連れで落ちた。便はどれも Claude
# デスクトップから起動していて、その scope の中の子だった。
# 案 B(`~/.config/systemd/user.conf.d/oom-policy.conf` の `DefaultOOMPolicy=continue`)は
# scope ごと止まることは防ぐが、Claude デスクトップと便がまだ同じ scope に相乗りのままなので、
# 逆方向(Claude デスクトップや別の窓が落ちると便が道連れになる)は残る。本ファイルは案 A ──
# 便を呼び手の scope から物理的に外し、便ごとに独立した systemd --user の transient service
# (`--scope` ではない、scope は呼び手の子のまま道連れになる)へ移す。
#
# 呼び手から見た形は変えない:
#   - 起動コマンドの形(`claude-niekawa -f BRIEF.md --budget N > log 2>&1 &`)は変わらない
#   - stdout / stderr は同じ log に入る(呼び手の fd1/fd2 の行き先へ、unit 内の実行も直接追記する)
#   - 見張りに使える pid を返す(呼び手の pid は unit の完了まで生き続ける、`--wait` 相当)
#   - 呼び手が死んでも unit は生き残る(`systemd-run --wait` の client を kill しても service は
#     続く ── 実測済み。`--pipe` は使わない、pipe だと呼び手が死ぬとパイプが切れて道連れになる)
#
# 使い方(呼び出し元スクリプトの先頭、set -euo pipefail の直後・resolve_self の直後):
#   # shellcheck source=lib/unit-wrap.sh
#   source "$CORE/scripts/lib/unit-wrap.sh"
#   if niekawa_unit_wrap "<persona>" "$script_path" "$@"; then
#     exit "$NIEKAWA_UNIT_WRAP_EXIT_CODE"
#   fi
#   # ここに来るのは wrap しなかったとき(退避口 / systemd-run 無し / 既に unit 内)。
#   # 呼び出し元スクリプトはそのまま今までどおり in-process で続ける。
#
# 退避口:
#   - env NIEKAWA_NO_UNIT=1 ── unit化せず、その場で走る(今までの動き)
#   - systemd-run が無い環境 ── 警告を出して in-process にフォールバック
#   - systemd --user が使えない環境(show-environment が失敗)── 同上
#   - 既に unit の中(NIEKAWA_UNIT_WRAPPED=1 が継承されている)── 二重ラップしない
#
# 上書き可能な env:
#   NIEKAWA_UNIT_MEMORY_MAX      既定 12G(systemd.resource-control の MemoryMax=)
#   NIEKAWA_UNIT_MEMORY_SWAP_MAX 既定 1G(同 MemorySwapMax=)
#   NIEKAWA_UNIT_OOM_POLICY      既定 continue(同 OOMPolicy=。continue|stop|kill)
#
# 既知の穴: unit化すると unit のプロセスの標準入力は /dev/null になる(systemd-run は既定で
# stdin を渡さない、--pipe / --pty は道連れ事故の元なので使わない)。「-f も task 引数も無いときは
# 標準入力からタスク本文を読む」経路は unit化すると使えなくなる。鷹野からの起動は文書化された形
# (`-f BRIEF.md`)を常に使うため実害は無い想定だが、退避口 NIEKAWA_NO_UNIT=1 で元の動きに戻せる。

# niekawa_unit_wrap <persona> <script_path> [元の CLI 引数...]
#   persona: unit名の接頭辞に使う短い識別子(例: niekawa, makabe)
#   script_path: 再実行する自分自身の絶対パス(呼び出し元の resolve_self の結果)
#   残りの引数: 元の CLI 引数をそのまま(このまま同じ script へ再現する)
#
# 戻り値:
#   0: wrap して unit の完了まで待った。NIEKAWA_UNIT_WRAP_EXIT_CODE に終了コードを入れる。
#      呼び出し元は `exit "$NIEKAWA_UNIT_WRAP_EXIT_CODE"` で終わること(この先には進まない)
#   1: wrap しなかった。呼び出し元はそのまま in-process で続ける
niekawa_unit_wrap() {
  local persona="$1"
  local script_path="$2"
  shift 2
  # 残りの "$@" が元の CLI 引数

  NIEKAWA_UNIT_WRAP_EXIT_CODE=0

  if [ "${NIEKAWA_UNIT_WRAPPED:-0}" = "1" ]; then
    return 1
  fi
  if [ "${NIEKAWA_NO_UNIT:-0}" = "1" ]; then
    return 1
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "[unit-wrap] 警告: systemd-run が無い。unit化せずその場で走る" >&2
    return 1
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "[unit-wrap] 警告: systemd --user が使えない。unit化せずその場で走る" >&2
    return 1
  fi

  local mem_max swap_max oom_policy
  mem_max="${NIEKAWA_UNIT_MEMORY_MAX:-12G}"
  swap_max="${NIEKAWA_UNIT_MEMORY_SWAP_MAX:-1G}"
  oom_policy="${NIEKAWA_UNIT_OOM_POLICY:-continue}"

  local ts unit
  ts="$(date '+%Y%m%d%H%M%S')"
  unit="${persona}-${ts}-$$-${RANDOM}"

  # 呼び手の fd1 / fd2 の行き先(通常は `> log 2>&1` で開かれた実ファイル)を見つける。
  # 実ファイルでなければ(tty・pipe 等)諦めて journal へ落とす(unit の既定の StandardOutput)。
  local out_target="" err_target=""
  out_target="$(readlink -f "/proc/$$/fd/1" 2>/dev/null || true)"
  err_target="$(readlink -f "/proc/$$/fd/2" 2>/dev/null || true)"
  [ -n "$out_target" ] && [ -f "$out_target" ] || out_target=""
  [ -n "$err_target" ] && [ -f "$err_target" ] || err_target=""
  if [ -n "$out_target" ] && [ -z "$err_target" ]; then
    err_target="$out_target"
  fi

  # 呼び手自身(この pre-wrap プロセス)の fd1/fd2 を、unit 内のプロセスが使うのと同じ
  # O_APPEND の fd に差し替える。差し替えないと、呼び手の元の fd(`> log` は O_APPEND
  # ではない ── 自分のカーソル位置に固定で書く)と unit 内の fd(`>>` で O_APPEND)が
  # 同じファイルを別のカーソルで書き合い、片方がもう片方を上書きして文字化けならぬ
  # 行の欠落が起きる(実測 ── die() のエラー文の前半が消えた事故)。
  if [ -n "$out_target" ]; then
    exec 1>>"$out_target"
  fi
  if [ -n "$err_target" ]; then
    exec 2>>"$err_target"
  fi

  # 呼び手の env を漏れなく渡す(systemd-run --user は呼び手の env を引き継がない)。
  local -a setenv_args=()
  local var
  for var in $(compgen -e); do
    case "$var" in
      NIEKAWA_UNIT_WRAPPED) continue ;;
      PATH|HOME|LANG|LC_ALL|LC_CTYPE|TERM|USER|LOGNAME|SHELL|TZ|TMPDIR) ;;
      CODEX_*|CLAUDE_*|ANTHROPIC_*|KASHIWAGI_*|MAKABE_*|MINASE_*|NIEKAWA_*|KIMI_*|ANNO_*|TAKANO_*|GIT_*|ORCH_*) ;;
      *) continue ;;
    esac
    setenv_args+=(-E "${var}=${!var}")
  done
  setenv_args+=(-E "NIEKAWA_UNIT_WRAPPED=1")

  local workdir
  workdir="$(pwd -P)"

  # 呼び手の fd1/fd2 の行き先が分かれば、unit 内のプロセスにも同じ行き先へ直接追記させる
  # (systemd の StandardOutput 経由ではなく、実行するコマンド自身に `>>` させる ── --pipe を
  # 使わずに「stdout / stderr は同じ log に入る」を満たすため)。
  local -a inner_cmd
  if [ -n "$out_target" ]; then
    inner_cmd=(bash -c 'out="$1"; err="$2"; shift 2; exec "$@" >>"$out" 2>>"$err"' \
      _ "$out_target" "${err_target:-$out_target}" bash "$script_path" "$@")
  else
    inner_cmd=(bash "$script_path" "$@")
  fi

  echo "[unit-wrap] persona=$persona unit=${unit}.service へ載せ替える(MemoryMax=$mem_max MemorySwapMax=$swap_max OOMPolicy=$oom_policy)" >&2

  local sdrun_log
  sdrun_log="$(mktemp)"
  (
    exec systemd-run --user --unit="$unit" --collect \
      --description="niekawa-unit ${persona} ${unit}" \
      --working-directory="$workdir" \
      -p "OOMPolicy=${oom_policy}" \
      -p "MemoryMax=${mem_max}" \
      -p "MemorySwapMax=${swap_max}" \
      "${setenv_args[@]}" \
      --wait -- "${inner_cmd[@]}"
  ) >"$sdrun_log" 2>&1 &
  local sdrun_pid=$!

  # MainPID(unit 内で実際に走るプロセスの pid)を短い poll で見つけて 1 行 log に書く。
  local mainpid="" tries=0
  while [ "$tries" -lt 100 ]; do
    mainpid="$(systemctl --user show -p MainPID --value "${unit}.service" 2>/dev/null || true)"
    if [ -n "$mainpid" ] && [ "$mainpid" != "0" ]; then
      break
    fi
    if ! kill -0 "$sdrun_pid" 2>/dev/null; then
      # systemd-run 自体がもう終わっている(起動に失敗した等)。これ以上待たない
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  echo "[unit-wrap] unit=${unit}.service MainPID=${mainpid:-不明}" >&2

  set +e
  wait "$sdrun_pid"
  NIEKAWA_UNIT_WRAP_EXIT_CODE=$?
  set -e

  # systemd-run 自身の診断出力(Running as unit: / Finished with result: 等)を
  # 呼び手の log(あれば)へも残す。無ければ自分の stderr へ(journal 相当)。
  if [ -s "$sdrun_log" ]; then
    if [ -n "$out_target" ]; then
      cat "$sdrun_log" >>"$out_target" 2>/dev/null || cat "$sdrun_log" >&2
    else
      cat "$sdrun_log" >&2
    fi
  fi
  rm -f "$sdrun_log"

  return 0
}
