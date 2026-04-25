<img width="1672" height="941" alt="ChatGPT Image 2026年4月22日 06_27_35" src="https://github.com/user-attachments/assets/501fa074-759c-41fa-966c-e3ea2377f468" />

Cover art inspired by Agent 47.

English | [简体中文](README.zh-CN.md)

# Agent Godette (v0.4.0)

![License](https://img.shields.io/badge/license-MIT-green) ![Node.js](https://img.shields.io/badge/Node.js-18+-brightgreen?logo=nodedotjs&logoColor=white) ![ACP](https://img.shields.io/badge/protocol-ACP-8b5cf6)

**Per-session model, mode, and reasoning** — switch model, reasoning effort, and permission mode per thread, right from the composer bar.

<img width="3840" height="2076" alt="Per-session model selector" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/model_select.png" />

**Plan · Queue · SceneTree focus** — the agent's TodoWrite plan collapses above the composer, queued follow-up prompts stack underneath it, and any node you've selected in the SceneTree auto-attaches as implicit context on send.

<img width="3840" height="2076" alt="Plan drawer, Queue drawer, and SceneTree focus indicator" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/plan+queue+selectnode.png" />


## What it is

A Godot 4 editor plugin that talks to local ACP (Agent Client Protocol) adapters — Claude and Codex run as stdio subprocesses, the editor is the client. No HTTP bridge.

## What it solves

Godot had no in-editor agent. This plugin makes the editor itself the chat surface: attach scene nodes, FileSystem files, or pasted screenshots as context; the agent edits your project in place. No copy-paste between a separate chat app and the editor.

## Requirements

[Node.js](https://nodejs.org) 18+ is required to run the local ACP adapters. Install the adapters you want to use:

```bash
npm install -g @zed-industries/claude-code-acp @zed-industries/codex-acp
```

The plugin also falls back to `npx -y <package>` on first run, so global install is optional — it just avoids the one-time download and works offline afterwards.

Each adapter handles its own authentication: [claude-code-acp](https://github.com/zed-industries/claude-code-acp) uses the Claude CLI login, [codex-acp](https://github.com/zed-industries/codex-acp) uses the OpenAI Codex CLI login. Run either CLI once outside Godot to sign in.

## Credits

Standing on [Zed](https://github.com/zed-industries/zed)'s shoulders — the ACP transport and most of the UX (plan / queue drawers, composer chips, transcript persistence, tool-call rendering) are modeled directly on Zed's external-agent implementation.
