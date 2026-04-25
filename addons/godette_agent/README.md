# Agent Godette

A Godot 4 editor plugin for talking to local Claude / Codex AI agents over ACP (Agent Client Protocol) stdio. Same transport Zed uses for external agents — no HTTP bridge, no separate chat app, the editor itself is the client.

## Setup

1. **Enable the plugin** — `Project → Project Settings → Plugins → Agent Godette → Enable`. The dock appears on the right side.

2. **Install the ACP adapters** ([Node.js](https://nodejs.org) 18+ required):

   ```bash
   npm install -g @zed-industries/claude-code-acp @zed-industries/codex-acp
   ```

   The plugin also auto-falls-back to `npx -y <package>` on first run, so global install is optional — it just avoids the one-time download.

3. **Sign in to each adapter** (one-time, outside Godot):
   - [`claude-code-acp`](https://github.com/zed-industries/claude-code-acp) → uses Claude CLI login
   - [`codex-acp`](https://github.com/zed-industries/codex-acp) → uses OpenAI Codex CLI login

4. **Pick an agent** in the dock's `+` menu, send your first prompt.

## Locale

UI strings follow `Project Settings → Editor → Editor Language`. Simplified Chinese (`zh_CN`) and English are bundled; everything else falls back to English.

## Full docs / screenshots / source

→ [github.com/JasonKim99/AgentGodette](https://github.com/JasonKim99/AgentGodette)

## License

MIT — see `LICENSE` next to this file.
