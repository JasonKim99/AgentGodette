@tool
class_name GodetteComposerPromptInput
extends TextEdit
#
# Thin TextEdit subclass that intercepts Ctrl+V (or ⌘+V on macOS) when the
# system clipboard currently holds an image — screenshots, copied rasters
# from image editors, etc. The caught event emits `image_pasted(image)` and
# short-circuits TextEdit's default text-paste so the image doesn't end up
# stringified as binary garbage in the text buffer.
#
# Text paste stays completely unchanged: we only consume the event when
# the clipboard actually has an image. Everything else — plain key input,
# Ctrl+V of text, arrow navigation, selection, etc. — falls through to
# `super._gui_input()` as usual.

signal image_pasted(image: Image)
# Fires when the user presses Enter without a modifier to submit the current
# prompt. Shift+Enter / Alt+Enter still fall through to TextEdit as a newline
# so multi-line prompts remain possible.
signal submit_requested


func _input(event: InputEvent) -> void:
	# `_input` fires before Control's `_gui_input` dispatch, so we can
	# intercept Ctrl+V before TextEdit's native paste runs. That matters:
	# if we reacted on `_gui_input` / the `gui_input` signal instead,
	# TextEdit would have already pasted (empty string or garbage) from
	# the image-bearing clipboard by the time we saw the event.
	if not has_focus():
		return
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	# Enter → submit. Shift/Alt+Enter → newline (let TextEdit handle it).
	# Ctrl+Enter also submits (common alternate binding in chat UIs for
	# users who got used to it elsewhere). KEY_KP_ENTER covers numpad.
	if key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
		if key_event.shift_pressed or key_event.alt_pressed:
			return
		emit_signal("submit_requested")
		get_viewport().set_input_as_handled()
		return

	if not (key_event.ctrl_pressed or key_event.meta_pressed):
		return
	if key_event.keycode != KEY_V:
		return
	if not DisplayServer.clipboard_has_image():
		return
	var image: Image = DisplayServer.clipboard_get_image()
	if image == null or image.is_empty():
		return
	emit_signal("image_pasted", image)
	# Mark handled so the event never reaches TextEdit's internal paste.
	get_viewport().set_input_as_handled()
