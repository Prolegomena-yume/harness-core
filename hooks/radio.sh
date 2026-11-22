#!/usr/bin/env bash
# 無線の読む口(harness-radio、設計 v0 案 A)。UserPromptSubmit・PostToolBatch・SessionStart に付ける。
# 未読の流れ・札・base の進みを additionalContext(JSON)で 1 回に 8 行・1,500 字まで差す。
# 何があっても exit 0(PostToolBatch で exit 2 を返すとループが止まり、UserPromptSubmit で返すと発言が塞がる)。
# 置き場は $RADIO_HOME(既定 ~/.local/state/harness-radio)。失敗は radio.log に 1 行。
d="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import radiolib; sys.exit(radiolib.hook_entry())' "$d/../scripts/lib" 2>/dev/null || true
exit 0
