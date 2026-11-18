#!/usr/bin/env bash
# 便・真壁・柏木のランチャが「触らせない branch」を数える 1 か所の定義。source して使う
# (claude-makabe / kimi-makabe / claude-kashiwagi / codex-agent)。守る branch を足すときはこの配列だけを直す。
# main / master は従来のリポ、staging(develop)・canon(master)は yumemism git flow の本番に出すリポ
# (docs/delegation.md「yumemism git flow」、役員 人見 2026-11-19)。

PROTECTED_BRANCHES=(main master staging canon)

# is_protected_branch <branch> ── 守る branch なら 0。
is_protected_branch() {
  local b
  for b in "${PROTECTED_BRANCHES[@]}"; do
    [ "$b" = "$1" ] && return 0
  done
  return 1
}

# is_protected_ref <ref> ── refs/heads/<守る branch> なら 0。
is_protected_ref() {
  case "$1" in
    refs/heads/*) is_protected_branch "${1#refs/heads/}" ;;
    *) return 1 ;;
  esac
}

# protected_branches_label ── die・usage 用の文言「main / master / staging / canon」。
protected_branches_label() {
  local out="" b
  for b in "${PROTECTED_BRANCHES[@]}"; do
    out="${out:+$out / }$b"
  done
  printf '%s\n' "$out"
}

# is_tech_repo <作業ルート> ── origin の URL が git.yumemism.com の company/tech なら 0(役員 人見 2026-11-19)。
# tech の CLAUDE.md は鷹野宛てで、真壁が起きると指示が混線する。tech の worktree(.claude/worktrees/*)・別 clone も
# 同じ扱いにするため path でなく remote で見る。https・ssh(scp 形式を含む)・`.git` の有無・末尾の `/` を許す。
is_tech_repo() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ git\.yumemism\.com[:/]company/tech(\.git)?/?$ ]]
}
