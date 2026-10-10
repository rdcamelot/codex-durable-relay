# 测试与证据边界

## 推荐入口

在 64 位 Windows PowerShell 5.1 中，从仓库根目录运行：

```powershell
.\scripts\Build.ps1
.\scripts\Test.ps1
```

Node 测试也可以单独运行：

```powershell
npm test
```

PowerShell 隔离测试文件位于 `tests\`，包括安装事务、hosts 字节级计划、helper
入口、状态判定和 lifecycle 清理 fixture。安装事务 fixture 还验证失败时不留下
任务/服务注册，以及 Unicode ownerName 和 `ProxyPort` 能保存在 UTF-8 settings
中。单独运行时使用 `powershell.exe -NoProfile -NonInteractive -File <test-file>`，
不要把测试脚本改成指向真实的系统 hosts。

## 覆盖内容

- relay 只接受 loopback 配置，限制连接数、握手头和预握手缓存，并正确转发
  HTTP `CONNECT` 成功/失败及 TLS 字节。
- 代理不可用、恢复、上游中断、停止请求和受保护 shutdown barrier 的状态转移。
- 可配置 `ProxyPort` 同时用于 TLS preflight 和 relay 上游连接。
- 安装事务的阶段性复制、失败保留受保护结果、Unicode settings 和已验证 payload
  参数。
- 卸载清理失败保留服务与任务注册，成功后再移除服务及安装目录。
- 日志轮转、大小上限和只暴露错误代码的写入失败状态。
- hosts 精确行的追加/移除、冲突/损坏拒绝、原始字节和 ACL/备份路径的保留。
- helper 对监听地址、进程所有者、Node/script 路径和严格命令行的身份检查；
  父启动器的路径、固定参数、所有者和启动时间也参与校验与写后复验。
- lifecycle 在 Stop、Initialize、owner logoff、其他会话、错误身份和 helper
  失败时的清理屏障。

## 不要从测试推断的结论

隔离测试没有证明真实机器上的网络策略、代理实现、用户权限、第三方 DNS 缓存、
Codex 应用协议或业务送达。当前真实证据只有作者机器上的 service `STOP` 路径；
该证据来自候选版本的前身，本公开候选的全新安装尚未在干净虚拟机实测。
真实关机、断电、注销、快速启动和多用户竞态尚未测试。TLS 探测通过也不代表
WebSocket 已认证或消息已经送达。

测试输出和诊断文件可能包含连接元数据、进程 ID、时间、路径或本地配置。公开报告
只保留脱敏的测试命令、版本、失败阶段和高层 reason；不要上传原始日志、settings、
hosts 备份或完整状态 JSON。
