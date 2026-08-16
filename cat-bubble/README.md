# Atom Bubble

原子桌面宠物侧车：透明置顶浮层、待机歪头动画、随机会话气泡，可接 Codex 授权弹窗。

## 运行要求

- Apple Silicon Mac（arm64）
- macOS 15 或更高
- 直接运行已编译的 `atom-bubble`，无需安装依赖

## 启动

```bash
./start.sh
```

或者手动启动：

```bash
./atom-bubble
```

## 控制

- 单击原子：立刻弹下一句气泡
- 双击原子：挥手
- 鼠标悬停：看向指针方向
- 按住拖动：跑动，方向跟随拖拽方向
- 右键原子：`挥手` / `放大原子` / `缩小原子` / `重置大小`（气泡和文字同步缩放）/ `隐藏原子` / `显示原子`
- 菜单栏气泡图标：`原子说一句` / `跳一下` / `挥手` / `演示授权气泡` / `隐藏或显示原子` / `退出`
- 自动气泡间隔：9-11 分钟随机一次
- 全局快捷键（需先在系统「辅助功能」里允许本程序）：`Control+Option+A` 下一句，`Control+Option+Z` 演示授权，`Control+Option+H` 隐藏/显示

## 自定义短语

编辑 `phrases.json`，只改 `phrases` 数组即可。重启后生效。

## 构建

```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
swiftc -O -sdk "$SDK" -target arm64-apple-macosx15.0 \
  -framework AppKit -framework ApplicationServices \
  -o atom-bubble src/atom_bubble.swift
```

## Codex 授权模式

```bash
cd <你想让 Codex 工作的目录>
/path/to/atom-bubble --codex
```

Codex 需要授权时，原子头上会弹出「允许 / 拒绝」气泡，点按钮即回传决策。
