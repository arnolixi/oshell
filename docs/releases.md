# 构建与发布

## 安装包

先在 `scripts/Info.plist` 更新版本号，并递增 build 编号。按目标生成 PKG 和 DMG：

```sh
python3 scripts/package-release.py --flavor arm64
python3 scripts/package-release.py --flavor legacy
python3 scripts/verify-installers.py --flavor arm64 --flavor legacy
```

现代 Universal 构建使用 `--flavor modern`。产物位于 `dist/installers/`；`--apps-only` 只组装应用。安装包校验会只读展开或挂载载荷，不执行安装。

默认使用本地 ad-hoc 签名，不代表 Developer ID 签名或 Apple 公证。公开二进制发布说明必须准确注明签名、公证和系统验证状态。向旧系统发布前，除编译与转译检查外，还应安排真实目标系统验收。

## GitHub Releases 更新

更新引擎固定为 Sparkle 2.9.6，以保留 macOS 10.13 支持。清单通过 GitHub 的 `releases/latest/download/<文件名>` 读取。更新源需要公开仓库和可下载的正式 Release；自动检查默认关闭。

两种架构必须同时附上对应 XML：

- `OShell-macOS13-arm64.xml`
- `OShell-macOS10.13-Intel.xml`

发布依赖：

```sh
python3 -m venv work/release-tools
work/release-tools/bin/pip install -r scripts/requirements-release.txt
```

签名私钥不在源码仓库中。维护者应在独立安全备份中保管 `.release-private/sparkle-ed25519.key`，保持 600 权限，不上传到 GitHub 或 Release。已有发行线不可随意替换公钥；恢复构建机器时应恢复对应私钥。

建立**独立的新发行线或 fork**时，需在自己的源码副本中移除 `scripts/Info.plist` 原有 `SUPublicEDKey` 字段，再生成自己的密钥：

```sh
work/release-tools/bin/python scripts/update-signing-key.py --initialize
```

这一操作只适用于新的信任链，不能用来绕过现有已安装应用的签名验证。源码可以在没有发布私钥的情况下编译；自行修改的应用也可以手动安装和运行。

以下示例的仓库和 tag 需要替换为实际发布目标：

```sh
python3 scripts/package-release.py --flavor arm64 --repository owner/repository
python3 scripts/package-release.py --flavor legacy --repository owner/repository
work/release-tools/bin/python scripts/publish-updates.py --repository owner/repository --tag v0.2.43
```

签名更新 ZIP、XML、校验值及附件清单生成到 `dist/updates/<版本>/`。脚本不上传文件，也不创建 Release。只需更新档案时，可为前两条命令加 `--apps-only`。

先创建 Release 草稿，上传两套更新 ZIP 和 XML，再发布为 Latest。更新 ZIP 是应用载荷，不能用 GitHub 自动生成的源码 ZIP 替代。签名文件修改后必须重新签名。此前没有内置更新功能的版本需要手动升级一次。

## 对应源代码与许可

分发二进制时，同时提供与该二进制对应的源代码、构建脚本、第三方许可和来源。使用不可变的 release tag，并让源码下载与二进制同样容易获得。

```sh
python3 scripts/check-public-source.py --index
python3 scripts/check-public-source.py --history main
python3 scripts/export-public-source.py --ref HEAD --output dist/source/OShell-source.tar.gz
```

源码包只导出审核过的 Git 提交，不包含工作目录、私钥或构建缓存。`Vendor/` 包含 SwiftTerm 与 CryptoSwift 源码，以及 lrzsz 和 Sparkle 的上游源码归档。第三方调整记录见 `THIRD_PARTY_NOTICES.txt`。应用内“开源许可…”可查看 GPL-3.0 与第三方声明。

参考：[GPL-3.0 原文](../LICENSE)、[Sparkle 文档](https://sparkle-project.org/documentation/)、[GitHub Release 下载链接](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)。
