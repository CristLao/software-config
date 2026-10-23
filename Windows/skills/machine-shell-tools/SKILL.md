---
name: machine-shell-tools
description: Windows/MSYS2 命令与依赖管理. 适用于 PowerShell 7, UCRT64 Bash/fish, mise, aube, uv.
---

<h1><center>Windows Shell 与开发工具</center></h1>

# Shell 调用

适用于本仓库配置; 与项目 `AGENTS.md` 冲突时以其为准. 配置先查平台目录, 再查通用目录.  
进入目标项目后执行命令. 用户目录用 `$HOME`, PowerShell 配置用 `$PROFILE`. 以下安装路径按目标机器调整.

```powershell
# PowerShell 7: 加载 profile, 不加 -NoProfile.
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NonInteractive -Command 'mise --version; officecli --version'

# 执行器禁用 profile 时, 在目标 PowerShell 7 中显式加载.
. $PROFILE
# PATH 缺失时补充 shims; mise 本身可继续用完整路径调用.
& "$HOME\.local\bin\mise.exe" activate pwsh --shims | Out-String | Invoke-Expression

# UCRT64 登录 Bash: 加载系统和用户配置, 保留工作目录.
$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
& 'C:\msys64\usr\bin\bash.exe' -lc 'mise --version; officecli --version'

# fish 经上述环境启动; 仅需交互函数时改用 -ic.
& 'C:\msys64\usr\bin\bash.exe' -lc 'fish -c ''mise --version; officecli --version'''
```

裸 `bash` 可能指向 WSL, 裸 `pwsh` 可能指向 agent 自带运行时, 应确认完整路径.  
本仓库 PowerShell profile 在输出重定向时跳过交互初始化; fish 在 UCRT64 下为非交互命令加载 shims.  
shims 只负责工具查找, 需要 mise 环境变量时用 `mise exec -- <command>`. 找不到工具先检查 PATH 和版本.  
MSYS2 路径用 `/d/...`, 传给 Windows 程序可用 `cygpath -w` 转换. 复杂命令写脚本, 避免父 shell 提前展开变量.

# 工具与依赖

系统 CLI 用系统包管理器; 开发环境, 开发工具和 AI Agent 优先用 mise.  
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

保留系统 Python, 不向全局环境安装依赖. mise 只管理 uv, 不安装或管理 Python; 不执行 `mise use python`, 不在 mise `[tools]` 中添加 Python.  
项目 Python 解释器, 虚拟环境和依赖统一由 mise 提供的 uv 管理.  
已有 uv 项目沿用 `uv add`, `uv sync`, `uv run`; 独立临时脚本用 `uv run --no-project --isolated --with <pkg> script.py`.

```powershell
# 在目标目录创建环境; 版本遵循项目要求, 3.13.12 仅为示例.
uv python install 3.13.12
uv python pin 3.13.12
uv venv --managed-python
uv pip install --python .\.venv\Scripts\python.exe <pkg>
& .\.venv\Scripts\python.exe script.py

# 仅需要 pip 时, 在虚拟环境中初始化.
& .\.venv\Scripts\python.exe -m ensurepip --upgrade
& .\.venv\Scripts\python.exe -m pip install -U pip
```

不覆盖已有 `.venv`, 不在无关目录 pin. `uv venv` 不会激活环境, 应显式指定解释器.  
MSYS2 调用 Windows uv 时仍使用 `.venv/Scripts/python.exe`, 不是 `.venv/bin/python`.
