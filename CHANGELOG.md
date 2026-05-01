# Changelog

English | [简体中文](CHANGELOG.zh-CN.md)

All notable changes to **Agent Godette** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-05-01

### Added
- **Token consumption tracker** — per-project cumulative token counter
  persisted to `user://godette_token_totals.json`. Accumulates from every
  ACP `usage_update` notification (Claude `message_delta`, Codex
  `TokenCountEvent`), updating the displayed total live during streaming
  (matches what the official CLI shows).
- **Token flame widget** in the dock header — Balatro-inspired badge
  next to the `+` button. Three layers: rounded card body (StyleBoxFlat)
  + flame TextureRect (custom shader) + per-glyph digit overlay. Click
  the widget to open a live settings dialog. Toggle visibility via
  "Show Flame" setting.
- **Flame shader** — full port of Balatro's `resources/shaders/flame.fs`:
  5-iteration domain warp, pixelisation to 30-cell grid,
  self-distortion, time-scrolling `flame_up_vec` upward flow, two-colour
  gradient (base colour → warm-tinted tip auto-derived from the user's
  theme colour). Body-aware visibility — confined to overflow region
  above the body, fills the body's transparent rounded-corner cutouts
  so the silhouette flows seamlessly. `flame_intensity` is token-driven
  (log_10 mapping, 0 tokens → 0, 1B tokens → 10).
- **Digit animation** — port of Balatro's `engine/text.lua` `DynaText`.
  Custom-drawn per-glyph layout via `Font.draw_string` /
  `draw_string_outline` (no HBoxContainer + Label, so glyph spacing
  matches the font's natural advance widths). Pulse uses a triangle wave
  that traverses letters left → right with position-based rotation
  (outer letters fan out). Single-pulse + queue=1 model — pulses play
  strictly sequentially with no overlap.
- **Slot-machine count-up** — tick-based linear ramp. Each tick
  advances the displayed number by one step AND fires one pulse
  (animation is "click click click" synchronised with pulses). Number
  formatted to 2 decimals at K / M / B ranges so per-tick changes are
  visibly tickable. Turn end (`session_busy_changed → false`) snaps to
  the authoritative target with a final pulse.
- **m6x11plus pixel font** support. Drop the `.ttf` into
  `addons/godette_agent/fonts/`; falls back to the editor's default
  font when missing.
- **Settings dialog** — Show Flame toggle, Color picker, Padding X/Y,
  Corner Radius, Flame Speed (%), Bounce Peak (%), Bounce Duration (ms),
  Count-up Duration (10–30s), Pulse Throttle (ms), Bounce Rotation (°),
  Reset to defaults. Bounce-related sliders fire a preview pulse on
  drag.

### Changed
- Adapter-agnostic snapshot accumulation
  (`record_session_token_snapshot(adapter, session_id, used)`) shared
  between Claude and Codex. Previously Codex-only.
- Dropped turn-end `result.usage` accumulation — mid-stream snapshots
  cover the same tokens; processing both would double-count.
- Display formula sums all token buckets (input / output / cache /
  unified `used`) per CLI convention; cache_read no longer excluded.

### Fixed
- `ProjectSettings.save()` now actually persists changes across editor
  reloads. Previous behaviour mutated only the in-memory copy and
  reverted on next project load — making "Reset to defaults" effectively
  a no-op after restart.

## [0.5.1] - 2026-04-28

### Added
- Composer slash-command popup — typing `/` in the prompt input opens
  a Zed-style two-pane picker driven by the adapter's
  `available_commands_update` notifications.

## [0.5.0] - 2026-04-28

### Changed
- **Phase 1 state-extraction refactor** — session, connection, and
  permission state moved out of `agent_dock.gd` into a shared
  `session_state.gd` module (`GodetteState`) owned by `plugin.gd`. Dock
  becomes a view that binds to the shared state via `bind(state)`. New
  `session_store.gd` owns disk I/O for the session index + per-thread
  caches.

## [0.4.3] - 2026-04-27

### Fixed
- Bug fixes in `list_block.gd`, `table_block.gd`, `text_block.gd`
  rendering paths.

### Changed
- Codex markdown rendering optimisations (block boundary detection).
- Cross-block selection robustness pass.
- Troubleshooting section added to README.

## [0.4.2] - 2026-04-27

### Changed
- README updates.

## [0.4.1] - 2026-04-25

### Added
- Code-block collapse/expand affordance with chevron icons
  (`lucide--chevron-up/down`) and circle-chevron variants.
- Shader code block recognition — `.gdshader` / `.glsl` / `.shader`
  fences get the same syntax-highlighted treatment as other languages.

### Changed
- IBeam text cursor across `code_block_block`, `list_block`,
  `table_block` for consistent selection feedback.
- Editor theme integration extended (`editor_theme.gd`).

## [0.4.0] - 2026-04-25

### Added
- **ListBlock** + **TableBlock** as self-drawn Controls — markdown
  lists and tables collapse into a single Control each, eliminating
  VirtualFeed measure-cascade drift on large transcripts.
- **Cross-block selection** — drag-select continuously across
  paragraphs, lists, and tables. Ctrl+C across cells preserves `\t` and
  `\n` formatting.
- **Inline link click** — click a link span to open it in the browser.
- **Right-click menu** — Copy Selection / Copy This Agent Response work
  on list and table blocks, not just text.
- Realtime session loading + per-thread history hydration on demand.

## [0.3.3] - 2026-04-25

### Changed
- i18n string updates.
- Tag handling refinements.

## [0.3.2] - 2026-04-25

### Changed
- i18n infrastructure (`i18n.gd`) groundwork.
- `.gitignore` / `.gitattributes` cleanups; addon-internal LICENSE +
  README.
- Folder organisation pass (asset paths, doc images).

## [0.3.1] - 2026-04-25

### Added
- Focus ring rendering (`focus_ring.gd`).
- Session menu refactor (`session_menu.gd`) — extracted from inline
  agent_dock code.
- Plugin icon (`icon-128-rounded.png`) and feature screenshots in docs.

### Changed
- Multi-iteration README polish across English + Simplified Chinese.

## [0.3.0] - 2026-04-24

### Added
- **Plan drawer** — agent's TodoWrite plan moved out of the transcript
  into its own Control above the composer. Zed-style SVG icons
  (`todo_pending` / `progress` / `complete`) with 2 s spin for
  in-progress, "All Done" badge, `×` clears entries.
- **Queue drawer** — full per-message actions (Trash / Pencil / Send
  Now). First row shows controls always, others reveal on hover. "Clear
  All" in header. Send Now interrupts the current turn; Edit restores
  the queued message's text + chips + attachments back into the
  composer. Queued messages don't enter the transcript until dispatch,
  so they no longer split a streaming agent response.
- FileSystem timestamp display in attachment chips.

## [0.2.1] - 2026-04-23

### Added
- Editor FileSystem auto-refresh — file changes made by the agent get
  picked up by Godot's resource browser without manual rescan.

## [0.2.0] - 2026-04-23

### Added
- **Composer chip overlay** — pasted screenshots, scene-tree node
  selections, and FileSystem files render as inline chips in the
  prompt input ahead of the user text.
- **Composer context** module (`composer_context.gd`) tracking
  attached resources separately from the prompt string.
- **Composer prompt input** as a dedicated Control with chip-aware
  caret navigation.

## [0.1.0] - 2026-04-22

### Added
- Initial release. A Godot 4 editor plugin that talks to local ACP
  (Agent Client Protocol) adapters — Claude Agent and Codex CLI run
  as stdio subprocesses, the editor is the client (no HTTP bridge).
- Multi-session chat dock with per-thread state.
- GFM markdown rendering with cross-block text selection.
- Zed-styled tool call rendering.
- Plan panel for TodoWrite output.
- Queued follow-up prompts.
- Scene/node/file attachment chips.
- MIT license.
- AI co-author trailer hook (`prepare-commit-msg`).

[Unreleased]: https://github.com/JasonKim99/AgentGodette/compare/v0.6.0...HEAD
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
