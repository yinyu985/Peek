# 开发说明

先阅读 [产品规格](../SPEC.md)。需要 macOS 13+ 和 Xcode Command Line Tools。

## 构建

在项目根目录运行：

```sh
./app/build.sh                  # 分别生成 ARM64、Intel 应用和 DMG
./app/Resources/build-icons.sh  # 从原始 PNG 生成 AppIcon.icns
```

产物位于 `app/.build/`：

- `arm64/Peek.app`、`x86_64/Peek.app`：两个单架构应用，最低 macOS 13。
- `Peek-版本号-arm64.dmg`、`Peek-版本号-x86_64.dmg`：各自包含 Peek 和指向 `/Applications` 的拖拽安装入口。
- 每个 DMG 对应一个 `.dmg.sha256` 下载校验文件。

编译、双架构签名检查和 DMG 完整性检查成功后才替换产物。更新前先退出旧版本，让受管理的窗口完成恢复，再通过 Finder 拖入并替换。没有安装或启动脚本。

图标生成器自动清理中间文件。构建使用 ad-hoc 签名，没有 Apple 公证。

修改 `build.sh` 顶部的 `version` 和 `build_number`，分别写入 `CFBundleShortVersionString`（用户可见版本）和 `CFBundleVersion`（内部构建编号）。`AppIcon.icns` 是随源码保留的运行资源，不是待删除缓存。

## 发布到 GitHub

项目仓库为 https://github.com/yinyu985/Peek 。在 `main` 分支提交并推送发布准备工作：

```sh
git add .
git commit -m "Prepare release"
git push -u origin main
```

检查本地 DMG 后，推送与 `version` 一致的标签：

```sh
git tag -a v1.3.3 -m "Peek 1.3.3"
git push origin v1.3.3
```

`.github/workflows/release.yml` 随标签推送触发，在 macOS runner 上分别构建 ARM64 和 Intel DMG。版本不匹配会终止构建。通过仓库自带的 `GITHUB_TOKEN` 发布，不需要个人 token 或 Apple 开发者证书；这不等于 Apple 签名认证或公证。

在 Actions 中查看进度。两个 DMG 及各自的校验文件全部上传成功后，草稿 Release 自动公开。上传失败时保留草稿，修复后可以重跑；已公开的版本不会被覆盖，应修改版本号、递增构建编号，再提交并推送新标签。

用户只需按芯片选择 Releases 中的一个 DMG；GitHub 自动提供的 Source code 是源码，不是安装包。README 的“下载最新版”指向 `/releases/latest`。

## 源码职责

| 文件 | 职责 |
| --- | --- |
| `main.swift` | 生命周期、组件连接、菜单栏、日志 |
| `MainWindow.swift` | 设置界面、绑定管理、快捷键录制 |
| `AppBinding.swift` | 配置、迁移、方向几何 |
| `GlobalShortcutManager.swift` | Carbon 全局快捷键注册及松键状态校正 |
| `HoverController.swift` | 停留／离开计时、拖拽暂停和几何同步 |
| `WindowController.swift` | AX 窗口控制、焦点、动画和恢复 |
| `PeekMark.swift` | PNG 标志加载及缺资源时的绘图后备 |

## 本地数据

- 设置：`~/Library/Preferences/dev.local.Peek.plist`
- 恢复记录：`~/Library/Application Support/Peek/window-recovery.json`
- 日志：`~/Library/Logs/Peek/app-launch.jsonl`

清理构建产物时不要删除这些数据。构建产物、临时检查程序及个人研究资料不进入 Git；`docs/images/` 中用于 README 的产品图片应提交。

## 提交前检查

- 干净构建、签名和安装后的版本正确。
- 分页、内容滚动、四项时间参数及配置保存正常。
- 在独立窗口中检查快捷键、Hover、调整尺寸后的收放、拖拽让出控制和退出恢复。
- 不自动更改用户的开机自启注册；不反复操作用户正在使用的窗口。
- 区分程序化 action、注入事件与物理键鼠验证；未验证的兼容性明确说明。

按项目约定，不保留测试套件或运行时测试入口。临时验证产物使用后清理；产品图片与临时测试截图分开。
