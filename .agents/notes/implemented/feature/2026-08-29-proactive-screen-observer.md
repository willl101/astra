# Agent Note: Proactive screen observer

Status: implemented

English | [中文](2026-08-29-proactive-screen-observer.zh.md)

## Problem

A personal proactive assistant needs enough cross-application context to notice useful moments without keyboard capture, per-application adapters, constant model calls, or frequent interruptions. Sending raw screenshots to a multimodal model increases cost and disclosure, while ordinary Harness Session and attachment persistence retain model-visible input longer than this sensitive ambient context permits.

## Decision

The private `@deepseek-ai/dsh-experimental-proactive-screen` plugin performs macOS ScreenCaptureKit captures at a user-selected frequency. The helper captures display-composited pixels cropped to the foreground-window region, runs Apple Vision OCR in memory on every frame, suppresses known sensitive applications, and emits bounded text episodes. It writes no screenshots or OCR files. The later [composed foreground screen context decision](2026-08-31-composed-foreground-screen-context.md) replaces the original independent-window and visual-change gates.

The Host plugin suppresses consecutive identical per-application OCR and substantial overlap with recently notified tasks, then wakes one restrained Harness agent with reasoning disabled. Execution mode mounts the standard toolset for both passive and explicit triggers; companion mode mounts no execution tools. One compact policy defines passive observation as exact silence (`0`) unless an intervention now has clear practical or emotional value, and explicit triggering as one concrete result or one necessary question. The last model text is treated as the notification itself, so screen summaries, private deliberation, plans, and tool narration are invalid in both modes. The Host rejects escaped process narration and retries one malformed explicit result once. Requests and normal progress visible inside another assistant or development tool are already handled work, and visible implementation text never authorizes the agent to inspect or modify its own code.

Passive requests and explicit decisions use transient random Sessions that are disposed after each completed decision. Autonomous action defaults to Fn×2; typed instruction defaults to Fn + Space and opens an input-only bottom-center overlay. Both shortcuts are independently configurable through the same recorder and reject macOS, other-application, and mutual conflicts. A valid Accessibility selection becomes the complete model context and suppresses screenshot capture; typed text becomes primary intent, while an absent selection falls back to the foreground screenshot. Cancelling the overlay makes no model request. Every notification follow-up supplies its bounded local transcript to its own transient Session, so a slow conversation cannot queue later messages behind shared agent state. OCR, selection, and typed instruction remain in process, provider transport, and the applicable Harness Session policy, while controller logs retain only application identity, character count, accepted decision metadata, token usage, and notification text. Exact silence is omitted from the controller activity stream.

One global proactive-editing switch controls a native `write_to_editor` tool for passive perception and both explicit entrances. For an explicit editing instruction, the Host extracts and writes exact finished text through the same bridge if the agent omits the tool. The controller first restores the opaque Accessibility target and range captured before the instruction overlay took focus. If that position changed or rejects mutation, it captures the current editable field and writes there instead. Each destination tries direct Accessibility assignment, then a clipboard-preserving Command-V sent only to that destination's process. Passive writes are limited to small objective high-confidence corrections with negligible downside; explicit selection or instruction supplies stronger editing intent but never authorizes invented commitments, personal stances, sending, or submission. The Node tool waits for a versioned native action result and reports success only after the controller accepts the write.

Password managers, macOS credential and authentication applications, and the controller itself are blocked by default. ChatGPT and Codex are observable like other foreground applications; blocking the controller itself prevents direct self-feedback. The model receives untrusted OCR framing. Execution agents use a neutral scratch workspace, and an agent-scoped tool guard rejects access to the observer's repository or installed implementation. Delegated subagents and workflow loops are omitted because their tool calls would not carry that parent guard. Clear low-risk reversible work may run autonomously when execution is enabled. Sending, submission, deletion or overwrite, publishing, payments, and account, security, privacy, or permission changes require one concise confirmation; after the user explicitly approves that action in a follow-up, the agent executes it.

The optional `主动 AI.app` controller owns one Harness child process and exposes start, stop, four perception levels at 60, 15, 5, and 1 second intervals, execution and proactive-editing switches, two configurable explicit shortcuts, notification testing, foldable diagnostics, history, and notification-to-conversation continuation. With Input Monitoring access, the shortcut editor can record double Fn; combination shortcuts use the system hot-key service. Autonomous action displays a brief bottom-center non-activating pulse. Typed instruction expands the same visual into a non-activating input-only panel that becomes key without showing the controller; Enter submits, while Escape or an outside click cancels and closes it. The local conversation request allows a complete agent turn to take up to 120 seconds. The plugin emits a versioned JSONL activity and native-action stream only when the controller requests it. The controller persists bounded accepted metadata and notification text, but never screenshots, selected text, typed instruction, OCR text, editor text, or silent model decisions; its bundle id is blocked before local OCR and again before model invocation.

## Alternatives considered

**Per-application adapters.** Native APIs provide higher-quality semantics for mail, notes, browsers, and chat, but their permissions, schemas, and maintenance cost defeat a universal personal demo.

**Ambient keyboard and accessibility capture.** Continuous event capture could improve timing but collects higher-risk input and requires application-specific interpretation. The controller instead observes only the configured shortcut and reads one selected-text value after that explicit request. Passive perception remains screenshot-only.

**Accessibility assignment alone.** Direct attribute assignment avoids clipboard use but fails in many browser and Electron editors. A clipboard-preserving simulated paste remains the portable fallback, with key events sent only to the chosen editor process.

**Periodic screenshot upload.** Direct multimodal requests remove local OCR code but spend image tokens, disclose pixels, and depend on image-capable models. The selected DeepSeek Flash route is text-only.

**Durable Session logging.** Recording exact OCR prompts would restore normal Harness replay, compaction, and audit behavior, but append-only persistence conflicts with ambient-screen minimization. The experimental plugin states the replay gap instead of retaining sensitive text.

**Notification-only agent.** A notification-only first version minimizes authority, but cannot research or complete useful local work. The controller therefore exposes one explicit execution-capability switch, while the agent policy keeps passive authority narrow.

## Consequences

One generic observation path works across visible foreground macOS windows. Local OCR has no provider fee; exact-screen and recent-notification deduplication consume no model tokens, while all other non-empty screen context reaches the agent under a fixed output cap. Screenshots and OCR text do not accumulate on disk, and exact `0` silence does not enter the controller activity stream.

The controller has its own macOS Screen Recording identity and requires one explicit permission grant. Its bounded activity history persists accepted notification text until the user clears it, trading a small local audit trail for easier testing without retaining the ambient input that produced the decision.

The observer can misunderstand OCR, miss non-text state, and disclose text from an unblocked sensitive window. It has no durable reminders, future wake-up, or mobile location source. Passive Sessions are intentionally short-lived, so debugging ambient decisions uses explicit local diagnostic mode and must accept the resulting temporary candidate disclosure.

Native write-back works across most accessible text fields but remains best effort. Secure, protected, canvas-based, and non-accessible editors reject mutation. The captured position remains preferred; when it is unavailable, the current editable field is the explicit fallback.
