# 03 · 前端 VCPChat 部署（Electron 桌面客户端）

> 目标：安装 Electron 依赖、编译 Rust 组件、配置 AppData、启动客户端。

---

## 1. 安装 npm 依赖

```bash
cd VCPChat
npm install
```

**批准原生模块安装脚本**（electron、better-sqlite3、hnswlib-node、node-pty、sharp、puppeteer 等 9 个）：

```bash
npm approve-scripts --allow-scripts-pending
```

**验证原生模块在 Electron ABI 下可用：**

```bash
# 必须用 Electron 运行时测试（系统 node 能加载 ≠ Electron 能加载）
cat > /tmp/test_abi.js << 'EOF'
const { app } = require('electron');
app.whenReady().then(() => {
  try {
    const db = require('/绝对路径/VCPChat/node_modules/better-sqlite3');
    const d = new db(':memory:'); d.exec('CREATE TABLE t(a)');
    console.log('better-sqlite3 OK');
  } catch (e) { console.log('FAIL:', e.message.split('\n')[0]); }
  app.quit();
});
EOF
./node_modules/.bin/electron /tmp/test_abi.js --no-sandbox
```

> ⚠️ **关键坑**：VCPChat 的原生模块必须按 **Electron 的 ABI**（非系统 Node 的 ABI）编译。若出现 `was compiled against a different Node.js version` / `NODE_MODULE_VERSION` 不匹配，用 electron-rebuild 修复：
>
> ```bash
> ./node_modules/.bin/electron-rebuild -f
> # 编译目标: better-sqlite3, electron-edge-js, hnswlib-node, node-pty
> # 期待输出: ✔ Rebuild Complete
> ```

---

## 2. 安装 Python 依赖

```bash
uv pip install -r requirements.txt
```

**Linux 排除 Windows 专用包：**

```bash
grep -vE '^(pywin32|uiautomation|rapidocr-onnxruntime)' requirements.txt > /tmp/req.txt
uv pip install -r /tmp/req.txt
```

依赖内容：flask / flask_socketio / gevent（本地服务）、soundfile / sounddevice / pydub / mutagen（音频）、pyautogui（桌面自动化）。

---

## 3. 编译 Rust 组件

VCPChat 含两个 Rust 原生服务，Linux/macOS 需本地编译（Windows 已附带 .exe）：

### 3.1 Rust 聊天数据服务（VCP-CDS）

```bash
cd VCPChat
npm run build
# 等价: node rust_chat_data_service/build-runtime.js
# 流程: cargo build --release → 复制到 modules/services/chatDataService/bin/<平台>-<arch>/
```

> 编译耗时约 4-5 分钟（依赖 tantivy / sqlite3 等重库）。产物约 15MB。
> 前置：Rust 工具链 `cargo --version`（1.97+）。

### 3.2 Rust 音频引擎（Hi-Fi Audio）

```bash
cd rust_audio_engine
cargo build --release
cp target/release/audio_server ../audio_engine/audio_server
chmod +x ../audio_engine/audio_server
```

> 引擎特性：Symphonia 解码 + cpal 输出 + actix-web 服务，默认监听 `127.0.0.1:63789`。
> 配置：`audio_engine/.env`（EQ 模式、目标采样率、重采样质量等，默认已可用）。

**验证：**

```bash
./audio_engine/audio_server --help
# 期待: VCP Hi-Fi Audio Engine v2.0.0 (Full Rust) ...
```

---

## 4. 配置 AppData（客户端数据目录）

VCPChat 的用户数据全部在 `VCPChat/AppData/`：

```
AppData/
├── settings.json              # 客户端核心配置（连接后端）
├── rust-assistant-config.json # Rust 桌面助手配置
├── Agents/                    # Agent 配置与聊天记录
├── AgentGroups/               # 群聊配置
├── UserData/                  # 聊天历史与附件
├── songlist.json              # 音乐列表
└── LoomApps/                  # Loom 网页应用（新特性）
```

### 4.1 settings.json（必须配置）

```bash
cd VCPChat/AppData
cp settings.json.example settings.json 2>/dev/null  # 若无模板则手动创建
```

**关键字段：**

```json
{
  "vcpServerUrl": "http://localhost:6005/v1/chat/completions",
  "vcpApiKey": "<与后端 Key 一致>",
  "vcpLogUrl": "ws://localhost:6005",
  "vcpLogKey": "<与后端 VCP_Key 一致>",
  "userName": "用户",
  "enableDistributedServer": true,
  "currentThemeMode": "dark"
}
```

> 后端重启后客户端自动重连；Key 必须与 VCPToolBox config.env 的 `Key` / `VCP_Key` 一致，否则鉴权失败。
> 缺失字段会自动补默认值（SettingsValidator 合并逻辑），旧配置直接可用。

### 4.2 可选：预置角色/话题

- `Agents/` 下每个子目录 = 一个 Agent 配置（含聊天历史）
- `AgentGroups/` 群聊配置
- 首次启动也会自动创建，可留空

---

## 5. 启动 VCPChat

### 5.1 Linux（X11 / Wayland）

```bash
cd VCPChat
npx electron . --no-sandbox --ozone-platform=x11
```

> **--no-sandbox**：容器/受限环境需要；**--ozone-platform=x11**：Wayland 下 Electron 窗口可能不可见，强制走 X11（XWayland）解决。
> 无显示器环境：`xvfb-run -a npx electron . --no-sandbox`

### 5.2 Windows

```bat
start.bat                  :: 或 启动Vchat.vbs（隐藏窗口）
```

### 5.3 后台运行（Linux）

```bash
nohup npx electron . --no-sandbox --ozone-platform=x11 > /tmp/vcpchat.log 2>&1 &
```

---

## 6. 验证客户端

```bash
# 进程存活
pgrep -f "electron/dist/electron"

# 子服务监听（音频引擎）
ss -tlnp | grep 63789

# 日志关键里程碑
tail -f /tmp/vcpchat.log
#   [Main] Rust Audio Engine is ready.
#   [VCP-CDS] VCP-CDS is ready, address: 127.0.0.1:xxxxx
#   [Main] Models fetched and cached successfully: [...]
```

桌面窗口应显示聊天界面，左侧为 Agent 列表，可开始对话。

**常见问题：**

| 现象 | 原因 | 解决 |
|---|---|---|
| 窗口不显示 | Wayland 兼容问题 | 加 `--ozone-platform=x11` |
| `spawn audio_server EACCES` | 二进制无执行权限 | `chmod +x audio_engine/audio_server` |
| `Address already in use` 63789 | 残留旧实例 | `pkill -f audio_server` 后重启 |
| `another VCP-CDS instance already owns AppData` | 残留 CDS 进程 | `pkill -f vcp_chat_data_service` 后重启 |
| 登录失败/401 | Key 与后端不一致 | 检查 settings.json 的 vcpApiKey |

---

下一步：[04-配置详解](04-配置详解.md)
