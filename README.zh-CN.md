<div align="center">

<img width="720" alt="Agent Godette 封面" src="https://github.com/user-attachments/assets/501fa074-759c-41fa-966c-e3ea2377f468" />

<sub>封面灵感来自 Agent 47。</sub>

[English](README.md) | 简体中文

# Agent Godette

### Godot 编辑器内的 ACP Agent

![License](https://img.shields.io/badge/license-MIT-green) ![Node.js](https://img.shields.io/badge/Node.js-18+-brightgreen?logo=nodedotjs&logoColor=white) ![ACP](https://img.shields.io/badge/protocol-ACP-8b5cf6) ![Version](https://img.shields.io/badge/version-0.4.3-blue)

</div>

**每个会话独立切换模型、模式、推理等级** —— 在 composer 底栏直接切换模型、推理强度、权限模式，每个 thread 各自为政。

<img width="3840" height="2076" alt="Per-session model selector" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/model_select.png" />

**Plan · Queue · 场景节点焦点** —— agent 的 TodoWrite 计划面板折叠在 composer 上方，排队中的后续 prompt 夹在计划和输入框之间，在 SceneTree 里选中的任何节点会作为隐式上下文自动附加到发送中。

<img width="3840" height="2076" alt="Plan drawer, Queue drawer, and SceneTree focus indicator" src="https://raw.githubusercontent.com/JasonKim99/AgentGodette/master/git_src/plan+queue+selectnode.png" />


## 是什么

一个 Godot 4 编辑器插件，和本地的 ACP（Agent Client Protocol）adapter 通信 —— Claude 和 Codex 以 stdio 子进程方式运行，编辑器就是 client，没有 HTTP 中转。

## 解决什么问题

Godot 此前没有编辑器内的 AI agent。这个插件把编辑器本身变成了聊天界面：场景节点、FileSystem 文件、剪贴板截图都能当作上下文附加；agent 直接在你的项目里改文件，不再需要在独立的聊天 app 和编辑器之间来回复制粘贴。

## 环境要求

运行本地 ACP adapter 需要 [Node.js](https://nodejs.org) 18+。推荐安装：

```bash
npm install -g @agentclientprotocol/claude-agent-acp @zed-industries/codex-acp
```

插件首次运行时也会自动 fallback 到 `npx -y <package>`，所以全局安装是可选的 —— 预装只是免去首次下载，并且离线后依然可用。

### 选择 Claude adapter

ACP 协议下有两个 Claude adapter，dock 自动探测，谁装了用谁，都支持：

| Adapter | 维护方 | 说明 |
|---|---|---|
| **[`@agentclientprotocol/claude-agent-acp`](https://www.npmjs.com/package/@agentclientprotocol/claude-agent-acp)** *（推荐）* | Anthropic 官方 | 跟 Claude SDK 同步发版，"Opus 4.7 with 1M context" 这类最新描述能及时拿到。|
| [`@zed-industries/claude-code-acp`](https://github.com/zed-industries/claude-code-acp) | Zed | 封装 Claude CLI。能用，但 pin 的 Claude SDK 偏旧，模型描述会落后一两个版本。|

### 选择 Codex adapter

Codex 这边只有一个稳定选项。OpenAI 没出官方 ACP adapter，`@agentclientprotocol/codex-acp` 还在 pre-1.0 阶段，不够稳。

| Adapter | 维护方 | 说明 |
|---|---|---|
| **[`@zed-industries/codex-acp`](https://github.com/zed-industries/codex-acp)** *（推荐）* | Zed | Codex ACP 事实上的标准实现。|

### 鉴权

每个 adapter 自己处理登录。**先在 Godot 外面**各自跑一次底层 CLI 登录：

- `claude-agent-acp` / `claude-code-acp` → Claude CLI 登录
- `codex-acp` → OpenAI Codex CLI 登录

## 升级到新模型

模型名称和描述（"Opus 4.7"、"GPT-5.4 / xhigh"……）是 ACP adapter 发过来的，**不在插件代码里**。所以 Anthropic / OpenAI 一发新模型，dock 里能不能显示出来，取决于你机器上跑的是 adapter 的哪个版本。

### dock 的 adapter 探测顺序

dock 按下面这个顺序找 adapter，第一个找到的就用：

1. 全局装的 adapter（`npm install -g …`）
2. 本地 Zed 安装目录里的 adapter（如果你装了 Zed）
3. `npx -y <pkg>@<version>` —— 插件**在这里 pin 死了一个具体版本**，让插件构建可复现

每次插件发版会同步 bump pin。但如果你想立刻拿到最新模型字符串、不等下次插件发版，全局装一份就行 —— 第 1 条优先级最高，会绕过 pin。

### 刷新模型字符串

```bash
# Claude（Anthropic 官方版）
npm install -g @agentclientprotocol/claude-agent-acp@latest

# 或 Claude（Zed 版 —— 注意这个 SDK 故意 pin 得旧）
npm install -g @zed-industries/claude-code-acp@latest

# Codex
npm install -g @zed-industries/codex-acp@latest
```

然后在 dock 里**新建一个 thread** —— 已有 thread 保留的是当初创建时缓存的模型列表。新 thread 才会拿到最新的字符串。

### 为什么两个项目显示不一致

每个 Godot 项目都有自己独立的 `addons/godette_agent/` 副本。如果项目 A 用的是新版插件（pin 也新）、项目 B 还是旧版插件（pin 也旧），同一台机器上看到的模型描述也会不同。统一办法：要么把两个项目的插件都更新到同一版本（AssetLib 重新下载、git pull、或者直接覆盖 `addons/godette_agent/` 目录），要么全局装一份 adapter，让 pin 失效。

## 致谢

站在 [Zed](https://github.com/zed-industries/zed) 的肩膀上 —— ACP 传输层以及大部分 UX（plan / queue drawer、composer chip、transcript 持久化、tool-call 渲染）都是直接参照 Zed 的 external-agent 实现复刻的。
