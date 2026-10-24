#!/usr/bin/env python3
"""claude-acct.sh の本体 ── Claude Max 2 枚(a / b)のうち、便を起こす側を起動時に選ぶ。

親ゴール: claude-makabe / claude-kashiwagi の便が、1 枚目(a)の枠が尽きたら人見の手なしで 2 枚目(b)で起きる。
b の便は b の 1 年 token(`claude setup-token`)で起こす。token は ymos の secret CLAUDE_CODE_OAUTH_TOKEN_B に、人見が
`claude-token-put.py --name CLAUDE_CODE_OAUTH_TOKEN_B` で OAuth を 1 回通して置く(貼り付けは無い)。claude-acct は token を
ファイルにも argv にも置かず、`ymos secret exec` が子の env に入れた物をそのまま claude の env に移す。
設計の正典は company/tech の _drafts/claude-acct/01-research.v0.md「4. うちの形に当てる」(案 A)。

  pick [--model ID] [--policy primary]   各枠の残りを読み、a / b を JSON 1 行で stdout に出す。資格の値は出さない
                                          exit 0 = 選んだ / 75 = 両方尽きた(label は null) / 2 = 使い方の誤り
  exec <a|b> -- cmd...                    b なら `ymos secret exec -n CLAUDE_CODE_OAUTH_TOKEN_B -- <relay> -- cmd` で起こす。a は何も足さず CLAUDE_CONFIG_DIR だけ外す
  relay -- cmd...                         (exec b の内部)子の env で CLAUDE_CODE_OAUTH_TOKEN_B を CLAUDE_CODE_OAUTH_TOKEN に移して exec
  is-limit <result.json> [stream.jsonl]   枠切れで終わった run か(exit 0 = 枠切れ / 1 = 違う)。launcher の終端にはまだ繋がない

b を選べる条件(両方):
  - b の dir(~/.claude-b)の `CLAUDE_CONFIG_DIR=<b の dir> rates claude` が読める。~/.claude-b は枠を読むためだけに使う
    (人見が b で `claude auth login` した dir。便は ~/.claude のまま走り、設定・hook・plugin・transcript・--resume は a と同じ)
  - `ymos secret exec -n CLAUDE_CODE_OAUTH_TOKEN_B -- true` が exit 0(token が登録済みで、この身元から引ける)

資格の扱い:
  - token の値は stdout / stderr / ファイル / argv のどこにも出さない。relay が env の中だけで移し(argv に載らない)、
    exec する claude に渡す。`ymos secret exec` は子に signal を送らないので、relay は親(ymos)が死んだら子へ SIGTERM が届くように
    PR_SET_PDEATHSIG を掛ける
  - claude-acct は a の資格(~/.claude/.credentials.json)も b の資格(~/.claude-b/.credentials.json)も開かない
  - b の子には CLAUDE_CONFIG_DIR・GUI 由来の account 情報(ACCOUNT_UUID・ORGANIZATION_UUID・USER_EMAIL)を持ち込まない
  - ANTHROPIC_API_KEY など優先順位が CLAUDE_CODE_OAUTH_TOKEN より上の env があれば、b を選ばず exec b も止める

env(全部省略可):
  CLAUDE_ACCT_A_DIR           a の設定ディレクトリ(既定 ~/.claude。env の CLAUDE_CONFIG_DIR は見ない ── exec a が外すため)
  CLAUDE_ACCT_B_DIR           b の枠を読む dir(既定 ~/.claude-b)
  CLAUDE_ACCT_B_SECRET        b の token の secret 名(既定 CLAUDE_CODE_OAUTH_TOKEN_B。^CLAUDE_CODE_OAUTH_TOKEN(_[A-Z0-9]+)?$ だけ受ける)
  CLAUDE_ACCT_YMOS            ymos の実行ファイル(既定 ymos、test で stub に替える)
  CLAUDE_ACCT_SWITCH_AT       a のどれかの枠の残りがこの値以下なら b を見る(既定 5)
  CLAUDE_ACCT_STOP_AT         b のどれかの枠の残りがこの値以下なら b は尽きた扱い(既定 3)
  CLAUDE_ACCT_RATES           rates の実行ファイル(既定 rates、test で stub に替える)
  CLAUDE_ACCT_DISABLE=1       pick は常に a(従来の挙動)
"""
import json
import os
import ctypes
import re
import signal
import subprocess
import sys
from pathlib import Path

EX_TEMPFAIL = 75
HOME = Path.home()

# CLAUDE_CODE_OAUTH_TOKEN より優先順位が上の資格(authentication.md の 1〜3 段)。あると b の token を渡しても黙って負ける
BLOCKING_ENV = ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY")
# GUI のセッションが子に渡す「どのアカウントか」の情報。b の便には持ち込まない(a の情報を b の token に添えない)
ACCOUNT_HINT_ENV = ("CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_ORGANIZATION_UUID", "CLAUDE_CODE_USER_EMAIL")

SECRET_NAME_RE = re.compile(r"CLAUDE_CODE_OAUTH_TOKEN(_[A-Z0-9]+)?")
DEFAULT_B_SECRET = "CLAUDE_CODE_OAUTH_TOKEN_B"
LIMIT_RE = re.compile(r"hit your .* limit", re.IGNORECASE)


def cfg():
    env = os.environ
    return {
        "a_dir": env.get("CLAUDE_ACCT_A_DIR") or str(HOME / ".claude"),
        "b_dir": env.get("CLAUDE_ACCT_B_DIR") or str(HOME / ".claude-b"),
        "switch_at": float(env.get("CLAUDE_ACCT_SWITCH_AT") or 5),
        "stop_at": float(env.get("CLAUDE_ACCT_STOP_AT") or 3),
        "rates": env.get("CLAUDE_ACCT_RATES") or "rates",
        "ymos": env.get("CLAUDE_ACCT_YMOS") or "ymos",
        "b_secret": env.get("CLAUDE_ACCT_B_SECRET") or DEFAULT_B_SECRET,
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


def check_b_secret(c):
    """`ymos secret exec -n <b の secret> -- true` が通るか。(True, None) か (False, 理由)。値は何も受け取らない(true は何も出さない)。"""
    if SECRET_NAME_RE.fullmatch(c["b_secret"]) is None:
        return False, "secret-name-invalid"
    try:
        p = subprocess.run([c["ymos"], "secret", "exec", "-n", c["b_secret"], "--", "true"], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"ymos-unavailable:{type(e).__name__}"
    if p.returncode != 0:
        return False, f"ymos-exit-{p.returncode}:" + " ".join(p.stderr.split())[:120]
    return True, None


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
                warn("b を選べない: " + ", ".join(blk) + " が env にある(優先順位が CLAUDE_CODE_OAUTH_TOKEN より上)")
            else:
                ok, why = check_b_secret(c)
                out["candidates"]["b"]["secret"] = c["b_secret"] if ok else None
                if ok:
                    return finish("b", "a-below-switch-line")
                unavailable = "b-no-secret"
                out["candidates"]["b"]["secret_error"] = why
                warn(f"b を選べない: {c['b_secret']} を ymos から引けない({why})")
        else:
            out["candidates"]["b"]["exhausted"] = True
    if unavailable is None:
        # a は線以下、b も止める線以下 ── 両方尽きた
        return finish(None, "both-exhausted", EX_TEMPFAIL)
    # b が使えない(尽きたのではなく、rates が読めない・secret が引けない・env が塞ぐ)。a が止める線より上なら a で続ける(従来の挙動)
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
            print("エラー: b の token を足せない ── " + ", ".join(blk) + " が env にある。優先順位が "
                  "CLAUDE_CODE_OAUTH_TOKEN より上で、黙って別の資格で動いてしまう。unset してから起こす", file=sys.stderr)
            return 2
        c = cfg()
        if SECRET_NAME_RE.fullmatch(c["b_secret"]) is None:
            print("エラー: CLAUDE_ACCT_B_SECRET は CLAUDE_CODE_OAUTH_TOKEN(_大文字英数)? だけ", file=sys.stderr)
            return 2
        # token は ymos が子(relay)の env にだけ入れる。relay が CLAUDE_CODE_OAUTH_TOKEN に移して claude を exec する。argv には載らない
        relay = [c["ymos"], "secret", "exec", "-n", c["b_secret"], "--", sys.executable, os.path.abspath(__file__),
                 "relay", "--"] + rest
        print(f"[claude-acct] exec b: secret={c['b_secret']}(ymos secret exec 経由)", file=sys.stderr)
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        env.pop(c["b_secret"], None)
        rest = relay
    else:
        env.pop("CLAUDE_CONFIG_DIR", None)  # a は既定の ~/.claude(pick の a_dir と同じ)
    try:
        os.execvpe(rest[0], rest, env)
    except OSError as e:
        print(f"エラー: {rest[0]} を起動できない: {e.strerror}", file=sys.stderr)
        return 127


# ---------------------------------------------------------------- relay

def cmd_relay(argv):
    """`ymos secret exec` の子として動く。env の <b の secret> を CLAUDE_CODE_OAUTH_TOKEN に移して cmd を exec する。"""
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        print("relay: 実行するコマンドが無い", file=sys.stderr)
        return 2
    name = cfg()["b_secret"]
    env = dict(os.environ)
    token = env.pop(name, "")
    if not token:
        print(f"エラー: relay の env に {name} が無い(ymos secret exec の子として動かす)", file=sys.stderr)
        return 3
    env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    env.pop("CLAUDE_CONFIG_DIR", None)  # 便は ~/.claude のまま(b の dir は枠を読むだけ)
    for k in ACCOUNT_HINT_ENV:
        env.pop(k, None)
    # `ymos secret exec` は子に signal を送らない。親(ymos)が死んだら exec 後の子へ SIGTERM が届くようにする(Linux)
    try:
        ctypes.CDLL(None, use_errno=True).prctl(1, int(signal.SIGTERM), 0, 0, 0)  # PR_SET_PDEATHSIG
        if os.getppid() == 1:  # 掛ける前に親が死んでいた
            return 143
    except (OSError, AttributeError):
        pass
    try:
        os.execvpe(argv[0], argv, env)
    except OSError as e:
        print(f"エラー: {argv[0]} を起動できない: {e.strerror}", file=sys.stderr)
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
    if cmd == "relay":
        return cmd_relay(rest)
    if cmd == "is-limit":
        return cmd_is_limit(rest)
    print(f"不明なサブコマンド: {cmd}(pick / exec / relay / is-limit)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
