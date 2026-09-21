#!/usr/bin/env bash
# ============================================================================
#  lxx_settings 分支维护脚本
#
#  分支策略: sync 先合并 origin/main, 再将本分支改动压缩为一个提交
#  有冲突时暂停, 手动解决并 git add 后再次 sync; 无内容差异时直接对齐 main
#
#  用法:
#    ./gitlxx.sh preview  # 预览本地分支与远程 lxx_settings 的提交/内容差异
#    ./gitlxx.sh fetch   # 强制本地 main 和 origin/main 对齐 upstream/main (作者 force push 后用)
#    ./gitlxx.sh sync    # 拉取并合并 origin/main, 再压缩为一个 commit (也用于冲突解决后继续)
#    ./gitlxx.sh reset   # 丢弃分支全部提交, 硬重置到远程 lxx_settings
#    ./gitlxx.sh push    # 强制推送 (压缩会改写历史, 用 force-with-lease 覆盖)
# ============================================================================
set -euo pipefail

BRANCH="lxx_settings"
REMOTE="origin"
UPSTREAM="upstream"

die() { echo "[ERROR] $1" >&2; exit 1; }

require_clean() {
    [[ -z "$(git status --porcelain)" ]] || die "工作区有未提交修改, 先 commit 或 stash"
}

show_conflicts() {
    echo "[ERROR] 合并尚有冲突, 已保留现场:" >&2
    git diff --name-only --diff-filter=U >&2
    echo "用 lazygit 或 git mergetool 解决, 也可手动编辑冲突文件." >&2
    echo "解决后 git add <已解决的文件> (删除文件用 git rm), 再运行 $0 sync." >&2
    echo "当前分支为 ours, 合入的 main 为 theirs; 取消本次合并: git merge --abort" >&2
    exit 1
}

# 前置检查: 必须在该分支上; sync 允许继续已解决并暂存的 main 合并
current="$(git branch --show-current)"
[[ "$current" == "$BRANCH" ]] || die "当前分支是 $current, 此脚本仅用于 $BRANCH"

cmd="${1:-}"
merge_head_file="$(git rev-parse --git-path MERGE_HEAD)"

# preview 与工作区无关; 不在 rebase/cherry-pick/revert 等操作中压缩或重置
if [[ "$cmd" != "preview" ]]; then
    for state in rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD sequencer; do
        [[ ! -e "$(git rev-parse --git-path "$state")" ]] || die "存在未完成的 Git 操作 ($state), 请先完成或取消"
    done
    if [[ -f "$merge_head_file" ]]; then
        [[ "$cmd" == "sync" ]] || die "存在未完成的合并, 请先解决后 sync 或 git merge --abort"
    else
        require_clean
    fi
fi

case "$cmd" in
preview)
    git show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH" || die "远程分支 $REMOTE/$BRANCH 不存在"
    git fetch "$REMOTE" "$BRANCH"

    read -r only_local only_remote <<< "$(git rev-list --left-right --count "HEAD...$REMOTE/$BRANCH")"
    echo "== 提交差异: 本地独有 $only_local 个, 远程独有 $only_remote 个 (< 仅本地 / > 仅远程)"
    if [[ "$only_local" -eq 0 && "$only_remote" -eq 0 ]]; then
        echo "   无"
    else
        git log --left-right --oneline "HEAD...$REMOTE/$BRANCH"
    fi

    echo ""
    echo "== 内容差异: $REMOTE/$BRANCH → HEAD"
    if git diff --quiet "$REMOTE/$BRANCH" HEAD; then
        echo "   无, 两侧内容一致"
    else
        git diff --stat "$REMOTE/$BRANCH" HEAD
    fi
    ;;
fetch)
    git remote get-url "$UPSTREAM" >/dev/null 2>&1 || die "未配置 $UPSTREAM 远程, 无法对齐作者 main"
    git fetch "$UPSTREAM" main

    # 本地 main 硬重置到作者 main; 当前就在 main 上时直接 reset, 否则强移分支指针
    if [[ "$current" == "main" ]]; then
        git reset --hard "$UPSTREAM/main"
    else
        git branch -f main "$UPSTREAM/main"
    fi

    # fork 的 main 强推对齐, 先 fetch origin 保证 lease 基于最新远程状态
    git fetch "$REMOTE" main
    git push --force-with-lease "$REMOTE" "$UPSTREAM/main:main"
    echo "完成: 本地 main 与 $REMOTE/main 已强制对齐 $UPSTREAM/main"
    ;;
sync)
    # 沿用本分支最近的普通提交信息, 避免采用手动完成合并时的默认 merge 信息
    msg="$(git log -1 --first-parent --no-merges --format=%s HEAD)"
    msg="${msg:-Sync $BRANCH}"

    if [[ -f "$merge_head_file" ]]; then
        merge_head="$(cat "$merge_head_file")"
        git rev-parse --verify --quiet "$merge_head^{commit}" >/dev/null &&
            git merge-base --is-ancestor "$merge_head" "$REMOTE/main" ||
            die "已有合并目标不属于当前记录的 $REMOTE/main, 请先 git merge --continue 或 git merge --abort"
        [[ -z "$(git ls-files --unmerged)" ]] || show_conflicts
        git diff --quiet || die "解决结果尚未全部暂存, 请 git add/git rm 后再次 sync"
        [[ -z "$(git ls-files --others --exclude-standard)" ]] || die "存在未跟踪文件, 请先处理后再次 sync"
        git commit --no-edit
        require_clean
    fi

    # 显式更新 origin/main, 包括远程改写历史的情况; 本次合并和压缩使用同一个基点
    git fetch "$REMOTE" "+refs/heads/main:refs/remotes/$REMOTE/main"
    base="$(git rev-parse "$REMOTE/main^{commit}")"
    if ! git merge --ff --no-edit --no-autostash --no-squash --commit "$base"; then
        [[ -z "$(git ls-files --unmerged)" ]] || show_conflicts
        die "合并未完成, 请检查 Git 输出后再次 sync; 若存在合并现场, 可用 git merge --abort 取消"
    fi

    require_clean
    git merge-base --is-ancestor "$base" HEAD || die "尚未合并 $REMOTE/main, 停止压缩"

    # 内容与 main 完全相同时直接对齐, 不产生空提交
    if git diff --quiet "$base" HEAD; then
        if [[ "$(git rev-parse HEAD)" != "$base" ]]; then
            git reset --hard "$base"
        fi
        echo "完成: 分支内容与 $REMOTE/main 相同, 已对齐 (无额外提交)"
        exit 0
    fi

    # 已经是 main 上的单个普通提交时不再改写, 多次 sync 保持稳定
    if [[ "$(git show -s --format=%P HEAD)" == "$base" ]]; then
        echo "完成: $BRANCH 已只领先 $REMOTE/main 一个 commit, 无需压缩"
        exit 0
    fi

    # 此时文件内容已经包含 main 的更新, 再压缩才不会反向撤销它们
    before_squash="$(git rev-parse HEAD)"
    git reset --soft "$base"
    if ! git commit -m "$msg"; then
        git reset --soft "$before_squash"
        die "压缩提交失败, 已恢复压缩前的分支指针并保留文件内容, 请检查 Git 输出"
    fi
    echo "完成: 已合并 $REMOTE/main, $BRANCH 现在只领先它一个 commit"
    ;;
reset)
    git fetch "$REMOTE" "$BRANCH"
    read -r -p "确认丢弃本地提交并重置到 $REMOTE/$BRANCH? 输入 yes 确认: " ans
    [[ "$ans" == "yes" ]] || die "已取消"
    git reset --hard "$REMOTE/$BRANCH"
    echo "完成: $BRANCH 已重置到 $REMOTE/$BRANCH"
    ;;
push)
    git push --force-with-lease "$REMOTE" "$BRANCH"
    echo "完成: 已推送到 $REMOTE/$BRANCH"
    ;;
*)
    die "用法: $0 {preview|fetch|sync|reset|push}"
    ;;
esac
