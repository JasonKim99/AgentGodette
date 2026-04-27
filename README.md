<div align="center">

<img width="720" alt="Agent Godette cover" src="https://github.com/user-attachments/assets/501fa074-759c-41fa-966c-e3ea2377f468" />

<sub>Cover art inspired by Agent 47.</sub>

English | [简体中文](README.zh-CN.md)

# Agent Godette

### ACP Agent in the Godot Editor

![License](https://img.shields.io/badge/license-MIT-green) ![Node.js](https://img.shields.io/badge/Node.js-18+-brightgreen?logo=nodedotjs&logoColor=white) ![ACP](https://img.shields.io/badge/protocol-ACP-8b5cf6) ![Version](https://img.shields.io/badge/version-0.4.2-blue)

</div>

**Per-session model, mode, and reasoning** — switch model, reasoning effort, and permission mode per thread, right from the composer bar.

<img width="3840" height="2076" alt="Per-session model selector" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/model_select.png" />

**Plan · Queue · SceneTree focus** — the agent's TodoWrite plan collapses above the composer, queued follow-up prompts stack underneath it, and any node you've selected in the SceneTree auto-attaches as implicit context on send.

<img width="3840" height="2076" alt="Plan drawer, Queue drawer, and SceneTree focus indicator" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/plan+queue+selectnode.png" />


## What it is

A Godot 4 editor plugin that talks to local ACP (Agent Client Protocol) adapters — Claude and Codex run as stdio subprocesses, the editor is the client. No HTTP bridge.

## What it solves

Godot had no in-editor agent. This plugin makes the editor itself the chat surface: attach scene nodes, FileSystem files, or pasted screenshots as context; the agent edits your project in place. No copy-paste between a separate chat app and the editor.

## Requirements

[Node.js](https://nodejs.org) 18+ is required to run the local ACP adapters. Recommended install:

```bash
npm install -g @agentclientprotocol/claude-agent-acp @zed-industries/codex-acp
```

The plugin also falls back to `npx -y <package>` on first run, so global install is optional — it just avoids the one-time download and works offline afterwards.

### Picking a Claude adapter

Two ACP adapters can speak Claude. The dock auto-detects whichever you have installed; both are supported.

| Adapter | Maintainer | Notes |
|---|---|---|
| **[`@agentclientprotocol/claude-agent-acp`](https://www.npmjs.com/package/@agentclientprotocol/claude-agent-acp)** *(recommended)* | Anthropic | Tracks the Claude SDK closely. Model strings like "Opus 4.7 with 1M context" stay fresh. |
| [`@zed-industries/claude-code-acp`](https://github.com/zed-industries/claude-code-acp) | Zed | Wraps the Claude CLI. Works fine, but pins an older Claude SDK so model descriptions lag a release or two behind. |

### Picking a Codex adapter

Only one production option here. OpenAI hasn't published an official ACP adapter, and `@agentclientprotocol/codex-acp` is still pre-1.0 / experimental.

| Adapter | Maintainer | Notes |
|---|---|---|
| **[`@zed-industries/codex-acp`](https://github.com/zed-industries/codex-acp)** *(recommended)* | Zed | The de facto Codex ACP adapter. |

### Authentication

Each adapter handles its own login. Run the underlying CLI **once outside Godot** to sign in:

- `claude-agent-acp` / `claude-code-acp` → Claude CLI login
- `codex-acp` → OpenAI Codex CLI login

## Updating to newer models

Model names and descriptions ("Opus 4.7", "GPT-5.4 / xhigh", …) are sent by the ACP adapter, **not hardcoded in this plugin**. So when Anthropic / OpenAI ship a new model, what surfaces in the dock depends on which adapter version is running on your machine.

### How the dock picks an adapter

The dock probes in this order and uses the first one that exists:

1. Globally installed adapter (`npm install -g …`)
2. Adapter found in your local Zed install (if you have Zed)
3. `npx -y <pkg>@<version>` — the **plugin pins a specific version here**, which is what makes plugin builds reproducible

The plugin pins are bumped each release. If you want fresher model strings without waiting for a plugin release, just bypass the pin by installing the adapter globally — option 1 wins.

### Refreshing model strings

```bash
# Claude (Anthropic official)
npm install -g @agentclientprotocol/claude-agent-acp@latest

# or Claude (Zed adapter — note: SDK is intentionally older here)
npm install -g @zed-industries/claude-code-acp@latest

# Codex
npm install -g @zed-industries/codex-acp@latest
```

Then **start a new thread** in the dock — existing threads keep whatever model list was cached when they were first created. The new thread will get the fresh strings.

### Why two projects can disagree

Each Godot project carries its own copy of `addons/godette_agent/`. If project A has the latest plugin (newer pin) and project B has an older plugin (older pin), they'll show different model descriptions even on the same machine. To unify them: update the plugin in both projects (AssetLib re-download, git pull, or just copy the folder over) — or globally install the adapter so the pin doesn't matter.

## Credits

Standing on [Zed](https://github.com/zed-industries/zed)'s shoulders — the ACP transport and most of the UX (plan / queue drawers, composer chips, transcript persistence, tool-call rendering) are modeled directly on Zed's external-agent implementation.
