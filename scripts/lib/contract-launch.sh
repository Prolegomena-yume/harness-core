#!/usr/bin/env bash
# claude-makabe.sh / claude-kashiwagi.sh の契約モード(--contract <dir> --batch <名>)の共通部品(source して使う)。
# 契約の MCP は lib/contract-mcp.py。path を持つのはそのプロセスだけで、モデルは道具(brief_get・result_put・gate_put)だけを使う。
# 庵野 2026-11-13(役員 人見)。正典は docs/delegation.md「契約の置き場」。

# contract_check_args <dir> <batch>: 契約のフォルダの絶対化(グローバル contract_dir を realpath にする)・便名の検査・brief.md の有無。
# 呼び出し側の die を使う(run_dir を作る前に呼ぶ)。
contract_check_args() {
  local dir="$1" batch="$2"
  [ -d "$dir" ] || die "--contract のフォルダが見つからない: $dir"
  case "$batch" in
    ""|.*|*..*|*/*|*\\*|*:*|*[[:space:]]*) die "--batch の便名に使えない形: '$batch'(空・先頭の . ・.. ・/ ・\\ ・: ・空白は不可)" ;;
  esac
  contract_dir="$(cd -P "$dir" && pwd)"
  [ -f "$contract_dir/$batch/brief.md" ] || die "brief.md が無い: $contract_dir/$batch/brief.md ── 鷹野が先に置く"
  [ ! -L "$contract_dir/$batch" ] || die "便のフォルダが symlink: $contract_dir/$batch"
}

# contract_task_text <makabe|kashiwagi> <batch>: 契約モードの最初の指示(task.md の頭)。path は書かない。
contract_task_text() {
  local who="$1" batch="$2"
  case "$who" in
    makabe)
      cat <<TXT
**契約モード。** この便の名は \`$batch\`。指示書(brief)は契約の MCP の道具で読む ── ファイルの path は無く、探さない。

1. 最初に \`brief_get\` を呼んで brief を読む。brief の通りに作業する(作業は作業ルート = 今の cwd の worktree の中だけ。commit は \`git-as makabe commit\`)
2. 終わりは \`result_put\` に終端の報告(codex/makabe.md の出力契約の形)を書く。長くなるなら途中で \`result_append\` に足してよい。\`result_get\` で今の中身を読める
3. brief に result.md の path が書いてあっても、そこへは Write せず \`result_put\` を使う。作業ルートの外へは Write / Edit が断られる
4. \`result_put\` を呼んでから最終メッセージを返す。矛盾などで止まるときも、止まる理由を \`result_put\` に書いてから返す
TXT
      ;;
    kashiwagi)
      cat <<TXT
**契約モード。** この便の名は \`$batch\`。ゲートの依頼文(brief)は契約の MCP の道具で読む ── ファイルの path は無く、探さない。

1. 最初に \`brief_get\` を呼んで依頼文を読む。真壁の報告は \`result_get\` で読める
2. 所見は \`gate_put\` に書く(claude/kashiwagi.md の出力契約の形)。P2 は作業ルート(今の cwd の worktree)の中で自分で直して commit してよい(\`git-as kashiwagi commit\`)。作業ルートの外へは Write / Edit が断られる
3. \`gate_put\` を呼んでから、最終メッセージに判定の一語(P0 無し / P0 あり(N 件) / エスカレーション)を書いて返す
TXT
      ;;
  esac
  printf '\n'
}

# write_contract_mcp_config <out.json> <CORE> <contract_dir> <batch> <tools(カンマ区切り)>: --mcp-config に渡す JSON を書く。
write_contract_mcp_config() {
  python3 - "$@" <<'PY'
import json
import sys

out, core, contract_dir, batch, tools = sys.argv[1:6]
cfg = {
    "mcpServers": {
        "contract": {
            "type": "stdio",
            "command": "python3",
            "args": [f"{core}/scripts/lib/contract-mcp.py"],
            "env": {"CONTRACT_DIR": contract_dir, "BATCH": batch, "CONTRACT_TOOLS": tools},
        }
    }
}
with open(out, "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}
