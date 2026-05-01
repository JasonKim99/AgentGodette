@tool
class_name GodetteState
extends Node

# Single source of truth for everything that lives "above" any one view.
# AgentDock and AgentMainScreen each hold a reference to ONE shared
# GodetteState; all writes to session data, ACP connections, plan entries,
# tool calls, etc. go through the methods on this class. The matching
# signals fire after every write so views can refresh their UI without
# polling.
#
# Surface mutual exclusion: each registered surface (e.g. "dock", "main")
# may "claim" one session at a time. A session claimed by surface A
# cannot be selected or deleted from surface B's session menu. This is
# enforced by `set_current_session_for_surface` and `remove_session`.

const SessionStoreScript = preload("res://addons/godette_agent/session_store.gd")
const ACPConnectionScript = preload("res://addons/godette_agent/acp_connection.gd")

const DEFAULT_AGENT_ID := "claude_agent"
const SESSION_PERSIST_DEBOUNCE_SEC := 0.4


# ---------------------------------------------------------------------------
# Shared state — read access is direct (`state.sessions[i]["foo"]`), but all
# writes MUST go through the setter / mutator methods below. External code
# treating these arrays / dicts as mutable will silently break the signal
# contract that views rely on.
# ---------------------------------------------------------------------------

var sessions: Array = []
var next_session_number: int = 1
var selected_agent_id: String = DEFAULT_AGENT_ID

# Global cumulative token counters since the user first installed
# Godette. Persisted in the same index file as `next_session_number`,
# so they survive editor restarts. Per-message breakdowns live on the
# session itself (transcript / tool calls); these four are just the
# running totals across every session, every agent, every model.
var total_input_tokens: int = 0
var total_output_tokens: int = 0
var total_cache_creation_tokens: int = 0  # Claude prompt-cache writes
var total_cache_read_tokens: int = 0      # Claude prompt-cache hits
# Codex-acp's token wire only carries one undifferentiated `used`
# number per session/update notification — no input/output/cache
# breakdown. Tracked in its own bucket so it doesn't muddy the Claude
# counters (those drive the widget's hot/cold colour blend, which is a
# cache-read ratio that only makes sense for Claude). The widget sums
# all five buckets when rendering the total so the user still sees one
# combined "tokens consumed" figure.
var total_codex_tokens: int = 0

# Per-session "last seen `used` value" from codex-acp's session/update
# usage_update notification. Codex reports CUMULATIVE session tokens (not
# per-turn delta), so we diff against this snapshot to extract the delta
# we should add to the global counter. Keyed by remote session id; not
# persisted (a fresh editor launch starts each Codex session over from
# scratch on its end too, since codex-acp doesn't restore prior context).
var _codex_session_used_snapshots: Dictionary = {}

var connections: Dictionary = {}                 # agent_id -> ACPConnection
var connection_status: Dictionary = {}           # agent_id -> "connecting" / "ready" / etc.
var pending_remote_sessions: Dictionary = {}     # agent_id -> [local_session_id, ...]
var pending_remote_session_loads: Dictionary = {}# agent_id -> [(local_id, remote_id), ...]
var pending_permissions: Dictionary = {}         # request_id -> {agent, session, params}
var replaying_sessions: Dictionary = {}          # "agent|remote_id" -> true
var startup_discovery_agents: Dictionary = {}    # agent_id -> bool
var agent_icon_cache: Dictionary = {}            # "agent_id|size" -> Texture2D

# Session-level visual preferences (shared across surfaces — at most one
# surface views a given session at a time, see surface claims below).
var expanded_tool_calls: Dictionary = {}
var expanded_thinking_blocks: Dictionary = {}
var user_toggled_thinking_blocks: Dictionary = {}
var auto_expanded_thinking_block: Dictionary = {}
var plan_dismissed_sessions: Dictionary = {}

# Surface claims: surface_id ("dock" / "main") -> session id (the
# stable per-thread "id" field stored in each session dict, NOT the
# index — indices shift when sessions are deleted).
# `set_current_session_for_surface` enforces uniqueness across surfaces.
var _surface_claims: Dictionary = {}

# Editor / persistence helpers.
var editor_interface: EditorInterface
var _persist_timer: Timer
var _persist_dirty: bool = false
var _managed_attachment_cleanup_pending: bool = false
var _editor_fs_scan_pending: bool = false


# ---------------------------------------------------------------------------
# Signals — every write that mutates a session's content fires one of
# these so views can incrementally refresh. Use the *narrowest* signal
# that covers the change: an `entry_appended` is cheaper for views to
# react to than a blanket `sessions_changed` rebuild.
# ---------------------------------------------------------------------------

signal sessions_changed                                                  # bulk replace (restore from disk, etc.)
signal session_added(idx: int)
signal session_removed(idx: int)
signal session_renamed(idx: int)
signal session_busy_changed(idx: int, busy: bool)
signal session_remote_attached(idx: int)                                 # remote_session_id assigned
signal session_models_changed(idx: int)
signal session_modes_changed(idx: int)
signal session_config_options_changed(idx: int)
signal session_current_model_changed(idx: int)
signal session_current_mode_changed(idx: int)
signal session_attachments_changed(idx: int)

signal session_transcript_appended(idx: int, entry_idx: int)             # new entry pushed
signal session_transcript_updated(idx: int, entry_idx: int)              # existing entry mutated (streaming / tool update)
signal session_transcript_chunk_appended(idx: int, entry_idx: int, delta: String)  # streaming fast path
signal session_transcript_cleared(idx: int)

signal session_plan_changed(idx: int)
signal session_tool_call_changed(idx: int, tool_call_id: String)
signal session_queue_changed(idx: int)

signal connection_status_changed(agent_id: String, status: String)
signal permission_requested(request_id: int)
signal permission_resolved(request_id: int)

signal tool_call_expanded_changed(key: String)
signal thinking_block_expanded_changed(key: String)
signal plan_dismissed_changed(scope_key: String)

signal surface_claims_changed                                            # any claim/release
signal total_tokens_changed                                              # global cumulative counters bumped
signal token_pulse_requested                                             # mid-stream usage_update (Balatro pulse trigger)


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


func configure(p_editor_interface: EditorInterface) -> void:
	editor_interface = p_editor_interface


func _ready() -> void:
	_persist_timer = Timer.new()
	_persist_timer.one_shot = true
	_persist_timer.wait_time = SESSION_PERSIST_DEBOUNCE_SEC
	_persist_timer.timeout.connect(_flush_persist_state)
	add_child(_persist_timer)


# ---------------------------------------------------------------------------
# Surface claim API (mutual exclusion)
# ---------------------------------------------------------------------------


# Returns the surface currently viewing `session_id`, or "" if none.
func session_claimed_by(session_id: String) -> String:
	for surface_id in _surface_claims:
		if str(_surface_claims[surface_id]) == session_id:
			return surface_id
	return ""


# True iff `session_id` is claimed by *another* surface (not `surface_id`).
# Used by session menu UI to decide whether to disable a row for this surface.
func is_locked_for(surface_id: String, session_id: String) -> bool:
	var claimer: String = session_claimed_by(session_id)
	return claimer != "" and claimer != surface_id


# Try to switch `surface_id`'s current session to index `idx`. Returns
# false (and does NOT change anything) when another surface already holds
# that session — caller should show a toast / blink UI. Passing idx < 0
# releases the surface's claim.
func set_current_session_for_surface(surface_id: String, idx: int) -> bool:
	if idx < 0:
		release_session_for_surface(surface_id)
		return true
	if idx >= sessions.size():
		return false
	var session: Dictionary = sessions[idx]
	var session_id: String = str(session.get("id", ""))
	if session_id.is_empty():
		return false
	var claimer: String = session_claimed_by(session_id)
	if claimer != "" and claimer != surface_id:
		return false
	_surface_claims[surface_id] = session_id
	surface_claims_changed.emit()
	return true


func release_session_for_surface(surface_id: String) -> void:
	if not _surface_claims.has(surface_id):
		return
	_surface_claims.erase(surface_id)
	surface_claims_changed.emit()


# Index of the session this surface is currently viewing, or -1.
func get_current_session_for_surface(surface_id: String) -> int:
	var session_id: String = str(_surface_claims.get(surface_id, ""))
	if session_id.is_empty():
		return -1
	return find_session_index_by_id(session_id)


# ---------------------------------------------------------------------------
# Lookup helpers (read-only — no signals)
# ---------------------------------------------------------------------------


func find_session_index_by_id(session_id: String) -> int:
	for i in range(sessions.size()):
		if str(sessions[i].get("id", "")) == session_id:
			return i
	return -1


func find_session_index_by_remote(agent_id: String, remote_session_id: String) -> int:
	for i in range(sessions.size()):
		var s: Dictionary = sessions[i]
		if (
			str(s.get("agent_id", "")) == agent_id
			and str(s.get("remote_session_id", "")) == remote_session_id
		):
			return i
	return -1


func find_latest_session_index_by_agent(agent_id: String) -> int:
	# Stub — implementation copies dock's _find_latest_session_index_by_agent.
	push_warning("[GodetteState] find_latest_session_index_by_agent not yet implemented")
	return -1


# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------


func create_session(agent_id: String) -> int:
	# Build a fresh session dict — schema must match what `restore_from_disk`
	# expects so a new thread round-trips through persist/load identically
	# to one that's been around since startup. `next_session_number` is
	# bumped so the next call gets a unique trailing digit.
	var now_msec: int = Time.get_ticks_msec()
	var title: String = "Session %d" % next_session_number
	var session: Dictionary = {
		"id": "session_%d" % next_session_number,
		"title": title,
		"agent_id": agent_id,
		"remote_session_id": "",
		"remote_session_loaded": false,
		"loading_remote_session": false,
		"creating_remote_session": false,
		"attachments": [],
		"managed_attachment_refs": [],
		"transcript": [],
		"assistant_entry_index": -1,
		"thought_entry_index": -1,
		"plan_entries": [],
		"queued_prompts": [],
		"tool_calls": {},
		"available_commands": {},
		"models": [],
		"modes": [],
		"config_options": [],
		"current_model_id": "",
		"current_mode_id": "",
		"cancelling": false,
		"busy": false,
		"hydrated": true,
		"updated_at": now_msec,
		"created_at": now_msec,
	}
	next_session_number += 1
	sessions.append(session)
	var new_idx: int = sessions.size() - 1
	session_added.emit(new_idx)
	schedule_persist()
	return new_idx


func remove_session(idx: int, requesting_surface: String) -> bool:
	if idx < 0 or idx >= sessions.size():
		return false
	var session: Dictionary = sessions[idx]
	var session_id: String = str(session.get("id", ""))
	# Reject if another surface is currently viewing this session — see
	# surface_claims docstring on _surface_claims.
	if is_locked_for(requesting_surface, session_id):
		return false

	# Drop scoped visual-state entries that referenced this session
	# (tool/thinking expand keys, plan-dismissed flag, replay flag).
	# Mirrors what dock used to do inline in `_evict_session`.
	var scope_key: String = "%s|%s" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
	]
	var scope_prefix: String = scope_key + "|"
	_drop_keys_with_prefix(expanded_tool_calls, scope_prefix)
	_drop_keys_with_prefix(expanded_thinking_blocks, scope_prefix)
	_drop_keys_with_prefix(user_toggled_thinking_blocks, scope_prefix)
	auto_expanded_thinking_block.erase(scope_key)
	plan_dismissed_sessions.erase(scope_key)
	replaying_sessions.erase(scope_key)

	# Release any surface that was viewing this session (rare but
	# possible — e.g. a session was force-evicted because the remote
	# adapter said it doesn't exist anymore).
	var keys_to_release: Array = []
	for sid in _surface_claims:
		if str(_surface_claims[sid]) == session_id:
			keys_to_release.append(sid)
	for sid in keys_to_release:
		_surface_claims.erase(sid)
	if not keys_to_release.is_empty():
		surface_claims_changed.emit()

	SessionStoreScript.delete_thread_cache(session_id)
	sessions.remove_at(idx)
	session_removed.emit(idx)
	schedule_persist()
	return true


# Strip every key in `target` whose name begins with `prefix`. Used to
# clear scope-keyed visual-state dicts during session removal.
func _drop_keys_with_prefix(target: Dictionary, prefix: String) -> void:
	var to_drop: Array = []
	for key_variant in target.keys():
		if str(key_variant).begins_with(prefix):
			to_drop.append(key_variant)
	for key_variant in to_drop:
		target.erase(key_variant)


# ---------------------------------------------------------------------------
# Per-session field setters
# ---------------------------------------------------------------------------


func set_session_busy(idx: int, busy: bool) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if bool(s.get("busy", false)) == busy:
		return
	s["busy"] = busy
	sessions[idx] = s
	session_busy_changed.emit(idx, busy)
	schedule_persist()


func set_session_current_model_id(idx: int, model_id: String) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if str(s.get("current_model_id", "")) == model_id:
		return
	s["current_model_id"] = model_id
	sessions[idx] = s
	session_current_model_changed.emit(idx)
	schedule_persist()


func set_session_current_mode_id(idx: int, mode_id: String) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if str(s.get("current_mode_id", "")) == mode_id:
		return
	s["current_mode_id"] = mode_id
	sessions[idx] = s
	session_current_mode_changed.emit(idx)
	schedule_persist()


func set_session_remote_attached(idx: int, agent_id: String, remote_session_id: String) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	var changed: bool = false
	if str(s.get("agent_id", "")) != agent_id:
		s["agent_id"] = agent_id
		changed = true
	if str(s.get("remote_session_id", "")) != remote_session_id:
		s["remote_session_id"] = remote_session_id
		changed = true
	if not bool(s.get("remote_session_loaded", false)):
		s["remote_session_loaded"] = true
		changed = true
	if not changed:
		return
	sessions[idx] = s
	session_remote_attached.emit(idx)
	schedule_persist()


func set_session_remote_loading(idx: int, loading: bool) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if bool(s.get("loading_remote_session", false)) == loading:
		return
	s["loading_remote_session"] = loading
	sessions[idx] = s
	# No dedicated signal — views read "loading" only as part of their
	# composite refresh after `session_remote_attached` / `session_added`.
	# If a future view wants to display a spinner specifically for the
	# loading phase, add a `session_remote_loading_changed` signal here.


func set_session_remote_creating(idx: int, creating: bool) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if bool(s.get("creating_remote_session", false)) == creating:
		return
	s["creating_remote_session"] = creating
	sessions[idx] = s
	# Same rationale as set_session_remote_loading — silent unless a view
	# specifically needs to react to the create-in-flight phase.


func set_session_title(idx: int, title: String) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if str(s.get("title", "")) == title:
		return
	s["title"] = title
	sessions[idx] = s
	session_renamed.emit(idx)
	schedule_persist()


func set_session_models(idx: int, models_variant) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	# Adapters can hand us models as either Array (legacy) or Dictionary
	# ({availableModels, currentModelId}) — `==` between cross-type
	# Variants throws in GDScript 4, so we only compare when the new
	# payload's type matches what's stored.
	var existing = s.get("models", null)
	if typeof(existing) == typeof(models_variant) and existing == models_variant:
		return
	s["models"] = models_variant
	sessions[idx] = s
	session_models_changed.emit(idx)
	schedule_persist()


func set_session_modes(idx: int, modes_variant) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	var existing = s.get("modes", null)
	if typeof(existing) == typeof(modes_variant) and existing == modes_variant:
		return
	s["modes"] = modes_variant
	sessions[idx] = s
	session_modes_changed.emit(idx)
	schedule_persist()


func set_session_config_options(idx: int, options_variant) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	var existing = s.get("config_options", null)
	if typeof(existing) == typeof(options_variant) and existing == options_variant:
		return
	s["config_options"] = options_variant
	sessions[idx] = s
	session_config_options_changed.emit(idx)
	schedule_persist()


func set_session_attachments(idx: int, attachments: Array) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	var existing = s.get("attachments", null)
	if existing is Array and (existing as Array) == attachments:
		return
	s["attachments"] = attachments
	sessions[idx] = s
	session_attachments_changed.emit(idx)
	schedule_persist()


# ---------------------------------------------------------------------------
# Transcript mutators
# ---------------------------------------------------------------------------


# Generic append. Used for system / tool / non-streaming entries — anything
# that doesn't continue an in-flight assistant or thought stream. Resets
# both stream pointers so the next chunk after this lands in a fresh entry.
func append_transcript_entry(idx: int, entry: Dictionary) -> int:
	if idx < 0 or idx >= sessions.size():
		return -1
	var s: Dictionary = sessions[idx]
	var transcript: Array = s.get("transcript", [])
	# Defense in depth: ACP ingress already strips NUL bytes from incoming
	# adapter messages, but we sanitise once more here so any other path
	# (legacy on-disk caches, manual injection from extensions, etc.)
	# can't seed a NUL into the transcript and trip TextServer's
	# "Unexpected NUL character" warnings on every redraw downstream.
	ACPConnectionScript._sanitize_nul_in_place_static(entry)
	transcript.append(entry)
	var new_idx: int = transcript.size() - 1
	s["transcript"] = transcript
	# Any non-assistant / non-thought entry breaks streaming continuity —
	# without this reset, a session/load replay (which doesn't emit
	# prompt_finished between past turns) would keep appending later
	# assistant chunks into the first historical assistant message.
	s["assistant_entry_index"] = -1
	s["thought_entry_index"] = -1
	sessions[idx] = s
	session_transcript_appended.emit(idx, new_idx)
	schedule_persist()
	return new_idx


# Mutates fields on an existing transcript entry (typically tool_call
# updates that flip status / append output / change title). Pass only
# the keys that change in `partial`. No-op when `entry_idx` is out of
# range. Emits `session_transcript_updated` so views can re-render the
# affected row in place.
func update_transcript_entry(idx: int, entry_idx: int, partial: Dictionary) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	var transcript: Array = s.get("transcript", [])
	if entry_idx < 0 or entry_idx >= transcript.size():
		return
	# See `append_transcript_entry` for why we sanitise here.
	ACPConnectionScript._sanitize_nul_in_place_static(partial)
	var entry: Dictionary = transcript[entry_idx]
	for key in partial:
		entry[key] = partial[key]
	transcript[entry_idx] = entry
	s["transcript"] = transcript
	sessions[idx] = s
	session_transcript_updated.emit(idx, entry_idx)
	schedule_persist()


# Streaming fast path for assistant messages. If the current session has
# an in-flight assistant entry (`assistant_entry_index` set + within
# transcript bounds), `text` is appended to its `content`. Otherwise a
# fresh assistant entry is created. Returns `{is_new, entry_index}` so
# the caller can pick the right view-side reaction (full entry build vs
# delta-into-existing-TextBlock).
#
# Emits one of two signals:
#   - `session_transcript_appended` when a new entry was created
#   - `session_transcript_chunk_appended(idx, entry_idx, delta)` for
#     deltas — narrow enough that views can cache the TextBlock by
#     entry_idx and append in O(1).
func append_assistant_chunk(idx: int, text: String, speaker_label: String) -> Dictionary:
	var result := {"is_new": false, "entry_index": -1}
	if idx < 0 or idx >= sessions.size():
		return result
	# See comment in `append_transcript_entry` for why we strip here too.
	text = ACPConnectionScript._strip_nul_chars(text)
	var s: Dictionary = sessions[idx]
	var transcript: Array = s.get("transcript", [])
	var assistant_idx: int = int(s.get("assistant_entry_index", -1))
	var is_new: bool = assistant_idx < 0 or assistant_idx >= transcript.size()
	if is_new:
		transcript.append({
			"kind": "assistant",
			"speaker": speaker_label,
			"content": text,
		})
		assistant_idx = transcript.size() - 1
		s["assistant_entry_index"] = assistant_idx
	else:
		var entry: Dictionary = transcript[assistant_idx]
		entry["content"] = str(entry.get("content", "")) + text
		transcript[assistant_idx] = entry
	# A normal assistant chunk ends any in-flight thought streaming
	# segment. The next thought chunk after this will create a fresh
	# entry rather than appending to the previous one.
	s["thought_entry_index"] = -1
	s["transcript"] = transcript
	sessions[idx] = s
	if is_new:
		session_transcript_appended.emit(idx, assistant_idx)
	else:
		session_transcript_chunk_appended.emit(idx, assistant_idx, text)
	schedule_persist()
	result["is_new"] = is_new
	result["entry_index"] = assistant_idx
	return result


# Streaming fast path for thought ("thinking") segments. Mirrors
# `append_assistant_chunk` but on `thought_entry_index`. A thought chunk
# interrupts any in-flight assistant message (the next assistant chunk
# will create a fresh entry).
func append_thought_chunk(idx: int, text: String, speaker_label: String) -> Dictionary:
	var result := {"is_new": false, "entry_index": -1}
	if idx < 0 or idx >= sessions.size():
		return result
	text = ACPConnectionScript._strip_nul_chars(text)
	var s: Dictionary = sessions[idx]
	var transcript: Array = s.get("transcript", [])
	var thought_idx: int = int(s.get("thought_entry_index", -1))
	var is_new: bool = thought_idx < 0 or thought_idx >= transcript.size()
	if is_new:
		transcript.append({
			"kind": "thought",
			"speaker": speaker_label,
			"content": text,
		})
		thought_idx = transcript.size() - 1
		s["thought_entry_index"] = thought_idx
	else:
		var entry: Dictionary = transcript[thought_idx]
		entry["content"] = str(entry.get("content", "")) + text
		transcript[thought_idx] = entry
	s["assistant_entry_index"] = -1
	s["transcript"] = transcript
	sessions[idx] = s
	if is_new:
		session_transcript_appended.emit(idx, thought_idx)
	else:
		session_transcript_chunk_appended.emit(idx, thought_idx, text)
	schedule_persist()
	result["is_new"] = is_new
	result["entry_index"] = thought_idx
	return result


func clear_transcript(idx: int) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if (s.get("transcript", []) as Array).is_empty():
		return
	s["transcript"] = []
	s["assistant_entry_index"] = -1
	s["thought_entry_index"] = -1
	sessions[idx] = s
	session_transcript_cleared.emit(idx)
	schedule_persist()


# Closes any in-flight assistant streaming so the next chunk starts a
# fresh entry (mirrors what `_on_connection_prompt_finished` does on the
# data side — flips the assistant_entry_index back to -1).
func mark_assistant_entry_finished(idx: int, entry_idx: int) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if int(s.get("assistant_entry_index", -1)) != entry_idx:
		return
	s["assistant_entry_index"] = -1
	sessions[idx] = s
	# No signal — view layer reacts to the matching session_busy_changed
	# (false) which always fires next from `_on_connection_prompt_finished`.


# ---------------------------------------------------------------------------
# Plan / tool calls / queue
# ---------------------------------------------------------------------------


# Replace the session's plan_entries with a normalized list. Caller is
# responsible for normalising each entry (content / status / priority)
# before passing in — keeps state schema-agnostic about plan content.
# Side effect: clears the "plan dismissed" flag for this session, so a
# fresh plan update from the agent re-surfaces the drawer even if the
# user × closed the previous plan.
func replace_plan(idx: int, entries: Array) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	s["plan_entries"] = entries
	sessions[idx] = s
	var scope_key: String = "%s|%s" % [
		str(s.get("agent_id", DEFAULT_AGENT_ID)),
		str(s.get("remote_session_id", "")),
	]
	if plan_dismissed_sessions.has(scope_key):
		plan_dismissed_sessions.erase(scope_key)
		plan_dismissed_changed.emit(scope_key)
	session_plan_changed.emit(idx)
	schedule_persist()


func clear_plan(idx: int) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if (s.get("plan_entries", []) as Array).is_empty():
		return
	s["plan_entries"] = []
	sessions[idx] = s
	session_plan_changed.emit(idx)
	schedule_persist()


# Insert / update a tool_call's entry. Caller must pre-format the
# transcript-entry dict (display title / summary / content string). State
# stores the per-call meta (`tool_calls[id]`) and either appends a fresh
# transcript entry or patches the one previously emitted for this id.
# Returns `{is_new, transcript_index}` so the caller can pick the right
# view-side reaction (build vs update).
func upsert_tool_call(
	idx: int,
	tool_call_id: String,
	tool_state: Dictionary,
	transcript_entry: Dictionary
) -> Dictionary:
	var result := {"is_new": false, "transcript_index": -1}
	if idx < 0 or idx >= sessions.size():
		return result
	if tool_call_id.is_empty():
		return result
	# Tool output / titles can contain literal NULs from `cat` of binary
	# files, malformed terminal output, etc. Sanitise both the entry that
	# will live in the transcript and the meta we cache on `tool_calls`.
	ACPConnectionScript._sanitize_nul_in_place_static(transcript_entry)
	ACPConnectionScript._sanitize_nul_in_place_static(tool_state)
	var s: Dictionary = sessions[idx]
	var transcript: Array = s.get("transcript", [])
	var tool_calls: Dictionary = s.get("tool_calls", {})
	var existing_state: Dictionary = tool_calls.get(tool_call_id, {})
	var transcript_idx: int = int(existing_state.get("transcript_index", -1))
	var is_new: bool = transcript_idx < 0 or transcript_idx >= transcript.size()
	if is_new:
		transcript.append(transcript_entry)
		transcript_idx = transcript.size() - 1
		tool_state["transcript_index"] = transcript_idx
		# A fresh tool_call breaks any in-flight assistant / thought
		# stream — next chunk creates a new entry.
		s["assistant_entry_index"] = -1
		s["thought_entry_index"] = -1
	else:
		var stored_idx: int = int(existing_state.get("transcript_index", transcript_idx))
		tool_state["transcript_index"] = stored_idx
		transcript[transcript_idx] = transcript_entry
	tool_calls[tool_call_id] = tool_state
	s["tool_calls"] = tool_calls
	s["transcript"] = transcript
	sessions[idx] = s
	if is_new:
		session_transcript_appended.emit(idx, transcript_idx)
	else:
		session_transcript_updated.emit(idx, transcript_idx)
	session_tool_call_changed.emit(idx, tool_call_id)
	schedule_persist()
	result["is_new"] = is_new
	result["transcript_index"] = transcript_idx
	return result


# Append `entry` to a session's queued_prompts. Returns the new queue
# slot's index (always size-1). Emits `session_queue_changed` so views
# can refresh their queue drawer.
func append_queue_entry(idx: int, entry: Dictionary) -> int:
	if idx < 0 or idx >= sessions.size():
		return -1
	var s: Dictionary = sessions[idx]
	var queue: Array = s.get("queued_prompts", [])
	queue.append(entry)
	var new_slot: int = queue.size() - 1
	s["queued_prompts"] = queue
	sessions[idx] = s
	session_queue_changed.emit(idx)
	schedule_persist()
	return new_slot


# Remove the queue entry at `queue_idx` and return it. Returns null when
# index is out of range. Used by Send Now / Edit / Delete buttons in the
# queue drawer.
func remove_queue_entry(idx: int, queue_idx: int):
	if idx < 0 or idx >= sessions.size():
		return null
	var s: Dictionary = sessions[idx]
	var queue: Array = s.get("queued_prompts", [])
	if queue_idx < 0 or queue_idx >= queue.size():
		return null
	var entry = queue[queue_idx]
	queue.remove_at(queue_idx)
	s["queued_prompts"] = queue
	sessions[idx] = s
	session_queue_changed.emit(idx)
	schedule_persist()
	return entry


# Pop the head entry from the queue and return it (null when empty).
# Used by `_dispatch_next_prompt` after a turn finishes.
func pop_queue_front(idx: int):
	if idx < 0 or idx >= sessions.size():
		return null
	var s: Dictionary = sessions[idx]
	var queue: Array = s.get("queued_prompts", [])
	if queue.is_empty():
		return null
	var entry = queue.pop_front()
	s["queued_prompts"] = queue
	sessions[idx] = s
	session_queue_changed.emit(idx)
	schedule_persist()
	return entry


# Push an entry onto the FRONT of the queue (used when dispatch fails
# and we have to put the prompt back).
func push_queue_front(idx: int, entry: Dictionary) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	var queue: Array = s.get("queued_prompts", [])
	queue.push_front(entry)
	s["queued_prompts"] = queue
	sessions[idx] = s
	session_queue_changed.emit(idx)
	schedule_persist()


# Move the entry at `from_idx` to `to_idx`. Used by Send Now to bring a
# queued message to the head before dispatching.
func move_queue_entry(idx: int, from_idx: int, to_idx: int) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	var queue: Array = s.get("queued_prompts", [])
	if from_idx < 0 or from_idx >= queue.size():
		return
	if to_idx < 0 or to_idx >= queue.size():
		return
	if from_idx == to_idx:
		return
	var entry = queue[from_idx]
	queue.remove_at(from_idx)
	queue.insert(to_idx, entry)
	s["queued_prompts"] = queue
	sessions[idx] = s
	session_queue_changed.emit(idx)
	schedule_persist()


func clear_queue(idx: int) -> void:
	if idx < 0 or idx >= sessions.size():
		return
	var s: Dictionary = sessions[idx]
	if (s.get("queued_prompts", []) as Array).is_empty():
		return
	s["queued_prompts"] = []
	sessions[idx] = s
	session_queue_changed.emit(idx)
	schedule_persist()


# ---------------------------------------------------------------------------
# Visual preference toggles (session-keyed)
# ---------------------------------------------------------------------------


func set_tool_call_expanded(key: String, expanded: bool) -> void:
	if expanded:
		expanded_tool_calls[key] = true
	else:
		expanded_tool_calls.erase(key)
	tool_call_expanded_changed.emit(key)


func is_tool_call_expanded(key: String) -> bool:
	return expanded_tool_calls.get(key, false)


func set_thinking_block_expanded(key: String, expanded: bool, user_initiated: bool = true) -> void:
	if expanded:
		expanded_thinking_blocks[key] = true
	else:
		expanded_thinking_blocks.erase(key)
	if user_initiated:
		user_toggled_thinking_blocks[key] = true
	thinking_block_expanded_changed.emit(key)


func is_thinking_block_expanded(key: String) -> bool:
	return expanded_thinking_blocks.get(key, false)


func mark_plan_dismissed(scope_key: String, dismissed: bool) -> void:
	if dismissed:
		plan_dismissed_sessions[scope_key] = true
	else:
		plan_dismissed_sessions.erase(scope_key)
	plan_dismissed_changed.emit(scope_key)


func is_plan_dismissed(scope_key: String) -> bool:
	return plan_dismissed_sessions.get(scope_key, false)


# ---------------------------------------------------------------------------
# Token usage (global cumulative)
# ---------------------------------------------------------------------------


# Add the deltas from a single ACP turn's usage payload to the global
# counters. Field names vary by adapter:
#   - claude-agent-acp: inputTokens / outputTokens /
#     cachedWriteTokens / cachedReadTokens / totalTokens (camelCase)
#   - codex-acp: usage shape unknown for now — falls back to
#     OpenAI's prompt_tokens / completion_tokens snake_case
#   - Anthropic raw API: input_tokens / cache_*_input_tokens /
#     output_tokens (snake_case, in case some path passes raw)
# Unknown fields are ignored; missing fields count as 0. Persisted on
# the next debounce tick along with the rest of the index file.
func record_token_usage(usage: Dictionary) -> void:
	if usage.is_empty():
		return
	var d_input: int = int(usage.get(
		"inputTokens",
		usage.get("input_tokens", usage.get("prompt_tokens", 0))
	))
	var d_output: int = int(usage.get(
		"outputTokens",
		usage.get("output_tokens", usage.get("completion_tokens", 0))
	))
	var d_cache_create: int = int(usage.get(
		"cachedWriteTokens",
		usage.get("cache_creation_input_tokens", 0)
	))
	var d_cache_read: int = int(usage.get(
		"cachedReadTokens",
		usage.get("cache_read_input_tokens", 0)
	))
	if d_input <= 0 and d_output <= 0 and d_cache_create <= 0 and d_cache_read <= 0:
		return
	total_input_tokens += max(0, d_input)
	total_output_tokens += max(0, d_output)
	total_cache_creation_tokens += max(0, d_cache_create)
	total_cache_read_tokens += max(0, d_cache_read)
	total_tokens_changed.emit()
	# Token totals file is ~150 bytes — flush immediately rather than
	# go through the session-index debounce. Decouples from streaming-
	# gated persistence (which holds the index write off until busy
	# clears) so a single turn's tokens land on disk right when the
	# turn ends, regardless of what other sessions are doing.
	_persist_token_totals()


# All ACP adapters that report cumulative session token usage via
# `session/update` `usage_update` notifications funnel into this same
# delta-accumulator. Both Claude (each Anthropic API `message_delta`)
# and Codex (each `TokenCountEvent`) emit cumulative session `used`
# counts mid-turn — diffing against the per-session snapshot recovers
# the increment and lets the widget number grow in real-time as the
# agent generates, matching what the official CLI shows.
#
# We accumulate into `total_codex_tokens` purely for naming inertia —
# the bucket is now adapter-agnostic, but renaming would force a
# persistence migration. Treat the field as "real-time `used`-derived
# tokens from any adapter".
#
# Snapshot keyed by `adapter|session_id` so two adapters opening
# overlapping sessions don't collide.
func record_session_token_snapshot(adapter_id: String, remote_session_id: String, used: int) -> void:
	if used < 0:
		return
	var key: String = adapter_id + "|" + remote_session_id
	var prev_used: int = int(_codex_session_used_snapshots.get(key, 0))
	# `used` resets to 0 after a `/compact` style session reset — treat
	# negative delta as "nothing to add" so the global counter doesn't
	# silently roll back.
	var delta: int = max(0, used - prev_used)
	_codex_session_used_snapshots[key] = used
	if delta <= 0:
		return
	total_codex_tokens += delta
	total_tokens_changed.emit()
	_persist_token_totals()


# Single source of truth for the token-totals persistence payload — both
# Claude and Codex paths funnel through this so adding a new bucket
# doesn't risk one path dropping the field while the other writes it.
func _persist_token_totals() -> void:
	SessionStoreScript.save_token_totals({
		"total_input_tokens": total_input_tokens,
		"total_output_tokens": total_output_tokens,
		"total_cache_creation_tokens": total_cache_creation_tokens,
		"total_cache_read_tokens": total_cache_read_tokens,
		"total_codex_tokens": total_codex_tokens,
	})


# ---------------------------------------------------------------------------
# Connections + permissions
# ---------------------------------------------------------------------------


func set_connection(agent_id: String, conn) -> void:
	connections[agent_id] = conn


func get_connection(agent_id: String):
	return connections.get(agent_id, null)


func set_connection_status(agent_id: String, status: String) -> void:
	if str(connection_status.get(agent_id, "")) == status:
		return
	connection_status[agent_id] = status
	connection_status_changed.emit(agent_id, status)


func add_pending_permission(request_id: int, params: Dictionary) -> void:
	pending_permissions[request_id] = params
	permission_requested.emit(request_id)


func resolve_permission(request_id: int) -> Dictionary:
	if not pending_permissions.has(request_id):
		return {}
	var params: Dictionary = pending_permissions[request_id]
	pending_permissions.erase(request_id)
	permission_resolved.emit(request_id)
	return params


func mark_session_replaying(agent_id: String, remote_session_id: String, replaying: bool) -> void:
	var key: String = "%s|%s" % [agent_id, remote_session_id]
	if replaying:
		replaying_sessions[key] = true
	else:
		replaying_sessions.erase(key)


func is_session_replaying(agent_id: String, remote_session_id: String) -> bool:
	var key: String = "%s|%s" % [agent_id, remote_session_id]
	return replaying_sessions.get(key, false)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------


func schedule_persist() -> void:
	_persist_dirty = true
	# Skip the debounce while any session is actively streaming. Writing
	# the full transcript + metadata index on every tool_call / chunk /
	# plan update blocks the main thread long enough to cause visible
	# stutter on long agent turns. Turn endings explicitly flush, so we
	# never lose a completed turn's state — only the partial mid-stream
	# state that's already in memory.
	if any_session_streaming():
		return
	if _persist_timer == null or not is_instance_valid(_persist_timer):
		_flush_persist_state()
		return
	_persist_timer.start()


func any_session_streaming() -> bool:
	for session_variant in sessions:
		if typeof(session_variant) != TYPE_DICTIONARY:
			continue
		if bool((session_variant as Dictionary).get("busy", false)):
			return true
	return false


func _flush_persist_state() -> void:
	if not _persist_dirty:
		return
	_persist_dirty = false
	# `current_session_id` is read off whichever surface holds the most
	# recently-active claim; persists "the dock surface" by default since
	# that's how it's always worked. AgentMainScreen will append its own
	# claim once Phase 2 lands.
	var current_idx: int = get_current_session_for_surface("dock")
	SessionStoreScript.persist(
		sessions,
		current_idx,
		next_session_number,
		selected_agent_id,
		DEFAULT_AGENT_ID,
	)


# Loads the persisted sessions index + per-thread caches from disk into
# this GodetteState. Returns true when anything was loaded. Should be
# called once per editor session before any view binds — dock /
# main_screen build their UI off the populated state. Also runs the
# one-shot legacy migrations (cancel-message purge, derived-title
# backfill) since those touch the same on-disk data.
func restore_from_disk() -> bool:
	# Token totals live in their own file independent of session
	# state — load them up front so they survive even when sessions
	# don't exist yet (fresh install, or index file deleted but
	# token file kept).
	var totals: Dictionary = SessionStoreScript.load_token_totals()
	total_input_tokens = int(totals.get("total_input_tokens", 0))
	total_output_tokens = int(totals.get("total_output_tokens", 0))
	total_cache_creation_tokens = int(totals.get("total_cache_creation_tokens", 0))
	total_cache_read_tokens = int(totals.get("total_cache_read_tokens", 0))
	total_codex_tokens = int(totals.get("total_codex_tokens", 0))

	var result: Dictionary = SessionStoreScript.load_persisted(DEFAULT_AGENT_ID)
	if not bool(result.get("found", false)):
		return false
	var loaded_sessions_variant = result.get("sessions", [])
	var loaded_sessions: Array = loaded_sessions_variant if loaded_sessions_variant is Array else []
	if loaded_sessions.is_empty():
		return false
	sessions = loaded_sessions
	next_session_number = int(result.get("next_session_number", sessions.size() + 1))
	selected_agent_id = str(result.get("selected_agent_id", DEFAULT_AGENT_ID))
	# Pre-claim the dock's surface to whichever session was active when
	# Godot last closed; falls through to most-recent-updated, then to
	# index 0. The view layer binds to this claim on its first frame
	# rather than running its own selection logic.
	var pinned_id: String = str(result.get("current_session_id", ""))
	var resolved_idx: int = -1
	if not pinned_id.is_empty():
		resolved_idx = find_session_index_by_id(pinned_id)
	if resolved_idx < 0:
		resolved_idx = _most_recent_session_index()
	if resolved_idx < 0 and not sessions.is_empty():
		resolved_idx = 0
	if resolved_idx >= 0:
		set_current_session_for_surface("dock", resolved_idx)
	sessions_changed.emit()
	return true


# Most recently updated session, picked by `updated_at_msec` (falls back
# to load order when absent). Mirrors dock's _most_recent_session_index.
func _most_recent_session_index() -> int:
	if sessions.is_empty():
		return -1
	var best_idx: int = 0
	var best_msec: int = _timestamp_msec_from_session(sessions[0])
	for i in range(1, sessions.size()):
		var msec: int = _timestamp_msec_from_session(sessions[i])
		if msec > best_msec:
			best_idx = i
			best_msec = msec
	return best_idx


func _timestamp_msec_from_session(session_variant) -> int:
	if typeof(session_variant) != TYPE_DICTIONARY:
		return 0
	var session: Dictionary = session_variant
	var raw = session.get("updated_at_msec", 0)
	if typeof(raw) == TYPE_INT or typeof(raw) == TYPE_FLOAT:
		return int(raw)
	return 0
