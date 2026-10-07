# OShell Shell 集成

脚本需要 OShell 0.2.30 或更新版本；0.2.31 起默认启用“集成优先、无脚本被动降级”，无需额外切换。适用于 Bash 和 Zsh，使用提示符钩子主动发送专用 OSC 777 `OShellHost=1;` 元数据，不向交互终端输入探测命令，也不修改或清除历史记录。

## 配置

1. 重新打开 OShell 0.2.31 或更新版本。默认不会输入标题探测命令：有脚本就接收上报，无脚本则读取提示符、OSC 0/2 标题及 OSC 7 目录信息。无需配置脚本也可使用被动识别，无法确认的 IP 显示待识别。
2. 在服务器上，以实际登录用户建立目录：

   ```sh
   mkdir -p "$HOME/.config/oshell"
   ```

3. 使用 SFTP 把本目录的 `oshell-integration.sh` 上传到该用户的 `~/.config/oshell/oshell-integration.sh`。开发应用也在 `OShell.app/Contents/Resources/oshell-integration.sh` 附带相同脚本。文件只需可读，无须执行权限，无须 root。
4. 用编辑器在 Bash 的 `~/.bashrc` **末尾**添加一行；Zsh 用户添加到 `~/.zshrc` 末尾（自定义 `ZDOTDIR` 时使用其下的 `.zshrc`）：

   ```sh
   [ -r "$HOME/.config/oshell/oshell-integration.sh" ] && . "$HOME/.config/oshell/oshell-integration.sh"
   ```

5. 重新连接。若要立即在当前会话启用，可手动执行上面一行一次。这一条安装命令可能留在历史中，但之后的自动上报不会成为交互历史命令。

Bash 的 SSH 登录环境通常通过 `~/.bash_profile` 加载 `~/.bashrc`。若不生效，检查已有 `.bash_profile` / `.bash_login` / `.profile` 的加载链，确认实际使用的登录配置会读取 `.bashrc`。不要覆盖现有文件；若缺少加载逻辑，可在对应文件加入：

```sh
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
```

## 行为

- 脚本在显示提示符时发送主机名和 IP。优先使用当前 `SSH_CONNECTION` 的服务器端 IP；缺少它时读取本机接口地址，OShell 排除回环/链路本地地址。网络信息缓存最多 30 秒，`SSH_CONNECTION` 变化时立即刷新，减少外部进程调用。
- 每台嵌套登录的服务器、每个使用的账户都需加载脚本。返回上一层时，该层下一次提示符会重新上报自身信息。
- Bash 保留已有字符串/数组形式的 `PROMPT_COMMAND` 及其收到的退出状态；Zsh 通过 `add-zsh-hook` 注册 `precmd`，不替换现有函数。重复加载不重复安装钩子；只读 `PROMPT_COMMAND` 不会被强行覆盖。
- 不更改 `PS1`、`HISTCONTROL`、`HISTIGNORE` 或历史文件，也不删除之前已经记录的探测命令。普通用户命令仍正常记录。
- 新会话与升级后的旧会话默认采用被动降级，包括旧配置里未启用仅集成模式的会话。会话属性中只有明确勾选“允许主动探测主机名/IP（可能写入命令历史）”才启用旧探测方式；收到集成上报后，该连接也停止主动探测。默认模式下“视图 → 刷新标题识别”仅重新解析当前提示符。
- 元数据仅用于标题显示，不用于 SSH 身份认证、连接目标选择或文件传输地址。
- 已验证直接 SSH 与嵌套 SSH。tmux/screen 等终端复用器可能过滤自定义 OSC，需另行验证其透传；脚本不自动修改复用器配置。Bash 数组钩子在支持该能力的新版 Bash 上启用，CentOS 6 使用字符串钩子即可。

## 停用

删除启动文件里的加载行，重新登录即可。当前 Shell 可设置 `OSHELL_INTEGRATION=0` 停止上报；要完全恢复加载前的钩子状态，重新登录。停用脚本后默认回到被动识别；主动探测需要在会话属性中明确启用。

机制参考：[Bash 提示符处理](https://www.gnu.org/software/bash/manual/html_node/Interactive-Shell-Behavior)、[Zsh 提示符钩子](https://zsh.sourceforge.io/Doc/Release/User-Contributions.html)。
