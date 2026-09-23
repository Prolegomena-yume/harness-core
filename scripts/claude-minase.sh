#!/usr/bin/env bash
set -euo pipefail
usage() {
  cat <<'USAGE'
使い方: claude-minase [-f <file>]... [-C <dir>] [--resume <session_id>] [--log <path>] [--effort <level>] [task...]
  -f, --file <path>  タスクファイル。複数指定可、引数の前に連結
  -C, --cd <dir>     作業ルート。既定は現在の git root または現在地
      --resume <id>  Claude セッションを継続
      --log <path>   raw JSON の追加保存先
      --effort <level> 推論 effort を指定
  -h, --help         この usage を表示
タスクファイルと引数が無い場合は標準入力から読む。
raw JSON は ~/.codex-agents/runs/minase-claude-<ts>-<pid>-<random>/last.json に保存。
出力末尾: session_id: <id> / permission_denials: <n> / result: と本文。
USAGE
}
die() { echo "エラー: $*" >&2; exit 2; }
core_dir="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
# shellcheck source=models.env
source "$core_dir/scripts/models.env"
root_input="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
resume_id=""
log_path=""
effort=""
task_files=()
task_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--file|-C|--cd|--resume|--log|--effort)
      [ "$#" -ge 2 ] || die "$1 には値が必要"
      [[ "$2" =~ [^[:space:]] ]] || die "$1 に空文字は指定できない"
      case "$1" in
        -f|--file) task_files+=("$2") ;;
        -C|--cd) root_input="$2" ;;
        --resume) resume_id="$2" ;;
        --log) log_path="$2" ;;
        --effort) effort="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; task_args+=("$@"); break ;;
    -*) die "不明な option: $1" ;;
    *) task_args+=("$1"); shift ;;
  esac
done
command -v claude >/dev/null 2>&1 || die 'claude が見つからない。PATH を確認してください'
command -v python3 >/dev/null 2>&1 || die 'JSON 解析に必要な python3 が見つからない'
[ -d "$root_input" ] || die "作業ルートが見つからない: $root_input"
root="$(cd "$root_input" && pwd -P)"
for task_file in "${task_files[@]}"; do
  if [ ! -f "$task_file" ] || [ ! -r "$task_file" ]; then
    die "タスクファイルを読めない: $task_file"
  fi
done
run_id="minase-claude-$(date '+%Y%m%d-%H%M%S')-$$-$RANDOM"
run_dir="${CODEX_AGENT_STATE_DIR:-$HOME/.codex-agents}/runs/$run_id"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd -P)"
task_path="$run_dir/task.md"
if [ "${#task_files[@]}" -eq 0 ] && [ "${#task_args[@]}" -eq 0 ]; then
  [ ! -t 0 ] || { usage >&2; exit 2; }
  cat > "$task_path"
else
  {
    for task_file in "${task_files[@]}"; do cat "$task_file"; printf '\n'; done
    if [ "${#task_args[@]}" -gt 0 ]; then printf '%s\n' "${task_args[*]}"; fi
  } > "$task_path"
fi
LC_ALL=C grep -q '[^[:space:]]' "$task_path" || die 'タスク本文が空白のみ'
# 本文を変数として渡す。プロンプト中の shell 構文を評価しない。
append_prompt="$(python3 - "$core_dir" <<'PY'
from pathlib import Path
import sys
core = Path(sys.argv[1])
body = (core / 'agents/minase.md').read_text()
lines = body.splitlines(keepends=True)
if lines and lines[0].strip() == '---':
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == '---'), None)
    if end is None:
        sys.exit('エラー: agents/minase.md の frontmatter が閉じていない')
    body = ''.join(lines[end + 1:])
print((core / 'roles/minase.md').read_text() + '\n' + body, end='')
PY
)"
export GIT_AUTHOR_NAME=水無瀬 GIT_COMMITTER_NAME=水無瀬
export GIT_AUTHOR_EMAIL=minase@ai.yumemism.dev GIT_COMMITTER_EMAIL=minase@ai.yumemism.dev
command_args=(claude -p --model "$MINASE_MODEL" --output-format json
  --append-system-prompt "$append_prompt"
  --allowedTools 'Read,Glob,Grep,Edit,Write,WebFetch,WebSearch,Bash(ls:*),Bash(cat:*),Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git add:*),Bash(git commit:*)')
[ -z "$resume_id" ] || command_args+=(--resume "$resume_id")
[ -z "$effort" ] || command_args+=(--effort "$effort")
command_args+=(-- "$(cat "$task_path")")
printf '[minase] Claude 起動 root=%s raw_json=%s\n' "$root" "$run_dir/last.json"
set +e
(cd "$root" && "${command_args[@]}" < /dev/null) > "$run_dir/last.json"
claude_status=$?
set -e
if [ -n "$log_path" ]; then
  mkdir -p "$(dirname "$log_path")"
  cp -- "$run_dir/last.json" "$log_path"
fi
python3 - "$run_dir/last.json" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as stream:
        data = json.load(stream)
    session_id = data['session_id']
    denials = data['permission_denials']
    result = data['result']
    if not isinstance(session_id, str) or not isinstance(denials, list) or not isinstance(result, str):
        raise ValueError('session_id / permission_denials / result の型が不正')
except (OSError, ValueError, KeyError, TypeError) as error:
    sys.exit(f'エラー: Claude JSON を解析できない: {error}; raw JSON: {sys.argv[1]}')
print(f'session_id: {session_id}')
print(f'permission_denials: {len(denials)}')
print('result:')
print(result)
PY
exit "$claude_status"
