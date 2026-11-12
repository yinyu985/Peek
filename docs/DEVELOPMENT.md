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
git tag -a v1.4.8 -m "Peek 1.4.8"
git push origin v1.4.8
```

`.github/workflows/release.yml` 随标签推送触发，在 macOS runner 上分别构建 ARM64 和 Intel DMG。版本不匹配会终止构建。通过仓库自带的 `GITHUB_TOKEN` 发布，不需要个人 token 或 Apple 开发者证书；这不等于 Apple 签名认证或公证。

在 Actions 中查看进度。两个 DMG 及各自的校验文件全部上传成功后，草稿 Release 自动公开。上传失败时保留草稿，修复后可以重跑；已公开的版本不会被覆盖，应修改版本号、递增构建编号，再提交并推送新标签。

用户只需按芯片选择 Releases 中的一个 DMG；GitHub 自动提供的 Source code 是源码，不是安装包。README 的“下载最新版”指向 `/releases/latest`。

## 源码职责

| 文件 | 职责 |
| --- | --- |
| `main.swift` | 生命周期、组件连接、菜单栏、日志 |
| `MainWindow.swift` | 设置界面、绑定管理、快捷键录制 |
| `Localization.swift` | 界面语言持久化、资源读取与已显示消息的语言刷新 |
| `AppBinding.swift` | 配置、迁移、方向几何 |
| `GlobalShortcutManager.swift` | Carbon 全局快捷键注册及松键状态校正 |
| `HoverController.swift` | 分段边缘触发、单次停留仲裁、停留／离开计时、拖拽暂停和几何同步 |
| `WindowController.swift` | AX 窗口身份、停放／应用隐藏／最小化、焦点和恢复（兼容旧压缩记录） |
| `ShadeBar.swift` | 顶部独立标题条、点击恢复与面板生命周期 |
| `WindowSpaces.swift` | 只读 SkyLight 桌面归属查询，未知时不允许跳转 |
| `PeekMark.swift` | PNG 标志加载及缺资源时的绘图后备 |

## 本地数据

- 设置：`~/Library/Preferences/dev.local.Peek.plist`
- 恢复记录：`~/Library/Application Support/Peek/window-recovery.json`
- 日志：`~/Library/Logs/Peek/app-launch.jsonl`

清理构建产物时不要删除这些数据。构建产物、临时检查程序及个人研究资料不进入 Git；`docs/images/` 中用于 README 的产品图片应提交。

## 提交前检查

- 干净构建、签名和安装后的版本正确。
- 分页、内容滚动、露出宽度、四项时间参数及配置保存正常。
- 同侧上下分区和重叠窗口每次停留只展开一个；焦点切换和周期刷新不重复触发。左、右、底部露出宽度保持正确，改变设置不立即移动隐藏窗口。
- 在独立窗口中检查快捷键、Hover、调整尺寸后的收放、拖拽让出控制和退出恢复。删除绑定不受恢复失败阻塞；退出允许保存未完成记录，启动仍能恢复同一窗口。验证 AX 不可读但 WindowServer 原始 frame 已恢复时的只读完成，以及错误窗口 ID 不清记录。
- 顶部实验默认关闭；当前只最小化；旧 `shade`／`compression` 方式读取为 `minimize`，保留标题条代码和恢复能力。旧 `topMinimizeEnabled` 迁移保留启用状态与最小化方式，其余延迟、时长、露出宽度不变。桌面切换新配置默认开启，显式保存的旧值保持不变。
- 验证顶部最小化的 Hover、快捷键、关闭开关后的召回、隐藏期间换策略、退出／重启恢复、目标关闭后不换绑。压缩保存 original 与 compressedFrame，不能用压缩高度覆盖原高度；移动压缩条保留原尺寸，用户调整尺寸则让出控制。
- 不修改 AXEnhancedUserInterface 等辅助功能设置。停放同时检查 AX 与 WindowServer。应用隐藏可能使 WindowServer 不再枚举目标窗口，因此在隐藏前保存 Space 归属，恢复时校验进程启动时间，再解除自己发起的隐藏，重新取得相同窗口 ID。未知或仍在过渡的状态不能记作成功。
- 恢复需校验 PID、启动时间、窗口 ID；最小化的短暂 AX 不可读只做有界重读，不换元素、不把 unknown 记作隐藏。旧记录缺少 ID 时保留并提示，不按标题猜测。
- 桌面开关关闭时不得激活其他 Space 的目标；开启时仅经目标窗口激活请求系统切换，等待 Space 变更通知与窗口可见性后再收放。自动隐藏、退出恢复不主动跨桌面聚焦；未知归属安全停止。不使用 Dock 注入、不改 SIP、不搬窗口到其他 Space。
- `WindowSpaces` 动态加载三个只读 SkyLight 符号；符号或数据缺失返回 unknown，不能把 Mission Control 中的可见缩略图当作当前桌面归属。测试当前／其他／未知和所有桌面集合，以及单屏两个真实普通 Space 的往返；区分普通 Space、全屏、多屏和 Stage Manager 的验收边界。
- 不自动更改用户的开机自启注册；不反复操作用户正在使用的窗口。
- 区分程序化 action、注入事件与物理键鼠验证；未验证的兼容性明确说明。

- 保留的标题条策略仅用于旧记录恢复，重新启用前需验收：独立窗口最小高度 600pt，停放和恢复不改变尺寸；停放被拒绝时，单窗口隐藏成功，多窗口不隐藏整个应用；外部唤回后移除标题条。验证悬停延迟、点击、关闭自动收放、删除绑定、退出与重启恢复。
- 关闭顶部后方向选项仅底、左、右；旧顶部绑定显示停用，新绑定默认右侧。检查开关说明、可点击操作状态、固定 44pt 行高和等宽下拉面板。底部验证 0、8、40、100pt 设置及系统夹紧后的实际露出高度和 Hover 区域。
- 中英文资源位于 `app/Resources/{zh-Hans,en}.lproj/`。验证文本键与占位符一致、两种语言下的四个页面与错误说明、语言菜单等宽、即时切换和重启后的语言持久化；测试使用独立 UserDefaults，不改变用户配置。

按项目约定，不保留测试套件或运行时测试入口。临时验证产物使用后清理；产品图片与临时测试截图分开。
