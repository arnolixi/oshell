# SecureCRT / Xshell 会话导入 OShell 教程

适用于 OShell **0.2.59 及之后**。导入后先核对连接信息，再手动连接；现有会话不会被覆盖。

其他客户端或需要自定义字段映射时，可参考 [其他终端会话转换指南](session-conversion.md)，借助 AI 编写脚本生成 OShell 原生 JSON，再通过 OShell 来源导入。

## 支持哪些版本和文件

| 来源 | 面向的主要版本 | 在 OShell 中选择的文件或目录 |
| --- | --- | --- |
| SecureCRT | 7.3–9.x 的标准 XML 导出 | `Tools → Export Settings` 生成的 `.xml` |
| SecureCRT | 使用传统 INI 会话配置的版本，包括较早的 6.x / 7.x 及 8.x / 9.x | 单个或多个 `.ini`，或完整 `Sessions` 目录 |
| Xshell | 5 / 6 / 7 / 8 的标准会话文件 | 单个或多个 `.xsh`，或完整 `Sessions` 目录 |
| Xshell | 内容为普通 ZIP 的会话导出包 | `.xts` 或装有 `.xsh` 的 `.zip` |

兼容性按文件结构判断，不能仅凭扩展名识别。已用格式夹具验证 XML、INI、UTF-8、UTF-16、中文目录及 ZIP/XTS；没有逐一运行上述每个厂商版本做实机验收。若某个版本生成加密或专有容器，使用下面的 Sessions 目录方式迁移。

### 能迁移什么

- 会话名称、原目录层级和空目录。
- SSH2、SFTP、普通 FTP 的主机、端口、用户名。
- POSIX 形式的私钥**路径**（`/…` 或 `~/…`）可以保留，但不会检查文件是否已迁移到 Mac，也不复制、读取或转换私钥文件。Windows 路径和程序内部密钥名称会提示重新选择。
- 已识别的协议保活字段及 Xshell TCP KeepAlive 开关；不自动启用空闲字符串。

这些内容需要导入后补充或核对：

- **Xshell 登录密码**：支持用原 Xshell 主密码解密并校验兼容的密码记录，再按 OShell 当前的主密码或本机密钥重新加密保存。两个程序的主密码可以不同。Windows 账户绑定密码需先在原 Xshell 中启用主密码并重新导出。
- **SecureCRT 密码、私钥口令、私钥内容、主机指纹不迁移。**
- 代理、跳板机、隧道、登录脚本、远端命令、宏、外观、快捷键和厂商特有配置不迁移。检测到的连接附加设置会列入提示；未知专有字段不会执行。
- Telnet、Rlogin、Serial、RDP、SSH1、FTPS 等不转换为 SSH，相关条目会明确跳过。

## 一、从 SecureCRT 导出

### 方法 A：XML，推荐用于 7.3 及之后

1. 在原电脑打开 SecureCRT。
2. 选择 **Tools（工具）→ Export Settings（导出设置）**。
3. 根据向导选择会话或文件夹并保存为 XML，例如 `SecureCRT-sessions.xml`。
4. 将 XML 复制到运行 OShell 的 Mac。

SecureCRT 9.6 增加了更细的导出选择。使用个人数据目录时，用户名等字段是否包含在文件中与 **Include Personal Configuration Data** 选项有关；9.5 及更早版本的此类备份可能没有用户名。OShell 不迁移密码，缺少用户名时会在预览中提示，导入后补填即可。[SecureCRT 官方导出说明](https://www.vandyke.com/support/tips/backupsessions.html)

### 方法 B：复制 Sessions 目录

适用于较早版本，或只想迁移会话文件的情况。

1. 打开 **Global Options（全局选项）→ Configuration Paths（配置路径）**，查看实际配置目录。
2. 保存修改并关闭 SecureCRT，避免遗漏尚未写入的更改。
3. 在配置目录中找到 **Sessions** 子目录，将它完整复制到 Mac，保留子目录及 `.ini` 文件。
4. 在 OShell 中选择这个 Sessions 目录。也可选择其上一层 Config 目录，OShell 会识别其中的 Sessions 子目录。

不要只依据网上的默认路径查找，因为配置目录可以自定义。选择整个目录才能保留层级；单独多选 INI 文件时，会按文件名放入同一导入目录。[SecureCRT 官方旧版本备份说明](https://www.vandyke.com/support/tips/backupsessions_72andearlier.html)

若复制的是 ZIP 形式的 SecureCRT 备份，请先解压，再选择其中的 Sessions 目录；SecureCRT 导入入口不直接处理 ZIP。

## 二、从 Xshell 导出

### 方法 A：导出向导

1. 在原 Windows 电脑打开 Xshell。
2. 选择 **File（文件）→ Export（导出）**，进入会话导入/导出向导。
3. 按向导选择会话和保存位置；如需迁移密码，先确保 Xshell 已设置主密码，并且**不要勾选 Clear Password（清除密码）**。
4. 点击 **Next / Finish（下一步 / 完成）**，将导出的文件复制到 Mac。
5. 导出结果是 ZIP 结构的 `.xts` 时，可以直接交给 OShell，无需改扩展名。若提示容器不受支持，改用方法 B。

菜单流程和密码的跨设备限制可参考 [Xshell 8 官方手册，第 5.3 节 Export](https://www.netsarang.com/docs/Xshell8_manual.pdf)；旧版界面可参考 [Xshell 5 官方手册](https://www.netsarang.com/docs/Xshell5_manual.pdf)。

### 方法 B：复制 XSH 会话目录，兼容性更直接

1. 在 Xshell 的 **Options（选项）→ General（常规）** 中查看 **Session Folder Path（会话文件夹路径）**。
2. 保存会话设置，将该目录完整复制到 Mac，保留子目录和 `.xsh` 文件。
3. 在 OShell 的 Xshell 导入入口选择这个目录。

不要复制安装程序目录；要复制存放会话的目录。版本升级、自定义用户数据目录或 OneDrive 等设置都可能改变实际位置，以软件显示的路径为准。[Xshell 8 官方手册，第 11.1 节](https://www.netsarang.com/docs/Xshell8_manual.pdf)

只有一个会话时可以直接选 `.xsh`；需要保留多级分类时，请选择整个 Sessions 目录。

如果手头只有无法识别的 XTS，先在原版 Xshell 中用 **File → Import** 恢复到会话管理，再按方法 B 复制 `.xsh` 文件。请勿仅将未知二进制文件改名成 `.xsh`。

## 三、导入到 OShell

1. 打开顶部 **会话管理**。
2. 进入目标目录，例如先创建并进入 `/迁移`。
3. 在会话列表空白处点击右键，选择 **导入会话到当前目录…**。也可以从 App 的“会话”菜单进入“导入会话…”。
4. 在来源窗口选择 **SecureCRT** 或 **Xshell**，点击 **选择文件或目录…**。
5. 选择刚复制的 XML、INI、XSH、XTS，或完整 Sessions 目录。
6. 查看预览：
   - **可导入会话**：核对名称、目录、协议、主机、端口和用户名。
   - **迁移提示 / 跳过原因**：查看需要补充的私钥路径、代理、隧道以及未支持的协议或错误条目。
7. 如需迁移 Xshell 密码，勾选“迁移 N 项 Xshell 加密密码”，点击 **导入** 后，在安全输入框填写原 Xshell 主密码。它只用于本次迁移，不会保存或成为 OShell 主密码。按 Esc 或取消不会保存会话；没有可导入会话时，导入按钮会禁用。
8. 导入完成后，查看实际迁移密码数量，核对私钥、代理等附加配置，再手动连接。原主密码错误、密文损坏或加密格式不兼容时，本次会话配置不写入。

会话自动归入对应来源子目录。例如源会话是 `生产/北京/数据库`，目标选 `/迁移`，结果为：

```text
/迁移/SecureCRT/生产/北京/数据库
/迁移/Xshell/生产/北京/数据库
```

原有会话保留。同一目录已有同名会话时，新条目会标记为“导入副本”；重复导入也不会覆盖旧配置。若目标是 `/Links`，沿用快捷引用规则：在 Links 中创建引用，源会话单独保存。

### 已导入会话只有连接信息，如何补充密码

进入包含这批会话的目录（不确定时可选择会话根目录），重新选择原 XTS，在预览中勾选“迁移 N 项 Xshell 加密密码”和“仅补充已导入会话的空密码”。程序优先匹配来源目录，再核对名称、协议、主机、端口和用户名；不会新建会话或覆盖已有密码。匹配不唯一会停止，未匹配项目会计数提示。

密码记录先验证完整性再迁移，任何校验失败都会取消本次保存。已有会话的 ID、代理、隧道、保活及其他属性保留。会话属性中的密码框不会显示明文，看到“已保存；留空保留”表示已有加密密码。

## 四、导入后检查与常见问题

| 情况 | 处理方式 |
| --- | --- |
| Xshell 密码没有带过来 | 检查是否使用支持密码迁移的新版 OShell，预览是否检测到加密密码；原导出不能勾选清除密码。已导入会话可用“仅补充空密码”重试。 |
| 提示主密码错误或格式不受支持 | 使用导出时的原 Xshell 主密码；OShell 主密码不要求与它相同。若仍失败，保留原文件并提供格式信息排查，不会保存未经校验的密码。 |
| 用户名显示“未提供” | 原导出未包含用户名，连接前补填；否则可能使用 Mac 的默认 SSH 用户。 |
| 私钥路径是 Windows 路径 | 将有权使用的私钥单独迁移到 Mac，确认格式可被 OpenSSH 使用，再在会话属性中重新选择。 |
| 以前通过代理、跳板机或隧道连接 | 重新配置这些附加连接设置，不要把基础信息导入成功理解为所有连接选项已迁移。 |
| 连接 CentOS 6 等旧 SSH 服务失败 | 在“连接”页按实际需要启用旧版 SSH 兼容选项；导入不会自动放宽算法。 |
| XTS 提示加密或格式不支持 | 在原 Xshell 中恢复导出包，再复制 Sessions 目录导入。ZIP64、分卷及非 ZIP 专有容器不支持。 |
| 中文乱码或编码提示 | 优先使用原始 UTF-8 / UTF-16 文件；中文旧 ANSI 文件可按 GB18030 读取，其他编码先另存为 UTF-8。 |
| 条目被跳过 | 查看预览中的具体原因；修正后只重新导入对应文件即可。 |
| 导出包太大 | 分批导出。单批最多 2000 个会话，输入及展开数据合计不超过 64 MiB；ZIP/XTS 最多 4000 项，每项不超过 2 MiB。 |

主机指纹不会从第三方客户端导入，首次连接时按实际服务器指纹核对。此功能只读取所选导出文件，不会修改 SecureCRT/Xshell 原配置，也不会执行其中的登录脚本。

Xshell 主密码记录的兼容性依据其 RC4/SHA-256 数据格式及完整性校验，不假定所有厂商版本都兼容；不支持的记录会明确失败。参考 [Xshell 导出说明](https://netsarang.atlassian.net/wiki/spaces/ENSUP/pages/31523231) 和 [加密格式研究](https://github.com/HyperSine/how-does-Xmanager-encrypt-password/blob/master/doc/how-does-Xmanager-encrypt-password.md)。
