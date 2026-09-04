#!/usr/bin/env bash
# ============================================================================
#  VCP 全栈一键启动 (mise + pitchfork) —— Linux / WSL / macOS 版
#  适配新版 VCP（VCPToolBox + VCPChat）
#
#  用法:
#    ./start-all-mise.sh            启动服务 + VCPChat
#    ./start-all-mise.sh --no-chat  仅启动后端服务
#    ./start-all-mise.sh --desktop  额外启动 VCP 桌面实例
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# 颜色 & 工具函数
# ----------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
section() { echo -e "\n${CYAN}==== $1 ====${NC}"; }
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()     { echo -e "${RED}[ERROR]${NC} $1"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
fatal()   { err "$1"; exit 1; }

# ----------------------------------------------------------------------------
# 0. 激活 mise
# ----------------------------------------------------------------------------
if command -v mise &>/dev/null; then
    eval "$(mise activate bash)"
else
    fatal "未检测到 mise，请先安装 mise 并配置 mise.toml。"
fi

# ----------------------------------------------------------------------------
# 路径常量
# ----------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLBOX_DIR="$ROOT_DIR/VCPToolBox"
VCPCHAT_DIR="$ROOT_DIR/VCPChat"
VENV_DIR="$ROOT_DIR/.venv"
API_SCRIPT="$ROOT_DIR/start-newapi.sh"

PITCHFORK_FILE="$ROOT_DIR/pitchfork.toml"
ADMIN_VUE_DIR="$TOOLBOX_DIR/AdminPanel-Vue"
ADMIN_DIST="$ADMIN_VUE_DIR/dist/index.html"
CONFIG_ENV="$TOOLBOX_DIR/config.env"
CONFIG_TPL="$TOOLBOX_DIR/config.env.example"
REQ_FILE="$TOOLBOX_DIR/requirements.txt"

MAIN_PORT="${PORT:-6005}"
ADMIN_URL="http://localhost:${MAIN_PORT}/AdminPanel/"
FRONTEND_URL="http://localhost:3000/"

START_CHAT=true
START_DESKTOP=false
[[ "${1:-}" == "--no-chat" ]] && START_CHAT=false
[[ "${1:-}" == "--desktop" ]] && START_DESKTOP=true

# ----------------------------------------------------------------------------
# Python 环境 (uv + .venv)
# ----------------------------------------------------------------------------
init_python() {
    section "准备 Python 环境 (uv + .venv)"
    command -v uv >/dev/null || fatal "未找到 uv 命令（mise 应提供）"

    if [[ ! -d "$VENV_DIR" ]]; then
        warn ".venv 不存在，使用 uv 创建..."
        (cd "$ROOT_DIR" && uv venv '.venv')
    else
        info "检测到虚拟环境: $VENV_DIR"
    fi

    # 激活
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"
    else
        fatal "虚拟环境激活脚本不存在: $VENV_DIR/bin/activate"
    fi

    if [[ -f "$REQ_FILE" ]]; then
        info "安装 Python 依赖 (uv pip)..."
        # win10toast 仅 Windows 通知脚本使用，Linux/macOS 下其依赖 pypiwin32 无法构建，排除之
        if [[ "$(uname -s)" != "MINGW*" && "$(uname -s)" != "MSYS*" && "$(uname -s)" != "CYGWIN*" ]]; then
            grep -v '^win10toast' "$REQ_FILE" > /tmp/vcp_requirements_native.txt
            uv pip install -r /tmp/vcp_requirements_native.txt
        else
            uv pip install -r "$REQ_FILE"
        fi
    fi
    ok "Python: $(python --version 2>&1)"
}

# ----------------------------------------------------------------------------
# VCPToolBox 依赖检查
# ----------------------------------------------------------------------------
init_toolbox_deps() {
    section "检查 VCPToolBox 依赖"
    command -v node >/dev/null || fatal "未找到 node 命令"
    command -v npm  >/dev/null || fatal "未找到 npm 命令"

    # config.env
    if [[ ! -f "$CONFIG_ENV" ]]; then
        if [[ -f "$CONFIG_TPL" ]]; then
            warn "config.env 不存在，从模板复制..."
            cp "$CONFIG_TPL" "$CONFIG_ENV"
            warn "请编辑 $CONFIG_ENV 填入 API 密钥等配置后重启。"
        fi
    else
        info "config.env 已存在"
    fi

    # npm 依赖
    if [[ ! -d "$TOOLBOX_DIR/node_modules" ]]; then
        warn "node_modules 不存在，执行 npm install..."
        (cd "$TOOLBOX_DIR" && npm install)
    else
        info "VCPToolBox node_modules 已就绪"
    fi

    # 构建 AdminPanel-Vue 前端
    if [[ ! -f "$ADMIN_DIST" ]]; then
        warn "AdminPanel-Vue 前端未构建，开始构建..."
        (cd "$ADMIN_VUE_DIR" && npm install && npm run build)
        if [[ -f "$ADMIN_DIST" ]]; then
            ok "AdminPanel-Vue 构建成功"
        else
            warn "AdminPanel-Vue 构建可能失败，管理面板可能不可用"
        fi
    else
        info "AdminPanel-Vue 前端已构建"
    fi
}

# ----------------------------------------------------------------------------
# new-api (可选)
# ----------------------------------------------------------------------------
start_newapi() {
    section "启动 new-api 网关（可选）"
    if [[ -f "$API_SCRIPT" ]]; then
        info "启动: $API_SCRIPT"
        bash "$API_SCRIPT" || warn "new-api 启动返回非零状态"
        sleep 10
    else
        info "未发现 start-newapi.sh，跳过 new-api（新版为外部可选服务）"
        echo -e "${RED}       如需 API 网关，请单独部署 NewAPI/OpenRouter 等上游。${NC}"
    fi
}

# ----------------------------------------------------------------------------
# VCPToolBox (pitchfork + pitchfork.toml)
# ----------------------------------------------------------------------------
start_toolbox() {
    section "通过 pitchfork.toml 启动 VCPToolBox (pitchfork)"
    command -v pitchfork >/dev/null || fatal "未找到 pitchfork 命令（mise 应提供）"
    [[ -f "$PITCHFORK_FILE" ]] || fatal "未找到 pitchfork.toml: $PITCHFORK_FILE"

    # pitchfork start 幂等: 已运行的 daemon 跳过; 配置修改后需 pitchfork restart
    # UV_THREADPOOL_SIZE 等运行时参数已写入 pitchfork.toml 的 env
    (cd "$ROOT_DIR" && {
        pitchfork start vcp-main vcp-admin
        echo ""
        pitchfork list
    })
    ok "VCPToolBox 服务已提交 pitchfork 托管"
}

# ----------------------------------------------------------------------------
# VCPChat (electron)
# ----------------------------------------------------------------------------
start_vcpchat() {
    section "启动 VCPChat (electron)"
    [[ -d "$VCPCHAT_DIR" ]] || { err "VCPChat 目录不存在: $VCPCHAT_DIR"; return; }
    (cd "$VCPCHAT_DIR" && {
        if [[ ! -d node_modules ]]; then
            warn "VCPChat node_modules 不存在，执行 npm install..."
            npm install
        fi
        if [[ -f NativeSplash.exe ]]; then
            (./NativeSplash.exe &) 2>/dev/null || true
        fi
        if $START_DESKTOP; then
            nohup npm run start:desktop >/dev/null 2>&1 &
        else
            nohup npm start >/dev/null 2>&1 &
        fi
    })
    ok "VCPChat 已启动"
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   VCP 全栈启动 (mise + pitchfork) 新版适配${NC}"
echo -e "${CYAN}========================================${NC}"

init_python
init_toolbox_deps
start_newapi
start_toolbox
$START_CHAT && start_vcpchat

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}   全部 VCP 服务已启动！${NC}"
echo -e "${GREEN}   pitchfork list              - 查看进程${NC}"
echo -e "${GREEN}   pitchfork logs vcp-main -t  - 查看日志${NC}"
echo -e "${GREEN}   pitchfork restart vcp-main vcp-admin  - 配置修改后重启${NC}"
echo -e "${GREEN}========================================${NC}"
