# AnyRouter check-in local config guide

本仓库现在支持只改一个本地文件后同步 GitHub Actions 配置。

## 本次失败原因

Actions 日志显示失败点是访问 `https://anyrouter.top/login` 获取 WAF cookies 时超时：

```text
Page.goto: Timeout 30000ms exceeded.
navigating to "https://anyrouter.top/login", waiting until "networkidle"
```

这不是 `ANYROUTER_ACCOUNTS` JSON 缺失导致的。主要问题是页面一直达不到 `networkidle`，脚本超时后又返回了不完整的结果，触发了 `not enough values to unpack`。

本次代码已改为默认等待 `domcontentloaded`，超时时间 60 秒，并把这些 WAF 参数放进 provider 配置，之后可以不改代码直接更新。

## 你以后只需要改的文件

编辑本地文件：

```text
CONFIG.local.json
```

这个文件已加入 `.gitignore`，不会被提交到 GitHub。它会被脚本写入 GitHub Environment Secrets。

必须替换：

- `accounts[0].cookies.session`: 浏览器里 AnyRouter 的 `session` cookie
- `accounts[0].api_user`: Network 请求头里的 `new-api-user`

通常保留这些 provider 参数即可：

```json
"waf_wait_until": "domcontentloaded",
"waf_timeout_ms": 60000,
"waf_extra_wait_ms": 5000,
"waf_headless": true
```

如果之后又遇到 WAF cookie 获取失败，可以先把 `waf_extra_wait_ms` 改成 `8000` 或 `10000`，再运行同步脚本。

## 一键同步

双击或在 PowerShell 里运行：

```bat
sync-config-and-push.bat
```

脚本会做这些事：

1. 检查 `gh` 是否已登录。
2. 创建或确认 GitHub Environment `production`。
3. 把 `accounts` 写入 `ANYROUTER_ACCOUNTS`。
4. 把 `providers` 写入 `PROVIDERS`。
5. 把非空通知配置写入对应 secrets。
6. 提交并推送仓库文件改动。
7. 按 `run_workflow_after_push` 触发一次 `checkin.yml`。

如果只想同步 secrets 和推送，不触发 workflow：

```bat
sync-config-and-push.bat -NoWorkflow
```

如果只想检查配置文件是否能被脚本读取，不写入 GitHub、不提交、不推送：

```bat
sync-config-and-push.bat -DryRun
```
