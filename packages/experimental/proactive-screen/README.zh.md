---
description: "通过按需单帧截图与本地 OCR 观察 macOS 屏幕，以统一的克制 agent 策略响应被动或主动触发，并返回少量主动结果。"
kind: "package-reference"
---

# @deepseek-ai/dsh-experimental-proactive-screen

[English](README.md) | 中文

## 概述

`dsh-experimental-proactive-screen` 让本地 Harness 进程无需键盘采集或逐应用适配，也能在 macOS 各应用中发现值得介入的时机。原生 helper 按设定频率截取合成后的前台窗口区域并运行 Apple Vision OCR；重复或近期已通知的上下文会在模型前抑制。主动行动默认 Fn×2，输入指令默认 Fn + Space 并打开屏幕下方中央的输入浮层。两者有选区时只使用选区，否则回退到截图。被动感知和两个主动入口共用一个克制 Agent 与可选的原位写回能力，仅介入门槛和明确意图不同。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [进一步探索](#further-exploration)
- [模型体验](#model-experience)
- [已知限制与延期工作](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用本包

先使用 shadow 模式，只检查决策元数据；确认观察频率合适后再切换到通知模式。

### 前置条件与隐私

本包需要 macOS、`/usr/bin/swift`、启动应用的“屏幕录制”权限、本地 subprocess provider，以及已配置的文本模型路由。屏幕帧只留在进程内存，Apple Vision OCR 不产生 API 费用。受长度限制的 OCR 文本会发送给配置的模型 provider；敏感内容可见时，除非 block list 已覆盖该应用，否则不要运行观察器。

密码管理器、钥匙串访问、密码、macOS 身份验证窗口、macOS 通知中心与控制台自身默认被屏蔽。ChatGPT、Codex、浏览器、文档编辑器与聊天应用在窗口允许截取时和其他前台应用一样可被观察。block list 能减少明显的数据暴露与自反馈，但不是安全边界。

### 最小配置

从本仓库挂载 source overlay：

```sh
pnpm run proactive:run
```

附带的 overlay 在本地 shadow 校准后使用 `deepseek-v4-flash` 与通知模式。只需观察决策元数据时，把 overlay 中的 `notificationMode` 改为 `shadow`。

该脚本会挂载以下 source overlay：

```yaml
- insert:
    - id: experimental-proactive-screen
      name: './src/index.ts'
      config:
        provider: deepseek-official
        model: deepseek-v4-flash
        notificationMode: notify
```

| 字段 | 默认值 | 含义 |
|---|---|---|
| `provider` | 必填 | 已注册的文本模型 provider 路由 |
| `model` | 必填 | 主动决策使用的模型 id |
| `notificationMode` | `shadow` | 记录决策元数据或投递通过的通知 |
| `captureIntervalSeconds` | `15` | 两次合成前台区域截图的间隔 |
| `maxInputCharacters` | `2400` | 单次请求的最大 OCR 字符数 |
| `maxOutputTokens` | `320` | 每个工具 agent 模型 step 的输出 token 上限 |
| `allowAgentExecution` | `true` | 挂载完整 standard 工具；关闭时 agent 只能静默或返回通知 |
| `allowEditorWrite` | `true` | 为捕获的当前编辑器暴露受约束的替换与插入工具 |
| `blockedBundleIds` | 内置敏感应用与自身应用列表 | OCR 永不进入模型的应用 |

生成的[配置目录](../../../docs/config-catalog.zh.md#deepseek-aidsh-experimental-proactive-screen)是可接受字段及其 JSDoc 的穷尽式真源。

### 本地控制 App

在仓库根目录安装并打开私有 macOS 控制台：

```sh
pnpm run app:proactive:install
```

该命令会把 `Astra.app` 安装到当前用户的“应用程序”目录。标准可缩放控制台窗口和菜单栏入口可以控制感知、Light（60 秒）到 High（1 秒）四档强度、Agent 执行与主动编辑，分别自定义两个快捷键，并测试通知或清空历史。主动行动默认 Fn×2，在屏幕下方中央显示星光；输入指令默认 Fn + Space，星光展开为不激活 App 的纯输入浮层，回车发送、Esc 或点击其他位置取消，空输入回车等同主动行动。浮层会成为 key window 以支持 macOS 输入法组合与候选窗，但不会激活或显示控制台主窗口。两个快捷键都会检查 macOS、其他应用和彼此的冲突。有选区时选区成为完整上下文，否则截图。开启主动编辑后，Agent 仅在必要且低风险时写入触发瞬间捕获的编辑位置，优先追加；替换需要主动选区与明确改写指令，目标变化时安全失败。写入优先使用 Accessibility，失败时保留并恢复剪贴板，并把 Command-V 只发送给原进程。安全或受保护编辑器会安全失败并把结果留在通知中。只有 Fn×2 需要“输入监控”，选区与写回需要“辅助功能”，截图需要“屏幕录制”。非零结果保持精简通知，并在独立可缩放窗口中继续对话。

控制台最多在 `Library/Application Support/ProactiveAI/activity.jsonl` 保留 1,000 条本地活动记录。记录只包含时间、应用身份、OCR 字符数、已接受的决策结果、token 数、错误与提醒文案；模型严格输出 `0` 时不产生决策记录。记录不包含截图或 OCR 原文。App 的 bundle id 同时在采集层与模型抑制层被屏蔽，因此控制台保持可见时不会占用 episode 或模型调用。

### 正常运行

使用其他应用时保持 Harness 进程运行。观察器按设定频率截取并 OCR 可见的前台窗口区域，只跳过同应用连续完全相同的 OCR 和与近期通知任务高度重合的内容。其他非空、受长度限制的当前画面 OCR 会完整进入 agent；不会把更早画面作为模型记忆加入。

Shadow 模式记录应用 bundle id、OCR 字符数、fingerprint 与已接受的决策元数据，但不记录 OCR 文本。`DSH_PROACTIVE_DIAGNOSTIC=trace` 会把候选与静默决策暴露到 stderr，仅供本地校准，不能作为日常隐私模式使用。控制台改为启用带版本的纯元数据 JSONL 活动流；由于 App 需要展示并持久化提醒历史，通过的通知文案也包含在其中。

-----

<a id="understand-the-implementation"></a>
## 理解实现

<details>
<summary>实现细节——点击展开</summary>

Swift helper 负责 ScreenCaptureKit 单帧截图、本地 OCR、Accessibility 选区与编辑目标、原位写回、敏感应用抑制、窗口共享状态检测以及 NDJSON 请求／结果流；明确选区存在时不截图。TypeScript 插件负责去重、standard 工具 Agent 策略、编辑意图识别、确定性写回兜底、结果校验与通知投递。工具 Agent 从中性的临时工作区启动，而不是把 Harness 仓库作为默认工作区；Agent 级 guard 会拒绝所有指向观察器自身实现的工具调用，并隐藏可能绕过该 guard 的委派 Agent／工作流循环。两个主动入口使用相同策略与能力，并进入独立执行通道。

原始帧永不进入 attachment store。被动观察、主动快捷键请求和每次通知后续对话都使用短生命周期 agent session，并在本回合完成后释放；最近六条明确对话在后续回合间携带受限上下文。所有模式使用同一项能力开关。App 活动日志只保存元数据与通过的通知文案，不保存截图、选区原文、OCR 原文或模型静默决策。

| 文件 | 职责 |
|---|---|
| [`native/ScreenObserver.swift`](native/ScreenObserver.swift) | 合成前台区域截图、Vision OCR 与 NDJSON episode |
| [`src/index.ts`](src/index.ts) | 触发抑制、工具 agent 回合、生命周期与通知投递 |
| [`app/ProactiveAIApp.swift`](app/ProactiveAIApp.swift) | 原生生命周期控制、测试动作、统计与受限活动历史 |
| [`src/invariant.ts`](src/invariant.ts) | 包级 invariant 归属 |

[主动屏幕观察器 Agent Note](../../../.agents/notes/implemented/feature/2026-08-29-proactive-screen-observer.zh.md)负责隐私、安全与沉默优先决策。

</details>

-----

<a id="further-exploration"></a>
## 进一步探索

- [Harness 架构](../../../docs/architecture.zh.md)——插件组合与能力归属。
- [LLM 流式输出子系统](../../../docs/subsystems/llm-streaming.zh.md)——provider 中立的一次性请求词汇。
- [Subprocess 子系统](../../../docs/subsystems/subprocess.zh.md)——受管理的 helper 与通知进程。
- [主动屏幕观察器 Agent Note](../../../.agents/notes/implemented/feature/2026-08-29-proactive-screen-observer.zh.md)——设计理由与接受的取舍。

-----

<a id="model-experience"></a>
## 模型体验

### 安静的主动决策

#### 模型看到什么

一段精简的 Agent 级指令把不可信的屏幕或选区数据与用户主动输入的请求分开，并定义两种触发语义。被动感知默认静默，只有需求明确、能够产出具体结果，而且预期实际价值或情绪价值明显高于打扰与风险时才介入，否则只返回单字符 `0`。主动触发必须立即提供价值：意图清晰就执行最小必要动作，信息不足才问一个具体问题。两种模式使用同一套工具与判断，不包含邮件、聊天、网页或文档的场景分支；增加工具即可扩展能力。低风险、可恢复工作可以执行，发送、提交、发布、删除数据、付款及账户、安全、隐私或权限变更必须先确认。最终文字只包含成品、已验证结果、必要确认或具体问询，不能复述画面或叙述观察、思考、计划与工具过程。

#### Token 影响

同应用连续完全相同、被屏蔽或与近期通知任务重复的屏幕不消耗 token。其他非空 OCR 即使很短或只有轻微变化，也会以 `off` reasoning effort 和每 step 320 token 上限进入 agent。执行模式只调用必要的 standard 工具；陪伴模式的工具目录为空。严格输出 `0` 是可靠的单 token 静默协议，既不通知，也不记录为一次决策。

#### KV Cache 影响

Standard agent 的 system 与工具前缀保持稳定，触发模式、本地时间、应用与 OCR 内容位于最新 user message。每个决策回合使用短生命周期 session，避免环境上下文或卡住的 agent 状态累积；最近六条明确后续对话会放进下一次请求。稳定前缀仍能在 provider 支持时利用前缀缓存。

## 已知限制与延期工作

<a id="known-limitations-and-deferred-work"></a>

这些限制让原型保持精简，并明确当前隐私与实用性边界。

- **仅限 macOS 前台窗口**——当前前台窗口可以位于任意已连接显示器，但没有 Windows、Linux、隐藏窗口或移动端定位来源。
- **应用共享策略**——前台窗口可以明确禁止 macOS 截取。被动模式直接跳过；主动请求会静默回退到窗口所在的整块屏幕，并标记受保护的前台内容已缺失，使模型使用用户指令和其他可见信息继续处理，不向用户暴露截图细节，也不把其他区域误认为前台内容。
- **仅限可见或明确选中文字**——被动感知使用 Vision OCR；主动入口可以改用当前 Accessibility 选区。两者都无法理解纯图片含义、隐藏内容、应用状态与附件。
- **编辑写回为尽力支持**——多数原生、浏览器与 Electron 文本框可接受 Accessibility 或定向模拟粘贴；安全、受保护、Canvas 或不暴露可编辑目标的编辑器会拒绝，捕获位置不可用时回退到当前可编辑区域。
- **没有环境记忆或持久提醒**——每次感知决策只看到当前截图 OCR，无法安排未来唤醒；主动后续对话只保留该次明确交互。
- **一个 Agent、三档意图**——被动感知、主动行动与输入指令共用工具。被动模式高度克制；两个主动入口绕过被动抑制，输入文字是首要意图。主动编辑是全局统一能力，只随意图变清晰而更可能使用。
- **启发式隐私 block list**——bundle id 与名称无法识别所有敏感窗口、无痕浏览标签或临时浮层。
- **主动对话历史**——每个 agent session 都会在本回合后释放。控制台只向模型发送原提醒与最近六条明确后续对话，但会在本地保留完整、有界的可见记录，因此关闭、最小化或重新打开对话窗口都不会丢失历史。截图本身永不持久化。
- **Source helper 启动成本**——附带的 overlay 启动 Swift 源码，每次进程启动会有一次编译延迟。
- **实验性约定**——包配置、prompt 与阈值可在没有兼容性承诺的情况下变化。

<a id="dev-note"></a>
### 开发备注

<details>
<summary>维护者的工作上下文——点击展开</summary>

无。

</details>
