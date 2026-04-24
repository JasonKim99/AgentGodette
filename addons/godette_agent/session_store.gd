@tool
class_name GodetteSessionStore
extends RefCounted
#
# Session persistence + thread-cache I/O + restore-time migrations.
#
# Two files on disk:
#   user://godette_sessions.json   — INDEX. Per-session metadata only
#                                    (id, title, agent_id, model/mode
#                                    lists, updated_at, …). Small and
#                                    rewritten whenever anything about
#                                    the session list changes.
#   user://godette_threads/<id>.json — THREAD CACHE. One file per
#                                    session carrying its transcript +
#                                    attachments. Heavy; only rewritten
#                                    for the active session.
#
# Split rationale: opening the dock with many threads parses only the
# small index, not every transcript. The per-thread caches rehydrate
# lazily via `hydrate()` when a session becomes active, and empty again
# via `dehydrate()` when another thread takes over — only one thread's
# transcript + attachments are resident at a time.
#
# This file is Node-free (RefCounted, all static methods) so it can be
# unit-tested or driven from headless tools without a live dock.

const ACPConnectionScript = preload("res://addons/godette_agent/acp_connection.gd")

const STATE_PATH := "user://godette_sessions.json"
const THREAD_CACHE_DIR := "user://godette_threads/"

# Upper bounds enforced at persist time so a single runaway session (or
# a pathological tool-call output) can't bloat the on-disk footprint.
# Older entries past the head window are dropped from the cached
# transcript; long strings are trimmed with an "..." marker. In-memory
# state is NOT truncated — only the serialised copy.
const MAX_PERSISTED_TRANSCRIPT_ENTRIES := 120
const MAX_PERSISTED_ENTRY_CHARS := 2400
const MAX_PERSISTED_TITLE_CHARS := 220
const MAX_PERSISTED_PLAN_ITEM_CHARS := 320


# ---------------------------------------------------------------------------
# Index file I/O (user://godette_sessions.json)
# ---------------------------------------------------------------------------


# Write the session list index and refresh the active session's thread
# cache. Only the active thread has in-memory mutations since the last
# persist (every other session is dehydrated and its cache is already
# current), so we skip rewriting the rest.
static func persist(
	sessions: Array,
	current_session_index: int,
	next_session_number: int,
	selected_agent_id: String,
	default_agent_id: String,
) -> void:
	var payload: Dictionary = {
		"current_session_id": "",
		"next_session_number": next_session_number,
		"selected_agent_id": selected_agent_id,
		"sessions": []
	}

	if current_session_index >= 0 and current_session_index < sessions.size():
		payload["current_session_id"] = str(sessions[current_session_index].get("id", ""))

	var metadata_sessions: Array = []
	for session_variant in sessions:
		if typeof(session_variant) != TYPE_DICTIONARY:
			continue
		metadata_sessions.append(session_metadata_snapshot(session_variant, default_agent_id))
	payload["sessions"] = metadata_sessions

	var file := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.flush()

	if current_session_index >= 0 and current_session_index < sessions.size():
		write_thread_cache(sessions[current_session_index])


# Load the index file. Returns a Dictionary with:
#   found              bool          — whether a usable index exists
#   sessions           Array[Dict]   — restored (metadata-only) session
#                                      shells ready to drop into the
#                                      dock's `sessions` array. Heavy
#                                      fields stay on disk until
#                                      `hydrate()` pulls them in.
#   current_session_id String        — the session the user was on at
#                                      last persist (empty if unknown)
#   next_session_number int
#   selected_agent_id  String
#
# Caller is responsible for applying the result to its own state and
# selecting an active session (_most_recent_session_index / similar).
static func load_persisted(default_agent_id: String) -> Dictionary:
	var result: Dictionary = {
		"found": false,
		"sessions": [],
		"current_session_id": "",
		"next_session_number": 1,
		"selected_agent_id": default_agent_id,
	}

	if not FileAccess.file_exists(STATE_PATH):
		return result
	var file := FileAccess.open(STATE_PATH, FileAccess.READ)
	if file == null:
		return result
	var raw_text: String = file.get_as_text()
	if raw_text.strip_edges().is_empty():
		return result
	var parsed = JSON.parse_string(raw_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return result
	var payload: Dictionary = parsed
	# Persisted titles / transcript fragments may contain embedded NULs
	# (encoded as `\u0000` in the file) from earlier adapter output before
	# we added ingress sanitation. Scrub them on load so no downstream UI
	# hands NUL-containing strings to TextParagraph / Label.
	ACPConnectionScript._sanitize_nul_in_place_static(payload)
	var saved_sessions_variant = payload.get("sessions", [])
	if not (saved_sessions_variant is Array):
		return result
	var saved_sessions: Array = saved_sessions_variant
	if saved_sessions.is_empty():
		return result

	var next_num: int = int(payload.get("next_session_number", saved_sessions.size() + 1))
	var restored_sessions: Array = []
	for saved_session_variant in saved_sessions:
		if typeof(saved_session_variant) != TYPE_DICTIONARY:
			continue
		var saved_session: Dictionary = saved_session_variant
		migrate_legacy_session_to_cache(saved_session)
		restored_sessions.append(restored_session(saved_session, default_agent_id, next_num))

	if restored_sessions.is_empty():
		return result

	result["found"] = true
	result["sessions"] = restored_sessions
	result["current_session_id"] = str(payload.get("current_session_id", ""))
	result["next_session_number"] = next_num
	result["selected_agent_id"] = str(payload.get("selected_agent_id", default_agent_id))
	return result


# ---------------------------------------------------------------------------
# Thread cache I/O (user://godette_threads/<id>.json)
# ---------------------------------------------------------------------------


static func thread_cache_path(session_id: String) -> String:
	return THREAD_CACHE_DIR + session_id + ".json"


static func ensure_thread_cache_dir() -> void:
	if DirAccess.dir_exists_absolute(THREAD_CACHE_DIR):
		return
	DirAccess.make_dir_recursive_absolute(THREAD_CACHE_DIR)


# Persist a session's transcript + attachments to its thread cache. The
# tool_calls dict is intentionally NOT written — those are in-flight
# turn state and get reconstructed via `session/load` replay when the
# session reopens. Writing them would just bloat the cache with state
# that's about to be re-derived.
static func write_thread_cache(session: Dictionary) -> void:
	var session_id: String = str(session.get("id", ""))
	if session_id.is_empty():
		return
	ensure_thread_cache_dir()
	var payload: Dictionary = {
		"id": session_id,
		"transcript": compact_transcript(session.get("transcript", [])),
		"attachments": session.get("attachments", []),
		"managed_attachment_refs": session.get("managed_attachment_refs", []),
		# Plan state lives on the session dict (not in the transcript)
		# since it's a drawer above the composer, not a chat bubble.
		# Persist it so the drawer repopulates across editor restarts —
		# matches Zed's thread.plan SQLite persistence.
		"plan_entries": compact_plan_items(session.get("plan_entries", [])),
	}
	var file := FileAccess.open(thread_cache_path(session_id), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.flush()


static func read_thread_cache(session_id: String) -> Dictionary:
	if session_id.is_empty():
		return {}
	var path := thread_cache_path(session_id)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var raw_text: String = file.get_as_text()
	if raw_text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(raw_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var payload: Dictionary = parsed
	# Older caches written before ingress NUL sanitation may carry embedded
	# `\u0000` in transcript text; scrub on load so downstream text shaping
	# never sees them.
	ACPConnectionScript._sanitize_nul_in_place_static(payload)
	return payload


static func delete_thread_cache(session_id: String) -> void:
	if session_id.is_empty():
		return
	var path := thread_cache_path(session_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


# ---------------------------------------------------------------------------
# Hydration (in-place mutation)
# ---------------------------------------------------------------------------


# Pull the session's transcript + attachments off disk into memory. No-op
# if already hydrated. Streaming continuity markers are reset because
# they only make sense within the lifetime of an active ACP turn; a
# returning session re-anchors them on the next live chunk.
static func hydrate(session: Dictionary) -> void:
	if bool(session.get("hydrated", false)):
		return
	var session_id: String = str(session.get("id", ""))
	var cache: Dictionary = read_thread_cache(session_id)
	var cached_transcript_variant = cache.get("transcript", [])
	var cached_attachments_variant = cache.get("attachments", [])
	var cached_managed_attachment_refs = cache.get("managed_attachment_refs", [])
	var cached_plan_entries_variant = cache.get("plan_entries", [])
	session["transcript"] = cached_transcript_variant if cached_transcript_variant is Array else []
	session["attachments"] = cached_attachments_variant if cached_attachments_variant is Array else []
	session["managed_attachment_refs"] = cached_managed_attachment_refs if cached_managed_attachment_refs is Array else []
	session["plan_entries"] = cached_plan_entries_variant if cached_plan_entries_variant is Array else []
	session["assistant_entry_index"] = -1
	session["thought_entry_index"] = -1
	session["tool_calls"] = {}
	session["hydrated"] = true


# Flush the session's heavy fields to disk and evict them from memory.
# Inactive threads stay browsable via the metadata-only index; the next
# activation rehydrates them.
static func dehydrate(session: Dictionary) -> void:
	if not bool(session.get("hydrated", false)):
		return
	write_thread_cache(session)
	session["transcript"] = []
	session["attachments"] = []
	session["plan_entries"] = []
	session["tool_calls"] = {}
	session["assistant_entry_index"] = -1
	session["thought_entry_index"] = -1
	session["hydrated"] = false


# ---------------------------------------------------------------------------
# Restore helpers
# ---------------------------------------------------------------------------


# Build a metadata-only session shell from an index file entry. Heavy
# fields stay empty until hydrate() pulls them from the thread cache.
# `fallback_number` supplies the trailing digit for the generated id
# when the saved entry has none (defensive — every persisted session
# should carry its own id, but older builds sometimes didn't).
static func restored_session(
	saved_session: Dictionary,
	default_agent_id: String,
	fallback_number: int,
) -> Dictionary:
	var session_id := str(saved_session.get("id", "session_%d" % fallback_number))
	# Timestamp priority (highest first):
	#   1. Explicit field from the persisted index (saved_session)
	#   2. `FileAccess.get_modified_time` on the thread cache file
	#      (real filesystem mtime — survives even when the index
	#      forgot to record a timestamp)
	#   3. Current time, last resort
	# This way old sessions that predate the `updated_at` field still
	# show a real freshness indicator based on when their transcript
	# cache was last written to disk.
	var fs_mtime_msec: int = _filesystem_modified_msec(session_id)
	var default_msec: int = fs_mtime_msec if fs_mtime_msec > 0 else int(Time.get_unix_time_from_system() * 1000.0)
	var updated_at: int = int(saved_session.get("updated_at", default_msec))
	if updated_at <= 0:
		updated_at = default_msec
	var created_at: int = int(saved_session.get("created_at", updated_at))
	if created_at <= 0:
		created_at = updated_at

	return {
		"id": session_id,
		"title": str(saved_session.get("title", "Session")),
		"derived_title": str(saved_session.get("derived_title", "")),
		"agent_id": str(saved_session.get("agent_id", default_agent_id)),
		"remote_session_id": str(saved_session.get("remote_session_id", "")),
		"remote_session_loaded": false,
		"loading_remote_session": false,
		"creating_remote_session": false,
		"attachments": [],
		"managed_attachment_refs": [],
		"transcript": [],
		"plan_entries": [],
		"assistant_entry_index": -1,
		"thought_entry_index": -1,
		"queued_prompts": [],
		"tool_calls": {},
		"available_commands": saved_session.get("available_commands", {}),
		"models": saved_session.get("models", []),
		"modes": saved_session.get("modes", []),
		"config_options": saved_session.get("config_options", []),
		"current_model_id": str(saved_session.get("current_model_id", "")),
		"current_mode_id": str(saved_session.get("current_mode_id", "")),
		"cancelling": false,
		"busy": false,
		"hydrated": false,
		"updated_at": updated_at,
		"created_at": created_at,
	}


# Query the thread cache file's mtime as Unix milliseconds.
# `FileAccess.get_modified_time` returns Unix seconds; we scale up.
# Returns 0 when the cache file doesn't exist (e.g. brand-new session
# that hasn't persisted a transcript yet).
static func _filesystem_modified_msec(session_id: String) -> int:
	if session_id.is_empty():
		return 0
	var path := thread_cache_path(session_id)
	if not FileAccess.file_exists(path):
		return 0
	var mtime_sec: int = FileAccess.get_modified_time(path)
	if mtime_sec <= 0:
		return 0
	return mtime_sec * 1000


# Older builds inlined the transcript into the index file. When we see
# that shape on load, hoist the heavy fields into a per-thread cache so
# the new metadata-only restore still has something to hydrate from.
# Leaves an existing cache alone on the assumption that the new code
# path is the source of truth when both exist.
static func migrate_legacy_session_to_cache(saved_session: Dictionary) -> void:
	var session_id: String = str(saved_session.get("id", ""))
	if session_id.is_empty():
		return
	var legacy_transcript_variant = saved_session.get("transcript", [])
	var legacy_attachments_variant = saved_session.get("attachments", [])
	var has_legacy_transcript: bool = legacy_transcript_variant is Array and not (legacy_transcript_variant as Array).is_empty()
	var has_legacy_attachments: bool = legacy_attachments_variant is Array and not (legacy_attachments_variant as Array).is_empty()
	if not has_legacy_transcript and not has_legacy_attachments:
		return
	var cache_path := thread_cache_path(session_id)
	if FileAccess.file_exists(cache_path):
		return
	ensure_thread_cache_dir()
	var cache_payload: Dictionary = {
		"id": session_id,
		"transcript": legacy_transcript_variant if legacy_transcript_variant is Array else [],
		"attachments": legacy_attachments_variant if legacy_attachments_variant is Array else []
	}
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(cache_payload))
	file.flush()


# ---------------------------------------------------------------------------
# Metadata projection + compaction
# ---------------------------------------------------------------------------


# Metadata-only view for the session index file. Heavy fields
# (transcript, attachments, tool_calls) live in per-thread caches keyed
# by session id so opening the plugin with many threads doesn't have to
# parse or re-shape every transcript during startup.
static func session_metadata_snapshot(session: Dictionary, default_agent_id: String) -> Dictionary:
	return {
		"id": str(session.get("id", "")),
		"title": str(session.get("title", "Session")),
		# `derived_title` is the first-user-message snippet captured
		# when the session first sends a prompt. Persisted here so the
		# thread menu can show meaningful labels for inactive
		# (dehydrated) sessions without re-reading each transcript.
		"derived_title": str(session.get("derived_title", "")),
		"agent_id": str(session.get("agent_id", default_agent_id)),
		"remote_session_id": str(session.get("remote_session_id", "")),
		"remote_session_loaded": not str(session.get("remote_session_id", "")).is_empty(),
		"available_commands": session.get("available_commands", {}),
		"models": session.get("models", []),
		"modes": session.get("modes", []),
		"config_options": session.get("config_options", []),
		"current_model_id": str(session.get("current_model_id", "")),
		"current_mode_id": str(session.get("current_mode_id", "")),
		"updated_at": int(session.get("updated_at", 0)),
		"created_at": int(session.get("created_at", 0)),
	}


static func trim_persist_text(value: String, max_chars: int) -> String:
	if max_chars <= 0:
		return ""
	if value.length() <= max_chars:
		return value
	return "%s..." % value.substr(0, max_chars)


static func compact_plan_items(items_variant) -> Array:
	if not (items_variant is Array):
		return []
	var source_items: Array = items_variant
	var compacted_items: Array = []
	for item_variant in source_items:
		if typeof(item_variant) != TYPE_DICTIONARY:
			continue
		var item_dict: Dictionary = item_variant
		compacted_items.append({
			"content": trim_persist_text(str(item_dict.get("content", "")), MAX_PERSISTED_PLAN_ITEM_CHARS),
			"status": str(item_dict.get("status", "")),
			"priority": str(item_dict.get("priority", ""))
		})
	return compacted_items


static func compact_transcript(transcript_variant) -> Array:
	if not (transcript_variant is Array):
		return []
	var source_transcript: Array = transcript_variant
	var first_index: int = max(0, source_transcript.size() - MAX_PERSISTED_TRANSCRIPT_ENTRIES)
	var compacted_transcript: Array = []
	for transcript_index in range(first_index, source_transcript.size()):
		var entry_variant = source_transcript[transcript_index]
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var compact_entry: Dictionary = {
			"speaker": str(entry.get("speaker", "System")),
			"kind": str(entry.get("kind", "")),
			"content": trim_persist_text(str(entry.get("content", "")), MAX_PERSISTED_ENTRY_CHARS)
		}

		var title: String = str(entry.get("title", ""))
		if not title.is_empty():
			compact_entry["title"] = trim_persist_text(title, MAX_PERSISTED_TITLE_CHARS)

		var summary: String = str(entry.get("summary", ""))
		if not summary.is_empty():
			compact_entry["summary"] = trim_persist_text(summary, MAX_PERSISTED_ENTRY_CHARS)

		var status: String = str(entry.get("status", ""))
		if not status.is_empty():
			compact_entry["status"] = status

		# User bubble's inline chip layout. Stored as pure JSON segments
		# (text runs + chip references). Round-trips as-is so transcripts
		# reloaded from disk render with the same inline chips the user
		# originally sent.
		if entry.has("segments"):
			var segments_variant = entry.get("segments", [])
			if segments_variant is Array:
				compact_entry["segments"] = segments_variant

		compacted_transcript.append(compact_entry)

	return compacted_transcript
