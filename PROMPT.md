# 用 Codex 在另一台 Mac 上复刻「原子」桌宠

请帮我把这台 Mac（Apple Silicon、macOS 15+、已安装 Codex）配置成一台可以直接跑「原子」桌宠的机器，并可选地从我提供的照片重新生成一只新猫。**开始前请先完整复述一遍我的需求，让我确认后再动手。**

## 一、目标

- 在桌面运行一只透明置顶、永不抢焦点的小猫浮层「原子」（奶油银渐层英短）
- 默认风格是真实猫咪照片抠图，不要动漫 / 卡通 / 插画
- 每 9-11 分钟随机冒一句暖奶油金色的本地短气泡（不联网）
- 单击原子：立刻冒下一句；双击：挥手；鼠标悬停：原子看向指针（16 方向）；按住拖动：原子按拖拽方向跑；右键 / 菜单栏：说话、跳一下、挥手、演示授权气泡、放大缩小、重置大小、隐藏显示、退出
- 可选：Codex 请求授权时，原子抬头冒「允许 / 拒绝」气泡
- 气泡和文字要随原子整体缩放同步缩放

## 二、素材要求

- 全身可见（头 + 身体 + 四只脚 + 尾巴完整）
- 透明背景或纯色 / 绿幕最佳，1080p 以上
- 至少覆盖：待机（带眨眼、歪头）、挥手、跳跃、左跑、右跑、抬头看、16 个方向的视线帧

## 三、参考实现（必读）

仓库：https://github.com/rainy646478795/Desktop-pet-kit

- `cat-bubble/` 是已经可以直接运行的 Swift/AppKit 完整应用（源码、素材、语录、编译好的程序、README、start.sh/stop.sh）
- `cat-bubble-skill/` 是这个侧车的 Skill 文档，告诉 Codex 怎么读、改、构建它
- `pet-maker/` 是从真实猫照片生成 Codex v2 宠物图集的 Skill 流程

## 四、两种复刻方式（请问我选哪个再动手）

**A. 直接复刻原子（最快，不需要 AI）**

1. `git clone https://github.com/rainy646478795/Desktop-pet-kit.git`
2. `cd Desktop-pet-kit/cat-bubble`
3. `./start.sh`
4. 不需要 Codex 跑模型、不需要联网

**B. 用我的素材重新生成 / 换一只新猫**

1. 我会给你提供透明 PNG（最省 Token）、绿幕视频，或者只有日常照片 / 视频（最费 Token）
2. 先读 `pet-maker/SKILL.md`、`references/photo-guide.md`、`references/token-saving.md`
3. 按 photo-guide 检查素材，告诉我哪些能用、还差哪些镜头，给出最低成本的补拍清单，等我确认
4. 然后切帧、组装 v2 图集、做接触板和 16 方向 QA、打包到 `~/.codex/pets/<猫名>/`
5. 再走 `cat-bubble-skill`，让它生成同样的 Cat Bubble 侧车并套上我的猫

## 五、关键实现细节

- Swift + AppKit，编译：`swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk -target arm64-apple-macosx15.0 -framework AppKit -framework ApplicationServices -o atom-bubble src/atom_bubble.swift`
- NSPanel 透明置顶：`.borderless` + `.nonactivatingPanel`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
- 帧间隔：待机 0.5 秒 / 帧，挥手 0.2 秒，跳跃 0.16 秒，奔跑 0.12 秒
- SpeechBubbleView 和 ApprovalBubbleView 必须按 petScale 等比重排文字、按钮、内边距，定位贴原子头顶
- 短语从 `phrases.json`（persona + rules + phrases）本地随机采样，不要默认启用 `--live-model`

## 六、可改的 DIY 点

| 想改什么 | 改哪里 |
| --- | --- |
| 语录内容 | `phrases.json` 的 `phrases` 数组 |
| 自动说话间隔 | 启动参数 `--interval-min` / `--interval-max` |
| 待机速度 | `startIdleLoop` 的 `0.5` |
| 气泡颜色 / 字体 | `SpeechBubbleView` |
| 快捷键 | 全局监听 keyCode |
| 宠物大小 | 右键 / 菜单栏（0.6-1.8 倍，气泡同步缩放） |
| 是否接 Codex 授权 | 启动加 `--codex` |

## 七、省 Token 提示

- 提前抠好透明 RGBA PNG 给 Codex，省最多
- 不开 `--live-model`，全程本地
- 单次完整跑约 1-2 小时，跑完会同时生成 5 个 GIF + 2 张气泡预览

## 八、动手前请先复述

请用一段话准确复述：目标、选 A 还是 B、素材来源、目标安装路径、你要做的步骤清单。等我确认后再开始操作，不要先猜先做。
