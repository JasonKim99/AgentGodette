<img width="1672" height="941" alt="ChatGPT Image 2026年4月22日 06_27_35" src="https://github.com/user-attachments/assets/501fa074-759c-41fa-966c-e3ea2377f468" />

_Cover art inspired by Agent 47._

# Agent Godette

_v0.3.1
<img width="3840" height="2076" alt="image" src="https://github.com/user-attachments/assets/807fc791-77de-40ad-a085-b906d7ef7154" />

## What it is

A Godot 4 editor plugin that talks to local ACP (Agent Client Protocol) adapters — Claude and Codex run as stdio subprocesses, the editor is the client. No HTTP bridge.

## What it solves

Godot had no in-editor agent. This plugin makes the editor itself the chat surface: attach scene nodes, FileSystem files, or pasted screenshots as context; the agent edits your project in place. No copy-paste between a separate chat app and the editor.

## Credits

Standing on [Zed](https://github.com/zed-industries/zed)'s shoulders — the ACP transport and most of the UX (plan / queue drawers, composer chips, transcript persistence, tool-call rendering) are modeled directly on Zed's external-agent implementation.
