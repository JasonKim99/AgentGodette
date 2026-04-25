<img width="1672" height="941" alt="ChatGPT Image 2026年4月22日 06_27_35" src="https://github.com/user-attachments/assets/501fa074-759c-41fa-966c-e3ea2377f468" />

封面灵感来自 Agent 47。

[English](README.md) | 简体中文

# Agent Godette (v0.4.0)

![License](https://img.shields.io/badge/license-MIT-green) ![Node.js](https://img.shields.io/badge/Node.js-18+-brightgreen?logo=nodedotjs&logoColor=white) ![ACP](https://img.shields.io/badge/protocol-ACP-8b5cf6)

**每个会话独立切换模型、模式、推理等级** —— 在 composer 底栏直接切换模型、推理强度、权限模式，每个 thread 各自为政。

<img width="3840" height="2076" alt="Per-session model selector" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/model_select.png" />

**Plan · Queue · 场景节点焦点** —— agent 的 TodoWrite 计划面板折叠在 composer 上方，排队中的后续 prompt 夹在计划和输入框之间，在 SceneTree 里选中的任何节点会作为隐式上下文自动附加到发送中。

<img width="3840" height="2076" alt="Plan drawer, Queue drawer, and SceneTree focus indicator" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/plan+queue+selectnode.png" />


## 是什么

一个 Godot 4 编辑器插件，和本地的 ACP（Agent Client Protocol）adapter 通信 —— Claude 和 Codex 以 stdio 子进程方式运行，编辑器就是 client，没有 HTTP 中转。

## 解决什么问题

Godot 此前没有编辑器内的 AI agent。这个插件把编辑器本身变成了聊天界面：场景节点、FileSystem 文件、剪贴板截图都能当作上下文附加；agent 直接在你的项目里改文件，不再需要在独立的聊天 app 和编辑器之间来回复制粘贴。

## 环境要求

运行本地 ACP adapter 需要 [Node.js](https://nodejs.org) 18+。把你要用的 adapter 装上：

```bash
npm install -g @zed-industries/claude-code-acp @zed-industries/codex-acp
```

插件首次运行时也会自动 fallback 到 `npx -y <package>`，所以全局安装是可选的 —— 预装只是免去首次下载，并且离线后依然可用。

每个 adapter 自己处理鉴权：[claude-code-acp](https://github.com/zed-industries/claude-code-acp) 走 Claude CLI 登录，[codex-acp](https://github.com/zed-industries/codex-acp) 走 OpenAI Codex CLI 登录。先在 Godot 外面各自跑一次 CLI 登录。

## 致谢

站在 [Zed](https://github.com/zed-industries/zed) 的肩膀上 —— ACP 传输层以及大部分 UX（plan / queue drawer、composer chip、transcript 持久化、tool-call 渲染）都是直接参照 Zed 的 external-agent 实现复刻的。
