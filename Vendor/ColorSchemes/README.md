# 配色来源与适配

- NetSarang 官方 Xshell-ColorScheme（MIT）：https://github.com/netsarang/Xshell-ColorScheme 。本目录保留参考 .xcs 原文件及 LICENSE，2026-10-07 获取。
- Dracula · Xshell：使用 AlphaLiu/Dracula.xcs 的背景、前景和 ANSI 色值；这是 Xshell 库中的变体，不等同于 Dracula Classic 的 #282A36 背景。
- Tango：参考 Xshell 库的 Tango 色值，统一 ANSI 标准/明亮顺序，并将浅色方案的前景修正为 #2E3436（参考文件原为白底白字）。
- Solarized：使用 Ethan Schoonover 公开的原始 16 色值及深浅背景/前景组合：https://ethanschoonover.com/solarized/ 。参考 Xshell 文件的变体保留作格式样本，不直接作为原版 Solarized 预设。
- Nord：使用公开的 Nord 色板，按 ANSI 角色映射：https://www.nordtheme.com/docs/colors-and-palettes/ 。
- OShell 深浅：保留此前终端默认背景/前景与 SwiftTerm terminalAppColors ANSI 色板。
- 石墨·焰橙：OShell 自有配色，延续已选品牌图标的深石墨底色与焰橙光标。

用户自定义方案不会修改内置预设。所有配色是终端调色板；应用程序发送的 24-bit 真彩色及独立突出显示集不被重映射。
