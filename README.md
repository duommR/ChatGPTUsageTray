# ChatGPT/Codex 用量桌面组件

Windows 桌面悬浮组件，每 30 秒通过后台 `cmd` 命令调用本机 `codex app-server`，读取当前 Codex/ChatGPT 登录用户的用量百分比和重置日期。网络不通、未登录、未安装 Codex 或请求超时时显示 `-`。

## 安装

双击 `ChatGPTUsageWidget-Setup.exe`。应用会立即启动，并添加到当前用户的开机启动项，不需要管理员权限。`install.cmd` 保留为开发调试安装方式。

配置文件位于 `%LOCALAPPDATA%\ChatGPTUsageWidget\config.json`。组件可拖动，右键可以刷新、编辑配置、切换置顶或退出。

右键选择“字体颜色”可以自定义标题和普通信息文字颜色；剩余百分比继续按剩余额度显示绿色、黄色或红色。

单击组件可以在进度条卡片和圆环计数样式之间切换；拖动组件不会切换样式，当前样式会自动保存。

将组件拖到屏幕左边缘或右边缘会自动收起，只保留一条竖向剩余用量进度条；单击竖条临时恢复完整卡片，5 秒后自动回到贴边状态。拖离边缘会取消自动收起。

完整卡片和圆环样式会显示当前 Codex 登录用户名；未登录或账户读取失败时显示 `-`。

## 当前登录用户模式（默认）

无需配置密钥，使用 Codex CLI 已登录的当前 Windows 用户：

```json
{
  "mode": "codex"
}
```

## OpenAI API 费用模式（自动）

此模式查询官方 `/v1/organization/costs` 接口，显示本月费用占预算的比例。它是 OpenAI API 用量，不是 ChatGPT Plus/Pro 消息额度。

1. 设置当前 Windows 用户环境变量 `OPENAI_ADMIN_KEY`（必须是组织 Admin Key）。
2. 将配置改为：

```json
{
  "mode": "api-cost",
  "monthlyBudget": 20
}
```

密钥不会写入配置文件。卸载时双击 `uninstall.cmd`；它只移除开机启动项，不删除配置。
