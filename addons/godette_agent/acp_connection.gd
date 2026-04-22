@tool
extends Node

signal initialized(agent_id: String, result: Dictionary)
signal session_created(agent_id: String, local_session_id: String, remote_session_id: String, result: Dictionary)
signal session_loaded(agent_id: String, local_session_id: String, remote_session_id: String, result: Dictionary)
signal session_load_failed(agent_id: String, local_session_id: String, remote_session_id: String, error_code: int, error_message: String)
signal session_create_failed(agent_id: String, local_session_id: String, error_code: int, error_message: String)
signal sessions_listed(agent_id: String, sessions: Array, next_cursor: String)
signal session_update(agent_id: String, remote_session_id: String, update: Dictionary)
signal prompt_finished(agent_id: String, remote_session_id: String, result: Dictionary)
signal session_mode_changed(agent_id: String, remote_session_id: String, mode_id: String)
signal session_model_changed(agent_id: String, remote_session_id: String, model_id: String)
signal session_config_options_changed(agent_id: String, remote_session_id: String, config_options: Array)
signal permission_requested(agent_id: String, request_id: int, params: Dictionary)
signal transport_status(agent_id: String, status: String)
signal protocol_error(agent_id: String, message: String)
signal stderr_output(agent_id: String, line: String)

const JSONRPC_VERSION := "2.0"
const PROTOCOL_VERSION := 1
const READ_CHUNK_BYTES := 4096
# Cap messages dispatched per frame so a session/load replay burst (hundreds
# of notifications back-to-back) spreads across frames instead of freezing
# the main thread. Remaining bytes stay buffered and are processed on the
# next _process tick.
const MAX_MESSAGES_PER_FRAME := 32

var agent_id := ""
var pid := -1
var stdio_pipe: FileAccess
var stderr_pipe: FileAccess
# Raw byte buffers — decode to String only on complete \n-delimited records
# so multi-byte UTF-8 sequences (e.g. CJK in tool output) never get cut by a
# chunk boundary.
var stdout_bytes: PackedByteArray = PackedByteArray()
var stderr_bytes: PackedByteArray = PackedByteArray()
var next_request_id := 1
var pending_requests := {}
var pending_session_creates := {}
var pending_session_loads := {}
var pending_session_lists := {}
var pending_prompts := {}
var pending_mode_changes := {}
var pending_model_changes := {}
var pending_config_changes := {}
var is_ready := false


func start(p_agent_id: String, launch_candidates: Array) -> bool:
	shutdown()
	agent_id = p_agent_id

	for candidate in launch_candidates:
		var path: String = str(candidate.get("path", ""))
		var args_variant = candidate.get("args", PackedStringArray())
		var args: PackedStringArray = PackedStringArray(args_variant)
		var result: Dictionary = OS.execute_with_pipe(path, args, false)
		if result.is_empty():
			continue

		pid = int(result.get("pid", -1))
		stdio_pipe = result.get("stdio", null)
		stderr_pipe = result.get("stderr", null)
		stdout_bytes = PackedByteArray()
		stderr_bytes = PackedByteArray()
		next_request_id = 1
		pending_requests.clear()
		pending_session_creates.clear()
		pending_session_loads.clear()
		pending_session_lists.clear()
		pending_prompts.clear()
		pending_mode_changes.clear()
		pending_model_changes.clear()
		pending_config_changes.clear()
		is_ready = false
		set_process(true)
		emit_signal("transport_status", agent_id, "starting")
		_send_request("initialize", {
			"protocolVersion": PROTOCOL_VERSION,
			"clientCapabilities": {}
		})
		return true

	emit_signal("transport_status", agent_id, "offline")
	emit_signal("protocol_error", agent_id, "Unable to launch ACP adapter for %s." % agent_id)
	return false


func create_session(local_session_id: String, cwd: String) -> int:
	var request_id: int = _send_request("session/new", {
		"cwd": cwd,
		"mcpServers": []
	})
	if request_id > 0:
		pending_session_creates[request_id] = local_session_id
	return request_id


func load_session(local_session_id: String, remote_session_id: String, cwd: String) -> int:
	var request_id: int = _send_request("session/load", {
		"sessionId": remote_session_id,
		"cwd": cwd,
		"mcpServers": []
	})
	if request_id > 0:
		pending_session_loads[request_id] = {
			"local_session_id": local_session_id,
			"remote_session_id": remote_session_id
		}
	return request_id


func list_sessions(cwd: String = "", cursor: String = "") -> int:
	var params: Dictionary = {}
	if not cwd.is_empty():
		params["cwd"] = cwd
	if not cursor.is_empty():
		params["cursor"] = cursor
	var request_id: int = _send_request("session/list", params)
	if request_id > 0:
		pending_session_lists[request_id] = true
	return request_id


func prompt(remote_session_id: String, prompt_blocks: Array) -> int:
	var request_id: int = _send_request("session/prompt", {
		"sessionId": remote_session_id,
		"prompt": prompt_blocks
	})
	if request_id > 0:
		pending_prompts[request_id] = remote_session_id
	return request_id


func cancel_session(remote_session_id: String) -> void:
	if stdio_pipe == null or remote_session_id.is_empty():
		return

	_send_message({
		"jsonrpc": JSONRPC_VERSION,
		"method": "session/cancel",
		"params": {
			"sessionId": remote_session_id
		}
	})


func set_session_mode(remote_session_id: String, mode_id: String) -> int:
	var request_id: int = _send_request("session/set_mode", {
		"sessionId": remote_session_id,
		"modeId": mode_id
	})
	if request_id > 0:
		pending_mode_changes[request_id] = {
			"session_id": remote_session_id,
			"mode_id": mode_id
		}
	return request_id


func set_session_model(remote_session_id: String, model_id: String) -> int:
	var request_id: int = _send_request("session/set_model", {
		"sessionId": remote_session_id,
		"modelId": model_id
	})
	if request_id > 0:
		pending_model_changes[request_id] = {
			"session_id": remote_session_id,
			"model_id": model_id
		}
	return request_id


func set_session_config_option(remote_session_id: String, config_id: String, value: String) -> int:
	var request_id: int = _send_request("session/set_config_option", {
		"sessionId": remote_session_id,
		"configId": config_id,
		"value": value
	})
	if request_id > 0:
		pending_config_changes[request_id] = {
			"session_id": remote_session_id,
			"config_id": config_id
		}
	return request_id


func reply_permission(request_id: int, outcome: Dictionary) -> void:
	_send_message({
		"jsonrpc": JSONRPC_VERSION,
		"id": request_id,
		"result": {
			"outcome": outcome
		}
	})


func shutdown() -> void:
	set_process(false)

	if stdio_pipe != null:
		stdio_pipe.close()
	if stderr_pipe != null:
		stderr_pipe.close()

	stdio_pipe = null
	stderr_pipe = null
	stdout_bytes = PackedByteArray()
	stderr_bytes = PackedByteArray()
	pending_requests.clear()
	pending_session_creates.clear()
	pending_session_loads.clear()
	pending_session_lists.clear()
	pending_prompts.clear()
	pending_mode_changes.clear()
	pending_model_changes.clear()
	pending_config_changes.clear()
	is_ready = false

	if pid > 0:
		OS.kill(pid)
	pid = -1


func _process(_delta: float) -> void:
	_pump_stdout()
	_pump_stderr()


func _pump_stdout() -> void:
	if stdio_pipe == null:
		return

	while true:
		var chunk: PackedByteArray = stdio_pipe.get_buffer(READ_CHUNK_BYTES)
		if chunk.is_empty():
			break
		stdout_bytes.append_array(chunk)

	var processed: int = 0
	while processed < MAX_MESSAGES_PER_FRAME:
		var nl_index: int = stdout_bytes.find(0x0A)
		if nl_index < 0:
			break
		var line_bytes: PackedByteArray = stdout_bytes.slice(0, nl_index)
		stdout_bytes = stdout_bytes.slice(nl_index + 1)
		var raw_line: String = _decode_line_bytes(line_bytes).strip_edges()
		if not raw_line.is_empty():
			_handle_message(raw_line)
			processed += 1


func _pump_stderr() -> void:
	if stderr_pipe == null:
		return

	while true:
		var chunk: PackedByteArray = stderr_pipe.get_buffer(READ_CHUNK_BYTES)
		if chunk.is_empty():
			break
		stderr_bytes.append_array(chunk)

	while true:
		var nl_index: int = stderr_bytes.find(0x0A)
		if nl_index < 0:
			break
		var line_bytes: PackedByteArray = stderr_bytes.slice(0, nl_index)
		stderr_bytes = stderr_bytes.slice(nl_index + 1)
		var raw_line: String = _decode_line_bytes(line_bytes).strip_edges()
		if not raw_line.is_empty():
			emit_signal("stderr_output", agent_id, raw_line)


func _sanitize_nul_in_place(value: Variant) -> void:
	_sanitize_nul_in_place_static(value)


static func _sanitize_nul_in_place_static(value: Variant) -> void:
	# Walks a JSON-decoded structure (Dictionary / Array / String leaves) and
	# strips any embedded NUL codepoints from String values. Mutates in
	# place so downstream signal handlers receive the clean Dictionary.
	if typeof(value) == TYPE_DICTIONARY:
		var dict: Dictionary = value
		for key in dict.keys():
			var child: Variant = dict[key]
			var child_type: int = typeof(child)
			if child_type == TYPE_STRING:
				dict[key] = _strip_nul_chars(child)
			elif child_type == TYPE_DICTIONARY or child_type == TYPE_ARRAY:
				_sanitize_nul_in_place_static(child)
	elif typeof(value) == TYPE_ARRAY:
		var arr: Array = value
		for i in range(arr.size()):
			var child: Variant = arr[i]
			var child_type: int = typeof(child)
			if child_type == TYPE_STRING:
				arr[i] = _strip_nul_chars(child)
			elif child_type == TYPE_DICTIONARY or child_type == TYPE_ARRAY:
				_sanitize_nul_in_place_static(child)


static func _strip_nul_chars(s: String) -> String:
	# Character-level NUL strip. Godot's String.contains / String.replace
	# occasionally fail to match embedded U+0000 depending on which internal
	# code path is used; iterating codepoints and rebuilding is slow but
	# unambiguously correct. Fast-paths the common "no NUL" case first.
	if s.is_empty():
		return s
	var length: int = s.length()
	var first_nul: int = -1
	for i in range(length):
		if s.unicode_at(i) == 0:
			first_nul = i
			break
	if first_nul < 0:
		return s
	var out := s.substr(0, first_nul)
	for i in range(first_nul + 1, length):
		var cp: int = s.unicode_at(i)
		if cp != 0:
			out += String.chr(cp)
	return out


func _decode_line_bytes(line_bytes: PackedByteArray) -> String:
	# Decodes a complete \n-delimited record. Two defensive passes:
	# 1. Strip embedded NULs — Godot's String is null-terminated, and some
	#    npx wrappers / Windows terminal shims inject NUL resets into the
	#    stream that would otherwise truncate the decoded String.
	# 2. UTF-8 decode on the whole line at once, so multi-byte sequences
	#    (CJK, emoji) are never split mid-glyph by pipe chunk boundaries.
	var has_null: bool = false
	for byte_value in line_bytes:
		if byte_value == 0:
			has_null = true
			break
	if not has_null:
		return line_bytes.get_string_from_utf8()
	var filtered := PackedByteArray()
	filtered.resize(line_bytes.size())
	var write_index: int = 0
	for byte_value in line_bytes:
		if byte_value == 0:
			continue
		filtered[write_index] = byte_value
		write_index += 1
	filtered.resize(write_index)
	return filtered.get_string_from_utf8()


func _handle_message(raw_line: String) -> void:
	var parsed = JSON.parse_string(raw_line)
	if typeof(parsed) != TYPE_DICTIONARY:
		emit_signal("protocol_error", agent_id, "ACP transport emitted non-JSON output.")
		return

	# Codex / Claude occasionally serialize tool output containing literal
	# `\u0000` escapes. After JSON decode those become real NUL codepoints
	# inside the resulting Strings. Any downstream UI that hands those
	# Strings to parse_utf8 (Label, Button, TextParagraph, etc.) logs a
	# "Unexpected NUL character" warning on every redraw pass — flooding
	# the console with tens of thousands of errors. Sanitize at the
	# transport boundary so no UI path ever sees a NUL.
	_sanitize_nul_in_place(parsed)
	var message: Dictionary = parsed
	var has_id: bool = message.has("id")
	var has_method: bool = message.has("method")

	if has_method and has_id:
		_handle_request(message)
		return

	if has_method:
		_handle_notification(message)
		return

	if has_id:
		_handle_response(message)
		return

	emit_signal("protocol_error", agent_id, "Received malformed ACP message.")


func _handle_request(message: Dictionary) -> void:
	var request_id: int = int(message.get("id", -1))
	var method: String = str(message.get("method", ""))
	var params: Dictionary = message.get("params", {})

	if method == "session/request_permission":
		emit_signal("permission_requested", agent_id, request_id, params)
		return

	_send_error(request_id, -32601, "Method not found: %s" % method)


func _handle_notification(message: Dictionary) -> void:
	var method: String = str(message.get("method", ""))
	var params: Dictionary = message.get("params", {})

	if method == "session/update":
		var remote_session_id: String = str(params.get("sessionId", ""))
		var update: Dictionary = params.get("update", {})
		emit_signal("session_update", agent_id, remote_session_id, update)


func _handle_response(message: Dictionary) -> void:
	var request_id: int = int(message.get("id", -1))
	var method: String = str(pending_requests.get(request_id, ""))
	pending_requests.erase(request_id)

	if message.has("error"):
		var error_payload: Dictionary = message.get("error", {})
		var error_message: String = str(error_payload.get("message", "Unknown ACP error"))
		var error_code: int = int(error_payload.get("code", 0))

		if method == "session/load" and pending_session_loads.has(request_id):
			var load_state: Dictionary = pending_session_loads.get(request_id, {})
			emit_signal(
				"session_load_failed",
				agent_id,
				str(load_state.get("local_session_id", "")),
				str(load_state.get("remote_session_id", "")),
				error_code,
				error_message
			)
		elif method == "session/new" and pending_session_creates.has(request_id):
			var local_session_id_for_create: String = str(pending_session_creates.get(request_id, ""))
			emit_signal(
				"session_create_failed",
				agent_id,
				local_session_id_for_create,
				error_code,
				error_message
			)

		pending_session_creates.erase(request_id)
		pending_session_loads.erase(request_id)
		pending_session_lists.erase(request_id)
		pending_prompts.erase(request_id)
		pending_mode_changes.erase(request_id)
		pending_model_changes.erase(request_id)
		pending_config_changes.erase(request_id)
		emit_signal("protocol_error", agent_id, "%s failed: %s" % [method, error_message])
		if method == "initialize":
			emit_signal("transport_status", agent_id, "error")
		return

	var result: Dictionary = message.get("result", {})
	match method:
		"initialize":
			is_ready = true
			emit_signal("initialized", agent_id, result)
			emit_signal("transport_status", agent_id, "ready")
		"session/new":
			var local_session_id: String = str(pending_session_creates.get(request_id, ""))
			pending_session_creates.erase(request_id)
			emit_signal("session_created", agent_id, local_session_id, str(result.get("sessionId", "")), result)
		"session/load":
			var load_state: Dictionary = pending_session_loads.get(request_id, {})
			pending_session_loads.erase(request_id)
			emit_signal(
				"session_loaded",
				agent_id,
				str(load_state.get("local_session_id", "")),
				str(load_state.get("remote_session_id", "")),
				result
			)
		"session/list":
			pending_session_lists.erase(request_id)
			emit_signal("sessions_listed", agent_id, result.get("sessions", []), str(result.get("nextCursor", "")))
		"session/prompt":
			var remote_session_id: String = str(pending_prompts.get(request_id, ""))
			pending_prompts.erase(request_id)
			emit_signal("prompt_finished", agent_id, remote_session_id, result)
		"session/set_mode":
			var mode_change: Dictionary = pending_mode_changes.get(request_id, {})
			pending_mode_changes.erase(request_id)
			emit_signal("session_mode_changed", agent_id, str(mode_change.get("session_id", "")), str(mode_change.get("mode_id", "")))
		"session/set_model":
			var model_change: Dictionary = pending_model_changes.get(request_id, {})
			pending_model_changes.erase(request_id)
			emit_signal("session_model_changed", agent_id, str(model_change.get("session_id", "")), str(model_change.get("model_id", "")))
		"session/set_config_option":
			var config_change: Dictionary = pending_config_changes.get(request_id, {})
			pending_config_changes.erase(request_id)
			emit_signal("session_config_options_changed", agent_id, str(config_change.get("session_id", "")), result.get("configOptions", []))


func _send_request(method: String, params: Dictionary) -> int:
	if stdio_pipe == null:
		return -1

	var request_id: int = next_request_id
	next_request_id += 1
	pending_requests[request_id] = method
	_send_message({
		"jsonrpc": JSONRPC_VERSION,
		"id": request_id,
		"method": method,
		"params": params
	})
	return request_id


func _send_error(request_id: int, code: int, message: String) -> void:
	_send_message({
		"jsonrpc": JSONRPC_VERSION,
		"id": request_id,
		"error": {
			"code": code,
			"message": message
		}
	})


func _send_message(payload: Dictionary) -> void:
	if stdio_pipe == null:
		return

	stdio_pipe.store_string(JSON.stringify(payload) + "\n")
	stdio_pipe.flush()
