#!/usr/bin/env bash
# claude-makabe.sh / claude-kashiwagi.sh が source する、Claude Max 2 枚(a / b)の選択まわりの共通処理(関数定義のみ)。
# 親ゴール: 便が、1 枚目(a)の枠が尽きても人見の手なしで 2 枚目(b)で起きる。道具の本体は scripts/claude-acct.sh。
#
# acct_select <run_dir> <model> <ログ接頭辞(例 makabe/claude)> の後に使える変数:
#   acct_label    選んだ側(a / b)。pick が失敗・無効なら a(従来どおり)
#   acct_email    その側の email(分からなければ空)
#   acct_prefix   claude_args の先頭に付ける配列。a は空、b は (claude-acct.sh exec b --)
#   acct_exhausted  1 = 両方尽きた(pick が exit 75)。呼び出し側が dry-run でなければ exit 75 で終える
#   acct_summary  dry-run / ログ用の 1 行(資格の値は含まない)
# 書くもの: <run_dir>/account.json(label・email・reason・各枠の残り・線。資格の値は書かない)と、
#   選んだ側の dir で取った <run_dir>/rates.json(取れなければ作らない ── 従来の `rates claude` と同じ)。
# CLAUDE_ACCT_DISABLE=1 なら pick を呼ばず、従来どおり既定の `rates claude` を 1 回叩く。

acct_label="a"
acct_email=""
acct_prefix=()
acct_exhausted=0
acct_summary=""

acct_select() {
  local run_dir="$1" model="$2" who="${3:-launcher}"
  local acct_sh="$CORE/scripts/claude-acct.sh"
  local pick_json="$run_dir/pick.json" pick_rc=0
  acct_label="a"; acct_email=""; acct_prefix=(); acct_exhausted=0; acct_summary=""

  if [ "${CLAUDE_ACCT_DISABLE:-0}" = "1" ] || [ ! -x "$acct_sh" ]; then
    _acct_legacy_rates "$run_dir"
    acct_summary="account: a (claude-acct 無効、従来どおり)"
    return 0
  fi

  "$acct_sh" pick --model "$model" > "$pick_json" 2>"$run_dir/acct.err" || pick_rc=$?
  if [ "$pick_rc" -ne 0 ] && [ "$pick_rc" -ne 75 ]; then
    echo "警告: claude-acct pick が失敗した(exit $pick_rc、a で続行): $(tr '\n' ' ' < "$run_dir/acct.err")" >&2
    rm -f "$pick_json"
    _acct_legacy_rates "$run_dir"
    acct_summary="account: a (pick 失敗、従来どおり)"
    return 0
  fi
  if [ -s "$run_dir/acct.err" ]; then
    while IFS= read -r line; do printf '[%s/acct] %s\n' "$who" "$line" >&2; done < "$run_dir/acct.err"
  fi

  # pick.json から account.json / rates.json / 変数を作る。資格の値は pick の出力に無いので、ここにも無い。
  local parsed
  if ! parsed="$(python3 - "$pick_json" "$run_dir" <<'PY'
import json
import os
import sys

pick_path, run_dir = sys.argv[1], sys.argv[2]
d = json.load(open(pick_path))
label = d.get("label")
chosen = (d.get("candidates") or {}).get(label) if label else None
# account.json: 各候補の rates 生 JSON は rates.json に回すので落とす
slim = {k: v for k, v in d.items() if k != "candidates"}
slim["candidates"] = {}
for name, cand in (d.get("candidates") or {}).items():
    slim["candidates"][name] = {k: v for k, v in cand.items() if k != "rates"}
with open(os.path.join(run_dir, "account.json"), "w") as f:
    json.dump(slim, f, ensure_ascii=False, indent=2)
    f.write("\n")
if chosen and isinstance(chosen.get("rates"), dict):
    with open(os.path.join(run_dir, "rates.json"), "w") as f:
        json.dump(chosen["rates"], f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
rem = (chosen or {}).get("remaining") or {}
brief = " ".join(f"{k}={v}" for k, v in rem.items() if v is not None)
print(label or "-")
print((chosen or {}).get("email") or "")
print(d.get("reason") or "")
print(brief)
PY
  )"; then
    echo "警告: claude-acct pick の出力を解析できない(a で続行)" >&2
    _acct_legacy_rates "$run_dir"
    acct_summary="account: a (pick 解析失敗、従来どおり)"
    return 0
  fi
  local l1 l2 l3 l4
  l1=""; l2=""; l3=""; l4=""
  # 末尾の空行は $(...) が削るので、最後の read は失敗しうる(set -e を踏ませない)
  { IFS= read -r l1 || true; IFS= read -r l2 || true; IFS= read -r l3 || true; IFS= read -r l4 || true; } <<<"$parsed"
  rm -f "$pick_json"

  if [ "$pick_rc" -eq 75 ]; then
    acct_exhausted=1
    acct_label="-"
    acct_summary="account: 両方尽きた ($l3) ── 起動しない(exit 75)"
    return 0
  fi
  acct_label="$l1"
  acct_email="$l2"
  if [ "$acct_label" = "b" ]; then
    acct_prefix=("$acct_sh" exec b --)
  fi
  acct_summary="account: $acct_label ${acct_email:-(email 不明)} reason=$l3 remaining: $l4"
  return 0
}

# 従来の挙動: 既定の設定ディレクトリで `rates claude` を 1 回、<run_dir>/rates.json へ。失敗は警告して続行
_acct_legacy_rates() {
  local run_dir="$1"
  if command -v rates >/dev/null 2>&1; then
    if ! rates claude > "$run_dir/rates.json" 2>"$run_dir/rates.err"; then
      echo "警告: rates claude の取得に失敗した(続行): $(tr '\n' ' ' < "$run_dir/rates.err")" >&2
      rm -f "$run_dir/rates.json"
    fi
  else
    echo "警告: rates コマンドが見つからない(続行)" >&2
  fi
}
