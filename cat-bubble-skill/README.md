# Cat Bubble

Cat Bubble 是一个桌面小猫宠物侧车：透明置顶的小猫会歪头待机、偶尔冒出短句气泡，还会对鼠标做出反应（看指针、挥手、被拖走时跑动），并且可以把 Codex 的授权请求变成小猫头顶的「允许 / 拒绝」气泡。

它最初叫 Atom Bubble，角色原型是一只叫「原子」的奶油银渐层英短，现在项目统一命名为 **Cat Bubble**，猫猫本体仍然可以叫原子。

## 一、拿到手就能用

开箱即用的部分不依赖 Codex，也不依赖任何 AI 服务：

- 透明置顶小猫浮层，待机歪头动画
- 9-11 分钟随机冒一句本地语录
- 单击弹下一句气泡
- 双击挥手
- 鼠标悬停看向指针方向
- 按住拖动跑动，方向跟随拖拽方向
- 右键菜单：说话、挥手、放大 / 缩小 / 重置大小（气泡和文字同步缩放）、隐藏 / 显示、退出
- 菜单栏图标：说话、跳一下、挥手、演示授权、放大 / 缩小 / 重置大小（气泡和文字同步缩放）、隐藏 / 显示、退出
- 全局快捷键（可选，需辅助功能授权）

## 二、运行要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 15 或更高 |
| 芯片 | Apple Silicon（arm64） |
| Codex | 不需要（只有授权气泡功能才需要） |
| AI 服务 | 不需要（默认本地语录） |

## 三、快速开始

```bash
unzip cat-bubble.zip
cd cat-bubble
./start.sh
```

退出用菜单栏里的「退出」，或 `./stop.sh`。

## 四、触发方式一览

| 操作 | 小猫反应 |
| --- | --- |
| 单击 | 弹下一句语录气泡 |
| 双击 | 挥手 |
| 鼠标悬停 | 看向指针方向（16 方向） |
| 按住拖动 | 跑动，方向跟随拖拽方向 |
| 右键 | 说话 / 挥手 / 放大或缩小 / 重置大小 / 隐藏或显示 / 退出 |
| 菜单栏图标 | 说话 / 跳一下 / 挥手 / 演示授权 / 放大或缩小 / 重置大小 / 隐藏或显示 / 退出 |
| Control+Option+A | 下一句（需辅助功能授权） |
| Control+Option+Z | 演示授权气泡（需辅助功能授权） |
| Control+Option+H | 隐藏 / 显示（需辅助功能授权） |

## 五、可以 DIY 的地方

| 想改什么 | 改哪里 | 难度 |
| --- | --- | --- |
| 语录内容 | `phrases.json` 的 `phrases` 数组 | 低，改完重启 |
| 语录人设 | `phrases.json` 的 `persona` / `voice_rules` | 低 |
| 自动说话间隔 | 启动参数 `--interval-min` / `--interval-max`（单位秒） | 低 |
| 气泡文字颜色 / 样式 | `src/atom_bubble.swift` 的 `SpeechBubbleView` | 中 |
| 待机动画速度 | `src/atom_bubble.swift` 里 `startIdleLoop` 的 `0.5` 秒/帧 | 低 |
| 动作动画速度 | 挥手 / 跳跃 / 跑动的帧间隔参数 | 低 |
| 宠物大小 | 右键「放大原子 / 缩小原子 / 重置大小」，范围 0.6-1.8 倍 | 低 |
| 快捷键 | `src/atom_bubble.swift` 的全局监听 keyCode | 中 |
| 触发方式 | `PetView` 的鼠标事件回调 | 中 |
| 小猫形象和动作帧 | 替换 `assets/` 下 `idle/`、`look/`、`waving/`、`jumping/`、`running-left/`、`running-right/` 的 PNG | 中 |
| 窗口位置和大小 | `applicationDidFinishLaunching` 里的窗口参数 | 中 |
| 是否接 Codex 授权 | 用 `--codex` 启动 | 低 |

## 六、关于 Codex / Agent / AI

- **没有 Codex 能跑吗？** 能。普通模式完全独立运行，只有 `--codex` 模式需要本机 Codex 的 `app-server`。
- **Codex 连的不是 GPT 能跑吗？** 能。默认语录是本地文件，和模型无关；只有 `--live-model` 会调用 OpenAI 兼容接口，不开就不涉及。
- **只要有一个 Agent 就能跑吗？** 别人直接用编译好的二进制就能跑，不需要 Agent；但如果他想改形象、加语录、调动画，就需要一个能读写 Swift 代码并执行构建命令的 Agent，任何支持本地文件操作的 Agent 都可以照着这个 README 做。

## 七、Codex 授权气泡（可选）

```bash
cd <你想让 Codex 工作的目录>
/path/to/cat-bubble --codex
```

Codex 请求授权时，小猫会抬头，头顶弹出「允许 / 拒绝」气泡，点击即回传决策。

## 八、构建

```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
swiftc -O -sdk "$SDK" -target arm64-apple-macosx15.0 \
  -framework AppKit -framework ApplicationServices \
  -o cat-bubble src/atom_bubble.swift
```

## 九、开源前记得做

- 换掉默认的 `phrases.json` 语录和 `assets/` 里的宠物形象，避免把个人定制内容原样发布
- 加一份 LICENSE
- 保留本 README 的 DIY 表格，方便别人自己改
