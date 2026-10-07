# 开发与测试

## 构建

需要现代 macOS、Swift 6 工具链、Xcode Command Line Tools、Python 3，以及系统提供的构建/打包工具。旧系统是运行目标，不是推荐的构建环境。

```sh
bash scripts/build.sh
```

输出为 `dist/OShell.app`，缓存位于 `work/build/`。依赖固定在 `Vendor/`；不要直接用上游最新版本替换本地修改过的终端组件。构建脚本将源码路径映射到统一前缀，避免把构建者的主目录写入二进制。

核心检查：

```sh
binary_dir="$(swift build --scratch-path work/build/swift -c release --show-bin-path)"
"$binary_dir/OShellCoreChecks"
```

## 集成检查

```sh
python3 -m venv work/test-tools
work/test-tools/bin/pip install -r scripts/requirements-test.txt
work/test-tools/bin/python scripts/run-tab-actions-tests.py
work/test-tools/bin/python scripts/run-ssh-clone-tests.py
work/test-tools/bin/python scripts/run-update-integration-tests.py
```

这些脚本使用临时数据、一次性账号和本机服务。测试输出写入 `validation/`，不应提交。运行 UI 检查需要可用的 macOS 图形会话；旧版 Intel 运行检查还需要对应硬件或 Rosetta。不要把开发测试指向真实服务器，也不要去掉临时数据目录设置后运行测试入口。

## 项目结构

- `Sources/OShell/`：原生界面、终端会话、文件管理和应用更新。
- `Sources/OShellCore/`：配置、密码保护、协议参数、目录和输入模型。
- `Sources/OShell*/`：认证、代理和外部启动辅助程序。
- `Tests/`：核心行为检查。
- `scripts/`：构建、测试、打包和发布工具。
- `shell-integration/`：可选的远端 Shell 集成。
- `Vendor/`：第三方依赖、许可证和对应来源。

## 发布前检查

```sh
python3 scripts/check-public-source.py --working-tree
python3 scripts/check-public-source.py --index
python3 scripts/check-public-source.py --history main
python3 scripts/check-public-source.py --app dist/OShell.app
```

默认规则拒绝构建缓存、私钥、会话文件、本地报告、个人主目录和明显令牌。第三方原有版权署名不会被自动改写。规则检查不能替代人工检查：截图、压缩附件和示例数据也需要逐项确认。

提交前应检查 `git diff --cached`。测试数据使用保留示例域名和地址，不能直接粘贴真实终端记录。变更说明放在 `CHANGELOG.md`；完整调试时间线和机器测试记录留在忽略的本地目录中。
