---
description: セッションを締める。同義語で自然発火(締めて/終わる/閉じる/サマリ起こす/定時)。サマリ1本を書いて git-as commit、push は鷹野のみ、memory 索引に1行足す
---

# close-session

**発動:**「締めて」「終わる」「閉じる」「サマリ起こす」「定時」など、明示的な締めの発話。返信が長く来ないだけの暗黙的な終了では発動しない。

## 形式は正典を直接読む

正典は `company/keiei` の `_sessions/README.md`(session-v1)。各リポの `_sessions/README.md` は同じ形式を指すだけの薄いポインタ(例:`company/tech/_sessions/README.md`)。**節構成・decision 行(`— 領域:.../ 裁定:.../ 反映:...`)の文法・書かないもの(確定事項の再掲、作業ログの逐一)はここへ写さない** ── 正典を直接開いて従う。

実例(節の形と decision 行の実物):`company/tech/_sessions/2026-09-23_01.md`、`company/tech/_sessions/2026-09-22_02.md`。

## 手順

1. **サマリ 1 本を書く。**今のリポの `_sessions/` 直下に `YYYY-MM-DD_NN.md`。日付ディレクトリは作らない。NN はそのリポ・その日の既存ファイルの続き番号(無ければ `01`)。会社の現在値を動かす決定を含む回は `company/keiei` の `_sessions/` にも decision 行を立てる(正典が指示する場合のみ)
2. **`git-as <自ロール>` で commit。**author/committer は役名(例 `git-as 鷹野 commit ...`)。**push は鷹野の職務** ── このコマンドを鷹野のセッションで実行しているときだけ push まで行う。他ロールのセッションで実行している場合は commit で止め、push が要ることを鷹野へ申し送る
3. **memory を更新する。**Claude Code の auto memory の規則どおり、索引(`MEMORY.md`)は 1 行 1 ポインタで足す。新しい学び・裁定・落とし穴があれば `memory/<slug>.md` を添えて索引から繋ぐ。無ければ索引更新だけで良い
