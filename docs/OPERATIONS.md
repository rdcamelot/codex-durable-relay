# 运维与手动生命周期验收

本文面向已经理解 README 安全边界的 Windows 操作员。所有命令从仓库根目录、
64 位 Windows PowerShell 5.1 执行；真实验收应使用测试账户和可撤销的本机代理
配置。

## 安装前检查

1. 确认系统为 64 位 Windows，且系统变量对应标准的 `C:\Windows`、
   `C:\Program Files`。
2. 确认 `node.exe` 是官方签名的 Node.js 22+，并确认本机 HTTP `CONNECT`
   代理监听在 `127.0.0.1:7890` 或选定端口。代理认证目前不受支持。
3. 先运行 `Build.ps1`，再运行统一测试入口 `Test.ps1`。审阅构建产物和哈希，
   不要把 `PayloadDirectory` 指向未审阅的目录。
4. 确认接受整机 hosts 影响：使用系统解析该固定域名的非 Codex 进程也会被
   路由到本机。
5. 安装入口必须由目标桌面普通用户启动，以绑定正确的用户任务并避免 relay
   以高权限转发；UAC 只用于随后执行受保护安装阶段。

## 手动验收表

| 阶段 | 操作 | 预期结果 | 失败时 |
| --- | --- | --- | --- |
| 构建 | `scripts\Build.ps1` | 生成 `dist` 和 manifest；没有服务、任务或 hosts 变化 | 保留构建输出和错误摘要，不运行安装 |
| 隔离测试 | `scripts\Test.ps1` | Node/PowerShell 隔离测试通过；不触碰系统 hosts、任务或服务 | 只修复测试/实现后重跑，不手工改系统状态 |
| 安装预览 | 普通用户执行 `scripts\Install.ps1 -ReviewOnly -ProxyPort <端口>` | 打印 install root、代理端口和哈希；不弹 UAC，不创建安装对象 | 预览失败时检查 Node 签名、路径和端口 |
| 安装 | 普通用户执行 `scripts\Install.ps1 -ProxyPort <端口>` 并接受一次 UAC | 创建受保护目录、用户任务、SYSTEM hosts 任务和 lifecycle 服务；不覆盖既有安装 | 保留失败目录，读取 `install-result.json`，不要盲删 |
| 首次启动 | `scripts\Control.ps1 -Action Start`，再执行 `Status` | 代理可达时状态最终为 `ready`；代理不可达时为 `waiting_proxy`，不会写 hosts 映射 | 先修复代理连通性，再看状态中的 reason |
| 映射 | 查看 `Status -AsJson` 和 helper 状态 | 只有 relay 进程身份匹配且 TLS 检查通过时才出现精确的 `127.0.0.2 codex-cloud-backend.chatgpt.com # CODEX-DURABLE-RELAY-V2` | 出现冲突或 stale 状态时停止排查，不手工覆盖 hosts |
| 停止 | 以绑定的普通用户执行 `scripts\Control.ps1 -Action Stop` | 监听关闭、relay 状态为 `stopped`，精确映射被 SYSTEM helper 移除；登录自动启动设置不变 | 若 cleanup 未确认，保留目录并等待/检查 helper，不删除 hosts |
| 自动启动 | `EnableAutostart`、`DisableAutostart` 后分别查看 `Status` | 只改变用户登录触发器；不会改变当前手动 Start 能力 | 需要提权时确认是受保护任务变更，不重复安装 |
| 卸载 | 停止后执行 `scripts\Control.ps1 -Action Uninstall` | 服务停止并删除、两个任务移除、映射确认不存在，然后才删除安装目录；用户诊断仍保留 | 任何一步失败都保留受保护目录和备份，转入失败处置 |

表中的 `ready` 只代表 relay 的 TLS 探测通过。它不验证 Codex 应用的认证、
WebSocket 或业务消息。

## 失败处置

安装或卸载失败时，受保护目录可能刻意保留，因为其中有安装结果、settings、
helper/lifecycle 状态和 hosts 备份。按以下顺序收集信息：

1. 用绑定的普通用户运行 `scripts\Control.ps1 -Action Status -AsJson`。
   部分卸载已经移除任务时，Status 可能无法完整查询；这不阻止重复执行卸载。
2. 记录高层 `status`、`reason`、`lifecycleService`、`sessionGuardAlive`、
   `cleanupHealth` 和 helper 状态；不要复制
   原始日志或完整 settings 到 issue。
3. 确认 `Codex Durable Relay - User`、`Codex Durable Relay - Hosts` 和
   `CodexDurableRelayLifecycle` 的状态，不要直接删除任务/服务绕过清理。
4. 如果 hosts 仍有标记行，先让受保护 helper 再执行一次；若仍失败，保留
   `hosts-backup.bin` 和当前 hosts，交给有权限的维护者检查。不要盲删 hosts
   文件或安装目录。

若卸载报告服务删除仍在等待，先关闭占用服务句柄的管理窗口，再以绑定普通用户
重新运行 `scripts\Control.ps1 -Action Uninstall`。卸载允许任务已经部分移除的
状态，不必重装。安装失败则不自动覆盖原目录，需要先确认失败回执和映射状态。

硬关机、断电、真实注销和快速启动可能跳过部分回调。下次系统启动时 helper
会按 relay 进程身份和精确标记再次 reconcile/cleanup；如果身份或文件结构不再
可信，它会拒绝操作并留下错误状态，此时需要人工审阅。

## 证据边界

仓库的自动化测试使用隔离目录、fixture 和随机本地端口，设计目标是验证 relay、
代理握手、日志轮转、hosts 字节保留、helper 和 lifecycle 脚本逻辑，不修改真实
系统 hosts、任务或服务。作者机器验证过前身的真实 service `STOP`；托盘版既有
安装已验证无终端窗口、取消通知不误停，以及普通用户通过控制入口停止后整个进程链、
监听和映射均消失并能恢复运行。该验收没有实际关闭电脑或点击托盘菜单，不能代替
真实电源循环或干净系统全新安装验证。

后续一次真实使用已确认：关机前通过托盘退出，清理成功后关机，下次快速启动能自动恢复，
新运行正确关联上次退出回执。这不等于未手动退出托盘时的自动关机清理也已通过。

真实快速启动验证先后暴露了服务异步清理过晚、PowerShell 退出窗口缺少新回执的问题。
本版本把用户
退出清理放在普通用户托盘宿主的顶层窗口中：及时同意 `WM_QUERYENDSESSION`，
在确认的 `WM_ENDSESSION` 内等待清理完成，取消则保持运行。等待上限约 12 秒，
Windows 或用户仍可以强制终止。SYSTEM 服务不再在注销后重复发起后台清理。
实现参考 Microsoft 的 [WM_ENDSESSION](https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-endsession)
及[隐藏应用的关机处理建议](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/mpc/application-shutdown-changes-in-windows-vista)。

托盘以 `UseShellExecute=false` 和 `CreateNoWindow=true` 启动固定 PowerShell
子进程；启动器用相同无控制台方式运行 Node。登录触发、等待代理和普通用户权限
不变。右键“停止并退出”会先停止后台、清除自有映射；未确认清理则保留托盘供重试。
参考 [.NET 的 CreateNoWindow](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.createnowindow)
与 [NotifyIcon](https://learn.microsoft.com/en-us/dotnet/desktop/winforms/controls/notifyicon-component-overview-windows-forms)。

`lastSessionCleanup` 保存用户退出处理的阶段、运行标识和触发来源；`previousExit`
在新启动时关联上次运行与回执，缺失匹配则显示未确认。`session-notification.json`
记录最近查询、取消或确认结束通知，便于区分通知未到达与清理失败。`lastLifecycleOperation`
保存服务最近一次停止结果，启动不覆盖它。`cleanupHealth` 优先核对当前及上次运行
标识；旧服务成功记录不能覆盖缺失的退出回执，较新的服务失败仍会提示。
用户目录中的回执用于诊断，属于同一用户的信任范围，不能作为特权操作授权。
尚不能把定向消息测试称为修复后的真实快速启动、强制关机、断电或多用户竞态验收。
