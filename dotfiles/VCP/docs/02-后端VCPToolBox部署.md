# 02 · 后端 VCPToolBox 部署

> 目标：装依赖 → 配 config.env → 构建前端 → pitchfork 启动 → 验证。

---

## 1. 获取源码与目录规划

```bash
# 源码（两个仓库）
git clone https://github.com/lioensky/VCPToolBox.git
git clone https://github.com/lioensky/VCPChat.git        # 下一节用到

# 目录布局（推荐）
mkdir -p VCP
mv VCPToolBox VCPChat VCP/
cd VCP
cp <部署包>/mise.toml .        # 见 01-环境准备
```

---

## 2. 安装 Node 依赖

```bash
cd VCPToolBox
npm install
```

**原生模块说明**：`better-sqlite3`、`hnswlib-node` 需要编译。npm 11+ 默认阻止 install scripts，需批准：

```bash
npm approve-scripts --allow-scripts-pending   # 审查后批准
# 或单独批准关键包：
npm approve-scripts better-sqlite3 hnswlib-node puppeteer
```

**验证原生模块可加载：**

```bash
node -e "
const db = require('better-sqlite3');
const d = new db(':memory:'); d.exec('CREATE TABLE t(a)');
console.log('better-sqlite3 OK:', require('better-sqlite3/package.json').version);
const h = require('hnswlib-node'); console.log('hnswlib-node OK');
"
```

---

## 3. 安装 Python 依赖

```bash
# 确保在 .venv 中（mise 自动激活 或 source .venv/bin/activate）
uv pip install -r requirements.txt
```

> **Linux 注意**：`requirements.txt` 含 `win10toast`（仅 Windows 通知用），其依赖 `pypiwin32` 在 Linux 无法构建，安装时排除：
>
> ```bash
> grep -v '^win10toast' requirements.txt > req-linux.txt
> uv pip install -r req-linux.txt
> ```

**验证：**

```bash
python -c "import sympy, numpy, scipy; print('Python deps OK')"
```

---

## 4. 初始化配置

### 4.1 config.env（核心）

```bash
cp config.env.example config.env
vim config.env
```

**必须修改的配置项：**

| 配置项 | 值 | 说明 |
|---|---|---|
| `API_URL` | `http://localhost:3000` | 上游网关地址 |
| `API_Key` | `sk-...` | 网关密钥 |
| `PORT` | `6005` | 主服务端口（管理面板=+1） |
| `Key` | 自定 | VCP 聊天 API 鉴权密码 |
| `Image_Key` | 自定 | 图片服务密码 |
| `File_Key` | 自定 | 文件服务密码 |
| `VCP_Key` | 自定 | WebSocket 鉴权 |
| `DEFAULT_TIMEZONE` | `Asia/Shanghai` | 时区 |
| `AdminUsername` / `AdminPassword` | 自定 | 管理面板登录 |

**必须修改的向量模型配置（知识库核心）：**

```bash
# 主向量模型 + 备援链（务必与网关上可用渠道一致，勿加前缀）
WhitelistEmbeddingModel=gemini-embedding-2-preview
EmbeddingModelSig=gemini-embedding-2-preview
EmbeddingModelBackup1=gemini-embedding-2-preview
EmbeddingModelBackup2=gemini-embedding-2-preview
```

**其余按需修改：**

- `TavilyKey` / `SILICONFLOW_API_KEY` / `WeatherKey` 等第三方 API 密钥（见 04-配置详解）
- `ChinaModel1`：国产模型 thinking 开关列表
- `KNOWLEDGEBASE_PERSIST_FOLDERS`：冷知识库持久化目录白名单

### 4.2 multimodal-config.json（多模态识别）

```bash
cp multimodal-config.json.example multimodal-config.json
```

| 配置项 | 说明 |
|---|---|
| `MultiModalModel` | 多模态识别模型（如图像/音频/视频转文本） |
| `MultiModalPrompt` | 识别系统提示词（默认已含完整时序整合协议） |
| `MultiModalModelOutputMaxTokens` | 输出上限（默认 50000） |
| `MultiModalModelThinkingBudget` | Gemini thinking budget |
| `MultiModalModelAsynchronousLimit` | 异步并发上限（默认 10） |

> 优先级：`multimodal-config.json` > `config.env`。修改 JSON 会热加载。

### 4.3 Agent 角色（agent_map.json + Agent/）

Agent 由「角色卡文件」定义：`Agent/<名字>.txt`（系统提示词/人设）+ 可选头像图片。

**agent_map.json**：Agent 名称 → 角色卡文件映射：

```json
{
  "Nova": "Nova.txt",
  "Aemeath": "Aemeath.txt",
  "Coco": "ThemeMaidCoco.txt",
  "Hornet": "Hornet.txt",
  "DreamNova": "DreamNova.txt"
}
```

> 新增角色三步：① 写 `Agent/<名字>.txt` ② 可选放头像图片 ③ 在 `agent_map.json` 加一行。

### 4.4 其他配置文件

```bash
cp agent_map.json.example agent_map.json   # 覆盖为上文的角色映射
cp sarprompt.json ...                       # Sar 模型专属提示词（如缺失可留空数组）
# SemanticModelRouter.json / rag_params.json / toolApprovalConfig.json 均已自带默认
```

---

## 5. 构建管理面板前端

```bash
cd VCPToolBox/AdminPanel-Vue
npm install
npm run build          # 产物: dist/
```

> 管理面板为 Vue3 + Vite，需构建后由 adminServer 服务。缺失 dist 时管理面板不可用。

---

## 6. 创建运行时目录

```bash
cd VCPToolBox
mkdir -p VCPTimedContacts dailynote image file TVStxt \
         VCPAsyncResults Plugin/VCPLog/log \
         Plugin/EmojiListGenerator/generated_lists VectorStore
```

---

## 7. 启动（pitchfork）

### 7.1 pitchfork.toml（编排配置）

仓库根目录的 `pitchfork.toml` 已定义两个 daemon：

| daemon | 脚本 | 端口 | 备注 |
|---|---|---|---|
| `vcp-main` | server.js | 6005 | 主服务（stop timeout 15s 保索引落盘） |
| `vcp-admin` | adminServer.js | 6006 | 管理面板（depends vcp-main，就绪后启动） |

> ⚠️ 两 daemon 均**不要设置** `memory_limit`：TagMemo/EPA 冷启动有合法内存尖峰，设限会触发重启死循环。
>
> 关键配置已内置：`mise = true`（经 mise 按项目 mise.toml 解析 node 版本）、`UV_THREADPOOL_SIZE=64`（env）、`retry = true`（崩溃自动重启）、`ready_port`（TCP 就绪检查）。

### 7.2 启动命令

```bash
cd VCP                               # pitchfork.toml 所在目录
pitchfork start vcp-main vcp-admin   # 幂等: 已运行则跳过, 就绪检查通过才返回
pitchfork list
```

### 7.3 一键脚本（推荐）

仓库根目录的 `start-all-mise.sh` 会自动完成：mise 激活 → uv 建 .venv → Python 依赖 → npm 依赖 → AdminPanel 构建 → new-api 探测 → pitchfork 启动 → 可选启动 VCPChat：

```bash
./start-all-mise.sh                 # 全栈
./start-all-mise.sh --no-chat       # 仅后端
```

---

## 8. 验证部署

```bash
# 1) 端口监听
ss -tlnp | grep -E '6005|6006'

# 2) API 模型列表（应返回网关模型）
curl -s http://localhost:6005/v1/models -H "Authorization: Bearer <Key>"

# 3) 日志健康（无原生崩溃、无 Exiting）
pitchfork logs vcp-main -t
# 期待看到：
#   [KnowledgeBase] ✅ System Ready
#   [TagMemoEngine] ...
#   [TDBKnowledge] ✅ Ready
#   [PluginManager] Loaded manifest: ...（300+ 插件）

# 4) 管理面板
# 浏览器打开 http://localhost:6006
```

**启动日志关键里程碑（按顺序）：**

```
[dotenvPatch] Successfully patched dotenv.parse...
[KnowledgeBase] 🦀 Vexus-Lite Rust engine loaded
[TDBKnowledge] 🧊 TriviumDB module loaded.
[Server] multimodal-config.json 配置真相源已加载
[SemanticModelRouter] 配置已加载: enabled=true, presets=2
[AgentManager] Agent map reloaded and prompt cache cleared.
[KnowledgeBase] ✅ System Ready
TDB 冷知识库初始化完成。
[PluginManager] Starting plugin discovery...
[Server] 监听 6005
```

---

## 9. 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `Could not locate the bindings file` | better-sqlite3 未编译 | `npm approve-scripts better-sqlite3 && npm rebuild better-sqlite3` |
| 原生崩溃 `Assertion failed: env != nullptr` | Node 版本过新 | 确认 `node --version` = 22.x，重装 node_modules 后 `npm rebuild` |
| `model_not_found` / `No available channel` | 模型名与网关渠道不符 | 统一模型名（勿加厂商前缀），网关侧配渠道 |
| 管理面板 404 | AdminPanel-Vue 未构建 | `cd AdminPanel-Vue && npm install && npm run build` |
| 日志 `Exiting with code 1` | 初始化失败 | 查看 exit 前的错误，多为配置/权限问题 |

---

下一步：[03-前端VCPChat部署](03-前端VCPChat部署.md)
