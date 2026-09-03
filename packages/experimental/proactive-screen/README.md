---
description: "Observe a macOS screen with on-demand screenshots and local OCR, wake one restrained tool agent from passive or explicit triggers, and deliver rare proactive results."
kind: "package-reference"
---

# @deepseek-ai/dsh-experimental-proactive-screen

English | [中文](README.zh.md)

## Summary

`dsh-experimental-proactive-screen` lets a local Harness process notice useful moments across macOS applications without keyboard capture or per-application integrations. A native helper captures the display-composited foreground-window region and runs Apple Vision OCR. Repeated or recently notified context is suppressed before the model. Autonomous action defaults to Fn×2; typed instruction defaults to Fn + Space and opens a bottom-center input overlay. Both use selected text alone when Accessibility exposes it and otherwise fall back to a screenshot. Passive perception and both explicit entrances share one restrained agent and optional native editor write-back; only their intervention threshold and supplied intent differ.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Further Exploration](#further-exploration)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

Start in shadow mode, inspect only decision metadata, and change to notification mode after the observed frequency feels appropriate.

### Prerequisites and privacy

The package requires macOS, `/usr/bin/swift`, Screen Recording permission for the launching application, a local subprocess provider, and a configured text-model route. Screen frames remain in process memory and Apple Vision OCR has no API fee. The bounded OCR text is sent to the configured model provider; do not use the observer while sensitive content is visible unless the block list covers that application.

Password managers, Keychain Access, Passwords, macOS authentication windows, macOS Notification Center, and the controller itself are blocked by default. ChatGPT, Codex, browsers, document editors, and chat applications are observable like other foreground applications when their windows permit capture. The block list reduces obvious exposure and self-referential feedback, but it is not a security boundary.

### Minimal configuration

Mount the source overlay from this repository:

```sh
pnpm run proactive:run
```

The included overlay uses `deepseek-v4-flash` and notification mode after local shadow calibration. Change `notificationMode` to `shadow` when only decision metadata should be observed.

The script mounts this source overlay:

```yaml
- insert:
    - id: experimental-proactive-screen
      name: './src/index.ts'
      config:
        provider: deepseek-official
        model: deepseek-v4-flash
        notificationMode: notify
```

| Field | Default | Meaning |
|---|---|---|
| `provider` | required | Registered text-model provider route |
| `model` | required | Model id used for proactive decisions |
| `notificationMode` | `shadow` | Record decision metadata or deliver accepted notifications |
| `captureIntervalSeconds` | `15` | Interval between composed foreground-region screenshots |
| `maxInputCharacters` | `2400` | Maximum OCR characters in one request |
| `maxOutputTokens` | `320` | Maximum output tokens for each tool-agent model step |
| `allowAgentExecution` | `true` | Mount the complete standard toolset; when false, the agent can only stay silent or return a notification |
| `allowEditorWrite` | `true` | Expose restrained replace/insert tools for the captured active editor |
| `blockedBundleIds` | built-in sensitive and self-app list | Applications whose OCR never reaches the model |

The generated [configuration catalog](../../../docs/config-catalog.md#deepseek-aidsh-experimental-proactive-screen) is the exhaustive source for accepted fields and their JSDoc.

### Local controller app

Install and open the private macOS controller from the repository root:

```sh
pnpm run app:proactive:install
```

The command installs `Astra.app` in the current user's Applications folder. Its standard resizable controller window and menu-bar item start or stop perception, select Light (60 seconds), Standard (15 seconds), Focus (5 seconds), or High (1 second), control execution and proactive editing separately, customize both shortcuts, test notification delivery, and clear local history. Autonomous action defaults to Fn×2 and shows a bottom-center star pulse. Typed instruction defaults to Fn + Space; the star expands into a non-activating input-only overlay where Enter sends, Escape cancels, clicking elsewhere cancels, and empty Enter behaves like autonomous action. The overlay becomes the key window for macOS input-method composition without activating or showing the controller window. Both shortcuts reject conflicts with macOS, other applications, and each other. A valid selection becomes the complete task context; without one, the app captures the foreground screen. With proactive editing enabled, the agent writes to the editor captured at trigger time only when doing so is necessary and low risk, preferring insertion. Replacement requires an intentional selection and an explicit rewrite request; target changes fail safely. Accessibility assignment is tried first, followed by a clipboard-preserving Command-V sent only to the original process. Secure or protected editors fail safely and leave the result in the notification. Input Monitoring is needed only for a Fn×2 shortcut, Accessibility for selection and write-back, and Screen Recording for capture. Nonzero results remain compact notifications that open a separate resizable follow-up window.

The controller persists at most 1,000 local activity records under `Library/Application Support/ProactiveAI/activity.jsonl`. Records contain timestamps, application identity, OCR character counts, accepted decision outcomes, token counts, errors, and notification text. Exact model silence (`0`) produces no decision record. Records never contain screenshots or OCR text. The app's bundle id is blocked in both capture and model suppression, so leaving the dashboard visible does not consume an episode or model call.

### Normal operation

Keep the Harness process running while using other applications. The observer captures and OCRs the visible foreground-window region at the chosen interval. It skips only consecutive identical OCR from the same application and tasks that substantially overlap a recent notification. Every other non-empty, bounded current-screen OCR reaches the agent in full; no earlier screen is added as model memory.

Shadow mode logs the app bundle id, OCR character count, fingerprint, and accepted decision metadata, but not the OCR text. `DSH_PROACTIVE_DIAGNOSTIC=trace` exposes candidates and silent decisions to stderr for local calibration and must not be used as the routine privacy mode. The controller instead enables a versioned metadata-only JSONL activity stream; accepted notification text is included because the app displays and persists the notification history.

-----

<a id="understand-the-implementation"></a>
## Understand the implementation

<details>
<summary>Implementation internals — click to expand</summary>

The Swift helper owns one-shot ScreenCaptureKit capture, local OCR, Accessibility selection and editor targets, native write-back, sensitive-app suppression, window-sharing detection, and an NDJSON request/result stream. It captures only when no valid explicit selection exists. The TypeScript plugin owns deduplication, the standard tool-agent policy, editor-intent detection, deterministic write-back fallback, result validation, and notification delivery. Tool agents start from a neutral scratch workspace instead of the Harness repository; an agent-scoped guard blocks every tool call aimed at the observer's own implementation, and delegated agent/workflow loops are hidden because they could escape that guard. Both explicit shortcuts use the same policy and capabilities on an independent execution lane.

Raw frames never enter the attachment store. Passive observations, explicit shortcut requests, and each notification follow-up use short-lived agent sessions that are disposed after the completed turn; the latest six explicit conversation turns carry bounded context between follow-ups. All modes use the same capability setting. The app's activity log stores only metadata and accepted notification text, not screenshots, selected source text, OCR source text, or silent model decisions.

| File | Role |
|---|---|
| [`native/ScreenObserver.swift`](native/ScreenObserver.swift) | Composed foreground-region capture, Vision OCR, and NDJSON episodes |
| [`src/index.ts`](src/index.ts) | Trigger suppression, tool-agent turns, lifecycle, and notification delivery |
| [`app/ProactiveAIApp.swift`](app/ProactiveAIApp.swift) | Native lifecycle controls, test actions, statistics, and bounded activity history |
| [`src/invariant.ts`](src/invariant.ts) | Package invariant ownership |

The [proactive screen observer Agent Note](../../../.agents/notes/implemented/feature/2026-08-29-proactive-screen-observer.md) owns the privacy, safety, and silence-first decisions.

</details>

-----

<a id="further-exploration"></a>
## Further Exploration

- [Harness architecture](../../../docs/architecture.md) — plugin composition and capability ownership.
- [LLM streaming subsystem](../../../docs/subsystems/llm-streaming.md) — provider-neutral one-shot request vocabulary.
- [Subprocess subsystem](../../../docs/subsystems/subprocess.md) — managed helper and notification processes.
- [Proactive screen observer Agent Note](../../../.agents/notes/implemented/feature/2026-08-29-proactive-screen-observer.md) — rationale and accepted trade-offs.

-----

<a id="model-experience"></a>
## Model Experience

### Quiet proactive decision

#### What the model sees

One short agent-scoped instruction separates untrusted screen or selection context from a typed user request and defines two trigger semantics. Passive observation is silent by default; it intervenes only when a need is concrete, a useful result can be produced, and expected practical or emotional value clearly exceeds interruption and risk. Otherwise it returns the sole character `0`. An explicit trigger must help now: clear intent leads to the minimum necessary action, while missing information leads to one specific question. Both modes share the same tools and judgment with no mail, chat, browser, or document branches; adding tools expands capability without expanding scenario prompts. Low-risk reversible work may proceed, while sending, submitting, publishing, deleting data, payments, and account, security, privacy, or permission changes require confirmation. Final text contains only finished content, a verified outcome, necessary confirmation, or a specific question—never screen repetition, perception, reasoning, plans, or tool narration.

#### Token effect

No tokens are used for consecutively identical, blocked, or recently-notified screens. Other non-empty OCR, even when short or only slightly changed, reaches the agent with reasoning effort `off` and a 320-token per-step output cap. In execution mode it may call only necessary standard tools; in companion mode the tool catalog is empty. Exact `0` is the reliable one-token silence protocol and is neither notified nor recorded as a decision.

#### KV Cache effect

The standard agent's system and tool prefix stays stable, while trigger mode, local time, application, and OCR content arrive in the latest user message. Every decision turn uses a short-lived session to avoid accumulating ambient or stalled agent state; the latest six explicit follow-up turns are supplied in the next request. Stable prefixes still allow provider-side prefix caching where supported.

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

These limits keep the prototype small and make its current privacy and usefulness boundaries explicit.

- **Foreground macOS windows only** — the current foreground window can be on any connected display, but there is no Windows, Linux, hidden-window, or mobile location source.
- **Application sharing policy** — a foreground window can explicitly prohibit macOS capture. Passive mode skips it. Explicit requests silently fall back to the containing display and mark the protected foreground as omitted, so the model can use the typed instruction and other visible context without exposing capture details or misattributing other regions.
- **Visible or explicitly selected text only** — passive perception uses Vision OCR; explicit entrances can instead use the current Accessibility selection. Both miss image-only meaning, hidden content, application state, and attachments.
- **Best-effort editor write-back** — most native, browser, and Electron text fields accept Accessibility or process-targeted simulated paste. Secure, protected, canvas-based, or non-accessible editors reject writes; when the captured position is unavailable, the current editable field is the fallback.
- **No ambient memory or durable reminders** — each perception decision sees only the current screenshot OCR and cannot schedule a future wake-up. Fn follow-up retains only that explicit interaction.
- **One agent, three intent levels** — passive perception, autonomous action, and typed instruction share tools. Passive mode remains highly restrained; explicit entrances bypass passive suppression, while typed text is primary intent. Proactive editing is one global capability and becomes more likely only as intent becomes clearer.
- **Heuristic privacy block list** — bundle ids and names cannot identify every sensitive window, private browser tab, or transient overlay.
- **Explicit conversation history** — every agent session is disposed after its turn. The local controller sends only the notification and latest six explicit follow-up turns to the model, while keeping the complete bounded conversation locally so closing, minimizing, or reopening its window preserves the visible history. Screenshots themselves are never persisted.
- **Source helper startup** — the included overlay launches Swift source and pays a one-time compile delay on each process start.
- **Experimental contract** — package configuration, prompts, and thresholds can change without a compatibility promise.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>
