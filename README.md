# Agent Godette

_v0.1.0 — Godot 4.6_

A Godot 4 editor plugin that talks to local ACP (Agent Client Protocol) adapters — the same transport Zed uses for external agents. Godot is the client; Claude and Codex run as local stdio subprocesses; no HTTP bridge.

## What it does

- Adds an **Agent** dock inside the Godot editor.
- Supports two local agents out of the box:
  - `Claude Agent`
  - `Codex CLI`
- Runs multiple chat sessions side by side, each with its own transcript, attachments, and queued prompts.
- Spawns the selected ACP adapter on demand and streams its `session/update` events straight into the dock.
- Renders agent replies as markdown: headings, lists, tables (GFM), fenced code blocks, blockquotes, inline code / bold / italic / links, horizontal rules.
- Cross-block text selection: drag across paragraphs / list items / table cells within one reply; `Ctrl+C` copies the whole selection, `Esc` clears.
- **Plan** panel that mirrors `TodoWrite`-style tool output: progress `done/total`, current task preview when collapsed, per-item strike-through on completion.
- Zed-styled tool call rendering: read/search/fetch/think tools show as one-line inline rows; edit/bash/permission tools get a full card.
- **Queued messages**: type and hit `Enter` while the agent is still replying — the prompt stacks up and auto-dispatches when the current turn ends. `Shift+Enter` inserts a newline.
- Permission prompts surface as in-dock dialogs with approve / reject buttons.
- Attachments you can drop into a prompt:
  - the currently edited scene,
  - the selected Scene Tree nodes,
  - selected FileSystem files (including pasted screenshots).
- Right-click entry points:
  - FileSystem dock → `Ask Agent About Selection`
  - Scene Tree dock → `Ask Agent About Nodes`

## Files

```
addons/godette_agent/
├── plugin.gd                       editor plugin entry point
├── agent_dock.gd                   dock UI, session state, ACP event handlers
├── acp_connection.gd               stdio JSON-RPC transport for ACP adapters
├── markdown.gd                     CommonMark + GFM subset parser → event stream
├── markdown_render.gd              event-stream renderer → Godot Controls
├── markdown_selection_manager.gd   cross-block drag selection + copy/clear
├── session_store.gd                session persistence + per-thread cache I/O
├── text_block.gd                   TextParagraph-based widget with span styling
├── virtual_feed.gd                 viewport-virtualised scroll feed (only
│                                   renders entries intersecting the visible
│                                   range; O(log n) y lookup)
├── composer_prompt_input.gd        prompt input (image paste, Enter to submit)
├── composer_context.gd             attachments strip above the composer
├── loading_scanner.gd              top bar progress indicator
├── filesystem_context_menu.gd      FileSystem right-click integration
└── scene_tree_context_menu.gd      Scene Tree right-click integration
```

## Requirements

Install the local ACP adapters before opening Godot:

```bash
npm install -g @agentclientprotocol/claude-agent-acp @zed-industries/codex-acp
```

The plugin looks for these adapters in the standard global npm location and falls back to `npx` when that path isn't resolvable.

## Run it

1. Open this folder in Godot 4.6.x.
2. Enable `Agent Godette` in `Project → Project Settings → Plugins`.
3. Open the `Agent` dock.
4. Choose `Claude Agent` or `Codex CLI`.
5. Create a session and send a prompt.

## Session data

Sessions are persisted outside the project tree, in Godot's user-data directory:

- **Windows:** `%APPDATA%/Godot/app_userdata/<project>/godette_sessions.json` + `godette_threads/*.json`
- **macOS / Linux:** the equivalent Godot `user://` location.

The index file (`godette_sessions.json`) holds per-session metadata; each thread's transcript lives in its own file under `godette_threads/`. Only the active thread is held in memory — switching threads hydrates the new one and dehydrates the old one back to disk.

## Notes

- Transport is ACP over stdio, matching Zed's external-agent design. No HTTP, no separate bridge process.
- Streamed output and session isolation are fully working. Multi-session parallel turns, queued prompts, and mid-stream cancellation all handled.
- File edit review is still minimal — permission requests are shown but the diff UX is much simpler than Zed's side-by-side review. That's on the roadmap.
