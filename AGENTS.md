# Qiming 项目约定

## 构建副本管理（用户明确要求）

- 仅保留日常使用版 `/Applications/Qiming.app` 和 Xcode 默认 DerivedData 中的一个 `Qiming Dev.app`。每次构建、测试和更新后都清理旧构建副本，不累积同名应用。
- Debug 使用 `./Scripts/build.sh Debug` 或 Xcode 的 Qiming / My Mac，两者共用默认 DerivedData。不要额外指定其他开发版输出目录。
- Release 使用 `./Scripts/build.sh Release`：先在 `.noindex` 临时目录构建并校验，再替换 `/Applications/Qiming.app`，最后清除临时 `.app`。有运行中的正式版时先正常退出并确认会话已清理；不要强制覆盖运行中的应用。
- 每次代码更新完成后运行 Release 流程，从本机安装的同一份正式版刷新 `dist/Latest` 中的 DMG 和 ZIP，并报告安装包大小。
- 正式版更新脚本会启动新版并等待无错误的 XPC 状态回执。已批准的辅助组件在签名不匹配时会自动尝试重新注册；如 macOS 要求批准，使用保护页的“配置…”处理，再确认“组件已连接，通信正常”。
- 测试使用 `./Scripts/test.sh`，产物放入 `.noindex` 目录，结束后自动清除测试应用。不要直接执行会留下额外应用副本的旧构建命令。
- 如必须临时指定其他构建路径，结束后运行 `python3 Scripts/manage_build_apps.py cleanup` 并核对只剩上述两份。不得删除源码、图标设计资源或未测功能清单。
