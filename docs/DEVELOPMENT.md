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

图标生成器自动清理中间文件。默认构建使用 ad-hoc 签名，没有 Apple 公证。需要公证时，在本机钥匙串配置 Developer ID Application 证书和 `notarytool store-credentials` profile，指定 `DEVELOPER_ID_APPLICATION='Developer ID Application: …' NOTARY_PROFILE='…' ./app/build.sh`。两个架构均先公证并装订 app，再签名、公证并装订 DMG，最后生成校验文件。

GitHub Actions 默认沿用 ad-hoc。启用公证需设置仓库变量 `PEEK_NOTARIZE=true`、`PEEK_SIGN_IDENTITY`、`PEEK_TEAM_ID`，以及 secrets `PEEK_CERTIFICATE_P12_BASE64`（含私钥）、`PEEK_CERTIFICATE_PASSWORD`、`PEEK_APPLE_ID`、`PEEK_APP_PASSWORD`（应用专用密码）。不要把证书或密码提交到仓库。首次公证发布前同步中英文 README 和官网的安装说明。

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
git tag -a v1.4.14 -m "Peek 1.4.14"
git push origin v1.4.14
```

`.github/workflows/release.yml` 随标签推送触发，在 macOS runner 上分别构建 ARM64 和 Intel DMG。版本不匹配会终止构建。通过仓库自带的 `GITHUB_TOKEN` 发布，不需要个人 token 或 Apple 开发者证书；这不等于 Apple 签名认证或公证。

在 Actions 中查看进度。两个 DMG 及各自的校验文件全部上传成功后，草稿 Release 自动公开。上传失败时保留草稿，修复后可以重跑；已公开的版本不会被覆盖，应修改版本号、递增构建编号，再提交并推送新标签。

用户只需按芯片选择 Releases 中的一个 DMG；GitHub 自动提供的 Source code 是源码，不是安装包。README 的“下载最新版”指向 `/releases/latest`。

## 源码职责

| 文件 | 职责 |
| --- | --- |
| `main.swift` | 生命周期、组件连接、菜单栏、日志 |
| `DockPresenceController.swift` | 设置窗口显示时加入 Dock，关闭／隐藏后切换后台；处理快速重开和窗口替换 |
| `MainWindow.swift` | 设置界面、绑定管理、快捷键录制 |
| `Localization.swift` | 界面语言持久化、资源读取与已显示消息的语言刷新 |
| `AppBinding.swift` | 配置、迁移、方向几何 |
| `GlobalShortcutManager.swift` | Carbon 全局快捷键注册及松键状态校正 |
| `HoverController.swift` | 分段边缘触发、单次停留仲裁、停留／离开计时、拖拽暂停和几何同步 |
| `ApplicationRecallMemory.swift` | 按应用保存已验证的召回方式，提供微信兼容默认值 |
| `WindowController.swift` | AX 窗口身份、边缘移动／应用隐藏／最小化、焦点和旧记录恢复 |
| `WindowSpaces.swift` | 只读 SkyLight 桌面归属查询，未知时不允许跳转 |
| `PeekMark.swift` | PNG 标志加载及缺资源时的绘图后备 |

## 本地数据

- 设置：`~/Library/Preferences/dev.local.Peek.plist`
- 恢复记录：`~/Library/Application Support/Peek/window-recovery.json`。同目录 `.json.lock` 后缀的文件用于排他锁；进程退出时释放锁，锁文件留在原位。仅数据变化时写回，拒绝覆盖外部改写。
- 应用状态：设置中的 `RecallAnchors.v1`，保存屏幕、展开布局和最近确认的 `hidden` 状态，不作为旧窗口恢复身份。兼容仅有几何的旧数据。目标应用退出后仍可从此入口发起启动请求；新窗口发现期间不得用临时可见状态或离线入口覆盖保存的隐藏状态。
- 日志：`~/Library/Logs/Peek/peek-YYYY-MM-DD.jsonl`（UTC）。写入新日期时清理，只保留今天及之前 6 天；旧 `app-launch.jsonl` 超过 7 天未更新后清理。单文件达到约 4 MiB 后续写 `peek-YYYY-MM-DD.1.jsonl` 等分卷。默认记录已注册快捷键的触发／松开、Hover 意图、绑定和设置变更、窗口选择／焦点／移动、恢复及失败，不需要启动参数。按 `session`、`request` 和 `seq` 串联 `window_request`、`window_queue_delay`、`request_stage`、`window_toggle`、`request_finished`；`request_skipped` 与 `request_cancelled` 区分未开始和已失效的意图。`stage`、`reason`、`message`、`ax_code` 等字段解释失败；AX 读失败按属性和返回码在每次执行中去重。不记录输入内容和窗口标题；日志含应用标识、窗口位置和操作时间，分享前检查。`recovery_reattached` 表示后台重新接管整应用隐藏记录，不代表窗口已经恢复可见。

清理构建产物时不要删除这些数据。构建产物、临时检查程序及个人研究资料不进入 Git；`docs/images/` 中用于 README 的产品图片应提交。

## 提交前检查

- 干净构建、签名和安装后的版本正确。
- 分页、内容滚动、露出宽度、四项时间参数及配置保存正常。
- 用独立 AppKit 窗口验证 Dock 生命周期：显示为 regular，关闭／隐藏后为 accessory 且进程继续运行，重开恢复可见和 regular；快速关闭重开、无关窗口关闭、语言切换替换窗口不得误移除 Dock 入口。实际 Peek 安装后确认 ⌘W 和关闭按钮、菜单栏／Finder 重开、关闭菜单栏图标后的 Finder 入口，以及后台快捷键／Hover 不受影响。不要修改用户 Dock 固定项或登录项。
- `README.md` 与 `README.en.md` 的语言切换链接、相对图片路径可用；中英文功能、默认值和安装说明保持一致，规格区分当前行为与旧记录兼容。
- 同侧上下分区和重叠窗口每次停留只展开一个；焦点切换和周期刷新不重复触发。左、右、底部露出宽度保持正确，改变设置不立即移动隐藏窗口。
- 在独立窗口中检查快捷键、Hover、调整尺寸后的收放、拖拽让出控制和退出恢复。删除绑定不受恢复失败阻塞；退出允许保存未完成记录，启动仍能恢复同一窗口。验证 AX 不可读但 WindowServer 原始 frame 已恢复时的只读完成，以及错误窗口 ID 不清记录。
- 顶部实验默认关闭；方式包含最小化窗口与隐藏整个应用，默认最小化；旧 `shade`／`compression` 方式读取为 `minimize`，删除标题条主动代码，仅保留旧记录恢复能力；新 `appHide` 配置正确持久化。旧 `topMinimizeEnabled` 迁移保留启用状态与最小化方式，其余延迟、时长、露出宽度不变。桌面切换新配置默认开启，显式保存的旧值保持不变。
- 验证顶部最小化的 Hover、快捷键、关闭开关后的召回、隐藏期间关闭顶部开关、退出／重启恢复、目标暂时不可读时不换窗口；确认进程退出或窗口关闭后保留应用绑定，显式召回时允许重新发现窗口。旧压缩记录保存 original 与 compressedFrame，不能用压缩高度覆盖原高度；旧压缩记录只做恢复，用户调整尺寸则让出控制。
- 窗口缓存回归：在独立应用中保留旧 WindowServer ID，同时令旧窗口 AX frame 不可读，再发布有效的 focused／main 普通窗口。无恢复记录时应重选新窗口并完成 hide／recall，保持 hasShown，不重放旧布局；移动、缩放或最小化恢复记录不得替换窗口。整应用隐藏记录按下述应用级接管规则验证。自进程 AX 测试的写操作须回到主线程，不能把这类测试夹具限制误当作跨进程产品行为。`window_target_selected` 记录新旧窗口 ID；失败日志记录 PID、窗口 ID、AX frame 可读性、策略和恢复记录状态，不记录窗口标题。
- 整应用隐藏的窗口更替回归：独立应用先发布登录窗口，Peek 隐藏后令旧窗口 orderOut 并保留 WindowServer ID，再发布主窗口。应用取消隐藏后须连续确认旧窗口不在 AX windows／focused／main 和屏幕列表中，新 focused／main 窗口属于同一进程、可见、非最小化、frame 一致且在当前 Space，才结束旧隐藏所有权并接管。覆盖后台 Hover 刷新、快捷键选择、取消隐藏过程中更替、启动时重附恢复记录、删除／退出的非激活恢复。验证接管后快捷键 hide／recall 和 Hover hide action 正常；不得把登录窗口布局写到主窗口，不学习更替期间的召回方式。覆盖旧窗口仍由 AX 发布、应用仍隐藏、进程身份不符、用户最小化、拖拽和记录保存失败，均须保留原记录。日志 `application_window_replaced` 记录 PID、新旧窗口 ID 和接管原因，不记录标题。程序化 action 不能代替真实键鼠验收；不操作用户的微信做回归。
- 不修改 AXEnhancedUserInterface 等辅助功能设置。旧停放记录恢复时同时检查 AX 与 WindowServer。应用隐藏可能使 WindowServer 不再枚举目标窗口，因此在隐藏前保存 Space 归属，恢复时校验进程启动时间，再解除自己发起的隐藏，重新取得相同窗口 ID；确认登录／主窗口更替时允许按应用级接管规则完成已结束的整应用隐藏。未知或仍在过渡的状态不能记作成功。
- 恢复需校验 PID、启动时间、窗口 ID；最小化的短暂 AX 不可读只做有界重读，不换元素、不把 unknown 记作隐藏。旧记录缺少 ID 时保留并提示，不按标题猜测。
- 桌面开关关闭时不得激活其他 Space 的目标；开启时仅经目标窗口激活请求系统切换，等待 Space 变更通知与窗口可见性后再收放。自动隐藏、退出恢复不主动跨桌面聚焦；未知归属安全停止。不使用 Dock 注入、不改 SIP、不搬窗口到其他 Space。
- `WindowSpaces` 动态加载三个只读 SkyLight 符号；符号或数据缺失返回 unknown，不能把 Mission Control 中的可见缩略图当作当前桌面归属。测试当前／其他／未知和所有桌面集合，以及单屏两个真实普通 Space 的往返；区分普通 Space、全屏、多屏和 Stage Manager 的验收边界。
- 不自动更改用户的开机自启注册；不反复操作用户正在使用的窗口。
- 区分程序化 action、注入事件与物理键鼠验证；未验证的兼容性明确说明。

- 使用独立双窗口应用验证直接 hide／unhide：所有窗口一起隐藏且不最小化，位置尺寸不变；顶部边缘 Hover 恢复绑定窗口，离开后收起。覆盖模式切换、重复隐藏、关闭顶部开关后恢复、用户自行隐藏／唤回、删除绑定和重启恢复。无标题条面板、停放或压缩请求。顶部过渡不使用移动动画时长。
- 关闭顶部后方向选项仅底、左、右；旧顶部绑定显示停用，新绑定默认右侧。检查开关说明、可点击操作状态、固定 44pt 行高和等宽下拉面板。底部验证 0、8、40、100pt 设置及系统夹紧后的实际露出高度和 Hover 区域。
- 中英文资源位于 `app/Resources/{zh-Hans,en}.lproj/`。验证文本键与占位符一致、两种语言下的四个页面与错误说明、语言菜单等宽、即时切换和重启后的语言持久化；测试使用独立 UserDefaults，不改变用户配置。

触发角与生命周期回归：四角 16×16pt 内不产生展开或收起；启动台、Mission Control 打开期间移动到各边缘不得操作窗口或抢走系统界面，关闭后旧计时不得立即触发。检测目前使用可见的大型 Dock 窗口，必须在目标 macOS 上实机确认。独立应用退出、重新启动、关闭最后窗口后检查快捷键和持久化边缘入口；后台刷新不能启动应用。AX 暂时不可读、整应用隐藏、其他 Space、用户最小化不得被当作窗口关闭。新窗口不得使用旧恢复记录。隐藏后退出目标应用，再由 Dock 启动，应恢复布局并自动收起；由快捷键或 Hover 启动，应展开聚焦，不得被已排队的生命周期收起覆盖。Peek 退出时恢复真实窗口，但保留应用期望状态；重开后重新应用。覆盖隐藏状态的持久化、旧几何数据解码、启动中 AX 空列表、无普通窗口但有面板、顶部停用、系统界面和拖拽延后、其他 Space 不抢焦点，以及删除撤销／换方向不被当作应用重启。

按项目约定，不保留测试套件或运行时测试入口。临时验证产物使用后清理；产品图片与临时测试截图分开。

整应用隐藏的附属窗口回归：在独立应用中动态打开主窗口外的图片查看器和浮动面板，覆盖主窗口→附属窗口→关闭按钮→全部窗口之外。检查隐藏请求排队后鼠标进入新窗口时取消隐藏、重新离开后仍能收起；窗口列表未知时不隐藏、其他应用遮挡附属窗口时不误认。若 WindowServer 把系统鼠标指针列在最前，跳过 cursor 层，再判断第一个命中窗口；不要跳过真实浮动面板或其他应用窗口。右侧只移动原绑定窗口，附属窗口保持可见和原位置。不得用用户的微信窗口反复测试。

启动恢复失败回归：用独立应用隐藏时 orderOut、仅收到 reopen 才重新发布同一窗口。写入隔离恢复记录后验证启动的非激活恢复失败、重复后台刷新仍建立 Hover 入口且不发起 reopen／不改保存状态；明确召回后同一窗口显示并可再次隐藏。覆盖手动显示同一窗口后仅靠后台刷新重新接管、可见性未知时 `recallPending` 入口、首次召回失败后离开再进入重试、进程启动身份不符、桌面未知、原屏幕断开及删除绑定后不重新启用。非 appHide 恢复记录只能提供待恢复入口，后台不得移动或取消最小化。不得用用户的微信反复测试。

顶部回归检查必须覆盖连续指针路径：y=0 → 菜单栏间隙 → 窗口内部 → 窗口外部；不能只从顶部跳到窗口外。检查隐藏过渡中 AppKit 身份缺失时的内核身份、未知状态保留恢复记录，以及需要先激活或接收系统重新打开事件才重新发布 AXWindows 的应用召回；用独立应用在隐藏时 orderOut、收到 reopen 时恢复同一窗口来覆盖微信路径。

召回方式保存于设置的 `ApplicationRecallMethods.v1` 字典。用独立 UserDefaults 验证首次兼容回退、下次直接调用、重建控制器后保留、首选失效后学习替代方式；失败及退出恢复不学习。通过 `application_recall_method` 和 `application_recalled` 的毫秒计时区分请求等待与系统过渡。

顶部方式统一由通用设置：应用隐藏位置菜单只有顶部、底部、左侧、右侧，关闭顶部后只剩三项。检查隐藏期间修改方式先按原记录恢复。中英文方式说明图标在最右侧，位置面板与按钮同为 72pt 宽，条目仍为 44pt。

界面可用性检查：使用独立 UserDefaults 验证删除立即停止管理、8 秒内撤销恢复原绑定及列表顺序、应用或快捷键冲突不覆盖配置、超时不恢复；撤销等待删除的恢复任务完成，只重新启用发现。验证可编辑零值与单位对比度、数值加减与开关原位更新及焦点保留；下拉框覆盖上下键、Home/End、Enter/空格、Esc、Tab/Shift-Tab，确认与取消后返回正确控件。中英文检查空状态、长应用名、录制状态、六行设置、72pt 位置菜单和通用设置标签、右侧控件及说明图标对齐。程序化验证不能代替真实键盘或 VoiceOver 验收。
