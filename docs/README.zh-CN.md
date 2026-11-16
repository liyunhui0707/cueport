# Agent Attention Router

帮助你集中查看多个 Codex 终端的待关注事项，并准确返回原来的 iTerm2 会话。

**这是实验性预览版。** 当前需要使用应用设置中的连接启动／恢复命令；直接
启动的普通 Codex 不会自动接入。尚未完成完整 P0、所有问题／审批生命周期和
无障碍验收，不要将其理解为通用的自动监控保证。

## 使用范围

- Apple Silicon Mac；已在两台 macOS 27.2.1、iTerm2 3.7.7 上进行限定检查。
- 仅接受原生 arm64 Codex **0.169.0**。Codex、iTerm2、账号和后端不随包提供。
- 应用为 ad-hoc 签名，尚未 Developer ID 签名或公证；可能需要自行审阅正常
  macOS 首次打开提示。不要关闭系统保护或运行绕过命令。

## 开始使用

1. 从本仓库 Releases 下载选定版本的 arm64 应用包，核对校验和，解压到
   `~/Applications/Agent Attention Router.app`。
2. 打开设置，在 Your connection → Opening the app 选择
   **Set up connected bridge…**，退出并重开应用，确认 Connected bridge。
3. 新会话使用 **Copy launch command**；继续旧项目使用
   **Copy resume command**，在实际项目的 iTerm2 Shell 运行，再选择原会话。
4. 自行完成原生登录、信任、iTerm API 和通知授权。勿扰模式或屏幕共享通知
   策略可能抑制弹出提醒；应用不会绕过它们。

主面板显示仍开启的注册来源；退出／关闭后移出主面板，历史记录保留在诊断页。
点击通知只代表查看，不会替你回答、批准或将未知问题标为已解决。

更新时保留设置、当前数据和运行中的桥接进程；旧进程在自然重新连接后才使用
新 helper。回退只恢复应用文件，不能用旧快照覆盖当前会话数据。

[完整安装、依赖、更新与回退](install.md) · [验收和已知限制](compatibility.md) ·
[隐私与安全](../SECURITY.md)。存储内容为元数据，不持久化提示词、代码、工具
命令、问题正文或对话路径。MIT 许可。
