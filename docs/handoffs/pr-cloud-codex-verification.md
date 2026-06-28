# PR 起草版 ── cloud-codex-verification

## 作成 URL(一発)

https://github.com/Prolegomena-yume/Prolegomena/compare/dev...claude/cloud-codex-verification-zo1yec?expand=1

base = `dev` / head = `claude/cloud-codex-verification-zo1yec`(自動セット済)

---

## Title

```
docs(cloud): codex 実装プロトコル §10.6 cloud Linux 実体験で sandbox flag 表確定
```

---

## Body

```markdown
## Summary

cloud session(`codex-cli 0.142.3` / Ubuntu 24.04)で `CODEX_AUTH_JSON` portable auth flow(commit 3b5d718 / 460d8b0)の初回実機検証を完遂、`docs/codex_implementer_protocol.md` §10.4 / §10.6 表を **「未検証」→「実体験で確定」** に更新。

cloud commit `3220600` の merge-base は `3b5d718` ── 本検証時点で `460d8b0`(compact JSON / 環境変数欄訂正)を取り込まずに作業されたが、互いの変更領域が overlap せず **3-way merge で衝突無し確定**(dev 側 `460d8b0` 訂正は保持、cloud 側 §10.4 / §10.6 sandbox flag 表確定値も取り込まれる)。

## Windows v0.141.0 と Linux v0.142.3 の挙動差(★ 本検証で確定)

| 検証段 | 起動オプション | Windows v0.141.0 | cloud Linux v0.142.3 |
|---|---|---|---|
| (i) | flag 一切無し + config `sandbox_mode = workspace-write` 単独 | 無視(`sandbox: read-only` 固定) | **effect**、`apply_patch` 成功(session `019f0d88-143c-75b2-8b9d-ce36167c1e02`) |
| (ii) | `-s workspace-write` flag 単独 | 無視 | effect、成功(session `019f0d89-58ff-7153-9a7b-4a86485a8298`) |
| (iii) | `--dangerously-bypass-approvals-and-sandbox` flag | **必須**(唯一の bypass 経路) | effect、banner `sandbox: danger-full-access`、ただし Linux では必須ではない(上位権限が要る時のみ、session `019f0d89-be79-7cf1-aa4c-5b051378ded1`) |

→ **cloud Linux 標準起動形は config seed + flag 無し**、Windows ワークアラウンドの bypass flag は cloud に持ち込み不要。

## 範囲外発見(本 PR スコープ外、別 session で拾い予定)

人見決定で本 session 退場、別 session(PRL-30 P3 = `harness-core` submodule 進行と合流)で対処:

1. **cloud UI Setup script cache が commit `3b5d718` 前の旧版** ── Phase 3 `npm install -g @openai/codex` 未走、cloud session 内で手動 install workaround で対処済。Anthropic 側 cache invalidation の挙動、UI 側で Setup script 欄を最新版で再貼付 + 保存で解決
2. **`bubblewrap` apt 不在** ── cosmetics warning(`Codex could not find bubblewrap on PATH ... Codex will use the bundled bubblewrap`)、動作上問題なし。`cloud_setup_script.sh` Phase 1 apt list に追加で消える。**PRL-30 P3(`harness-core` submodule)着地後に harness-core 側で対処予定**(prolegomena 側に `cloud_setup_script.sh` 残らないため)
3. **task args の `git push origin dev` が cloud git branch rule と矛盾** ── cloud session の system rule(branch 固定 `claude/cloud-codex-verification-zo1yec`)、cloud Claude の検証指示書改訂で対処すべき範囲、docs 側 cloud override 節への注記追加は別 commit

## Test plan

- [x] cloud session で `codex --version` / `codex exec "echo hello"` / 書込み smoke 3 段全成功
- [x] `tmp/codex_cloud_smoke.txt` 削除済(cloud session 内)
- [x] dev との 3-way merge 衝突無し確認(merge-base=`3b5d718`、変更領域 overlap 無し)
- [ ] PRL-30 P3(`harness-core` submodule)合流確認 ── 別 session で取り込み判断

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
