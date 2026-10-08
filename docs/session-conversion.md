# 将其他终端客户端的会话转换为 OShell 会话

本文面向能够运行脚本、检查数据，并借助 AI 编写转换程序的用户。流程是：**从原客户端导出会话配置 → 让 AI 根据真实样本开发转换脚本 → 用主密码加密登录密码并生成 OShell 会话 JSON → 在 OShell 中导入并核对。**

这里的“会话”指保存的连接配置，例如名称、主机、端口、用户名和目录分类；终端输出日志、聊天记录、命令历史或正在运行的 Shell 不能通过此格式恢复。

SecureCRT 和 Xshell 用户可以先尝试 OShell 的内置导入，见 [会话导入教程](session-import.md)。本文适用于其他来源，或需要自定义字段映射的情况；不要求 OShell 直接识别原客户端的文件。

## 1. 准备来源文件和样本

1. 在原客户端导出会话、连接列表或配置备份。若没有导出功能，按该客户端的说明复制会话配置目录。保留原文件和目录结构，在副本上转换。
2. 记录客户端名称、版本、导出方式和文件编码。不要仅修改扩展名，也不要让 AI 根据产品名称猜测内部格式。
3. 准备几条有代表性的脱敏样本：普通 SSH、非默认端口、中文名称、多级目录，以及实际使用的 SFTP、FTP、代理或跳板机条目。保留字段名、数据类型、转义方式和层级关系。
4. 在 OShell 中创建一个测试会话，先导出不含密码的文件，作为当前安装版本的结构参考。再用虚构登录密码创建一份“包含已保存密码”的导出，核对密码封装；不要将真实密码样本交给 AI。若要转换代理、隧道等高级配置，再分别配置并导出对应样本。

向 AI 提供本指南、来源样本和 OShell 参考文件。密码、令牌、私钥内容及真实内网地址应从提供给 AI 的样本中移除或替换；完整原始文件可留在本机，由生成的脚本本地读取。

如果来源是加密或未知二进制容器，先用原客户端恢复并导出可读取的配置，不要把二进制内容强行当作 JSON、XML 或 INI 解析。不同版本的源格式和继承规则，需要根据实际文件或对应厂商文档确认。

## 2. 目标文件：OShell 会话 JSON

本文生成 **包含主密码加密的登录密码、不含快捷引用的版本 2 文件**，保存为 UTF-8 编码的 `converted.oshell.json`。文件本体是一个 JSON 对象，不是 ZIP，也不是会话数组或 OShell 的整份应用配置。

以下完整示例可以复制保存后导入，第一条会话包含加密密码，第二条没有保存密码。示例文件主密码为 `OShell-demo-master-2026`，第一条登录密码为 `Example-login-2026!`；两者均为公开测试值，不可用于真实连接。示例地址不提供可连接的服务器：

```json
{
  "format": "OShell.sessions",
  "version": 2,
  "profiles": [
    {
      "id": "63A0A998-2899-4D2E-940F-543AE592A8C1",
      "name": "应用服务器",
      "group": "原客户端/生产/华东",
      "kind": "ssh",
      "host": "192.0.2.10",
      "port": 22,
      "username": "ops",
      "identityFile": "",
      "jumpHost": "",
      "encryptedPassword": {
        "version": 1,
        "algorithm": "AES-256-GCM",
        "kdf": "PBKDF2-HMAC-SHA256",
        "iterations": 600000,
        "salt": "giuQS/jqCUaCHtg9tOvcJw==",
        "ciphertext": "pdLqsKlchFItx1cvqdSj6gvAfF7pR2qIYI3DLNP38Whclt2u6Uc7d/H4AKJsD8M=",
        "identity": {
          "host": "192.0.2.10",
          "user": "ops",
          "port": 22
        }
      }
    },
    {
      "id": "7AB2316B-E564-4077-8613-839D30E56A47",
      "name": "文件服务器",
      "group": "原客户端/测试",
      "kind": "sftp",
      "host": "files.example.test",
      "port": 2222,
      "username": "files",
      "identityFile": "",
      "jumpHost": "",
      "initialDirectory": "."
    }
  ],
  "directories": [
    "原客户端",
    "原客户端/生产",
    "原客户端/生产/华东",
    "原客户端/测试",
    "原客户端/空目录"
  ]
}
```

JSON 不允许注释或末尾多余的逗号。数字和布尔值不要写成字符串，字段名及枚举值区分大小写。

### 顶层字段

| 字段 | 类型 | 要求 |
| --- | --- | --- |
| `format` | 字符串 | 必填，固定为 `OShell.sessions`。 |
| `version` | 整数 | 必填，本指南使用 `2`；不是应用版本号。 |
| `profiles` | 对象数组 | 必填，保存会话，最多 2000 条。 |
| `directories` | 字符串数组 | 必填；没有显式目录时可为 `[]`，空目录必须在这里声明才能保留。建议收集所有会话目录及父目录后去重，最多 4000 项。 |
| `links` | 对象数组 | 可省略。非空时必须使用版本 `3`，本指南的基础转换不生成此字段。 |

当前读取器接受版本 1–3；版本 1 不支持 SFTP / FTP 会话。带快捷引用的版本 3 格式另见 [使用指南](usage.md)，不要只提高版本号来表达源客户端的功能。

### 每个会话的必填字段

以下十个字段必须全部存在，即使其中某些值是空字符串。不要因为 OShell 界面有默认值就省略它们。

| 字段 | 类型 | 映射规则 |
| --- | --- | --- |
| `id` | UUID 字符串 | 为每条会话生成 UUID，同一文件内不可重复。Python 可使用 `str(uuid.uuid4())`。 |
| `name` | 字符串 | 会话显示名，不能是空白。来源缺失时可按事先约定用主机名补齐，并在报告中记录。 |
| `group` | 字符串 | 会话目录，例如 `原客户端/生产/华东`；根目录为 `""`。不包含会话名称。 |
| `kind` | 字符串 | 远程连接使用 `ssh`、`sftp` 或 `ftp`，不能写成 `SSH2` 等源软件名称。 |
| `host` | 字符串 | 纯主机名、IP 或 SSH 配置别名；不包含协议前缀、用户名、路径或端口。 |
| `port` | 整数 | 1–65535。仅在来源未指定端口且协议明确时，SSH/SFTP 默认 22，普通 FTP 默认 21。 |
| `username` | 字符串 | 登录用户名；未知时写 `""` 并报告待补充，不擅自填 `root`。 |
| `identityFile` | 字符串 | 私钥在目标 Mac 上的路径，未知或不适用时写 `""`；不是私钥内容。 |
| `jumpHost` | 字符串 | 基础转换写 `""`。确需映射时按后文要求核对。 |

`local` 也是合法的 `kind`，表示本地终端；本文不将远程会话转换为本地终端。Telnet、Rlogin、Serial、RDP、SSH1、FTPS 或未知协议应跳过并说明原因，不能强行改成 SSH 或普通 FTP。

### 可选字段和高级设置

以下字段在格式中可选，但本指南要求为有来源密码的会话生成 `encryptedPassword`。其他字段省略后使用 OShell 模型的默认值，并不表示继承了源客户端或用户自定义的“默认会话”设置。

| 字段 | 省略时的行为 | 转换建议 |
| --- | --- | --- |
| `initialDirectory` | SSH/SFTP 为 `.`，FTP 为 `/` | 文件会话的远端初始目录。不是客户端本地下载目录，也不是启动命令。 |
| `encryptedPassword` | 无已保存密码 | 有登录密码时按第 3 节生成完整加密对象；没有密码才省略。 |
| `proxy` | 无代理 | 基础转换省略，来源启用代理时列为待配置。 |
| `tunnels` | 无隧道 | 基础转换省略，来源启用端口转发时列为待配置。 |
| `keepAlive` | 协议保活开启，间隔 30 秒、最多 3 次未响应；TCP KeepAlive 开启；空闲字符串关闭 | 不等同于源客户端设置，需要保留原行为时明确映射。 |
| `legacySSH` | `false` | 不自动启用旧版算法兼容。 |
| `titleMode` | `shellIntegration` | 通常省略。 |
| `quickConnect` | `true` | 通常省略。 |

有把握时可以继续迁移代理、隧道、保活，但应以**当前 OShell 导出的完整对象**为模板逐项映射。`proxy`、`keepAlive` 和每条隧道对象中的非可选字段都需要完整填写，不能只输出一个 `kind` 或 `enabled`。相关结构见文末源码链接。

旧字段 `jumpHost` 可表示 OpenSSH `-J` 形式的跳板机，例如 `ops@bastion.example.test:2222`；它不能与非 `none` 的 `proxy` 同时设置。优先通过 OShell 的代理页配置跳板机并导出样本。源软件中“引用另一个会话”的代理设置不能直接复制引用 ID，需要解析其连接信息。

登录密码按下一节迁移；代理密码可按同一算法绑定代理对象后加密。私钥内容、私钥口令不在本指南的迁移范围内。其他客户端的密文必须先按其真实格式在本机解密并验证，再用文件主密码重新加密；不能直接复制到 OShell 字段中。

## 3. 用主密码生成 OShell 可识别的密码字段

### 先区分三种密码

| 名称 | 用途 |
| --- | --- |
| 服务器登录密码 | 要迁移的每条 SSH/SFTP/FTP 会话密码。 |
| 来源客户端主密码 | 若来源只提供加密记录，用它按来源格式解密；不是每种客户端都支持跨设备解密。 |
| 文件主密码 | 转换时由用户指定，用来加密输出中的所有密码。OShell 导入时先输入这个密码，再用目标 OShell 的主密码或本机密钥重新加密保存。 |

文件主密码和目标 OShell 主密码可以不同。转换器应通过 `getpass` 在本机交互读取并确认文件主密码，按 OShell 新主密码要求使用至少 8 个字符、最多 1024 个 UTF-8 字节；建议使用较长的 ASCII 口令，避免不同语言对 Unicode 字符计数的差异。不要去除密码首尾空白或进行 Unicode 归一化，也不要把主密码放入命令行参数、输出 JSON 或报告。

来源必须能提供真实登录密码：来自本地明文导出、已验证的来源解密流程，或用户本机交互补充。只有无法解密的第三方密文时，不能直接转成 OShell 密文。脚本应默认停止并报告密码迁移失败；只有用户明确允许时，才跳过对应密码并保留连接信息。

此处加密保护的是密码字段；会话名称、地址、用户名和目录仍是明文 JSON。

### `encryptedPassword` 对象

每条有密码的会话增加一个 `encryptedPassword` **对象**。用户通常所说的“加密后的密码字符”是其中的 `ciphertext` Base64 字符串；仅提供该字符串不足以导入，还必须携带以下字段：

| 字段 | 固定值或生成规则 |
| --- | --- |
| `version` | 整数 `1`，这是密码封装版本，与文件顶层的 `version: 2` 不同。 |
| `algorithm` | `AES-256-GCM`。 |
| `kdf` | `PBKDF2-HMAC-SHA256`。 |
| `iterations` | 生成时使用整数 `600000`；读取器接受 600000–2000000。 |
| `salt` | 每项独立生成 16 个安全随机字节，标准 Base64 编码。 |
| `ciphertext` | 标准 Base64 编码的 `12 字节 nonce + AES-GCM 密文 + 16 字节认证标签`。 |
| `identity` | `{ "host": "实际目标主机", "user": "实际登录用户", "port": 22 }`，注意内部是 `user`，不是 `username`。 |

跨设备文件必须**省略 `localKeyID`**，它是本机密钥引用。无需在会话文件中加入 `masterPasswordVerifier`；本流程也不生成 OShell 的整份应用配置。

密钥派生：以文件主密码原样编码后的 UTF-8 字节为密码，用 PBKDF2-HMAC-SHA256、16 字节 salt、600000 次迭代，派生 32 字节 AES 密钥。每项密码都独立随机生成 salt 和 12 字节 nonce，即使登录密码相同也不能复制密文对象。

AES-GCM 的附加认证数据（AAD）按下面八段拼接，段间为一个 **NUL 字节 `0x00`**，最后一段后没有分隔符；整体编码为 UTF-8：

```text
OShell-password-v1
profile.id 的标准大写 UUID（带连字符）
profile.host
profile.port 的十进制字符串
profile.username
identity.host
identity.user
identity.port 的十进制字符串
```

这张列表中的换行只表示分段，不是实际分隔符。不要把字面量 `\0` 的两个字符或 JSON 文本作为 AAD。先确定最终 UUID、主机、端口、用户名和 identity，再加密；之后修改任一绑定字段都需要重新加密。重命名和修改目录不在 AAD 中。

`identity` 必须与真实连接身份一致。对明确主机、显式用户名且没有 SSH 配置重写的会话，可直接使用 `host`、`username`、`port`。使用 SSH 别名、默认用户名或主机规范化配置时，应先确认目标 Mac 实际解析后的身份；不知道时不要猜测。OShell 连接时会比较该身份，导入解密通过也不代表身份一定正确。FTP 使用会话本身的主机、用户名、端口。

### Python 加密参考实现

以下函数负责 OShell 密码封装，可交给 AI 嵌入来源转换脚本；它不负责解析来源或解密其他客户端密码。Python 标准库提供 PBKDF2，AES-GCM 使用 `cryptography`。可在独立环境中安装：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install cryptography
```

```python
import base64
import hashlib
import secrets
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def encrypt_oshell_password(profile, password, master, identity):
    """profile 已完成映射；identity 是已经确认的实际目标身份。"""
    plain = password.encode("utf-8")
    if not plain or len(plain) > 4096 or any(c in password for c in "\0\r\n"):
        raise ValueError("登录密码必须非空、最多 4096 字节，且不含 NUL/回车/换行")
    master_bytes = master.encode("utf-8")
    # CLI 应交互确认主密码；本例建议至少 8 个 ASCII 字符。
    if len(master) < 8 or len(master_bytes) > 1024:
        raise ValueError("文件主密码至少 8 个字符，最多 1024 个 UTF-8 字节")
    for port in (profile["port"], identity["port"]):
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError("端口必须为 1–65535 的整数")
    if not identity["host"] or not identity["user"]:
        raise ValueError("先确认实际目标主机和用户名，再迁移密码")

    canonical_id = str(uuid.UUID(profile["id"])).upper()
    aad = "\0".join([
        "OShell-password-v1", canonical_id,
        profile["host"], str(profile["port"]), profile["username"],
        identity["host"], identity["user"], str(identity["port"]),
    ]).encode("utf-8")
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(12)
    key = hashlib.pbkdf2_hmac("sha256", master_bytes, salt, 600000, dklen=32)
    encrypted_with_tag = AESGCM(key).encrypt(nonce, plain, aad)
    return {
        "version": 1,
        "algorithm": "AES-256-GCM",
        "kdf": "PBKDF2-HMAC-SHA256",
        "iterations": 600000,
        "salt": base64.b64encode(salt).decode("ascii"),
        "ciphertext": base64.b64encode(nonce + encrypted_with_tag).decode("ascii"),
        "identity": dict(identity),
    }
```

`AESGCM.encrypt()` 返回“密文 + 16 字节标签”，因此代码只在前面加 nonce；不要再附加一次标签，也不要分别 Base64 编码后拼接。[cryptography 官方 AESGCM 文档](https://cryptography.io/en/latest/hazmat/primitives/aead/#cryptography.hazmat.primitives.ciphers.aead.AESGCM)

对第 2 节中第一条显式地址会话，可在本机这样调用；正式脚本应从本地来源记录读取每条密码，而不是要求逐条手输：

```python
from getpass import getpass

master = getpass("文件主密码：")
if master != getpass("再次输入文件主密码："):
    raise ValueError("两次主密码不一致")
profile = archive["profiles"][0]  # archive 是已经构造的会话文件对象
identity = {
    "host": profile["host"],
    "user": profile["username"],
    "port": profile["port"],
}
password = getpass("此会话的登录密码：")
profile["encryptedPassword"] = encrypt_oshell_password(
    profile, password, master, identity
)
```

代理密码使用同样的封装，存放在 `profile.proxy.encryptedPassword`。AAD 的会话字段改用**代理自己的 `id`、`host`、`port`、`username`**，身份也使用代理地址和账号；不能绑定到目标服务器会话 ID。OShell 的 SOCKS5 和 HTTP CONNECT 代理支持密码；本指南不把 SSH 跳板机密码当作这类代理密码迁移。

验证时应同时检查：正确主密码可解密；错误主密码、改动 UUID/主机/端口/用户名或密文后解密失败；OShell 能导入并为新 ID 重新加密。只在脚本内部加解密自测，无法排除双方同时使用了错误格式。

本文的 JSON 示例由上述 Python 函数生成，已用当前仓库的 `SessionArchive`、`SessionCipher` 验证读取、解密、错误主密码及篡改拒绝，并验证导入后更换 UUID 和主密码的重新加密结果可由 Python 解密。该验证覆盖原生文件处理逻辑，不代表已验证来源客户端解密或真实服务器连接。

## 4. 转换脚本必须处理的规则

### 目录与重名

- JSON 中的路径相对会话根目录，使用 `/` 分隔；不要带开头或末尾的 `/`、连续的 `//`、反斜杠、`.` 或 `..` 路径段，各段两侧不带空白。
- `group` 和 `directories` 中的每个路径最多 2048 个 UTF-8 字节、32 层，不含控制字符。中文长度按 UTF-8 字节计算。
- 来源中的目录分隔符、目录名内的 `/` 和转义字符要根据其格式区分；转换后若不同目录合并成同一路径，必须报告，不能静默丢失层级。
- 顶层 `Links` 是 OShell 快捷引用专用目录。基础转换建议加来源前缀，例如 `原客户端/Links`，并导入普通目录，避免触发快捷引用规则。
- 不按主机地址去重：同一服务器可能有不同用户名、端口或连接用途。相同目录下的同名会话也应保留，并在报告中列出。
- OShell 导入时会重新生成会话 ID。同一目录重名会话会另存为“导入副本”；再次导入相同文件会新增副本，不会按 UUID 更新现有会话。

### 主机、端口与路径

- `host` 必须非空、不能以 `-` 开头；当前接受 ASCII 字母、数字和 `.-_:[]`，不接受空白、`@`、`/` 或 `ssh://`。国际化域名应先明确转换为 ASCII 域名。IPv6 使用独立的 `port` 字段。
- 从 URL 或连接字符串提取地址时，正确拆分协议、用户名、主机、端口和路径，尤其不能用简单的冒号切分 IPv6。
- SSH/SFTP 用户名不能以 `-` 开头或包含空白、控制字符；FTP 用户名不能包含 `:`、换行、回车或 NUL。不要为了通过校验静默改写用户名。
- 显式提供却无效的端口应报错或跳过，不能当作“未提供”替换成默认端口。INI 中的十六进制数、布尔标志等必须按来源格式解释。
- Windows 私钥路径或客户端内部密钥名称不能直接成为 Mac 路径。未提供明确的路径映射时，将 `identityFile` 留空并报告；`~/.ssh/example_key` 等路径只引用文件，不会复制或转换私钥。
- `initialDirectory` 不能是空字符串，不能含 NUL、回车或换行，最多 8192 个 UTF-8 字节。没有明确来源值时省略即可。

### 转换报告与文件校验

每次运行同时输出转换报告，至少列出：读取的源会话总数、成功数、跳过数、待补充项，以及每个跳过或修改项的源文件/条目位置和原因。未知协议、缺失主机、无效端口、编码失败、继承设置未解析等问题必须可定位。

代理、跳板机、隧道、登录脚本、远端命令、宏、环境变量、终端编码、外观、快捷键及主机指纹，若未迁移，应在报告中明确列出。未知字段也应汇总，不要把“生成了 JSON”表述为“所有配置已迁移”。源文件中如果存在自动执行脚本，只读取并报告，不执行它们。

输出前应校验上述结构、类型、UUID 唯一性、目录格式和数量限制。**每个 JSON 文件最多 16 MiB（16 × 1024 × 1024 字节）**；超限时分批输出，每批最多 2000 个会话、4000 个显式目录，并保留该批所需目录。不要截断条目来满足限制。

可先用 Python 检查 JSON 语法：

```sh
python3 -m json.tool converted.oshell.json > /dev/null
```

这只检查 JSON 语法，不验证 OShell 格式或连接可用性。最终还需通过 OShell 的实际导入校验。

## 5. 可直接交给 AI 的开发提示词

将下面模板与本指南、来源样本和 OShell 参考导出一起交给 AI，替换方括号中的内容。让 AI 生成可重复运行的脚本，而不是直接手工改写全部会话。

```text
请开发一个本地运行的会话转换脚本，将其他终端客户端导出的会话配置，
转换为 OShell 可以通过“OShell 会话导出（JSON）”入口导入的文件。

来源客户端及版本：[填写]
来源导出方式、文件类型和编码：[填写；不确定的项目标为未知]
脚本运行系统及语言：[例如 macOS / Python 3，允许 cryptography 加密库]
来源目录前缀：[例如 原客户端]
输入样本：[附脱敏样本，包含子目录和特殊连接设置]
目标参考：[附本指南及当前 OShell 参考导出；密码样本只使用虚构值]
来源密码可用方式：[明文导出 / 已确认的解密方式 / 需本机交互补充]
密码范围：[登录密码；如需代理密码请明确说明]
需要额外迁移的设置：[无，或列出已确认的代理、隧道、保活等]
明确的私钥路径映射：[无，或列出原路径到目标 Mac 路径的映射]

请先分析实际源格式并给出“源字段 → OShell 字段”的映射表，说明协议、
编码、端口表示法、目录层级及全局/目录继承设置。不要猜测未知字段；
证据不足时指出还需要哪种脱敏样本，不要假装已支持。

实现要求：
1. 支持 --input、--output、--report 和 --dry-run。只读取指定输入，
   不修改来源文件或 OShell 配置，不连接服务器，不执行导出中的脚本。
   已有输出文件默认拒绝覆盖，显式 --force 才可覆盖。
2. 输出 UTF-8 JSON 对象，format 为 OShell.sessions，version 为整数 2，
   必须包含 profiles 和 directories，不生成 links。包含有来源的登录密码，
   但只写入用文件主密码生成的 encryptedPassword 对象，绝不写明文。
3. 每个 profile 都必须包含 id、name、group、kind、host、port、username、
   identityFile、jumpHost。id 为唯一 UUID；port 为整数；没有值的
   username、identityFile、jumpHost 使用空字符串，不能缺字段。
4. 仅将确认的 SSH2/SSH、SFTP、普通 FTP 映射为 ssh、sftp、ftp。
   未知或不支持的协议应跳过并报告，不得改为 SSH 或将 FTPS 降为 FTP。
5. 按指南处理目录规范、IPv6、默认端口、中文编码、空目录、重名、
   私钥路径和字段校验。不要按主机去重；保留源条目与输出 UUID 的对应。
6. 严格按指南第 3 节的 PBKDF2-HMAC-SHA256、AES-256-GCM、AAD 顺序和
   密文字节布局生成 encryptedPassword。每项使用独立随机 salt 和 nonce，
   UUID 用大写标准格式参与 AAD；输出不包含 localKeyID 或主密码校验器。
   不复制第三方密文、不迁移私钥内容。来源密码必须有可靠的读取/解密
   方式；无法获取时报告，不猜测，也不声称迁移成功。
   使用 getpass 在本机交互读取并确认文件主密码，不写入参数、日志或报告。
   默认要求完整迁移来源中已保存的密码：任一解密或加密失败即停止，
   只有用户显式允许缺失密码时才输出部分结果，并逐条记录缺失原因。
   加密前先确定最终 UUID、主机、端口、用户名及实际 identity，不在加密
   后修改这些绑定字段。未知用户名或 SSH 别名目标未确定时不得猜测 identity。
   除明确要求且有样本证明可映射的设置外，省略其他可选字段，并报告差异。
7. 对代理、跳板机、隧道、自动执行命令等未迁移项输出逐项提示。
   对无法解析的字段、编码或继承关系给出定位信息，不静默忽略。
8. 写出前校验整个文件：字段类型、UUID 唯一性、目录规范、协议、
   主机、端口、用户名；单文件不超过 16 MiB、2000 个会话、4000 个目录。
   失败不得留下看似可用的半成品，超限应明确报错或生成独立的分批文件。
9. 报告源会话总数、成功数、跳过数和待补充项，成功数加跳过数应与
   识别出的源会话总数一致。解析失败的文件另列，不得计作零条成功。
   报告另列检测到的密码数、成功加密数、缺失/失败数；只输出计数和定位，
   不输出密码、主密码、密文或私钥内容。预演不生成凭据文件。
10. 提供运行说明和脱敏测试样例，覆盖正常 SSH、SFTP/FTP、中文目录、
    非默认端口、IPv6、空目录、同名会话、缺失主机、非法端口、未知协议，
    以及来源格式实际存在的编码、转义或继承情况。验证正确主密码可解密、
    错误主密码及修改绑定字段会失败，并用 OShell 原生导入验证兼容性，
    不能仅以脚本自己加解密成功作为互操作证明。

交付：转换脚本、字段映射表、使用说明、样例输出和转换报告示例。
同时说明哪些密码与设置未迁移、需要导入后手工补充；不要声称已验证真实服务器连接。
```

脚本若按此接口实现，可先预演，再生成文件；以下命令是对生成脚本的接口约定，并非 OShell 自带命令：

```sh
python3 convert_sessions.py --input ./source-export --output ./converted.oshell.json --report ./conversion-report.json --dry-run
python3 convert_sessions.py --input ./source-export --output ./converted.oshell.json --report ./conversion-report.json
```

## 6. 在 OShell 中导入

1. 先查看转换报告，确认会话数量和未迁移项。首次建议只转换几条代表性会话，验收后再处理全量。
2. 在 OShell 打开“会话管理”（默认 `⇧⌘O`），创建并进入普通目录，例如 `/迁移测试`。
3. 在会话列表空白处右键，选择“导入会话到当前目录…”。
4. 来源选择 **“OShell 会话导出（JSON）”**，点击“选择文件或目录…”，选择 `converted.oshell.json`。转换后的文件不要再选原客户端来源。
5. OShell 会先读取并校验整份文件，再显示会话数量和目标目录。原生 JSON 入口没有第三方导入的逐条映射预览，应提前检查转换报告及生成文件。确认“导入 N 项加密密码”的数量与报告一致，并保持勾选。
6. 选择导入后的密码保护方式。需要用主密码保护时选择“使用主密码加密”；若 OShell 已设置主密码，使用现有主密码。也可选择本机加密保存（界面允许时）。
7. 点击“导入”，在“输入导出文件密码或原主密码”中输入**转换脚本加密时的文件主密码**。之后如选择主密码保护，再按提示输入或设置 **OShell 的主密码**；两者可以不同。
8. OShell 会解密原记录，为新会话 ID 重新加密后保存。导入完成后核对会话属性，补充未迁移的密码、私钥路径及代理、跳板机、隧道等设置，再手动连接。

例如目标为 `/迁移测试`，文件中的 `group` 为 `原客户端/生产/华东`，最终目录是 `/迁移测试/原客户端/生产/华东`。JSON 导入不会自动加客户端来源目录，因此来源前缀应由脚本写入。

任一密码解密或校验失败会终止本次导入，不保存本批会话；不要通过取消勾选密码来掩盖密文错误。主动取消勾选“导入 N 项加密密码”则只导入配置。

导入会保留已有会话，同名条目另存为副本，且不会自动连接。不要通过反复导入来更新同一批会话；若需重试，可先核对并删除专门测试目录中的上一批结果。导入到 `/Links` 会使用快捷引用规则，基础迁移应选择普通目录。

首次连接仍需核对服务器主机指纹。使用 SSH 别名的会话还依赖目标 Mac 上对应的 SSH 配置；私钥路径指向的文件也必须实际存在。

## 7. 常见问题

| 问题 | 排查方式 |
| --- | --- |
| JSON 能通过语法检查，但 OShell 导入失败 | 检查十个必填会话字段、数据类型、枚举大小写、UUID、目录规范和端口范围；语法正确不代表模型合法。任一无效条目会导致整份原生文件校验失败。 |
| 提示版本或格式不支持 | 检查 `format` 是否精确为 `OShell.sessions`，`version` 是否为整数 `2`；不要输入整份应用配置。 |
| AI 生成了 `password`、`protocol` 或 `folder` | 它们不能替代 `encryptedPassword`、`kind` 或 `group`。未知字段可能被忽略，不能据此判断已迁移成功。 |
| 目录多了一层或重复前缀 | 最终路径由导入目标目录与文件中的 `group` 拼接。不要两处都写完整迁移路径。 |
| 导入成功但无法连接 | 对照源客户端检查用户名、非默认端口、私钥、代理、跳板机和隧道；再核对 SSH 别名依赖。 |
| 提示主密码不正确或连接信息被修改 | 确认输入的是转换时的文件主密码；检查 UUID 大写形式、AAD 字段顺序、NUL 分隔符、identity 和 `nonce + 密文 + tag` 布局。改过绑定字段时须重新加密。 |
| 密码导入成功但连接时提示目标改变 | 对比实际 SSH 解析后的主机、用户、端口与 `encryptedPassword.identity`；补全目标身份后重新保存密码。 |
| 同一会话越来越多 | 导入是新增副本，不是同步或更新；固定 UUID 也不会让再次导入覆盖旧条目。 |
| 中文乱码 | 返回原始文件确认编码，不要对已经乱码的文本再次转码；由脚本明确解码后输出 UTF-8。 |

## 格式依据

本文依据当前仓库实现整理。面向不同 OShell 版本开发脚本时，优先核对该版本的实际导出和对应源码：

- [SessionArchive.swift](../Sources/OShellCore/SessionArchive.swift)：文件标识、版本、容量限制、校验和合并行为。
- [Models.swift](../Sources/OShellCore/Models.swift)：会话必填字段、默认值和协议校验。
- [ConnectionOptions.swift](../Sources/OShellCore/ConnectionOptions.swift)：目录规范、代理、隧道和保活对象。
- [OperatorModels.swift](../Sources/OShellCore/OperatorModels.swift)：FTP 与远端路径校验。
- [SessionCipher.swift](../Sources/OShellCore/SessionCipher.swift)：密码封装、密钥派生、AAD 绑定和加解密。
- [CredentialManagement.swift](../Sources/OShellCore/CredentialManagement.swift)：主密码要求。
- [SessionTransfer.swift](../Sources/OShell/SessionTransfer.swift)：导入入口及确认流程。
