# Agent Note: Composed foreground screen context

Status: implemented

English | [中文](2026-08-31-composed-foreground-screen-context.zh.md)

## Problem

Independent application-window capture can omit display-composited pixels. Deterministic image-change, minimum-text, changed-text, similarity, and cooldown thresholds can also discard useful short or gradually changing context before the agent can judge it. Blocking ChatGPT and Codex conflicts with the intended universal foreground assistant while the controller already has a distinct self-app identity that can be blocked directly.

## Decision

Capture the final display-composited pixels cropped to the foreground application's largest visible layer-zero window. This remains a foreground-region capture rather than a whole-display upload and needs no application-specific path for windows that permit sharing. Run local Vision OCR on every scheduled frame.

Use the first complete ScreenCaptureKit compositor frame. Do not add application-specific retries, stabilization gates, or multi-frame selection to the universal loop.

Before model invocation, suppress only a consecutive identical OCR fingerprint for the same application and screen content that substantially overlaps a recently delivered notification. Send every other non-empty, bounded current-screen OCR to the agent in full. Register the stable value and silence policy as an agent-scoped system prompt, while keeping OCR in an untrusted user-level observation. The policy, not deterministic host heuristics, decides whether the context offers enough practical or genuine emotional value to justify output or action; exact `0` remains passive silence. Normalize a passive response that only narrates the screen or explains that nothing is actionable to the same silent outcome as a protocol safety net.

Keep credential applications, password managers, macOS authentication surfaces, Notification Center, and the controller itself blocked. Notification Center is excluded because a delivered assistant notification must never become fresh model context. Allow ChatGPT, Codex, browsers, document editors, Feishu, and other ordinary foreground applications through the same capture path. Inspect the foreground window's CoreGraphics sharing state before capture. If it declares `kCGWindowSharingNone`, skip passive perception; for an explicit request, capture the containing display and mark the protected foreground as omitted. The model uses the typed instruction and remaining visible context without exposing the technical limitation or attributing other regions to the foreground app.

Run explicit Fn requests on a serialized explicit lane independent from passive work, so a user request cannot be overwritten by later ambient frames or wait for an ongoing passive agent turn. Every turn remains transient. Notification follow-ups carry only the original notification and latest six explicit turns, allowing continued conversation without unbounded model context.

## Alternatives considered

**Capture the entire display.** This would include unrelated windows, menu-bar content, notifications, and more private text without improving the normal foreground task.

**Maintain application-specific capture adapters.** Process-family filters can repair one rendering architecture but add fragile bundle and window rules for every exceptional application.

**Retain deterministic usefulness thresholds.** Image-distance, minimum-character, new-character, similarity, and time gates reduce calls but cannot distinguish a valuable short message from low-value long text. They deny context before the agent can apply the product policy.

**Continue blocking ChatGPT and Codex.** This prevents useful cross-assistant and development context. Blocking the controller bundle still prevents the direct notification-dashboard feedback loop.

## Consequences

Shareable Word, Feishu, browser, ChatGPT, Codex, and other ordinary foreground windows use one capture implementation. Short text, scrolling pages, blinking cursors, and small changes can reach the agent. Consecutive identical OCR and recent notification overlap still avoid the clearest redundant calls.

Applications can enforce a non-shareable capture boundary. The generic observer skips it passively and uses a marked display-level fallback for explicit requests; it does not carry application-specific capture behavior.

OCR runs at every selected interval and more non-empty screens may invoke the model, especially at Focus and High. Cost and interruption control move deliberately to exact deduplication, bounded input and output, the restrained policy, and single-token `0` silence. Display-composited overlays inside the foreground region are included. The bundle and name block list remains a privacy heuristic, not a page-level security boundary.
