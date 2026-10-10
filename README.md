# codex-durable-relay

非官方、实验性的 Windows 单域名 TLS passthrough 中继。它把
`codex-cloud-backend.chatgpt.com:443` 的本机连接转发到一个本机 HTTP
`CONNECT` 代理；中继本身不终止或解密 TLS。

> English summary: An unofficial experimental 64-bit Windows relay for one
> fixed Codex cloud hostname. It forwards opaque TLS through a local HTTP
> `CONNECT` proxy and does not decrypt application traffic.

## 适用范围

本项目当前只在 64 位 x64 Windows、标准的 `C:\Windows` 和 `C:\Program Files`
路径，以及官方签名的 Node.js 22 或更高版本上验证；ARM 未验证。安装时要求本机已有一个监听在
回环地址上的 HTTP `CONNECT` 代理；默认是 `127.0.0.1:7890`，也可以在安装
时用 `-ProxyPort` 指定 1 到 65535 的端口。代理认证没有配置入口。

中继只接受固定的本地监听地址 `127.0.0.2:443`，只向固定目标
`codex-cloud-backend.chatgpt.com:443` 建立上游 `CONNECT`。它不是通用端口
转发器，也不是通用的 SOCKS/HTTP 代理。

## 数据流

```text
使用系统解析的本机进程
        │ hosts: codex-cloud-backend.chatgpt.com -> 127.0.0.2
        ▼
127.0.0.2:443  ──TLS 字节──>  Node 中继
                                  │ HTTP CONNECT（无认证）
                                  ▼
                         127.0.0.1:<ProxyPort>
                                  │ CONNECT codex-cloud-backend.chatgpt.com:443
                                  ▼
                         codex-cloud-backend.chatgpt.com:443
```

安装的 SYSTEM hosts 维护任务只管理这一条带有
`CODEX-DURABLE-RELAY-V2` 标记的映射。普通用户 Node 进程负责监听和转发；
受保护的 SYSTEM 任务负责 hosts 维护，另一个 SYSTEM 生命周期服务负责在
关机、服务停止和适用的会话注销路径请求清理。

## 重要边界

- 适用于信任当前 Windows 用户及其本机会话的个人电脑。安装授权同时允许该用户
  启停一个域名的整机映射；它不提供针对恶意同机用户或进程注入的隔离。
- hosts 映射是整机范围的：所有使用 Windows 系统 hosts 解析这一域名的进程，
  包括非 Codex 进程，都会看到 `127.0.0.2`。使用自有 DNS、缓存或 DoH 的进程
  可能不受影响。安装前应确认这正是你要的范围。
- 不支持其他管理员程序并行替换 hosts；原子替换前的检查仍有竞争窗口。需要
  使用其他 hosts 管理器时，先停止中继，避免互相覆盖更改。
- 回环监听没有应用层认证；同一台机器上的其他进程可能连接它。上游 HTTP
  `CONNECT` 代理也没有认证字段，因此必须信任本机代理及其运行账户。
- TLS 只透传。中继不读取明文 TLS 内容、不记录应用 payload，也不保存账号
  凭据；本机代理、操作系统网络栈、目标服务仍可能看到连接时间、大小、失败
  状态等元数据。诊断状态和日志同样包含有限的连接统计与时序信息。
- `Status` 显示 TLS 检查通过，只表示探测可以完成 TLS 验证，不证明 WebSocket
  已认证、Codex 业务已送达或消息会被重放。项目不自动重放消息，也不修复
  Dot/业务路径权限或其他应用环境问题。
- 正常关机和注销清理是有时间预算的尽力行为。硬关机、断电或系统未执行完
  生命周期回调时，hosts 映射可能暂时保留；下次启动维护任务会再次检查，
  但不能保证每一种异常关机都能清理成功。

## 当前支持与不支持

| 当前支持 | 当前不支持 |
| --- | --- |
| 64 位 x64 Windows 的固定单域名 TLS 透传 | 非 Windows、ARM 未验证或非标准系统/程序路径 |
| `127.0.0.2:443` 到本机 HTTP `CONNECT` 代理 | 多域名、多目标、可配置监听地址或目标地址 |
| 默认 7890 或安装时指定的本机代理端口 | 需要代理用户名/密码的 HTTP CONNECT |
| 普通用户 Node 进程、SYSTEM hosts 维护和生命周期服务 | TLS 解密、证书替换、内容审计或应用消息重放 |
| 原子 hosts 映射、受保护备份和冲突拒绝 | Codex/Dot 业务送达保证或路径权限修复 |

## 构建、测试和安装

以下命令从仓库根目录、64 位 Windows PowerShell 5.1 执行。构建使用系统
`.NET Framework` 编译器生成受校验的 `dist` payload；它不会创建服务、计划
任务、hosts 映射或网络设置。

```powershell
.\scripts\Build.ps1
.\scripts\Test.ps1
```

正式安装前先用普通用户会话审阅。`-ReviewOnly` 只打印目标路径、代理端口和
哈希，不触发 UAC，也不执行安装：

```powershell
.\scripts\Install.ps1 -ReviewOnly -ProxyPort 7890
```

确认审阅结果后，仍从普通用户 PowerShell 启动实际安装；脚本会在检查完成后
请求一次 UAC 以运行受保护阶段。已经以管理员身份打开的 PowerShell 会被拒绝，
因为安装需要绑定正确的桌面用户，并避免 relay 以高权限转发；哈希校验由安装
流程独立完成。

```powershell
.\scripts\Install.ps1 -ProxyPort 7890
# 也可以显式指定已验证的官方 Node：
.\scripts\Install.ps1 -NodePath 'C:\Program Files\nodejs\node.exe' -ProxyPort 7890
```

安装器使用构建产物目录作为受校验的 `PayloadDirectory`，并把 `ProxyPort` 写入
受保护的 UTF-8 `settings.json`。不要把 payload 目录指向未审阅的文件，也不要
手工修改安装目录中的 settings；需要更换端口时应按卸载、重新构建、重新安装
流程处理。

安装成功后主要对象是：

| 对象 | 位置/名称 |
| --- | --- |
| 受保护 payload、配置和生命周期结果 | `C:\Program Files\CodexDurableRelay` |
| 普通用户状态、诊断和轮转日志 | `%LocalAppData%\CodexDurableRelay` |
| 用户登录任务 | `Codex Durable Relay - User` |
| SYSTEM hosts 维护任务 | `Codex Durable Relay - Hosts` |
| SYSTEM 生命周期服务 | `CodexDurableRelayLifecycle` |
| 系统 hosts 备份 | 受保护目录中的 `hosts-backup.bin` |

## 日常控制

```powershell
.\scripts\Control.ps1 -Action Status
.\scripts\Control.ps1 -Action Status -AsJson
.\scripts\Control.ps1 -Action Start
.\scripts\Control.ps1 -Action Stop
.\scripts\Control.ps1 -Action EnableAutostart
.\scripts\Control.ps1 -Action DisableAutostart
.\scripts\Control.ps1 -Action Uninstall
```

`Status` 是默认动作。`Start` 和 `Stop` 应由安装时绑定的普通用户执行；不要
为了停止 relay 以管理员身份运行 `Stop`。启用/禁用登录自动启动和卸载可能
触发 UAC。`Start` 只请求启动，relay 会等待本机代理可用并自行重试；可用状态
仍以 `Status` 为准。

停止或卸载时，程序会先停止监听，再请求 SYSTEM 任务移除自己创建的精确 hosts
行，并验证映射已经消失。卸载成功后，用户状态和诊断记录按设计保留。如果
安装失败、停止超时、hosts 清理未确认或卸载中途失败，受保护目录会被保留以便
排查；不要盲目删除 `C:\Program Files\CodexDurableRelay`，也不要手工清空或
重写整个 `hosts` 文件。先查看 `Status -AsJson`、helper/lifecycle 结果和受保护
备份，再决定下一步。

更完整的手动验收表见 [`docs/OPERATIONS.md`](docs/OPERATIONS.md)，测试证据和
未覆盖的真实系统场景见 [`docs/TESTING.md`](docs/TESTING.md)。

## 隐私和公开问题

原始 `relay.jsonl`、`status.json`、`settings.json`、hosts 备份、安装结果和
生命周期诊断不得上传到公开 issue、聊天或代码仓库。它们可能包含用户名、路径、
时间、进程标识、连接统计或本机配置。报告问题时只提供脱敏摘要、软件版本、
高层状态/原因和必要的时间范围；如需原始材料，应先通过维护者指定的私下渠道
确认接收范围。

## 许可证与实现声明

当前候选许可证为 MIT，详见 [`LICENSE`](LICENSE)。本项目实现使用 Node.js 内置
模块和 .NET/Windows API，没有引入 Proxifier 等项目代码。安全边界和报告方式见
[`SECURITY.md`](SECURITY.md)。
