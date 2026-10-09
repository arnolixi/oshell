# 构建与发布

## GitHub Actions 自动发布

流水线位于 [release.yml](../.github/workflows/release.yml)。将配置和源码提交到 GitHub 后，推送 `vX.Y.Z` 标签会自动构建并发布；也可在 Actions 手动运行，按所选分支的版本自动创建标签。

| 构建目标 | 最低系统 | 架构 | DMG 文件后缀 |
| --- | --- | --- | --- |
| `legacy` | macOS 10.13 | Intel x86_64 | `macOS10.13-Intel` |
| `compat` | macOS 11 | Universal：arm64 + x86_64 | `macOS11-Universal` |
| `arm64` | macOS 13 | Apple Silicon arm64 | `macOS13-arm64` |
| `intel` | macOS 13 | Intel x86_64 | `macOS13-x86_64` |

现代版本以 macOS 13 为最低运行目标，可以用于更新系统；并非限制只能在 macOS 13 使用。四种包共用源码，最低系统和名称统一定义在 `scripts/release_targets.py`。macOS 11 的目标同时设置在项目和 SwiftTerm 的编译配置中，并非只改 Info.plist。

仅需编译时，在 **Run workflow** 中关闭 **publish**。流程不创建版本标签、不发布 Release，也不读取签名私钥；四种 DMG 保存在本次运行的 `dmg-*` Artifacts，可分别下载。

发布步骤：

1. 更新 `scripts/Info.plist` 的 `CFBundleShortVersionString`，递增 `CFBundleVersion`，提交所有源码和流水线文件。
2. 将提交推送到 GitHub。手动发布时进入 **Actions → Build and publish macOS DMGs → Run workflow**，选择要发布的分支（通常为 `main`），**tag 留空**。流程读取该提交的 Info.plist，例如版本 `0.2.61` 会创建 `v0.2.61`；也可明确填写匹配版本。已有同名标签必须指向所选提交，流程不会移动或覆盖它。若需重试旧版本，请选择原标签作为运行来源。标签与源码版本不匹配时，会在创建标签和编译前报错。也可以自行创建并推送匹配的 `vX.Y.Z` 标签来触发发布。
3. 标签确定后，Actions 会运行四个独立构建任务。四个任务全部完成核心测试、DMG 挂载检查、全部 Mach-O 的架构/最低系统检查和签名完整性检查后，才进入发布阶段。
4. Release 先以草稿创建，上传四个 DMG 和对应源码包，并在 Release 说明中嵌入四种目标的签名更新信息。`SHA256SUMS.txt` 和 `release-manifest.json` 放在每个 DMG 内，不再单独上传为 Release 附件。确认远端附件完整后才公开发布并设为 Latest。

GitHub API 只使用自动提供的 `GITHUB_TOKEN`，无需额外 PAT。发布前还需在仓库 **Settings → Secrets and variables → Actions** 配置 `OSHELL_UPDATE_SIGNING_KEY`，内容为现有 Sparkle Ed25519 私钥文件中的 Base64 种子。该密钥必须与应用的 `SUPublicEDKey` 匹配，不能重新生成替代。密钥仅在签名步骤写入临时 0600 文件，完成后清理；不写入源码、日志或发布附件。缺少密钥时停止发布，避免生成会导致检查更新失败的不完整 Release。仓库需允许 Actions 运行；构建阶段仅有 `contents: read`，准备标签和发布 job 申请 `contents: write`。如果组织策略禁止写权限，需要仓库管理员允许该工作流发布 Release。工作流不读取开发者本机 `.release-private`，由维护者配置加密 Secret，也不设置默认更新仓库。

准备阶段创建的标签在后续构建失败时会保留，以便重试相同源码；若要改动源码，应使用新版本，不能将原标签移动到新提交。旧失败记录的 **Re-run jobs** 仍使用当时的工作流；升级流程后应从 `main` 新建一次 **Run workflow**。

失败不会发布残缺 Release；日志保留为各构建任务的 `diagnostics-*` Artifact。同一 tag 的运行会串行排队。上传中断后可以重跑：只续传带有同一提交标记的自有草稿；已公开的 Release 和其他草稿不会被覆盖。发布成功后应递增版本并使用新标签，而不是覆盖旧附件。

构建机使用 GitHub 托管的 `macos-15`（arm64）与 `macos-15-intel`，固定选择 Xcode 16.4，避免 `macos-latest` 标签更换架构或默认工具链变动影响旧系统构建。第三方 Actions 已固定到官方版本提交。若 GitHub 将来移除该 Xcode，需要更新固定工具链并重新验证旧目标；构建机版本不等于安装包的最低运行版本。

当前沿用 ad-hoc 签名，**没有 Developer ID 签名和 Apple 公证**，Release 说明会明确标注。部署目标校验不等于真实 macOS 10.13/11 的运行验收。流水线发布的 DMG 同时用于手动安装和内置更新；也可按下方步骤在本机签名。不会自动创建或更换发布密钥。

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

从 0.2.61 起，客户端通过 GitHub 的 `repos/<owner>/<repo>/releases/latest` API 读取最新正式 Release，按照系统和架构选择 DMG。Release 只需发布四个 DMG 和对应源码包，不再生成独立 XML 或 `*-update.zip` 附件。自动检查默认关闭。

签名更新信息由流水线嵌入 Release 说明中的 `oshell-update-v1` 隐藏注释。不要删除或编辑这些注释；修改普通版本说明时应完整保留。下载地址、文件大小、版本和最低系统都包含在签名信息中。客户端还核对其是否匹配本仓库实际上传的附件。

Sparkle 2.9.6 继续负责签名验证、下载、安装和重新启动，以保留 macOS 10.13 支持。应用只在本机回环地址提供一个随机路径的临时适配通道，将 Release 中原样保留的签名数据交给 Sparkle；没有公开更新服务或额外服务器。`SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction` 和原有公钥保持启用，签名失败不会降级。

架构选择：Apple Silicon 的 macOS 13+ 使用 arm64 包，macOS 11/12 使用 Universal 包；Intel 的 macOS 13+ 使用 x86_64 包，更早系统使用 macOS 10.13 Intel 包。不会下载全部安装包。

**不兼容旧客户端的更新方式。** 从旧版升级需手动安装 0.2.61 或更新版本一次，此后使用程序内检查更新。历史 Release 不会被重写；新发布流程不生成旧客户端的过渡附件。

发布依赖：

```sh
python3 -m venv work/release-tools
work/release-tools/bin/pip install -r scripts/requirements-release.txt
```

本机签名私钥位于 `.release-private/sparkle-ed25519.key`，必须保持 0600 权限并独立备份，不能进入源码、日志或 Release。GitHub Actions 使用同一密钥的加密 Secret `OSHELL_UPDATE_SIGNING_KEY`。不要重新生成密钥替代现有公钥对应的密钥。

本机生成发布签名元数据的示例（替换仓库与版本）：

```sh
python3 scripts/package-release.py --flavor all --format dmg
python3 scripts/verify-installers.py --format dmg
work/release-tools/bin/python scripts/publish-updates.py --repository owner/repository --tag v0.2.61
```

签名脚本验证 DMG 与安装校验报告一致，然后仅生成内部 JSON 元数据；不创建额外应用包，不上传附件。CI 收集这些数据写入 Release 说明，并验证远端说明及全部附件完整后才公开发布。

建立独立的新发行线或 fork 时，应配置自己的更新公钥与签名密钥；这不能作为替换现有用户信任密钥的办法。签名更新不等于 Apple Developer ID 签名或 Apple 公证。

## 对应源代码与许可

分发二进制时，同时提供与该二进制对应的源代码、构建脚本、第三方许可和来源。使用不可变的 release tag，并让源码下载与二进制同样容易获得。

```sh
python3 scripts/check-public-source.py --index
python3 scripts/check-public-source.py --history main
python3 scripts/export-public-source.py --ref HEAD --output dist/source/OShell-source.tar.gz
```

源码包只导出审核过的 Git 提交，不包含工作目录、私钥或构建缓存。`Vendor/` 包含 SwiftTerm 与 CryptoSwift 源码，以及 lrzsz 和 Sparkle 的上游源码归档。第三方调整记录见 `THIRD_PARTY_NOTICES.txt`。应用内“开源许可…”可查看 GPL-3.0 与第三方声明。

参考：[GPL-3.0 原文](../LICENSE)、[Sparkle 文档](https://sparkle-project.org/documentation/)、[GitHub Release 下载链接](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)。


## 包内构建信息与校验

打开 DMG 后，`OShell.app` 旁边提供 `release-manifest.json` 和 `SHA256SUMS.txt`。前者记录该包的版本、构建号、系统目标、架构、源码提交和签名状态；后者校验包内应用、安装说明及清单文件。它不校验自身或外层 DMG，避免循环依赖。可在挂载卷根目录运行 `shasum -a 256 -c SHA256SUMS.txt`。

流水线仍计算外层 DMG、源码包的校验值用于发布前验证，但这些流程内部文件不展示为 Release 附件。更新客户端从 Release 说明读取签名信息并使用 DMG；包内清单不替代更新签名或 Apple 公证。

## 静态更新站点（GitHub Pages）

客户端读取 `https://<owner>.github.io/<repository>/updates/latest.json`，不调用 GitHub Releases REST API，不需要用户 Token。用户站点仓库 `<owner>.github.io` 使用根目录下的 `/updates/latest.json`。仓库地址仍在 OShell 更新设置中填写，应用自动推导标准 Pages 地址；当前不支持重定向到自定义 Pages 域名。

管理员首次在仓库 Settings → Pages 将发布来源设为 GitHub Actions。`.github/workflows/update-pages.yml` 可以手动执行，用最新已公开的正式 Release 初始化或修复更新站点，无需重建安装包或重新签名。正式发布流水线在 Release 上传校验并公开成功后调用它；只编译模式不部署 Pages。

部署任务使用 Actions 的短期 `GITHUB_TOKEN` 读取最新 Release，验证四份更新元数据的 Ed25519 签名、版本一致性、DMG 名称和大小，然后生成站点。它不读取发布私钥，也不向 Pages 上传源码、配置或安装包。权限为 `contents: read`、`pages: write`、`id-token: write`；站点环境为 `github-pages`。部署串行执行，每次读取最新正式版本，避免旧构建任务拿自己的旧版本覆盖更新源。仓库如限制部署分支，需要允许主分支及发布标签。

Pages 只有首页和 `updates/latest.json` 等静态文件。JSON 按四种平台包装原有签名数据，不改变签名覆盖的字节；客户端仍由 Sparkle 验证更新信息与 DMG。Releases 保留原有签名注释供 0.2.61–0.2.63 客户端升级一次使用，不增加 XML、update ZIP 或额外 JSON 附件。

客户端缓存成功检查结果五分钟；请求失败至少等待一分钟，服务端提供 Retry-After 时遵循其等待时间。过期缓存不会伪装成新的成功检查。Pages 暂不可用时明确报错，不回退到匿名 API。仍使用旧通道的客户端需要升级一次；被 API 限流时可等额度恢复或手动安装新版。

如果 Release 已发布但 Pages 部署失败，旧站点不被替换。修复原因后单独重跑“Publish static update site”，不要覆盖已有正式 Release。默认 GitHub Pages 的域名与地域可达性仍受网络条件影响，此方案解决 REST API 匿名额度问题，不保证所有网络均能访问。
