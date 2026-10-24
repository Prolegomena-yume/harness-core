#!/usr/bin/env python3
"""claude-acct.sh の本体 ── Claude Max 2 枚(a / b)のうち、便を起こす側を起動時に選ぶ。

親ゴール: claude-makabe / claude-kashiwagi の便が、1 枚目(a)の枠が尽きたら人見の手なしで 2 枚目(b)で起き、
b の資格の更新は Claude Code 自身に任せる(1 年 token も自前の refresh も持たない)。
設計の正典は company/tech の _drafts/claude-acct/01-research.v0.md「4. うちの形に当てる」。ただし b の渡し方は
env の token(案 A の初版)から CLAUDE_CONFIG_DIR 方式に替えた(b.token の貼り付けが崩れた事故があり、自前 refresh も採らないため。鷹野 2026-10-25)。

  pick [--model ID] [--policy primary]   各枠の残りを読み、a / b を JSON 1 行で stdout に出す。資格の値は出さない
                                          exit 0 = 選んだ / 75 = 両方尽きた(label は null) / 2 = 使い方の誤り
  exec <a|b> -- cmd...                    b なら CLAUDE_CONFIG_DIR=<b の dir> を子の env に入れて exec。a は何も足さず、CLAUDE_CONFIG_DIR だけ外す
  is-limit <result.json> [stream.jsonl]   枠切れで終わった run か(exit 0 = 枠切れ / 1 = 違う)。launcher の終端にはまだ繋がない

b の形:
  - b の dir(~/.claude-b)は b で `claude auth login` した設定ディレクトリ。資格(.credentials.json)と .claude.json だけが b のもので、
    settings.json・settings.local.json・skills・plugins・projects は ../.claude/ への symlink(人見・鷹野が張る)。
    そのため b の便も hook・plugin・transcript・--resume は a と同じものを使う
  - b の資格の更新は、b の dir で動く Claude Code 本体と rates(期限の 60 秒前に更新)に任せる。claude-acct は b の資格を読みも書きもしない
  - b を選べる条件は「b の dir の `rates claude` が読めること」(読めればその時点で資格は生きている)。token の出どころ・期限の判定は持たない

資格の扱い:
  - a の資格(<a_dir>/.credentials.json)も b の資格(<b_dir>/.credentials.json)も、claude-acct は開かない
  - env の CLAUDE_CODE_OAUTH_TOKEN・GUI 由来の account 情報は b の子に持ち込まない(a の資格や token が b の dir の資格に勝たないように)
  - ANTHROPIC_API_KEY など優先順位が資格より上の env があれば、b を選ばず exec b も止める

env(全部省略可):
  CLAUDE_ACCT_A_DIR           a の設定ディレクトリ(既定 ~/.claude。env の CLAUDE_CONFIG_DIR は見ない ── exec a が外すため)
  CLAUDE_ACCT_B_DIR           b の設定ディレクトリ(既定 ~/.claude-b)
  CLAUDE_ACCT_SWITCH_AT       a のどれかの枠の残りがこの値以下なら b を見る(既定 5)
  CLAUDE_ACCT_STOP_AT         b のどれかの枠の残りがこの値以下なら b は尽きた扱い(既定 3)
  CLAUDE_ACCT_RATES           rates の実行ファイル(既定 rates、test で stub に替える)
  CLAUDE_ACCT_DISABLE=1       pick は常に a(従来の挙動)
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

EX_TEMPFAIL = 75
HOME = Path.home()

# 資格(CLAUDE_CONFIG_DIR の .credentials.json)より優先順位が上の資格(authentication.md の 1〜3 段)。あると b の dir を向けても黙って負ける
BLOCKING_ENV = ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY")
# GUI のセッションが子に渡す「どのアカウントか」の情報。b の便には持ち込まない(a の情報を b の資格に添えない)
ACCOUNT_HINT_ENV = ("CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_ORGANIZATION_UUID", "CLAUDE_CODE_USER_EMAIL")

LIMIT_RE = re.compile(r"hit your .* limit", re.IGNORECASE)


def cfg():
    env = os.environ
    return {
        "a_dir": env.get("CLAUDE_ACCT_A_DIR") or str(HOME / ".claude"),
        "b_dir": env.get("CLAUDE_ACCT_B_DIR") or str(HOME / ".claude-b"),
        "switch_at": float(env.get("CLAUDE_ACCT_SWITCH_AT") or 5),
        "stop_at": float(env.get("CLAUDE_ACCT_STOP_AT") or 3),
        "rates": env.get("CLAUDE_ACCT_RATES") or "rates",
        "disable": env.get("CLAUDE_ACCT_DISABLE") == "1",
    }


def warn(msg):
    print(f"[claude-acct] {msg}", file=sys.stderr)


# ---------------------------------------------------------------- rates

def run_rates(c, config_dir):
    """`CLAUDE_CONFIG_DIR=<dir> rates claude` の JSON(dict)。失敗は (None, 理由)。"""
    env = dict(os.environ)
    env["CLAUDE_CONFIG_DIR"] = config_dir
    try:
        p = subprocess.run([c["rates"], "claude"], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"rates を実行できない: {type(e).__name__}"
    if p.returncode != 0:
        return None, "rates claude が失敗: " + " ".join(p.stderr.split())[:160]
    try:
        d = json.loads(p.stdout)
        if not isinstance(d, dict) or not isinstance(d.get("remaining"), dict):
            raise ValueError("remaining が無い")
    except ValueError as e:
        return None, f"rates の出力が読めない: {e}"
    return d, None


def model_keys(remaining, model):
    """見る枠: 5h と weekly は常に。model が分かれば、その系統の週枠(weekly_sonnet / weekly_opus / weekly_<名>)も。"""
    keys = ["5h", "weekly"]
    m = (model or "").lower()
    if m:
        for k in remaining:
            if k.startswith("weekly_") and k != "weekly_cowork" and k[len("weekly_"):] in m:
                keys.append(k)
    return keys


def below(remaining, model, line):
    """線以下の枠の名前。値が null の枠は判断材料にしない。"""
    out = []
    for k in model_keys(remaining, model):
        v = remaining.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v <= line:
            out.append(k)
    return out


def has_value(remaining, model):
    return any(isinstance(remaining.get(k), (int, float)) and not isinstance(remaining.get(k), bool)
               for k in model_keys(remaining, model))


def blocking_env():
    return [k for k in BLOCKING_ENV if os.environ.get(k) not in (None, "", "0")]


# ---------------------------------------------------------------- pick

def cmd_pick(argv):
    model, policy = "", "primary"
    i = 0
    while i < len(argv):
        if argv[i] == "--model" and i + 1 < len(argv):
            model = argv[i + 1]; i += 2
        elif argv[i] == "--policy" and i + 1 < len(argv):
            policy = argv[i + 1]; i += 2
        else:
            print(f"pick: 不明な引数: {argv[i]}", file=sys.stderr)
            return 2
    if policy != "primary":
        print("pick: --policy は primary だけ(balance は作らない)", file=sys.stderr)
        return 2
    c = cfg()
    out = {"label": None, "email": None, "reason": "", "policy": policy, "model": model or None,
           "switch_at": c["switch_at"], "stop_at": c["stop_at"], "candidates": {}}

    def finish(label, reason, code=0):
        out["label"] = label
        out["reason"] = reason
        cand = out["candidates"].get(label) if label else None
        out["email"] = cand.get("email") if cand else None
        print(json.dumps(out, ensure_ascii=False))
        return code

    if c["disable"]:
        return finish("a", "disabled")

    a, a_err = run_rates(c, c["a_dir"])
    if a is None or not has_value(a["remaining"], model):
        out["candidates"]["a"] = {"ok": False, "error": a_err or "枠の値が無い", "dir": c["a_dir"]}
        warn(f"a の rates を読めない(a に倒す): {out['candidates']['a']['error']}")
        return finish("a", "a-rates-failed")
    a_below = below(a["remaining"], model, c["switch_at"])
    out["candidates"]["a"] = {"ok": True, "email": a.get("email"), "remaining": a["remaining"],
                              "below_switch": a_below, "dir": c["a_dir"], "rates": a}
    if not a_below:
        return finish("a", "a-above-line")

    # a のどれかが切り替えの線以下 ── b を見る
    b, b_err = run_rates(c, c["b_dir"])
    unavailable = None
    if b is None or not has_value(b["remaining"], model):
        unavailable = "b-rates-failed"
        out["candidates"]["b"] = {"ok": False, "error": b_err or "枠の値が無い", "dir": c["b_dir"]}
    else:
        b_below = below(b["remaining"], model, c["stop_at"])
        out["candidates"]["b"] = {"ok": True, "email": b.get("email"), "remaining": b["remaining"],
                                  "below_stop": b_below, "dir": c["b_dir"], "rates": b}
        if not b_below:
            blk = blocking_env()
            if blk:
                unavailable = "b-blocked-by-env"
                out["candidates"]["b"]["blocked_by_env"] = blk
                warn("b を選べない: " + ", ".join(blk) + " が env にある(優先順位が b の dir の資格より上)")
            else:
                return finish("b", "a-below-switch-line")
        else:
            out["candidates"]["b"]["exhausted"] = True
    if unavailable is None:
        # a は線以下、b も止める線以下 ── 両方尽きた
        return finish(None, "both-exhausted", EX_TEMPFAIL)
    # b が使えない(尽きたのではなく、rates が読めない・env が塞ぐ)。a が止める線より上なら a で続ける(従来の挙動)
    if not below(a["remaining"], model, c["stop_at"]):
        return finish("a", unavailable + "-stay-a")
    return finish(None, "both-exhausted:" + unavailable, EX_TEMPFAIL)


# ---------------------------------------------------------------- exec

def cmd_exec(argv):
    if not argv or argv[0] not in ("a", "b"):
        print("使い方: claude-acct.sh exec <a|b> -- cmd...", file=sys.stderr)
        return 2
    label = argv[0]
    rest = argv[1:]
    if rest and rest[0] == "--":
        rest = rest[1:]
    if not rest:
        print("exec: 実行するコマンドが無い", file=sys.stderr)
        return 2
    env = dict(os.environ)
    if label == "b":
        blk = blocking_env()
        if blk:
            print("エラー: b の dir を向けられない ── " + ", ".join(blk) + " が env にある。優先順位が "
                  "CLAUDE_CONFIG_DIR の資格より上で、黙って別の資格で動いてしまう。unset してから起こす", file=sys.stderr)
            return 2
        b_dir = cfg()["b_dir"]
        if not (Path(b_dir) / ".credentials.json").is_file():
            print(f"エラー: b の資格が無い: {b_dir}/.credentials.json(b で `CLAUDE_CONFIG_DIR={b_dir} claude auth login` が要る)", file=sys.stderr)
            return 3
        env["CLAUDE_CONFIG_DIR"] = b_dir
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        for k in ACCOUNT_HINT_ENV:
            env.pop(k, None)
        print(f"[claude-acct] exec b: CLAUDE_CONFIG_DIR={b_dir}", file=sys.stderr)
    else:
        env.pop("CLAUDE_CONFIG_DIR", None)  # a は既定の ~/.claude(pick の a_dir と同じ)
    try:
        os.execvpe(rest[0], rest, env)
    except OSError as e:
        print(f"エラー: {rest[0]} を起動できない: {e.strerror}", file=sys.stderr)
        return 127


# ---------------------------------------------------------------- is-limit

def is_limit_hit(result_path, stream_path=None):
    """枠切れで終わった run か。launcher の終端には繋がない(PoC 3 の実物が取れてから)。

    is_error=true で、次のどちらか:
      - result の本文が `hit your .* limit` に当たる
      - stream.jsonl に system/api_retry の error=rate_limit がある
    """
    try:
        text = Path(result_path).read_text().strip()
        last = json.loads(text.splitlines()[-1]) if text else {}
    except (OSError, ValueError, IndexError):
        return False
    if not isinstance(last, dict) or not last.get("is_error"):
        return False
    if LIMIT_RE.search(str(last.get("result") or "")):
        return True
    if stream_path:
        try:
            for line in Path(stream_path).read_text().splitlines():
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if (isinstance(d, dict) and d.get("type") == "system" and d.get("subtype") == "api_retry"
                        and d.get("error") == "rate_limit"):
                    return True
        except OSError:
            pass
    return False


def cmd_is_limit(argv):
    if not argv:
        print("使い方: claude-acct.sh is-limit <result.json> [stream.jsonl]", file=sys.stderr)
        return 2
    return 0 if is_limit_hit(argv[0], argv[1] if len(argv) > 1 else None) else 1


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "pick":
        return cmd_pick(rest)
    if cmd == "exec":
        return cmd_exec(rest)
    if cmd == "is-limit":
        return cmd_is_limit(rest)
    print(f"不明なサブコマンド: {cmd}(pick / exec / is-limit)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
