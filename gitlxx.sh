#!/usr/bin/env bash
# ============================================================================
#  lxx_settings 分支维护脚本
#
#  分支策略: 本分支永远只领先远程 main 一个 commit (所有改动压缩为一个提交)
#  合并远程 main 请自行执行 git merge, 本脚本只负责压缩提交
#
#  用法:
#    ./gitlxx.sh preview  # 预览本地分支与远程 lxx_settings 的提交/内容差异
#    ./gitlxx.sh fetch   # 强制本地 main 和 origin/main 对齐 upstream/main (作者 force push 后用)
#    ./gitlxx.sh sync    # 把领先 origin/main 的全部提交压缩为一个 commit
#    ./gitlxx.sh reset   # 丢弃分支全部提交, 硬重置到远程 lxx_settings
#    ./gitlxx.sh push    # 强制推送 (压缩会改写历史, 用 force-with-lease 覆盖)
# ============================================================================
set -euo pipefail

BRANCH="lxx_settings"
REMOTE="origin"
UPSTREAM="upstream"

die() { echo "[ERROR] $1" >&2; exit 1; }

# 前置检查: 必须在该分支上, 且工作区干净 (避免压缩/重置时丢失未提交修改)
current="$(git branch --show-current)"
[[ "$current" == "$BRANCH" ]] || die "当前分支是 $current, 此脚本仅用于 $BRANCH"

cmd="${1:-}"

# preview 只读对比 refs, 与工作区无关; 其余操作要求工作区干净
if [[ "$cmd" != "preview" ]]; then
    [[ -z "$(git status --porcelain)" ]] || die "工作区有未提交修改, 先 commit 或 stash"
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
    ahead="$(git rev-list --count "$REMOTE/main..HEAD")"
    if [[ "$ahead" -eq 0 ]]; then
        echo "分支没有领先 $REMOTE/main 的提交, 无需压缩"
        exit 0
    fi

    # 记录压缩后沿用的提交信息 (取当前分支顶端 subject)
    msg="$(git log -1 --format=%s HEAD)"

    # 内容与 main 完全相同时直接对齐, 不产生空提交
    if git diff --quiet "$REMOTE/main" HEAD; then
        git reset --hard "$REMOTE/main"
        echo "分支内容与 main 相同, 已对齐"
        exit 0
    fi

    # 软重置到远程 main, 领先的全部提交压成一个
    git reset --soft "$REMOTE/main"
    git commit -m "$msg"
    echo "完成: 已把 $ahead 个提交压缩为一个, $BRANCH 现在只领先 $REMOTE/main 一个 commit"
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
