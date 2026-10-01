<h1><center>飞书 lark-cli 鉴权经验</center></h1>

# 概述

本文记录官方 `lark-cli` 的鉴权, 权限和文档操作流程.
当前使用的 CLI 通过 `@larksuite/cli` 安装, 可执行文件为 `lark-cli`.
本文按本机已验证的 `lark-cli 1.0.93` 编写.

官方 CLI 同时支持两种身份:

| 身份 | 凭证 | 能代表谁 | 典型用途 |
| --- | --- | --- | --- |
| `user` | 应用凭证 + 用户 OAuth | 当前登录用户 | 读取或修改用户有权限访问的个人文档 |
| `bot` | 应用凭证 | 飞书应用本身 | 自动化任务, 访问已向应用开放的资源 |

处理个人云盘文档时优先使用 `user`.
处理无人值守自动化时使用 `bot`, 并把目标文档或文件夹共享给应用.
`bot` 不能通过 `auth login` 变成用户, 也不能代替用户访问用户私有资源.

# 1. 凭证和权限的两层模型

飞书鉴权不是只填一次 App Secret:

1. 应用层: 在飞书开放平台为应用开通 API 权限.
2. 用户层: 以 `user` 身份操作时, 用户通过 OAuth 同意这些权限.

两层都满足后, CLI 才能以用户身份调用对应 API.
仅应用层凭证可用于 `bot` 身份, 但应用仍需具备对应的 bot scope, 且资源访问范围受飞书资源权限控制.

建议遵循最小权限原则.
只读任务优先申请文档只读 scope, 需要编辑时再增量申请写权限.
`--recommend` 适合快速初始化, 但可能申请多个业务域的常用权限, 不适合长期生产授权.

# 2. 没有应用: 一键创建并授权

适用于没有自己的飞书企业自建应用的情况.

## 2.1 初始化应用

在本机终端执行:

```powershell
lark-cli config init --new
```

该命令会启动配置向导并输出授权 URL.
在浏览器完成应用创建和配置后, 命令才会退出.

如果命令输出 `verification_url`, `verification_uri_complete` 或 `console_url`, URL 必须按原样使用.
不要重新编码, 截断 query 或手动拼接参数.
需要转发给其他人时, 可生成二维码:

```powershell
lark-cli auth qrcode "<verification_url>" --output auth-config.png
```

`--output` 使用相对路径, 文件会写入当前目录.

## 2.2 发起用户授权

在本机交互式使用时:

```powershell
lark-cli auth login --domain docs --domain drive --recommend
```

`docs` 覆盖云文档相关权限, `drive` 覆盖云盘及文件相关权限.
如果只需要明确的权限, 不使用 `--recommend`, 改用精确 scope:

```powershell
lark-cli auth scopes
lark-cli auth login --scope "<scope-1> <scope-2>"
```

多次 `auth login` 的授权范围会累积.
要减少权限, 不要假定重新登录会自动撤销旧 scope, 应到飞书授权管理页撤销服务端授权.

## 2.3 Agent 或远程终端使用 split flow

不要在同一轮中既展示授权 URL 又阻塞等待浏览器.
先发起不等待的授权:

```powershell
lark-cli auth login --domain docs --domain drive --no-wait --json
```

从 JSON 中取出 `verification_url` 和 `device_code`.
把 URL 原样交给用户, 同时生成二维码.
用户完成浏览器授权后, 再执行:

```powershell
lark-cli auth login --device-code <device_code>
```

授权链接或 device code 过期后必须重新发起流程, 不要跨流程复用.

# 3. 已有应用: 使用 App ID 和 App Secret

适用于已经有飞书企业自建应用, 或已有应用管理员统一维护权限的情况.

## 3.1 在开放平台准备应用

打开[飞书开放平台开发者后台](https://open.feishu.cn/app), 进入目标企业自建应用:

1. 在 `凭证与基础信息` 获取 App ID.
2. 在 `权限管理` 开通 Docs 和 Drive 所需 API 权限.
3. 如果后台提示需要创建版本, 发布或审批, 完成后再进行用户授权.
4. 对 bot 场景, 将目标文档或父文件夹共享给应用或应用机器人.

常见文档相关权限名称包括 `docx:document:readonly`, `docx:document`, `drive:drive` 等.
具体可用 scope 以当前应用后台和 `lark-cli auth scopes` 的结果为准.

## 3.2 安全地写入 CLI 配置

不要把 App Secret 放到命令行参数, Git 仓库, mise 配置或聊天记录中.
使用 stdin 传入, 避免出现在进程列表.

PowerShell 7:

```powershell
$secure = Read-Host "Feishu App Secret" -AsSecureString
$secret = [System.Net.NetworkCredential]::new("", $secure).Password
$secret | lark-cli config init `
  --app-id cli_xxx `
  --app-secret-stdin `
  --brand feishu
Remove-Variable secure, secret
```

如果不需要隐藏输入, 也可以使用环境变量或安全管道, 但不要把 Secret 写入持久化环境变量.
`--brand feishu` 用于中国大陆飞书; Lark 国际版使用 `--brand lark`.

## 3.3 以用户身份完成 OAuth

配置应用后执行:

```powershell
lark-cli auth login --domain docs --domain drive --no-wait --json
```

浏览器确认权限后, 使用返回的 device code 完成轮询:

```powershell
lark-cli auth login --device-code <device_code>
```

若已在本机交互式终端中操作, 也可以直接使用:

```powershell
lark-cli auth login --domain docs --domain drive --recommend
```

# 4. 验证鉴权结果

建议每次授权后执行:

```powershell
lark-cli auth status --json --verify
lark-cli whoami
lark-cli auth scopes
```

检查单个 scope:

```powershell
lark-cli auth check --scope "docx:document:readonly"
```

判定 JSON 成功时看 `ok == true` 或进程退出码 `0`.
不要用顶层 `code == 0` 判定成功, 因为成功信封不一定有顶层 `code` 字段.

重点确认:

- `identity` 是否为预期的 `user` 或 `bot`.
- `verified` 是否为 `true`.
- `identities.user.tokenStatus` 是否为 `valid`.
- 文档操作所需 scope 是否出现在授权列表中.

本机实际验证经验: `auth status --json --verify` 同时显示 bot 和 user 均可用时, CLI 的默认身份仍可能是 `user`.
需要稳定身份时, 文档命令显式加 `--as user` 或 `--as bot`.

# 5. 用户身份和 Bot 身份的选择

## 5.1 用户身份

用户身份需要应用权限和用户 OAuth 两层授权.
适用于读取或编辑当前用户能打开的文档:

```powershell
lark-cli docs +fetch `
  --doc "https://example.feishu.cn/docx/xxx" `
  --doc-format markdown `
  --as user
```

## 5.2 Bot 身份

Bot 身份不需要 `auth login`.
它使用应用凭证换取应用侧访问凭证, 但必须满足以下条件:

1. 应用后台已开通对应 bot scope.
2. 目标文档或文件夹已共享给应用或应用机器人.
3. 命令使用 `--as bot`.

```powershell
lark-cli docs +fetch `
  --doc "https://example.feishu.cn/docx/xxx" `
  --doc-format markdown `
  --as bot
```

如果 Bot 查询用户私有文档, 可能得到空结果或权限错误.
这不是重新执行 `auth login` 能解决的问题, 应改用 `--as user` 或调整文档共享权限.

# 6. 在线文档操作的安全顺序

读文档:

```powershell
lark-cli docs +fetch --doc "<document-url-or-token>" --doc-format markdown --as user
```

做块级编辑前, 先获取 block ID:

```powershell
lark-cli docs +fetch `
  --doc "<document-url-or-token>" `
  --detail with-ids `
  --scope outline `
  --as user
```

写操作先预览:

```powershell
lark-cli docs +update `
  --doc "<document-url-or-token>" `
  --command str_replace `
  --pattern "旧文本" `
  --content "新文本" `
  --doc-format markdown `
  --dry-run `
  --as user
```

确认目标, 范围和内容无误后, 去掉 `--dry-run` 再执行.
批量或高风险操作遇到确认门禁时, 先阅读命令返回的 `risk`, `action` 和 `hint`, 不要静默追加确认参数.

# 7. 常见问题排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `not_configured` | 尚未执行 `config init` | 执行 `lark-cli config init --new` 或使用已有 App ID 配置 |
| `no_token` 或用户未登录 | 只有应用配置, 没有用户 OAuth | 执行 `lark-cli auth login` |
| `missing_scope` | 应用层或用户层缺少 scope | 查看错误中的 `missing_scopes`, `console_url`, `hint`; 按最小范围补授权 |
| 结果显示 `identity: bot`, 但目标是个人文档 | 身份自动选择不符合目标 | 显式增加 `--as user` 并确认用户 token 有效 |
| Bot 访问文档为空 | 文档没有共享给应用, 或该资源属于用户私有空间 | 共享文档给应用, 或切换到 `--as user` |
| 浏览器授权成功但 CLI 仍未登录 | 轮询未完成, device code 过期, 或本地凭证存储异常 | 重新执行 `--no-wait --json`, 再执行新的 `--device-code`, 最后用 `auth status --verify` 检查 |
| 只想退出本机登录 | `auth logout` 只清理本机登录态 | 执行 `lark-cli auth logout --json`; 服务端授权需在飞书授权管理页撤销 |

# 8. 凭证安全规则

- 不在终端输出 App Secret, access token 或 refresh token.
- 不把 App Secret 或 token 写入 `config.local.toml`, Git 仓库, `.env` 提交内容或脚本参数.
- 优先使用 `--app-secret-stdin`, 并在 PowerShell 中及时删除临时变量.
- 只授权实际需要的业务域和 scope.
- 写入或删除文档前保留 `--dry-run` 预览和目标确认步骤.
- 发现凭证泄漏时, 立即在飞书开放平台重置 App Secret, 并在授权管理页撤销用户授权.

# 9. 官方参考

- [lark-cli 官方仓库和快速开始](https://github.com/larksuite/cli)
- [lark-cli 中文说明](https://github.com/larksuite/cli/blob/main/README.zh.md)
- [飞书开放平台开发者后台](https://open.feishu.cn/app)
- [获取自建应用 tenant_access_token](https://open.feishu.cn/document/server-docs/authentication-management/access-token/tenant_access_token_internal)
- [获取自建应用 app_access_token](https://open.feishu.cn/document/server-docs/authentication-management/access-token/app_access_token_internal)
- [获取 user_access_token](https://open.feishu.cn/document/server-docs/authentication-management/access-token/create-2)
- [获取用户信息](https://open.feishu.cn/document/server-docs/authentication-management/login-state-management/get)

文档命令和权限列表会随 CLI 版本更新.
遇到参数差异时, 以本机 `lark-cli --help`, 对应子命令 `--help` 和 `lark-cli auth scopes` 为准.
