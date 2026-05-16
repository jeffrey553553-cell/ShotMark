# ShotMark

ShotMark 是一个 macOS 15+ 原生菜单栏截图、标注和区域录屏工具 MVP。

## 功能

- 默认 `Option + A` 快捷截图；可在状态栏“权限与设置...”里自定义截图快捷键。
- 进入截图后先冻结当前屏幕帧，动态内容如视频不会在选区和最终截图中继续变化。
- 框选后在选区层显示浮动工具条，标注先叠在选区上，最终确认时才真实截图。
- 支持框选、箭头、序号、文字评论。
- 支持选中标注后移动、调整大小、删除，以及撤销/重做。
- 支持 OCR 识别并复制文本。
- 支持框选区域录制 MP4，默认 1080p、60fps、显示鼠标；音频模式支持无声、系统音、麦克风、系统+麦克风。
- 支持长截图、钉住截图、深毛玻璃马赛克遮挡。
- `Cmd + C` 复制最终截图到剪切板。
- `Space` 保存 PNG 到 `~/Downloads`。
- 录制中再次按当前截图快捷键停止，或从状态栏菜单/顶部悬浮停止条停止；视频保存到 `~/Downloads`。
- 初始框选阶段：拖出选区后可移动/缩放；按 `Enter` 才真实截图并复制，按 `Space` 才真实截图并保存。
- 标注阶段仍在选区层内完成；按 `1` 切到框选工具，按 `2` 切到箭头工具，按 `3` 切到序号工具，按 `T` 切到文字工具，按 `5` 切到马赛克，按 `6` OCR，按 `7` 钉住，按 `8` 长截图，按 `9` 录制。
- 编辑快捷键：`Cmd + Z` 撤销，`Cmd + Shift + Z` 或 `Cmd + Y` 重做，`Delete` 删除选中标注。
- 激活文字工具后，点击选区内任意位置可直接输入文本评论；已落成的文字可再次点击编辑。
- OCR 面板支持自由选择文本，点击“复制全部”后自动关闭并反馈复制成功。
- 状态栏菜单提供屏幕录制、辅助功能、麦克风权限状态，提供打开系统设置和退出入口；权限修改后请退出并重新打开 App。

## 本地运行

```bash
CLANG_MODULE_CACHE_PATH=.build/module-cache swift run --disable-sandbox ShotMark
```

不触发真实截图权限、只预览编辑器：

```bash
CLANG_MODULE_CACHE_PATH=.build/module-cache swift run --disable-sandbox ShotMark --demo
```

## 打包 .app

```bash
scripts/build_app.sh
```

生成路径：

```text
dist/ShotMark.app
```

可选签名：

```bash
CODE_SIGN_IDENTITY="ShotMark Local Developer" scripts/build_app.sh
```

## 打包 DMG

```bash
scripts/package_dmg.sh
```

生成的 DMG 中包含 `ShotMark.app` 和 `Applications` 快捷方式。安装或升级时，打开 DMG 后把 `ShotMark.app` 拖到 `Applications`，如果旧版已存在，Finder 会提示是否替换。

可选签名和公证：

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/package_dmg.sh
```

## 权限修复

如果系统设置里看起来已经允许了屏幕录制或麦克风，但 ShotMark 仍提示需要权限，通常是 macOS 还没有把权限刷新给当前运行中的 App，或者权限给到了旧的未签名构建、`swift run` 进程、另一个 bundle 身份。
当前机器如果没有代码签名证书，构建脚本会使用 ad-hoc 签名；这种签名每次重建都可能改变系统隐私权限识别用的指纹。

优先处理方式：

1. 从状态栏菜单选择“打开屏幕录制设置...”或“打开麦克风设置...”，确认 ShotMark 已开启。
2. 从状态栏菜单选择“退出 ShotMark（权限变更后重启）”。
3. 重新打开新版 App：

```bash
open dist/ShotMark.app
```

如果仍然异常，再退出 ShotMark 并运行：

```bash
scripts/reset_permissions.sh
```

再打开新版 App：

```bash
open dist/ShotMark.app
```

按当前截图快捷键（默认 `Option + A`），重新在系统提示里授权屏幕录制。授权后需要退出并重新打开 ShotMark。

查看当前签名状态：

```bash
scripts/signing_status.sh
```

想让权限稳定，建议在“钥匙串访问”里创建本地代码签名证书：

1. 打开“钥匙串访问”
2. 菜单选择“钥匙串访问 -> 证书助理 -> 创建证书...”
3. 名称填写 `ShotMark Local Developer`
4. 身份类型选择“自签名根证书”
5. 证书类型选择“代码签名”
6. 创建后重新运行 `scripts/build_app.sh`

脚本会自动优先使用名为 `ShotMark Local Developer` 的签名身份。也可以显式指定：

```bash
CODE_SIGN_IDENTITY="ShotMark Local Developer" scripts/build_app.sh
```

## 核心链路回归

每次改工具栏、标注 UI、权限提示或导出逻辑后，先跑自动检查：

```bash
scripts/core_regression_check.sh
```

脚本会构建 Debug/Release、验证签名、打包并校验 DMG，然后在 `dist/regression/` 生成固定手测清单。手测矩阵固定覆盖：单屏、外接屏、Retina、全屏框选、小区域框选、保存、复制、钉住、OCR、录屏和马赛克。
