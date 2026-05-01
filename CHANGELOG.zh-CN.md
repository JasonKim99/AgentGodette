# 更新日志

[English](CHANGELOG.md) | 简体中文

**Agent Godette** 的所有重要变更记录在此。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

## [0.6.0] - 2026-05-01

### 新增
- **Token 消耗追踪** —— 按项目持久化的累积 token 计数器，存于
  `user://godette_token_totals.json`。从所有 ACP `usage_update` 通知累积
  （Claude `message_delta`，Codex `TokenCountEvent`），流式期间数字实时
  上涨（与官方 CLI 一致）。
- **Token 火焰徽章** 挂在 dock 顶端 —— Balatro 风格，紧靠 `+` 按钮。三层
  结构：圆角卡身（StyleBoxFlat）+ 火焰 TextureRect（自定义 shader）+
  逐字符数字 overlay。点击 widget 弹出实时设置弹窗。"Show Flame" 开关
  控制显隐。
- **火焰 shader** —— 完整移植 Balatro 的 `resources/shaders/flame.fs`：
  5 次迭代 domain warp、像素化到 30 格、self-distortion、时间滚动的
  `flame_up_vec` 上升流、双色纵向渐变（主色 → 暖白色火尖，从用户主题
  色自动派生）。Body 感知：仅在 body 上方的 overflow 区渲染，且填满
  body 圆角缺口让轮廓无缝过渡。`flame_intensity` 由 token 总数驱动
  （log_10 映射，0 token → 0，1B token → 10）。
- **数字动画** —— 移植 Balatro `engine/text.lua` 的 `DynaText`。每个字符
  通过 `Font.draw_string` / `draw_string_outline` 手动绘制（不用
  HBoxContainer + Label，所以字间距用字体自己的 advance width）。Pulse
  用三角波从左到右扫过字符，旋转按位置驱动（外侧字符向外倾，内侧不动）。
  单 pulse + queue=1 模型 —— pulse 严格依次播放，永不叠加。
- **老虎机式 count-up** —— 基于 tick 的线性爬升。每个 tick 数字跨一步、
  同时触发一次 pulse（动画"咔咔咔"和 pulse 同步）。K / M / B 范围用
  2 位小数显示，每个 tick 的小变化都肉眼可见。Turn 结束
  （`session_busy_changed → false`）直接 snap 到权威目标值并触发最后
  一次 pulse。
- 支持 **m6x11plus 像素字体**。把 `.ttf` 丢进 `addons/godette_agent/fonts/`
  即可启用；缺失则回退到编辑器默认字体。
- **设置弹窗** —— Show Flame 开关、Color 调色器、Padding X/Y、Corner
  Radius、Flame Speed (%)、Bounce Peak (%)、Bounce Duration (ms)、
  Count-up Duration（10–30 秒）、Pulse Throttle (ms)、Bounce Rotation (°)、
  Reset to defaults。Bounce 相关滑条拖动时实时预览 pulse。

### 变更
- 跨 adapter 通用的快照累积函数
  `record_session_token_snapshot(adapter, session_id, used)`，Claude 和
  Codex 共用。之前仅 Codex 走这条路。
- 移除 turn 结束时的 `result.usage` 累积 —— mid-stream 快照已经覆盖了
  这些 token，再处理一次会双计。
- 显示口径汇总所有 token 桶（input / output / cache / 统一 `used`），
  跟 CLI 习惯一致；不再排除 cache_read。

### 修复
- `ProjectSettings.save()` 现在确实跨编辑器重启持久化设置变更了。之前
  只改内存副本，重新打开项目会丢回磁盘旧值 —— "Reset to defaults"
  本质上重启后等于没按。

## [0.5.1] - 2026-04-28

### 新增
- Composer 斜杠命令弹窗 —— prompt 输入框敲 `/` 弹出 Zed 风格的双栏
  picker，由 adapter 的 `available_commands_update` 通知驱动。

## [0.5.0] - 2026-04-28

### 变更
- **Phase 1 状态提取重构** —— session、connection、permission 状态从
  `agent_dock.gd` 中拆出，挪到独立的 `session_state.gd`（`GodetteState`）
  模块，由 `plugin.gd` 持有。Dock 退化成绑定共享 state 的视图（通过
  `bind(state)`）。新增 `session_store.gd` 独占 session 索引文件 +
  per-thread 缓存的磁盘 I/O。

## [0.4.3] - 2026-04-27

### 修复
- `list_block.gd`、`table_block.gd`、`text_block.gd` 渲染路径的若干
  bug。

### 变更
- Codex markdown 渲染优化（block 边界检测）。
- 跨 block 选择健壮性提升。
- README 增加 troubleshooting 章节。

## [0.4.2] - 2026-04-27

### 变更
- README 更新。

## [0.4.1] - 2026-04-25

### 新增
- 代码块折叠 / 展开操作 —— 配雪佛龙图标
  （`lucide--chevron-up/down`）和圆形雪佛龙变体。
- Shader 代码块识别 —— `.gdshader` / `.glsl` / `.shader` 围栏与其他
  语言一样获得语法高亮。

### 变更
- `code_block_block`、`list_block`、`table_block` 统一使用 IBeam 文本
  光标，给选择反馈一致的体感。
- 编辑器主题集成扩展（`editor_theme.gd`）。

## [0.4.0] - 2026-04-25

### 新增
- **ListBlock** + **TableBlock** 改成自绘 Control —— markdown 列表
  和表格各自塌缩成单一 Control，消除 VirtualFeed 在长 transcript 上
  的累积测量误差。
- **跨 block 选择** —— 在段落、列表、表格之间连续拖选。Ctrl+C 跨
  单元格保留 `\t` 和 `\n` 格式。
- **行内链接点击** —— 点击 link span 在浏览器打开。
- **右键菜单** —— Copy Selection / Copy This Agent Response 在列表
  和表格 block 上也能用，不再仅限文本。
- 实时 session 加载 + per-thread history 按需 hydrate。

## [0.3.3] - 2026-04-25

### 变更
- i18n 字符串更新。
- 标签处理优化。

## [0.3.2] - 2026-04-25

### 变更
- i18n 基础设施（`i18n.gd`）铺底。
- `.gitignore` / `.gitattributes` 整理；addon 内置 LICENSE + README。
- 文件夹组织一轮（资源路径、文档图）。

## [0.3.1] - 2026-04-25

### 新增
- 焦点环渲染（`focus_ring.gd`）。
- Session 菜单重构（`session_menu.gd`）—— 从 inline 的 agent_dock
  代码中拆出。
- 插件图标（`icon-128-rounded.png`）和功能截图入文档。

### 变更
- README 中英文双语多次迭代打磨。

## [0.3.0] - 2026-04-24

### 新增
- **Plan 抽屉** —— agent 的 TodoWrite 计划从 transcript 中拆出，
  挪到 composer 上方独立的 Control。Zed 风格 SVG 图标
  （`todo_pending` / `progress` / `complete`），in_progress 状态 2 秒
  旋转动画，"All Done" 徽章，`×` 清空。
- **Queue 抽屉** —— 完整的逐条 message 操作（垃圾桶 / 铅笔 / Send
  Now）。第一行控件常驻，其它行 hover 才显示。表头有 "Clear All"。
  Send Now 打断当前 turn；Edit 把排队 message 的文本 + chips +
  附件还原到 composer 里。排队的 message 在派发前不进 transcript，
  所以不再切断流式 agent 响应。
- 附件 chip 显示 FileSystem 时间戳。

## [0.2.1] - 2026-04-23

### 新增
- 编辑器 FileSystem 自动刷新 —— agent 修改的文件 Godot 资源浏览器
  无需手动 rescan 即可感知。

## [0.2.0] - 2026-04-23

### 新增
- **Composer chip 覆盖层** —— 粘贴的截图、SceneTree 节点选择、
  FileSystem 文件以行内 chip 形式渲染在 prompt 输入框中、用户文本
  之前。
- **Composer 上下文** 模块（`composer_context.gd`）独立追踪附加
  资源，与 prompt 文本分开管理。
- **Composer prompt 输入框** 升级为感知 chip 的独立 Control（chip
  与 caret 导航联动）。

## [0.1.0] - 2026-04-22

### 新增
- 首次发布。一个 Godot 4 编辑器插件，与本地 ACP（Agent Client
  Protocol）adapter 通信 —— Claude Agent 和 Codex CLI 以 stdio 子进程
  方式运行，编辑器就是 client（没有 HTTP 中转）。
- 多 session 聊天 dock，每条 thread 独立状态。
- GFM markdown 渲染 + 跨 block 文本选择。
- Zed 风格的 tool call 渲染。
- TodoWrite 输出的 Plan 面板。
- 排队的后续 prompt。
- 场景节点 / 文件附件 chip。
- MIT 协议。
- AI 联合作者 trailer hook（`prepare-commit-msg`）。

[未发布]: https://github.com/JasonKim99/AgentGodette/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/JasonKim99/AgentGodette/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/JasonKim99/AgentGodette/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/JasonKim99/AgentGodette/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/JasonKim99/AgentGodette/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/JasonKim99/AgentGodette/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/JasonKim99/AgentGodette/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/JasonKim99/AgentGodette/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/JasonKim99/AgentGodette/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/JasonKim99/AgentGodette/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/JasonKim99/AgentGodette/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/JasonKim99/AgentGodette/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/JasonKim99/AgentGodette/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/JasonKim99/AgentGodette/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JasonKim99/AgentGodette/releases/tag/v0.1.0
