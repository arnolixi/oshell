# OShell / OShell Desktop 共享配置协议

共享配置协议的单一维护源是 **oshell-desktop 仓库的 `docs/configuration-protocol-v2.md`**，当前文档修订为 2.0（2026-10-17）。本文件只提供入口，不复制正文。

- [同级本地 checkout 中的协议规范](../../oshell-desktop/docs/configuration-protocol-v2.md)

协议修改必须检查并测试两个实现。真实 Swift/Go 双向及多节点验证入口：

```sh
cd /path/to/oshell-desktop
python3 scripts/test-sync-interop.py --native-source /path/to/OShell
```

发布时记录两个项目的提交号、规范修订号及字段合同 SHA-256。共享配置读 v1/v2、写 v2；未知字段拒绝应用和回写。字段合同源为 oshell-desktop 的 `internal/core/shared_configuration_schema.json`，Swift 文件通过 `scripts/sync-configuration-contract.py` 生成；禁止手工维护两套定义。所有参与同一同步目标的节点都要升级后再启用新版同步。已有未提交的其他功能修改不属于协议文档变更。
