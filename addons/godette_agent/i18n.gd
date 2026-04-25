@tool
class_name GodetteI18n

# Lightweight locale-aware string lookup for Godette. Uses English source
# strings as dictionary keys so any string without a zh_CN translation
# entry automatically falls back to English — no separate "default"
# plumbing needed at call sites.
#
# Detection:
#   - Reads the editor's configured language from
#     EditorSettings["interface/editor/editor_language"].
#   - If that's exactly "zh_CN" (Simplified Chinese), Chinese is served.
#   - Everything else (en, zh_TW, ja, …) serves English.
#   - Cached on first access; changing the editor language requires
#     reloading the plugin (or restarting the editor).

const ZH_CN: Dictionary = {
	# Buttons
	"Delete this thread": "删除此会话",
	"Switch thread": "切换会话",
	"Send": "发送",
	"Stop": "停止",
	"Queue this prompt — sends when the current turn ends": "加入队列 — 当前回合结束时发送",
	"Copy": "复制",
	"Copied!": "已复制！",
	"Clear All": "全部清除",
	"Drop every queued prompt": "清除所有排队中的消息",
	"Send Now": "立即发送",
	"Send this queued message immediately": "立即发送这条排队中的消息",
	"Dismiss plan": "关闭计划",

	# Menu items
	"Agent Godette: Focus Dock": "Agent Godette：聚焦面板",
	"Ask Agent About Selection": "向 Agent 询问所选",
	"Ask Agent About Nodes": "向 Agent 询问这些节点",
	"External Agents": "外部 Agent",
	"Add More Agents": "添加更多 Agent",
	"Copy Selection": "复制所选",
	"Copy Message": "复制消息",
	"Copy This Agent Response": "复制此条回复",
	"Copy Command": "复制命令",
	"Scroll to Bottom": "滚到底部",
	"Scroll to Top": "滚到顶部",

	# Tooltips
	"Collapse": "折叠",
	"Expand": "展开",
	"Next in Queue": "队列中下一条",
	"In Queue": "队列中",
	"Focus node is INCLUDED in the next prompt — click to ignore": "当前节点将作为下一条消息的上下文 — 点击忽略",
	"Focus node is IGNORED — click to include in the next prompt": "已忽略当前节点 — 点击以加入下一条消息",
	"Select a node in the Scene Tree to attach it as context": "在场景树选中一个节点作为上下文",
	"%s  ·  %s\nEye toggle decides whether this node is included in the next prompt.": "%s  ·  %s\n眼睛开关决定此节点是否附加到下一条消息。",

	# Status labels
	"Starting...": "启动中…",
	"No session": "无会话",
	"Ready": "就绪",
	"Connecting": "连接中",
	"Error": "错误",
	"Offline": "离线",
	"Stopping": "停止中",
	"Working": "进行中",
	"Opening": "创建中",
	"Loading": "加载中",

	# Section headers
	"Recently Updated": "最近更新",
	"All Sessions": "所有会话",

	# System / error messages (shown in transcript or as dialogs)
	"Write a prompt first.": "请先输入内容。",
	"Couldn't launch the local ACP adapter for %s.": "无法启动 %s 的本地 ACP adapter。",
	"Session \"%s\" no longer exists on %s; removing from local history.": "会话 \"%s\" 在 %s 上已不存在,从本地历史中移除。",
	"Couldn't create a new session: %s": "无法创建新会话:%s",
	"No edited scene is open.": "当前没有打开的场景。",
	"Current scene is already attached.": "当前场景已经附加。",
	"Couldn't save pasted image: error %d": "无法保存粘贴的图片:错误 %d",
	"Pasted image is too large (%d bytes) — try a smaller screenshot.": "粘贴的图片太大(%d 字节)—— 换一张更小的截图。",
	"Couldn't send the prompt to the local ACP adapter.": "无法向本地 ACP adapter 发送消息。",
	"Couldn't create the remote ACP session.": "无法创建远程 ACP 会话。",
	"Couldn't load the existing remote ACP session.": "无法加载现有的远程 ACP 会话。",
	"Couldn't load this session: %s": "无法加载此会话:%s",
	"Couldn't create this session: %s": "无法创建此会话:%s",
	"%s finished with %s.": "%s 以 %s 结束。",

	# Placeholders
	"Message %s...": "向 %s 发送消息…",

	# Labels / chip badges
	"Thinking": "思考中",
	"You": "你",
	"Tool": "工具",
	"System": "系统",
	"Scene": "场景",
	"Node": "节点",
	"in %s": "所在:%s",
	"Plan": "计划",
	"Current: %s": "进行中:%s",
	"All Done": "全部完成",
	"Needs approval": "需要授权",
	"No focus": "无焦点",
	"Show less ⌃": "收起 ⌃",
	"Show full command ⌄": "展开完整命令 ⌄",
	"Raw Input:": "原始输入:",
	"Output:": "输出:",
}

# Cached detection result. -1 = not yet detected, 0 = false, 1 = true.
# Using an int sentinel so we can distinguish "never checked" from
# "checked and false", avoiding repeated EditorSettings lookups.
static var _is_zh_cn_cached: int = -1


static func is_zh_cn() -> bool:
	if _is_zh_cn_cached != -1:
		return _is_zh_cn_cached == 1
	# Only cache when EditorInterface is actually available — if it
	# isn't yet (pre-plugin-ready), returning false is a safe default
	# but we mustn't burn that into the cache, otherwise zh_CN users
	# would stay on English for the rest of the session.
	if not Engine.is_editor_hint():
		return false
	var locale: String = ""
	# Primary: explicit editor language setting. Empty when the user
	# hasn't picked a language (Godot's "auto" / system-default mode).
	var settings: EditorSettings = EditorInterface.get_editor_settings()
	if settings != null:
		locale = str(settings.get_setting("interface/editor/editor_language"))
	# Fallback: OS locale. Covers users who never touched the editor
	# language dropdown but run a Chinese OS — the editor displays in
	# Chinese anyway, so we should match.
	# Godot stores "use system default" as the literal string "auto",
	# not an empty value, so we treat both as "no explicit choice".
	if locale.is_empty() or locale == "auto":
		locale = OS.get_locale()
	# Accept variants: "zh_CN", "zh_CN.UTF-8", "zh-CN", "zh_CN_GB", etc.
	# Explicitly excludes zh_TW / zh-TW so Traditional Chinese stays on
	# the English fallback (matches the "non-Simplified Chinese → English"
	# requirement).
	var normalised: String = locale.replace("-", "_")
	var result: bool = normalised.begins_with("zh_CN")
	# Only cache when we actually have a definitive answer. If both the
	# editor setting and OS locale came up empty, we don't cache so a
	# later call after EditorInterface is fully ready can re-detect.
	if not locale.is_empty():
		_is_zh_cn_cached = 1 if result else 0
	return result


static func t(key: String) -> String:
	# Returns the translated string if zh_CN is active and a translation
	# exists for this key; otherwise returns the English source (which
	# is the key itself). Format placeholders (%s / %d) are preserved in
	# translations so callers can `t("...") % args` as usual.
	if not is_zh_cn():
		return key
	return ZH_CN.get(key, key)


static func t_queue_count(count: int) -> String:
	# Special-case plural handling. English code originally used
	# "%d Queued Message%s" with "" / "s" suffix args; Chinese has no
	# plural so we bypass that template entirely.
	if is_zh_cn():
		return "队列中 %d 条消息" % count
	var suffix: String = "" if count == 1 else "s"
	return "%d Queued Message%s" % [count, suffix]


static func t_plan_left(count: int) -> String:
	# Plan drawer's "N left" badge. Separate helper so the Chinese
	# version doesn't end up "3 条未完成s" if we tried to stuff it into
	# the generic t() flow.
	if is_zh_cn():
		return "%d 条未完成" % count
	return "%d left" % count
