@tool
class_name GodetteFlatRender
extends RefCounted
#
# Phase 2 of the flat-draw refactor (see design/flat_draw.md).
#
# Renderer entry point that mirrors GodetteMarkdownRender.render_events()
# but produces a tree containing N RichTextLabel runs interleaved with
# dedicated Controls for content BBCode can't carry (code blocks,
# horizontal rules) — instead of the deeply-nested Container subtree the
# current path generates per assistant message.
#
# Per §4 of the design doc:
#   - Continuous text content (paragraphs / headings / lists / blockquotes
#     / tables / inline emphasis / links) lives in a single RichTextLabel.
#   - Code blocks and rules break the active RTL and emit their own
#     Control, then a fresh RTL starts for whatever markdown follows.
#
# This module is OPT-IN. agent_dock.gd gates it behind a feature flag so
# the existing GodetteMarkdownRender path stays untouched until the new
# path is verified end-to-end.
#
# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
#   render_events(events: Array, ctx: Dictionary) -> Control
#       Same signature as GodetteMarkdownRender.render_events() so the
#       caller swap is a one-line change.
#
# Internally we route events through GodetteMarkdownToBBCode.translate()
# to get a flat segment list, then walk segments to build the Control tree.
#
# ctx fields used here (all optional, with defaults):
#   - fg, selection_color, code_block_bg, rule_color
#   - font_bold, font_italic, font_bold_italic, font_mono, font_mono_bold
#   - base_font_size, line_spacing
# Plus the fields the translator reads (code_bg, link_bg, blockquote_bar,
# base_font_size) — passed through unchanged.

const TranslatorScript = preload("res://addons/godette_agent/markdown_to_bbcode.gd")

# Layout constants — match GodetteMarkdownRender so visual parity is
# byte-for-byte close on the bits we don't change.
const PARAGRAPH_GAP: int = 8
const CODE_PAD_X: int = 10
const CODE_PAD_Y: int = 8
const RULE_HEIGHT: int = 1
const RULE_VERTICAL_PAD: int = 8


# Public entry. Translates events → segments → Control tree.
static func render_events(events: Array, ctx: Dictionary) -> Control:
	var segments: Array = TranslatorScript.translate(events, ctx)
	return render_segments(segments, ctx)


# Builds a VBoxContainer holding one Control per segment. Exposed as a
# separate function so callers that already have segments (e.g. a future
# streaming path that translates incrementally) can skip the parser
# round-trip.
static func render_segments(segments: Array, ctx: Dictionary) -> Control:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", PARAGRAPH_GAP)

	for seg_variant in segments:
		if typeof(seg_variant) != TYPE_DICTIONARY:
			continue
		var seg: Dictionary = seg_variant
		match str(seg.get("type", "")):
			"bbcode":
				var text: String = str(seg.get("text", ""))
				if text.is_empty():
					continue
				root.add_child(_make_rtl(text, ctx))
			"code_block":
				root.add_child(_make_code_block_card(
					str(seg.get("language", "")),
					str(seg.get("code", "")),
					ctx
				))
			"rule":
				root.add_child(_make_rule(ctx))
			_:
				pass

	return root


# ---------------------------------------------------------------------------
# Segment renderers
# ---------------------------------------------------------------------------


# Build one RichTextLabel for a continuous BBCode run. fit_content +
# scroll_active=false means the label sizes itself to the BBCode's
# natural height — the parent VBoxContainer handles vertical stacking.
static func _make_rtl(bbcode: String, ctx: Dictionary) -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.selection_enabled = true
	rtl.context_menu_enabled = true
	# Mouse filter STOP so per-RTL selection works without VirtualFeed
	# eating the events; this is RichTextLabel's default but we set it
	# explicitly so a future ctx that wants click-through can flip it.
	rtl.mouse_filter = Control.MOUSE_FILTER_STOP

	_apply_text_theme(rtl, ctx)

	# Set BBCode last so the theme overrides above are in effect when
	# the parser walks the markup.
	rtl.text = bbcode

	# Link click: route to OS.shell_open. Inline lambda dodges the
	# Callable(class_ref, method) binding question for static methods
	# (which can be flaky across Godot 4.x point releases) and keeps
	# the link-handling policy local to where the RTL is built.
	rtl.meta_clicked.connect(func(meta: Variant) -> void:
		var href: String = str(meta)
		if href.is_empty():
			return
		if href.begins_with("http://") or href.begins_with("https://"):
			OS.shell_open(href)
	)

	return rtl


# Code block card: PanelContainer + padding + monospace RichTextLabel.
# Mirrors the structure of GodetteMarkdownRender's code_block path so
# visual parity holds, with the simplification that the inner content
# is also an RTL (using `[code]` would be redundant; we just use the
# mono font slot directly via RTL's normal_font override).
static func _make_code_block_card(_lang: String, code: String, ctx: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var style := StyleBoxFlat.new()
	style.bg_color = ctx.get("code_block_bg", Color(0, 0, 0, 0.25))
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", CODE_PAD_X)
	pad.add_theme_constant_override("margin_right", CODE_PAD_X)
	pad.add_theme_constant_override("margin_top", CODE_PAD_Y)
	pad.add_theme_constant_override("margin_bottom", CODE_PAD_Y)
	panel.add_child(pad)

	var rtl := RichTextLabel.new()
	# Disable BBCode parsing — code content is verbatim. This dodges
	# the "user pasted markdown-syntax inside fenced code" edge case
	# without needing to escape `[` etc.
	rtl.bbcode_enabled = false
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.selection_enabled = true
	rtl.mouse_filter = Control.MOUSE_FILTER_STOP

	# Force monospace for the entire code block content. We override
	# `normal_font` (RTL's default text font) rather than relying on
	# `[code]` BBCode tags since bbcode_enabled is false here.
	if ctx.has("font_mono"):
		rtl.add_theme_font_override("normal_font", ctx["font_mono"])
	if ctx.has("base_font_size"):
		rtl.add_theme_font_size_override("normal_font_size", int(ctx["base_font_size"]))

	var fg: Color = ctx.get("fg", Color(1, 1, 1, 0.95))
	rtl.add_theme_color_override("default_color", fg)
	if ctx.has("selection_color"):
		rtl.add_theme_color_override("selection_color", ctx["selection_color"])

	rtl.text = code
	pad.add_child(rtl)
	return panel


# Horizontal rule: 1px ColorRect inside a vertical-padded MarginContainer.
# Identical layout to GodetteMarkdownRender._emit_rule.
static func _make_rule(ctx: Dictionary) -> Control:
	var wrapper := MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("margin_top", RULE_VERTICAL_PAD)
	wrapper.add_theme_constant_override("margin_bottom", RULE_VERTICAL_PAD)
	var rule := ColorRect.new()
	rule.color = ctx.get("rule_color", Color(1, 1, 1, 0.18))
	rule.custom_minimum_size = Vector2(0, RULE_HEIGHT)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(rule)
	return wrapper


# ---------------------------------------------------------------------------
# RTL theme application
# ---------------------------------------------------------------------------


# Wire ctx fonts / colors / font sizes onto the RTL via theme overrides.
# RichTextLabel exposes per-style font slots (normal / bold / italic /
# bold_italic / mono) — each markdown emphasis style routes to the
# matching slot. Sizes override per-slot too so headings inheriting
# `[font_size=N]` work alongside the body size we set here.
static func _apply_text_theme(rtl: RichTextLabel, ctx: Dictionary) -> void:
	var fg: Color = ctx.get("fg", Color(1, 1, 1, 0.95))
	rtl.add_theme_color_override("default_color", fg)

	if ctx.has("selection_color"):
		rtl.add_theme_color_override("selection_color", ctx["selection_color"])

	if ctx.has("font_bold"):
		rtl.add_theme_font_override("bold_font", ctx["font_bold"])
	if ctx.has("font_italic"):
		rtl.add_theme_font_override("italic_font", ctx["font_italic"])
	if ctx.has("font_bold_italic"):
		rtl.add_theme_font_override("bold_italic_font", ctx["font_bold_italic"])
	if ctx.has("font_mono"):
		rtl.add_theme_font_override("mono_font", ctx["font_mono"])

	if ctx.has("base_font_size"):
		var size: int = int(ctx["base_font_size"])
		rtl.add_theme_font_size_override("normal_font_size", size)
		rtl.add_theme_font_size_override("bold_font_size", size)
		rtl.add_theme_font_size_override("italic_font_size", size)
		rtl.add_theme_font_size_override("bold_italic_font_size", size)
		rtl.add_theme_font_size_override("mono_font_size", size)


