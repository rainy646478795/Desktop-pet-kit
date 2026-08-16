# Ready-to-Use Prompts

别人拿到 Pet Maker 后，把下面这些提示词复制给任何能读写文件、能执行脚本的 Agent 就能开始。替换方括号里的内容即可。

## 1. 最省 Token：透明抠图素材（推荐）

```text
用 Pet Maker。我提供透明 PNG 素材：正面、侧面、背面各一张，
另加走路、跳跃、抬爪视频里抽好的透明帧。
宠物：[品种/毛色/名字，例如：奶油银渐层英短，名字叫原子]。
所有图都是全身完整、尾巴可见、已去背景的 RGBA PNG。
请先写 run-summary.json 和 checklist，然后切帧、组装 v2 图集、
做接触板 QA、打包到 ~/.codex/pets/<名字>/，最后配 Cat Bubble 侧车。
全程按 token-saving.md 执行，不要让我重复发图。
```

## 2. 绿幕素材

```text
用 Pet Maker。我有绿幕视频：
正面站姿 3 秒、侧面走路 5 秒、跳跃 5 秒、抬爪 3 秒，1080p。
请按 photo-guide.md 抽帧、去绿幕、组装图集并 QA，
最后生成 Cat Bubble。先告诉我你打算怎么省 Token。
```

## 3. 只有日常照片/视频（最费 Token）

```text
用 Pet Maker。我只有日常拍的猫照片和视频，没抠过图，
猫全身基本可见但背景很杂。请先按 photo-guide.md 检查素材，
告诉我哪些能用、还差哪些镜头，给出最低成本的补拍清单，
确认后再开始做。
```

## 4. 已有宠物，只加 Cat Bubble

```text
用 Cat Bubble Skill（pet-maker 的侧车部分）。
我已经有安装好的宠物：~/.codex/pets/<名字>/。
请直接生成 Cat Bubble 桌面侧车，语录用本地 phrases.json，
默认 9-11 分钟说一句，触发方式按 README 配好。
```

## 5. 定制语录 / 速度 / 快捷键 / 动作

```text
用 Cat Bubble Skill 帮我改：
1. 语录换成我下面列出的内容；
2. 待机动画每帧 0.5 秒；
3. 双击改为挥手；
4. Control+Option+A 弹下一句，Control+Option+Z 演示授权，
   Control+Option+H 隐藏/显示；
5. 气泡颜色改成暖奶油金。
改完重新编译并重启侧车，告诉我怎么验证。
```

## 6. 只想先看说明和拍照要求

```text
用 Pet Maker，先读 README.md、photo-guide.md 和 token-saving.md，
告诉我：要拍哪些镜头、怎么拍最省 Token、素材要达到什么标准。
先不要生成任何宠物。
```

## 7. 做开源发布包

```text
用 Pet Maker 准备开源发布：
整理 README、SKILL.md、示例提示词；
把示例语录和示例猫图替换成通用占位内容；
检查没有个人照片、猫名、语录残留；
给出发布目录结构和缺失的 LICENSE 说明。
```

## 通用小技巧

- 开头点名 Skill：`用 Pet Maker` / `用 Cat Bubble Skill`，Agent 才会加载对应流程
- 明确素材类型：透明 PNG / 绿幕 / 原始照片，决定省 Token 程度
- 明确输出位置：`~/.codex/pets/<名字>/` 和侧车目录
- 明确「先看文档再动手」或「直接开始」，避免 Agent 自作主张
- 如果 Agent 没有 Codex，只说不要接 `--codex` 授权模式即可
