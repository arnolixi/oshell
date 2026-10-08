# 构建与发布

## GitHub Actions 自动发布

流水线位于 [release.yml](../.github/workflows/release.yml)。将配置和源码提交到 GitHub 后，推送 `vX.Y.Z` 标签会自动构建并发布；也可在 Actions 手动运行，输入已存在的同名标签。

| 构建目标 | 最低系统 | 架构 | DMG 文件后缀 |
| --- | --- | --- | --- |
| `legacy` | macOS 10.13 | Intel x86_64 | `macOS10.13-Intel` |
| `compat` | macOS 11 | Universal：arm64 + x86_64 | `macOS11-Universal` |
| `arm64` | macOS 13 | Apple Silicon arm64 | `macOS13-arm64` |
| `intel` | macOS 13 | Intel x86_64 | `macOS13-x86_64` |

现代版本以 macOS 13 为最低运行目标，可以用于更新系统；并非限制只能在 macOS 13 使用。四种包共用源码，最低系统和名称统一定义在 `scripts/release_targets.py`。macOS 11 的目标同时设置在项目和 SwiftTerm 的编译配置中，并非只改 Info.plist。

发布步骤：

1. 更新 `scripts/Info.plist` 的 `CFBundleShortVersionString`，递增 `CFBundleVersion`，提交所有源码和流水线文件。
2. 将提交推送到 GitHub，并创建匹配的稳定版本标签。例如当前源码版本为 `0.2.59`，标签应为 `v0.2.59`。标签和 Info.plist 不匹配、使用预发布标签或中途移动标签都会被拒绝。
3. 推送标签后，Actions 会运行四个独立构建任务。四个任务全部完成核心测试、DMG 挂载检查、全部 Mach-O 的架构/最低系统检查和签名完整性检查后，才进入发布阶段。
4. Release 先以草稿创建，上传四个 DMG、对应源码包、`SHA256SUMS.txt` 和 `release-manifest.json`。确认远端附件完整后才公开发布并设为 Latest。

只使用 GitHub 自动提供的 `GITHUB_TOKEN`，无需额外 PAT。仓库需允许 Actions 运行；构建阶段仅有 `contents: read`，发布 job 单独申请 `contents: write`。如果组织策略禁止写权限，需要仓库管理员允许该工作流发布 Release。工作流不读取本机 `.release-private`，也不设置默认更新仓库。

失败不会发布残缺 Release；日志保留为各构建任务的 `diagnostics-*` Artifact。同一 tag 的运行会串行排队。上传中断后可以重跑：只续传带有同一提交标记的自有草稿；已公开的 Release 和其他草稿不会被覆盖。发布成功后应递增版本并使用新标签，而不是覆盖旧附件。

构建机使用 GitHub 托管的 `macos-15`（arm64）与 `macos-15-intel`，固定选择 Xcode 16.4，避免 `macos-latest` 标签更换架构或默认工具链变动影响旧系统构建。第三方 Actions 已固定到官方版本提交。若 GitHub 将来移除该 Xcode，需要更新固定工具链并重新验证旧目标；构建机版本不等于安装包的最低运行版本。

当前沿用 ad-hoc 签名，**没有 Developer ID 签名和 Apple 公证**，Release 说明会明确标注。部署目标校验不等于真实 macOS 10.13/11 的运行验收。本流程只发布手动安装 DMG；Sparkle 签名更新 ZIP/XML 仍采用下方的独立发布步骤，不会自动读取或更换发布密钥。

参考：[GitHub 托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[macOS 15 工具链清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)、[GitHub CLI Release 命令](https://cli.github.com/manual/gh_release_create)。

## 安装包

先在 `scripts/Info.plist` 更新版本号，并递增 build 编号。按目标生成 PKG 和 DMG：

```sh
python3 scripts/package-release.py --flavor arm64
python3 scripts/package-release.py --flavor legacy
python3 scripts/verify-installers.py --flavor arm64 --flavor legacy
```

使用 `--flavor compat` 构建 macOS 11 Universal，`--flavor intel` 构建 macOS 13 x86_64；`--flavor all` 构建上述四种发行目标。原有 macOS 13 Universal 仍可通过 `--flavor modern` 单独构建。加 `--format dmg` 仅生成 DMG；`--test-core` 同时运行构建机原生架构的核心检查。产物位于 `dist/installers/`；`--apps-only` 只组装应用，随后可用 `verify-installers.py --flavor compat --app-only` 检查部署目标。仅 DMG 校验使用 `verify-installers.py --flavor compat --format dmg`。安装包校验会只读展开或挂载载荷，不执行安装。

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
