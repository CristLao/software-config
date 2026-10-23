---
name: arch-shell-tools
description: Arch Linux 命令与依赖管理. 适用于 Bash/fish, mise, aube, uv.
---

<h1><center>Arch Linux Shell 与开发工具</center></h1>

# Shell 调用

适用于本仓库配置; 与项目 `AGENTS.md` 冲突时以其为准. 配置先查平台目录, 再查通用目录.  
进入目标项目后执行命令. 用户路径用 `$HOME`, 工具安装位置不同时按实际路径调整.

```bash
# 登录 Bash 加载用户配置; fish 默认加载非交互配置.
/usr/bin/bash -lc 'command -v mise aube uv; mise --version; uv --version'
/usr/bin/fish -c 'command -v mise aube uv; uv --version'

# PATH 缺失时直接通过 mise 执行, 或补充当前 Bash 的 shims.
"$HOME/.local/bin/mise" exec -- uv --version
eval "$("$HOME/.local/bin/mise" activate bash --shims)"

# 定位工具.
mise which uv
```

本仓库 `.bash_profile` 加载 `.bashrc`; fish 在非交互退出前初始化 PATH/shims. 裸 `bash -c` 不保证加载配置.  
fish 补充 shims 用 `"$HOME/.local/bin/mise" activate fish --shims | source`; 仅需交互函数时使用 `fish -ic`.  
shims 只负责工具查找, 需要 mise 环境变量时用 `mise exec -- <command>`. 找不到工具先检查 PATH 和版本.

# 工具与依赖

系统 CLI 用 pacman/AUR; 开发环境, 开发工具和 AI Agent 优先用 mise.  
持久工具 mise 无法提供时再回退对应语言包管理器, 仍遵守 aube 和 Python 隔离规则. 安装失败先排查, 不自动切换.

| 操作 | 命令 |
| --- | --- |
| 持久工具 | `mise use -g <tool>` |
| npm / Python CLI | `mise use -g npm:<pkg>` / `mise use -g pypi:<tool>` |
| Rust / Go CLI | `mise use -g cargo:<tool>` / `mise use -g go:<tool>` |
| JS 项目依赖 | `aube install`, `aube add <pkg>`, `aube add -D <pkg>` |
| JS 临时执行 / 项目脚本 | `aubx <pkg>` / `aubr <script>` |
| Python 临时 CLI | `uvx <tool>` |

禁止 npm/npx/pnpm/pnpx 引入依赖. `aubx`/`aubr` 不可用时用 `aube dlx`/`aube run`.  
mise 的 `npm:` 默认使用内嵌 aube, 无需额外指定或安装 aube; 项目命令使用独立 aube CLI. `pypi:` 使用 uv 后端.  
私密变量放 mise 配置目录的 `config.local.toml` 的 `[env]`, 不提交或输出秘密.

# Python 环境

保留系统 `/usr/bin/python`, 不向全局环境安装依赖. mise 只管理 uv, 不安装或管理 Python; 不执行 `mise use python`, 不在 mise `[tools]` 中添加 Python.  
项目 Python 解释器, 虚拟环境和依赖统一由 mise 提供的 uv 管理.  
已有 uv 项目沿用 `uv add`, `uv sync`, `uv run`; 独立临时脚本用 `uv run --no-project --isolated --with <pkg> script.py`.

```bash
# 在目标目录创建环境; 版本遵循项目要求, 3.13 仅为示例.
uv python install --no-bin 3.13
uv venv --managed-python --python 3.13 .venv
uv pip install --python .venv/bin/python -r requirements.txt
./.venv/bin/python script.py
```

不覆盖已有 `.venv`, 仅需固定项目版本时用 `uv python pin <version>`.  
`uv venv` 不会激活环境; 显式调用 `.venv/bin/python`. `uv pip` 不要求环境内安装 pip.  
项目中的 `uv run` 会使用/同步项目环境, 不总是临时隔离; 要保持锁文件不变时加 `--locked`.
