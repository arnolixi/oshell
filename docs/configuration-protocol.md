# OShell / OShell Desktop 共享配置协议

共享配置协议的单一维护源是 **oshell-desktop 仓库的 `docs/configuration-protocol-v2.md`**，当前文档修订为 2.0（2026-10-17）。本文件只提供入口，不复制正文。

- [同级本地 checkout 中的协议规范](../../oshell-desktop/docs/configuration-protocol-v2.md)

协议修改必须检查并测试两个实现。真实 Swift/Go 双向及多节点验证入口：

```sh
cd /path/to/oshell-desktop
python3 scripts/test-sync-interop.py --native-source /path/to/OShell
```

发布时记录两个项目的提交号、规范修订号及字段合同 SHA-256。共享配置读 v1/v2、写 v2；未知字段拒绝应用和回写。字段合同源为 oshell-desktop 的 `internal/core/shared_configuration_schema.json`，Swift 文件通过 `scripts/sync-configuration-contract.py` 生成；禁止手工维护两套定义。所有参与同一同步目标的节点都要升级后再启用新版同步。已有未提交的其他功能修改不属于协议文档变更。

## 0.2.75 发布验证基线

- OShell：`v0.2.75`，协议实现提交 `0aa1a047fc4aa251f36290cb306d86d05de2ddd5`。
- OShell Desktop：`89aa37cd88a0362b05b2329e28c72543984c1c3d`。
- 规范修订：2.0（2026-10-17）。
- 字段合同 SHA-256：`9a82a335e40d315f9a54455c874f87bcaea0fe3551a69770d67955f439261657`。

## 0.2.76 发布验证基线

- OShell：`v0.2.76`，共享协议与字段合同保持 v2 不变。
- OShell Desktop：`28571b3a41d15777f79ae77f2658755d0abebaee`；验证时工作区干净，未修改或发布该项目。
- 规范修订：2.0（2026-10-17）；验证日期：2026-10-18。
- 字段合同 SHA-256：`9a82a335e40d315f9a54455c874f87bcaea0fe3551a69770d67955f439261657`。
- Swift 核心源码摘要：`c5cadb3869a544e059e91a165806704a02a654e7fae6ef2881dbf87f7b1870a7`。
- Go 原生兼容样本及 `test-sync-interop.py` 真实双向验证通过：Swift/Go 往返、多节点目录与 WebDAV 同步、首次读取无多余改写、完整共享字段与未知字段拒绝、会话归档使用同一字段定义。
- 本次侧栏专用快捷键、显示状态和鼠标选词偏好留在 Mac 本机，不进入共享配置；Touch ID 记录、命令历史、文件传输记录及续传检查点不加入同步。
