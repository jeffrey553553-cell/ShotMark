# ShotMark

ShotMark 是一个 macOS 15+ 原生菜单栏截图、标注和区域录屏工具。

## 功能

- 默认 `Option + A` 快捷截图；可在状态栏“权限与设置...”里自定义截图快捷键。
- 进入截图后先冻结当前屏幕帧，动态内容如视频不会在选区和最终截图中继续变化。
- 框选后在选区层显示浮动工具条，标注先叠在选区上，最终确认时才真实截图。
- 支持矩形、椭圆、箭头、自由画笔、荧光笔、序号、文字评论和深毛玻璃遮挡。
- 序号支持实心、描边、浅色三种样式；已有序号选中后可继续调整样式、大小、颜色和透明度。
- 评论会根据目标框周围空间自动选择斜向布局，箭头吸附目标边缘并随文字长度实时调整；拖动目标框只移动目标，拖动文字会带动箭尾，拖动箭头可移动整组。
- 评论输入阶段不会重复绘制底层文字；`Esc` 取消新评论，`Cmd + Enter` 完成输入。评论样式支持独立调整字号、线宽、颜色和不透明度。
- 评论输入后可直接拖动目标内部、八方向缩放手柄或箭头端点，第一次操作不会被输入框吞掉；暂时不输入文字也会保留评论结构供继续调整。
- 支持选中标注后移动、调整大小、删除，以及撤销/重做。
- 绘制选区、矩形、椭圆、马赛克和评论框时，按住 `Shift` 约束为正方形/正圆，按住 `Option` 从中心向外绘制；两个修饰键可以组合使用。
- 绘制或调整箭头端点时，按住 `Shift` 吸附到 45° 方向；调整选区或形状角点时，按住 `Shift` 保持原始宽高比。
- 绘制和调整标注时实时显示宽高、箭头长度与角度，尺寸反馈会自动避让截图边缘。
- 标注、端点和文字输入框会约束在截图选区内，靠近边缘输入文字时输入框会自动向内展开。
- 支持 OCR 识别并复制文本。
- 支持按选区原生像素尺寸录制 MP4，60fps、显示鼠标，可选系统级鼠标点击提示；音频模式支持无声、系统音、麦克风、系统+麦克风。
- 钉图支持滚轮/触控板缩放、透明度、复制、保存、锁定鼠标穿透；状态栏可显示或关闭全部钉图。
- 支持长截图、钉住截图、深毛玻璃马赛克遮挡。
- 长截图对动态页面采用渐进式自动重试，并在重试期间保留滚动方向与距离提示。
- `Cmd + C` 复制最终截图到剪切板。
- `Space` 将图片以 PNG 格式保存到 `~/Downloads`。
- 录制中可从顶部控制条或状态栏暂停、继续和停止；再次按当前截图快捷键仍会停止。暂停片段会无缝合并，视频保存到 `~/Downloads`。
- 初始框选阶段：拖出选区后可移动/缩放；按 `Enter` 才真实截图并复制，按 `Space` 才真实截图并保存。
- 标注阶段仍在选区层内完成；矩形、箭头等数字快捷键可在悬停菜单中配置，`E` 切换椭圆，`P` 切换画笔，`H` 切换荧光笔，`T` 切换文字。
- 编辑快捷键：`Cmd + Z` 撤销，`Cmd + Shift + Z` 或 `Cmd + Y` 重做，`Delete` 删除选中标注。
- 选区精调：方向键按屏幕物理像素移动选区，`Shift + 方向键` 调整选区大小；选中标注后可用方向键微调，按住 `Shift` 每次移动 10 像素。
- 拖拽或缩放选区时显示像素放大镜；按住 `Command` 移动鼠标可随时查看像素坐标和颜色，`Command + 滚轮` 调整放大倍数。
- 激活文字工具后，点击选区内任意位置可直接输入文本评论；已落成的文字可再次点击编辑。
- OCR 面板支持自由选择文本，点击“复制全部”后自动关闭并反馈复制成功。
- 状态栏菜单提供屏幕录制、辅助功能、麦克风权限状态，提供打开系统设置、应用设置和退出入口；权限修改后请退出并重新打开 App。

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
