import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics
import Darwin
import OSLog
import SwiftUI
import UserNotifications

private let activityPrefix = "[proactive-screen:activity] "
private let maximumHistoryRecords = 1_000
private let maximumVisibleReminders = 3
private let maximumConversationSessions = 100
private let maximumConversationTurns = 200
private let maximumFollowUpContextTurns = 6
private let notificationCategory = "PROACTIVE_REMINDER"
private let continueAction = "CONTINUE_CHAT"
private let captureIntervalDefaultsKey = "proactive.capture-interval-seconds"
private let agentExecutionDefaultsKey = "proactive.allow-agent-execution"
private let editorWriteDefaultsKey = "proactive.allow-editor-write"
private let shortcutDefaultsKey = "proactive.explicit-shortcut"
private let instructionShortcutDefaultsKey = "proactive.instruction-shortcut"
private let pauseUntilDefaultsKey = "proactive.pause-until"
private let excludedAppsDefaultsKey = "proactive.excluded-apps"
private let proactiveLogger = Logger(subsystem: "ai.deepseek.proactive.local", category: "shortcut")
private let proactiveHotKeySignature: OSType = 0x50524149 // PRAI

private func isPresentableReminder(_ message: String?) -> Bool {
  guard let message else { return false }
  let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  guard !normalized.isEmpty else { return false }
  let silentSuffix = try? NSRegularExpression(pattern: "(?:^|\\s)0[。.]?\\s*$")
  let fullRange = NSRange(normalized.startIndex..., in: normalized)
  if silentSuffix?.firstMatch(in: normalized, range: fullRange) != nil { return false }
  if normalized.hasPrefix("0 ") || normalized.hasPrefix("0:") || normalized.hasPrefix("0：") { return false }
  let processPrefixes = [
    "i'll ", "i will ", "i'm ", "i am ", "i see ", "let me ", "passive observation", "the user ",
    "the context ", "the screen ", "the conversation ", "the page ", "the window ", "this is ", "this appears",
    "the current agent", "the workspace context", "i have the code", "i observe ", "actually ", "same task",
    "identical screen", "final:", "final：",
    "still in ", "still on ", "still viewing ", "looking at ", "looking at the ", "looking at this ",
    "我正在分析", "我正在检查", "我正在修正", "我分析了", "我检查了",
  ]
  let passiveSilenceMarkers = [
    "需要保持静默", "应该保持静默", "当前处于被动感知模式", "没有新的可执行请求", "没有需要我主动介入",
    "no action needed", "no intervention needed", "nothing actionable", "passive trigger", "passive mode",
    "我不提交", "不会提交", "等你的明确指示",
  ]
  return !processPrefixes.contains(where: normalized.hasPrefix)
    && !passiveSilenceMarkers.contains(where: normalized.contains)
}

private func notificationPreview(_ message: String) -> String {
  let normalized = message
    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let limit = normalized.range(of: "\\p{Han}", options: .regularExpression) == nil ? 150 : 72
  guard normalized.count > limit else { return normalized }
  let prefix = String(normalized.prefix(limit))
  let marks = ["。", "！", "？", ".", "!", "?"]
  let boundary = marks.compactMap { prefix.range(of: $0, options: .backwards)?.upperBound }.max()
  let clipped = boundary.map { String(prefix[..<$0]) }
    ?? String(prefix.prefix(limit - 1)) + "…"
  return clipped.trimmingCharacters(in: .whitespacesAndNewlines) + "  点击查看完整内容"
}

@discardableResult
private func copyToPasteboard(_ text: String) -> Bool {
  NSPasteboard.general.clearContents()
  return NSPasteboard.general.setString(text, forType: .string)
}

private enum ShortcutKind: String, Codable {
  case doubleFunction
  case keyCombination
}

private struct ShortcutDefinition: Codable, Equatable {
  let kind: ShortcutKind
  let keyCode: UInt32?
  let modifiers: UInt32?
  let keyLabel: String?

  static let actionDefault = ShortcutDefinition(
    kind: .doubleFunction,
    keyCode: nil,
    modifiers: nil,
    keyLabel: nil)

  static let instructionDefault = ShortcutDefinition(
    kind: .keyCombination,
    keyCode: 49,
    modifiers: UInt32(kEventKeyModifierFnMask),
    keyLabel: "Space")

  static func load(key: String, default defaultValue: ShortcutDefinition) -> ShortcutDefinition {
    guard let data = UserDefaults.standard.data(forKey: key),
          let value = try? JSONDecoder().decode(ShortcutDefinition.self, from: data),
          value.isValid else { return defaultValue }
    return value
  }

  var isValid: Bool {
    kind == .doubleFunction || (keyCode != nil && modifiers != nil && keyLabel != nil)
  }

  var displayName: String {
    guard kind == .keyCombination, let modifiers, let keyLabel else { return "Fn ×2" }
    if modifiers == UInt32(kEventKeyModifierFnMask), keyLabel == "Space" {
      return "Fn + Space"
    }
    var parts: [String] = []
    if modifiers & UInt32(kEventKeyModifierFnMask) != 0 { parts.append("fn") }
    if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
    if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
    if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
    if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
    parts.append(keyLabel)
    return parts.joined()
  }
}

private struct SelectedTextContext {
  let text: String
  let app: String
  let bundleId: String
}

private enum ShortcutPurpose: String, Identifiable {
  case action
  case instruction

  var id: String { rawValue }
  var title: String { self == .action ? "主动行动" : "输入指令" }
  var defaultShortcut: ShortcutDefinition {
    self == .action ? .actionDefault : .instructionDefault
  }
}

private enum ExplicitTriggerKind: Equatable {
  case action
  case instruction
}

private enum EditorWriteMode: String {
  case replaceSelection = "replace_selection"
  case insertAfterSelection = "insert_after_selection"
  case insertAtCursor = "insert_at_cursor"
}

private struct EditorTextAnchor: Equatable {
  let before: String
  let selected: String
  let after: String
}

private final class EditorTarget: @unchecked Sendable {
  let id = UUID().uuidString
  let element: AXUIElement
  let processIdentifier: pid_t
  let selectedRange: CFRange
  let textAnchor: EditorTextAnchor?
  let capturedAt = Date()

  init(
    element: AXUIElement,
    processIdentifier: pid_t,
    selectedRange: CFRange,
    textAnchor: EditorTextAnchor?
  ) {
    self.element = element
    self.processIdentifier = processIdentifier
    self.selectedRange = selectedRange
    self.textAnchor = textAnchor
  }
}

private struct CompletedEditorWrite {
  let completedAt: Date
  let ok: Bool
  let message: String
}

private struct UndoEditorWrite {
  let element: AXUIElement
  let processIdentifier: pid_t
  let range: CFRange
  let insertedText: String
  let originalText: String
  let originalAnchor: EditorTextAnchor
  let completedAt: Date
}

private enum EditorWriteAttempt {
  case succeeded
  case rejected
  case uncertain
}

private struct CapturedInteraction {
  let selection: SelectedTextContext?
  let editorTargetId: String?
  let application: NSRunningApplication?
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
  var value: UInt32 = 0
  if flags.contains(.command) { value |= UInt32(cmdKey) }
  if flags.contains(.shift) { value |= UInt32(shiftKey) }
  if flags.contains(.option) { value |= UInt32(optionKey) }
  if flags.contains(.control) { value |= UInt32(controlKey) }
  if flags.contains(.function) { value |= UInt32(kEventKeyModifierFnMask) }
  return value
}

private func shortcutKeyLabel(for event: NSEvent) -> String {
  switch event.keyCode {
  case 36: return "↩"
  case 48: return "⇥"
  case 49: return "Space"
  case 51: return "⌫"
  case 53: return "Esc"
  case 115: return "Home"
  case 116: return "Page Up"
  case 117: return "⌦"
  case 119: return "End"
  case 121: return "Page Down"
  case 123: return "←"
  case 124: return "→"
  case 125: return "↓"
  case 126: return "↑"
  default:
    let text = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? "Key (event.keyCode)" : text.uppercased()
  }
}

private func shortcutDefinition(from event: NSEvent) -> ShortcutDefinition? {
  let modifiers = carbonModifiers(from: event.modifierFlags)
  let hasIntentionalModifier = modifiers & UInt32(controlKey | optionKey) != 0
    || modifiers & UInt32(kEventKeyModifierFnMask) != 0
    || modifiers.nonzeroBitCount >= 2
  guard hasIntentionalModifier else { return nil }
  return ShortcutDefinition(
    kind: .keyCombination,
    keyCode: UInt32(event.keyCode),
    modifiers: modifiers,
    keyLabel: shortcutKeyLabel(for: event))
}

private func cocoaModifiers(from carbon: UInt32) -> UInt {
  var value: UInt = 0
  if carbon & UInt32(cmdKey) != 0 { value |= NSEvent.ModifierFlags.command.rawValue }
  if carbon & UInt32(shiftKey) != 0 { value |= NSEvent.ModifierFlags.shift.rawValue }
  if carbon & UInt32(optionKey) != 0 { value |= NSEvent.ModifierFlags.option.rawValue }
  if carbon & UInt32(controlKey) != 0 { value |= NSEvent.ModifierFlags.control.rawValue }
  if carbon & UInt32(kEventKeyModifierFnMask) != 0 { value |= NSEvent.ModifierFlags.function.rawValue }
  return value
}

private func conflictsWithSystemSymbolicHotKey(_ shortcut: ShortcutDefinition) -> Bool {
  guard let keyCode = shortcut.keyCode, let modifiers = shortcut.modifiers else { return false }
  let domain = "com.apple.symbolichotkeys" as CFString
  CFPreferencesAppSynchronize(domain)
  guard let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] else {
    return false
  }
  let expectedModifiers = cocoaModifiers(from: modifiers)
  for value in hotKeys.values {
    guard let entry = value as? [String: Any],
          (entry["enabled"] as? NSNumber)?.boolValue == true,
          let detail = entry["value"] as? [String: Any],
          let parameters = detail["parameters"] as? [NSNumber],
          parameters.count >= 3 else { continue }
    if parameters[1].uint32Value == keyCode,
       parameters[2].uintValue == expectedModifiers { return true }
  }
  return false
}

private func validateShortcutRegistration(_ shortcut: ShortcutDefinition) -> String? {
  guard shortcut.kind == .keyCombination,
        let keyCode = shortcut.keyCode,
        let modifiers = shortcut.modifiers else { return nil }
  if conflictsWithSystemSymbolicHotKey(shortcut) {
    return "这个快捷键已被 macOS 系统功能占用。"
  }
  var reference: EventHotKeyRef?
  let identifier = EventHotKeyID(signature: proactiveHotKeySignature, id: 99)
  let status = RegisterEventHotKey(
    keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
  if let reference { UnregisterEventHotKey(reference) }
  if status == noErr { return nil }
  if status == eventHotKeyExistsErr { return "这个快捷键已被系统或其他应用占用。" }
  return "无法注册这个快捷键（(status)）。"
}

private func functionKeyHasSystemAction() -> Bool {
  let domain = "com.apple.HIToolbox" as CFString
  CFPreferencesAppSynchronize(domain)
  guard let number = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? NSNumber else {
    return false
  }
  return number.intValue != 0
}

@MainActor
private final class EditorTargetStore {
  static let shared = EditorTargetStore()
  private var targets: [String: EditorTarget] = [:]
  private var completedWrites: [String: CompletedEditorWrite] = [:]
  private var undoWrite: UndoEditorWrite?

  var canUndo: Bool {
    guard let undoWrite else { return false }
    return Date().timeIntervalSince(undoWrite.completedAt) <= 600
  }

  func capture() -> CapturedInteraction {
    guard AXIsProcessTrusted() else {
      return CapturedInteraction(selection: nil, editorTargetId: nil, application: nil)
    }
    let application = NSWorkspace.shared.frontmostApplication
    guard application?.bundleIdentifier != "ai.deepseek.proactive.local" else {
      return CapturedInteraction(selection: nil, editorTargetId: nil, application: application)
    }
    let system = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
      let focusedValue,
      CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
      return CapturedInteraction(selection: nil, editorTargetId: nil, application: application)
    }
    let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
    var roleValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
       let role = roleValue as? String,
       role == "AXSecureTextField" {
      return CapturedInteraction(selection: nil, editorTargetId: nil, application: application)
    }
    var selectedValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedValue)
    let rawSelection = selectedValue as? String ?? ""
    let trimmedSelection = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
    let selection = trimmedSelection.isEmpty ? nil : SelectedTextContext(
      text: String(trimmedSelection.prefix(12_000)),
      app: application?.localizedName ?? "Unknown",
      bundleId: application?.bundleIdentifier ?? "unknown")

    var rangeValue: CFTypeRef?
    var selectedRange = CFRange(location: 0, length: 0)
    let hasRange = AXUIElementCopyAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success
      && rangeValue.map { AXValueGetValue(unsafeBitCast($0, to: AXValue.self), .cfRange, &selectedRange) } == true
    var selectedTextSettable = DarwinBoolean(false)
    var selectedRangeSettable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
    AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeSettable)
    let role = roleValue as? String ?? ""
    let textRole = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role)
    let editable = hasRange && (selectedTextSettable.boolValue || selectedRangeSettable.boolValue || textRole)
    guard editable, let application else {
      return CapturedInteraction(selection: selection, editorTargetId: nil, application: application)
    }
    let target = EditorTarget(
      element: element,
      processIdentifier: application.processIdentifier,
      selectedRange: selectedRange,
      textAnchor: textAnchor(of: element, around: selectedRange))
    targets[target.id] = target
    pruneTargets()
    return CapturedInteraction(selection: selection, editorTargetId: target.id, application: application)
  }

  func perform(targetId: String, mode: EditorWriteMode, text: String) async -> (Bool, String) {
    if let completed = completedWrites[targetId] {
      proactiveLogger.info("Editor write reused completed result")
      return (completed.ok, completed.message)
    }
    guard !text.isEmpty else { return (false, "没有可写入的内容。") }

    if let captured = targets[targetId], Date().timeIntervalSince(captured.capturedAt) <= 600 {
      let capturedPositionIsSafe = captured.textAnchor.map {
        textAnchor(of: captured.element, around: captured.selectedRange) == $0
      } ?? true
      if capturedPositionIsSafe {
        switch await write(text, mode: mode, to: captured) {
        case .succeeded:
          proactiveLogger.info("Editor write confirmed at captured target")
          rememberUndo(text: text, mode: mode, target: captured)
          return complete(targetId: targetId, ok: true, message: "已写入发送时的编辑区。")
        case .uncertain:
          proactiveLogger.info("Editor write at captured target changed state but could not be confirmed")
          return complete(
            targetId: targetId,
            ok: false,
            message: "发送时的编辑区可能已写入，但无法确认；未再次写入以免重复。")
        case .rejected:
          proactiveLogger.info("Editor write rejected at captured target")
        }
      } else {
        proactiveLogger.info("Captured editor content changed")
      }
    } else {
      proactiveLogger.info("Captured editor unavailable")
    }
    return complete(targetId: targetId, ok: false, message: "原编辑位置已变化，未写入以避免改错位置。")
  }

  func undoLast() async -> (Bool, String) {
    guard let undo = undoWrite, Date().timeIntervalSince(undo.completedAt) <= 600 else {
      undoWrite = nil
      return (false, "没有可撤销的写入。")
    }
    guard let value = textValue(of: undo.element) else {
      undoWrite = nil
      return (false, "无法确认原内容，未执行撤销。")
    }
    let source = value as NSString
    let insertedLength = (undo.insertedText as NSString).length
    guard undo.range.location >= 0,
          undo.range.location + insertedLength <= source.length,
          source.substring(with: NSRange(location: undo.range.location, length: insertedLength)) == undo.insertedText else {
      undoWrite = nil
      return (false, "内容已经变化，未执行撤销。")
    }
    _ = AXUIElementSetAttributeValue(
      undo.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let replacementRange = CFRange(location: undo.range.location, length: insertedLength)
    guard setSelectedRange(replacementRange, on: undo.element),
          setSelectedText(undo.originalText, on: undo.element) else {
      return (false, "编辑区未接受撤销。")
    }
    try? await Task.sleep(nanoseconds: 120_000_000)
    let restoredRange = CFRange(
      location: undo.range.location, length: (undo.originalText as NSString).length)
    guard textAnchor(of: undo.element, around: restoredRange) == undo.originalAnchor else {
      undoWrite = nil
      return (false, "内容可能已撤销，但无法确认。")
    }
    undoWrite = nil
    return (true, "已撤销上次写入。")
  }

  func discard(targetId: String?) {
    guard let targetId else { return }
    targets.removeValue(forKey: targetId)
  }

  private func pruneTargets() {
    let cutoff = Date().addingTimeInterval(-600)
    targets = targets.filter { $0.value.capturedAt >= cutoff }
    completedWrites = completedWrites.filter { $0.value.completedAt >= cutoff }
    if targets.count > 128 {
      for target in targets.values.sorted(by: { $0.capturedAt < $1.capturedAt }).prefix(targets.count - 128) {
        targets.removeValue(forKey: target.id)
      }
    }
  }

  private func complete(targetId: String, ok: Bool, message: String) -> (Bool, String) {
    targets.removeValue(forKey: targetId)
    completedWrites[targetId] = CompletedEditorWrite(
      completedAt: Date(), ok: ok, message: message)
    pruneTargets()
    return (ok, message)
  }

  private func selectedRange(of element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
      let value else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
    return range
  }

  private func rememberUndo(text: String, mode: EditorWriteMode, target: EditorTarget) {
    guard let originalAnchor = target.textAnchor else {
      undoWrite = nil
      return
    }
    let effectiveMode: EditorWriteMode = target.selectedRange.length == 0 ? .insertAtCursor : mode
    let location: Int
    switch effectiveMode {
    case .replaceSelection, .insertAtCursor:
      location = target.selectedRange.location
    case .insertAfterSelection:
      location = target.selectedRange.location + target.selectedRange.length
    }
    let insertionAnchor: EditorTextAnchor
    if effectiveMode == .insertAfterSelection {
      let prefix = (originalAnchor.before + originalAnchor.selected) as NSString
      insertionAnchor = EditorTextAnchor(
        before: prefix.substring(from: max(0, prefix.length - 64)),
        selected: "",
        after: originalAnchor.after)
    } else {
      insertionAnchor = originalAnchor
    }
    undoWrite = UndoEditorWrite(
      element: target.element,
      processIdentifier: target.processIdentifier,
      range: CFRange(location: location, length: (text as NSString).length),
      insertedText: text,
      originalText: effectiveMode == .replaceSelection ? originalAnchor.selected : "",
      originalAnchor: insertionAnchor,
      completedAt: Date())
  }

  private func write(
    _ text: String,
    mode: EditorWriteMode,
    to target: EditorTarget
  ) async -> EditorWriteAttempt {
    let effectiveMode: EditorWriteMode
    if target.selectedRange.length == 0, mode != .insertAtCursor {
      proactiveLogger.info("Editor write mode normalized to cursor insertion")
      effectiveMode = .insertAtCursor
    } else {
      effectiveMode = mode
    }
    let insertionRange: CFRange
    switch effectiveMode {
    case .replaceSelection:
      insertionRange = target.selectedRange
    case .insertAfterSelection:
      insertionRange = CFRange(
        location: target.selectedRange.location + target.selectedRange.length,
        length: 0)
    case .insertAtCursor:
      insertionRange = CFRange(location: target.selectedRange.location, length: 0)
    }

    _ = AXUIElementSetAttributeValue(
      target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard setSelectedRange(insertionRange, on: target.element) else { return .rejected }
    let contentBefore = textValue(of: target.element)
    if setSelectedText(text, on: target.element) {
      try? await Task.sleep(nanoseconds: 120_000_000)
      if writeAppearsApplied(text, at: insertionRange, on: target.element) {
        return .succeeded
      }
      let contentAfter = textValue(of: target.element)
      if contentBefore == nil || contentAfter == nil {
        // A successful AX assignment is the strongest signal exposed by some
        // rich editors; they do not make their document value readable.
        return .succeeded
      }
      if contentBefore != contentAfter { return .uncertain }
    }
    return await paste(
      text,
      at: insertionRange,
      on: target.element,
      processIdentifier: target.processIdentifier) ? .succeeded : .rejected
  }

  private func textValue(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXValueAttribute as CFString, &value) == .success,
      let value else { return nil }
    if let plainText = value as? String { return plainText }
    return (value as? NSAttributedString)?.string
  }

  private func textAnchor(of element: AXUIElement, around range: CFRange) -> EditorTextAnchor? {
    guard let text = textValue(of: element) else { return nil }
    let source = text as NSString
    let selectionEnd = range.location + range.length
    guard range.location >= 0, range.length >= 0, selectionEnd <= source.length else { return nil }
    let radius = 64
    let beforeStart = max(0, range.location - radius)
    let afterLength = min(radius, source.length - selectionEnd)
    return EditorTextAnchor(
      before: source.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
      selected: source.substring(with: NSRange(location: range.location, length: range.length)),
      after: source.substring(with: NSRange(location: selectionEnd, length: afterLength)))
  }

  private func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> Bool {
    var mutableRange = range
    guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
    return AXUIElementSetAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, value) == .success
  }

  private func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(
      element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
  }

  private func writeAppearsApplied(_ text: String, at range: CFRange, on element: AXUIElement) -> Bool {
    if let value = textValue(of: element) {
      let source = value as NSString
      let insertedLength = (text as NSString).length
      if range.location >= 0, range.location + insertedLength <= source.length,
         source.substring(with: NSRange(location: range.location, length: insertedLength)) == text {
        return true
      }
    }
    var selectedValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      element, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
      let selected = selectedValue as? String,
      selected == text { return true }
    guard let current = selectedRange(of: element) else { return false }
    let insertedLength = (text as NSString).length
    return (current.location == range.location + insertedLength && current.length == 0)
      || (current.location == range.location && current.length == insertedLength)
  }

  private func paste(
    _ text: String,
    at range: CFRange,
    on element: AXUIElement,
    processIdentifier: pid_t
  ) async -> Bool {
    _ = AXUIElementSetAttributeValue(
      element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard setSelectedRange(range, on: element) else { return false }
    let pasteboard = NSPasteboard.general
    let savedItems = pasteboard.pasteboardItems?.map { item in
      item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
        if let data = item.data(forType: type) { values[type] = data }
      }
    } ?? []
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string),
          let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
    let insertedChangeCount = pasteboard.changeCount
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.postToPid(processIdentifier)
    up.postToPid(processIdentifier)
    try? await Task.sleep(nanoseconds: 220_000_000)
    let applied = writeAppearsApplied(text, at: range, on: element)
    if pasteboard.changeCount == insertedChangeCount {
      pasteboard.clearContents()
      let restored = savedItems.map { values -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: type) }
        return item
      }
      if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
    return applied
  }
}

private enum TriggerPulseState: Equatable {
  case working
  case success
  case attention
  case cancelled

  var symbol: String {
    switch self {
    case .working: return "sparkles"
    case .success: return "checkmark"
    case .attention: return "exclamationmark"
    case .cancelled: return "xmark"
    }
  }
}

private struct TriggerPulseView: View {
  let state: TriggerPulseState
  @State private var visible = false
  @State private var pulseScale = 0.97

  var body: some View {
    ZStack {
      Circle()
        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
      Circle()
        .fill(
          RadialGradient(
            colors: [.white.opacity(0.15), .clear],
            center: .topLeading,
            startRadius: 2,
            endRadius: 38))
      Circle()
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
      Image(systemName: state.symbol)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(state == .attention ? Color.orange : Color.secondary)
    }
      .frame(width: 42, height: 42)
      .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
      .scaleEffect(visible ? (state == .working ? pulseScale : 1) : 0.84)
      .opacity(visible ? 1 : 0)
      .onAppear {
        withAnimation(.easeOut(duration: 0.18)) { visible = true }
        if state == .working {
          withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
            pulseScale = 1.04
          }
        }
      }
  }
}

@MainActor
private final class TriggerPulsePresenter {
  static let shared = TriggerPulsePresenter()
  private var panel: NSPanel?
  private var dismissal: DispatchWorkItem?
  private(set) var isWorking = false

  func showWorking() {
    isWorking = true
    show(.working, dismissAfter: 90)
  }

  func finish(success: Bool) {
    guard isWorking else { return }
    isWorking = false
    show(success ? .success : .attention, dismissAfter: 1.1)
  }

  func cancel() {
    isWorking = false
    show(.cancelled, dismissAfter: 0.8)
  }

  private func show(_ state: TriggerPulseState, dismissAfter delay: TimeInterval) {
    dismissal?.cancel()
    panel?.close()
    let size = CGSize(width: 58, height: 58)
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    let frame = screen?.visibleFrame ?? NSScreen.main?.frame ?? .zero
    let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY + 22)
    let panel = NSPanel(
      contentRect: CGRect(origin: origin, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    let hostingView = NSHostingView(rootView: TriggerPulseView(state: state))
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    panel.contentView = hostingView
    panel.orderFrontRegardless()
    self.panel = panel
    let dismissal = DispatchWorkItem { [weak self, weak panel] in
      panel?.close()
      if self?.panel === panel { self?.panel = nil }
    }
    self.dismissal = dismissal
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dismissal)
  }
}

private final class InstructionPanel: NSPanel {
  var onResignKey: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
}

private final class InstructionTextView: NSTextView {
  var submit: (() -> Void)?
  var cancel: (() -> Void)?
  var placeholder = "想让 AI 做什么？"

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !hasMarkedText() else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 15),
      .foregroundColor: NSColor.tertiaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    NSString(string: placeholder).draw(
      in: NSRect(x: textContainerInset.width, y: textContainerInset.height, width: bounds.width, height: 20),
      withAttributes: attributes)
  }

  override func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    needsDisplay = true
  }

  override func unmarkText() {
    super.unmarkText()
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    if !hasMarkedText() {
      switch event.keyCode {
      case 36, 76:
        submit?()
        return
      case 53:
        cancel?()
        return
      default:
        break
      }
    }
    super.keyDown(with: event)
  }
}

private final class InstructionTextContainer: NSScrollView {
  let inputView: InstructionTextView

  init(inputView: InstructionTextView) {
    self.inputView = inputView
    super.init(frame: .zero)
    borderType = .noBorder
    drawsBackground = false
    hasHorizontalScroller = false
    hasVerticalScroller = false
    documentView = inputView
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.makeFirstResponder(self.inputView)
      self.inputView.inputContext?.activate()
    }
  }

  override func layout() {
    super.layout()
    inputView.frame.size = NSSize(width: max(contentSize.width, 1), height: 32)
  }
}

private struct InstructionTextInput: NSViewRepresentable {
  @Binding var text: String
  let submit: () -> Void
  let cancel: () -> Void

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: InstructionTextInput

    init(_ parent: InstructionTextInput) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> InstructionTextContainer {
    let textView = InstructionTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 32))
    textView.delegate = context.coordinator
    textView.submit = submit
    textView.cancel = cancel
    textView.isRichText = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.font = .systemFont(ofSize: 15)
    textView.textColor = .labelColor
    textView.insertionPointColor = .controlAccentColor
    textView.markedTextAttributes = [
      .foregroundColor: NSColor.labelColor,
      .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
      .underlineColor: NSColor.controlAccentColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    textView.textContainerInset = NSSize(width: 0, height: 7)
    textView.minSize = NSSize(width: 0, height: 32)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 32)
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.maximumNumberOfLines = 1
    textView.textContainer?.lineBreakMode = .byClipping

    return InstructionTextContainer(inputView: textView)
  }

  func updateNSView(_ scrollView: InstructionTextContainer, context: Context) {
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? InstructionTextView else { return }
    textView.submit = submit
    textView.cancel = cancel
    // Updating `string` while an IME owns marked text clears the visible
    // pinyin/pre-edit range. Leave composition entirely to AppKit.
    if !textView.hasMarkedText(), textView.string != text {
      textView.string = text
    }
  }
}

private struct InstructionPromptView: View {
  let submit: (String) -> Void
  let cancel: () -> Void
  @State private var instruction = ""
  @State private var expanded = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
      if expanded {
        InstructionTextInput(
          text: $instruction,
          submit: { submit(instruction) },
          cancel: cancel)
          .frame(height: 32)
          .transition(.opacity.combined(with: .move(edge: .leading)))
      }
    }
    .padding(.horizontal, expanded ? 12 : 7)
    .frame(width: expanded ? 420 : 44, height: 46)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.42), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: expanded)
    .onAppear {
      expanded = true
    }
  }
}

@MainActor
private final class InstructionPromptPresenter {
  static let shared = InstructionPromptPresenter()
  private var panel: InstructionPanel?
  private var cancelCurrent: (() -> Void)?

  func show(
    interaction: CapturedInteraction,
    completion: @escaping (CapturedInteraction, String) -> Void
  ) {
    cancelCurrent?()
    let size = CGSize(width: 450, height: 64)
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    let frame = screen?.visibleFrame ?? NSScreen.main?.frame ?? .zero
    let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY + 20)
    let panel = InstructionPanel(
      contentRect: CGRect(origin: origin, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    let finish: (String?) -> Void = { [weak self, weak panel] value in
      guard self?.panel === panel else { return }
      self?.panel = nil
      self?.cancelCurrent = nil
      panel?.onResignKey = nil
      panel?.close()
      guard let value else {
        EditorTargetStore.shared.discard(targetId: interaction.editorTargetId)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        completion(interaction, value.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    panel.onResignKey = { finish(nil) }
    let hostingView = NSHostingView(rootView: InstructionPromptView(
      submit: { finish($0) },
      cancel: { finish(nil) }))
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    panel.contentView = hostingView
    self.panel = panel
    self.cancelCurrent = { finish(nil) }
    panel.makeKeyAndOrderFront(nil)
  }
}

private extension Notification.Name {
  static let openProactiveDashboard = Notification.Name("ai.deepseek.proactive.open-dashboard")
  static let openProactiveConversation = Notification.Name("ai.deepseek.proactive.open-conversation")
  static let forceProactiveCapture = Notification.Name("ai.deepseek.proactive.force-capture")
  static let requestKeyboardShortcutPermission = Notification.Name("ai.deepseek.proactive.request-keyboard-shortcut-permission")
  static let proactiveShortcutChanged = Notification.Name("ai.deepseek.proactive.shortcut-changed")
  static let proactiveShortcutRegistrationFailed = Notification.Name("ai.deepseek.proactive.shortcut-registration-failed")
  static let proactiveShortcutRecordingBegan = Notification.Name("ai.deepseek.proactive.shortcut-recording-began")
  static let proactiveShortcutRecordingEnded = Notification.Name("ai.deepseek.proactive.shortcut-recording-ended")
  static let proactiveShortcutRecordingEvent = Notification.Name("ai.deepseek.proactive.shortcut-recording-event")
  static let proactiveWritebackTestRequested = Notification.Name("ai.deepseek.proactive.writeback-test")
  static let cancelProactiveRequest = Notification.Name("ai.deepseek.proactive.cancel-request")
}

private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var functionEventTap: CFMachPort?
  private var functionEventSource: CFRunLoopSource?
  private var actionHotKeyReference: EventHotKeyRef?
  private var instructionHotKeyReference: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var permissionObserver: NSObjectProtocol?
  private var shortcutObserver: NSObjectProtocol?
  private var writebackTestObserver: NSObjectProtocol?
  private var shortcutRecordingObservers: [NSObjectProtocol] = []
  private var lastFunctionPress: Date?
  private var isShortcutRecording = false
  private var actionShortcut = ShortcutDefinition.load(
    key: shortcutDefaultsKey, default: .actionDefault)
  private var instructionShortcut = ShortcutDefinition.load(
    key: instructionShortcutDefaultsKey, default: .instructionDefault)
  private var doubleFunctionPressWindow: TimeInterval {
    min(max(NSEvent.doubleClickInterval, 0.35), 0.75)
  }

  private static let functionEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = delegate.functionEventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }
    if delegate.isShortcutRecording,
       (type == .keyDown || type == .flagsChanged),
       let recordingEvent = NSEvent(cgEvent: event) {
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: .proactiveShortcutRecordingEvent,
          object: recordingEvent)
      }
      return Unmanaged.passUnretained(event)
    }
    if type == .flagsChanged {
      delegate.observeFunctionKey(event)
    }
    return Unmanaged.passUnretained(event)
  }

  private static let hotKeyCallback: EventHandlerUPP = { _, event, userInfo in
    guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    var identifier = EventHotKeyID()
    var actualSize = 0
    guard GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      &actualSize,
      &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
    DispatchQueue.main.async {
      guard !delegate.isShortcutRecording else { return }
      if identifier.id == 1 { delegate.performExplicitTrigger(.action) }
      if identifier.id == 2 { delegate.performExplicitTrigger(.instruction) }
    }
    return noErr
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let action = UNNotificationAction(identifier: continueAction, title: "继续聊", options: [.foreground])
    let category = UNNotificationCategory(identifier: notificationCategory, actions: [action], intentIdentifiers: [])
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([category])
    registerConfiguredShortcut()
    permissionObserver = NotificationCenter.default.addObserver(
      forName: .requestKeyboardShortcutPermission,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.requestKeyboardShortcutPermission()
    }
    shortcutObserver = NotificationCenter.default.addObserver(
      forName: .proactiveShortcutChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.registerConfiguredShortcut()
    }
    writebackTestObserver = NotificationCenter.default.addObserver(
      forName: .proactiveWritebackTestRequested,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      let instruction = notification.userInfo?["instruction"] as? String
      let interaction = EditorTargetStore.shared.capture()
      self.postExplicitTrigger(interaction: interaction, instruction: instruction)
    }
    shortcutRecordingObservers = [
      NotificationCenter.default.addObserver(
        forName: .proactiveShortcutRecordingBegan,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.isShortcutRecording = true
        self?.lastFunctionPress = nil
        if Self.keyboardShortcutPermissionGranted(), self?.functionEventTap == nil {
          self?.installFunctionEventTap()
        }
      },
      NotificationCenter.default.addObserver(
        forName: .proactiveShortcutRecordingEnded,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.isShortcutRecording = false
        self?.lastFunctionPress = nil
        if self?.actionShortcut.kind != .doubleFunction,
           self?.instructionShortcut.kind != .doubleFunction {
          self?.unregisterFunctionShortcut()
        }
      },
    ]
  }

  func applicationWillTerminate(_ notification: Notification) {
    unregisterConfiguredShortcut()
    if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    hotKeyHandler = nil
    if let permissionObserver { NotificationCenter.default.removeObserver(permissionObserver) }
    if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
    if let writebackTestObserver { NotificationCenter.default.removeObserver(writebackTestObserver) }
    for observer in shortcutRecordingObservers { NotificationCenter.default.removeObserver(observer) }
    shortcutRecordingObservers.removeAll()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    // Granting Input Monitoring happens in System Settings. Recreate the tap
    // when the user returns so no application restart is required.
    if (actionShortcut.kind == .doubleFunction || instructionShortcut.kind == .doubleFunction),
       functionEventTap == nil, Self.keyboardShortcutPermissionGranted() {
      registerConfiguredShortcut()
    } else if (actionShortcut.kind == .keyCombination && actionHotKeyReference == nil)
                || (instructionShortcut.kind == .keyCombination && instructionHotKeyReference == nil) {
      registerConfiguredShortcut()
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    DispatchQueue.main.async {
      if let dashboard = sender.windows.first(where: { $0.identifier?.rawValue == "dashboard"
        || $0.title == "Astra" }) {
        dashboard.collectionBehavior.insert(.moveToActiveSpace)
        if dashboard.isMiniaturized { dashboard.deminiaturize(nil) }
        dashboard.makeKeyAndOrderFront(nil)
      } else {
        NotificationCenter.default.post(name: .openProactiveDashboard, object: nil)
      }
    }
    return true
  }

  private func registerConfiguredShortcut() {
    unregisterConfiguredShortcut()
    actionShortcut = ShortcutDefinition.load(key: shortcutDefaultsKey, default: .actionDefault)
    instructionShortcut = ShortcutDefinition.load(
      key: instructionShortcutDefaultsKey, default: .instructionDefault)
    installHotKeyHandlerIfNeeded()
    registerCombinationShortcut(actionShortcut, identifier: 1, reference: &actionHotKeyReference)
    registerCombinationShortcut(
      instructionShortcut, identifier: 2, reference: &instructionHotKeyReference)
    if actionShortcut.kind == .doubleFunction || instructionShortcut.kind == .doubleFunction {
      registerFunctionShortcut()
    }
  }

  private func registerCombinationShortcut(
    _ shortcut: ShortcutDefinition,
    identifier: UInt32,
    reference: inout EventHotKeyRef?
  ) {
    guard shortcut.kind == .keyCombination,
          let keyCode = shortcut.keyCode,
          let modifiers = shortcut.modifiers else { return }
    let hotKeyIdentifier = EventHotKeyID(signature: proactiveHotKeySignature, id: identifier)
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyIdentifier, GetApplicationEventTarget(), 0, &reference)
    guard status == noErr else {
      reference = nil
      proactiveLogger.error("Unable to register configured shortcut: \(status)")
      NotificationCenter.default.post(
        name: .proactiveShortcutRegistrationFailed,
        object: nil,
        userInfo: ["identifier": Int(identifier), "message": status == eventHotKeyExistsErr
          ? "这个快捷键已被系统或其他应用占用。"
          : "无法注册主动触发快捷键（\(status)）。"])
      return
    }
    proactiveLogger.info("Configured shortcut ready: \(shortcut.displayName, privacy: .public)")
  }

  private func installHotKeyHandlerIfNeeded() {
    guard hotKeyHandler == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      Self.hotKeyCallback,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &hotKeyHandler)
  }

  private func unregisterConfiguredShortcut() {
    unregisterFunctionShortcut()
    if let actionHotKeyReference { UnregisterEventHotKey(actionHotKeyReference) }
    if let instructionHotKeyReference { UnregisterEventHotKey(instructionHotKeyReference) }
    actionHotKeyReference = nil
    instructionHotKeyReference = nil
  }

  private func registerFunctionShortcut() {
    unregisterFunctionShortcut()
    guard Self.keyboardShortcutPermissionGranted() else {
      proactiveLogger.notice("Fn shortcut waiting for Input Monitoring access")
      return
    }
    installFunctionEventTap()
  }

  private func installFunctionEventTap() {
    guard functionEventTap == nil else { return }
    let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
      | (CGEventMask(1) << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: mask,
      callback: Self.functionEventTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      proactiveLogger.error("Unable to create Fn event tap despite Input Monitoring access")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return
    }
    functionEventTap = tap
    functionEventSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    proactiveLogger.info("Fn event tap ready")
  }

  private func unregisterFunctionShortcut() {
    if let source = functionEventSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      functionEventSource = nil
    }
    if let tap = functionEventTap {
      CFMachPortInvalidate(tap)
      functionEventTap = nil
    }
  }

  private func observeFunctionKey(_ event: CGEvent) {
    // Fn/Globe emits key code 63. Only the down edge counts, so holding Fn or
    // its corresponding flags-changed release event can never fire twice.
    guard !isShortcutRecording,
          event.getIntegerValueField(.keyboardEventKeycode) == 63,
          event.flags.contains(.maskSecondaryFn) else { return }
    let now = Date()
    if let lastFunctionPress, now.timeIntervalSince(lastFunctionPress) <= doubleFunctionPressWindow {
      self.lastFunctionPress = nil
      proactiveLogger.info("Fn double press detected")
      let kind: ExplicitTriggerKind = actionShortcut.kind == .doubleFunction ? .action : .instruction
      DispatchQueue.main.async { self.performExplicitTrigger(kind) }
    } else {
      lastFunctionPress = now
    }
  }

  @MainActor
  private func performExplicitTrigger(_ kind: ExplicitTriggerKind) {
    if kind == .action, TriggerPulsePresenter.shared.isWorking {
      TriggerPulsePresenter.shared.cancel()
      NotificationCenter.default.post(name: .cancelProactiveRequest, object: nil)
      return
    }
    let interaction = EditorTargetStore.shared.capture()
    if kind == .instruction {
      InstructionPromptPresenter.shared.show(interaction: interaction) { [weak self] interaction, instruction in
        self?.postExplicitTrigger(interaction: interaction, instruction: instruction)
      }
      return
    }
    postExplicitTrigger(interaction: interaction, instruction: nil)
  }

  @MainActor
  private func postExplicitTrigger(interaction: CapturedInteraction, instruction: String?) {
    TriggerPulsePresenter.shared.showWorking()
    var userInfo: [String: Any] = [:]
    if let selection = interaction.selection {
      userInfo = [
        "selectedText": selection.text,
        "app": selection.app,
        "bundleId": selection.bundleId,
      ]
      proactiveLogger.info("Explicit trigger captured \(selection.text.count) selected characters")
    } else {
      proactiveLogger.info("Explicit trigger falling back to screen capture")
    }
    if let editorTargetId = interaction.editorTargetId {
      userInfo["editorTargetId"] = editorTargetId
    }
    if let instruction, !instruction.isEmpty { userInfo["instruction"] = instruction }
    NotificationCenter.default.post(
      name: .forceProactiveCapture,
      object: nil,
      userInfo: userInfo)
  }

  private func requestKeyboardShortcutPermission() {
    let granted = CGRequestListenEventAccess()
    if granted {
      registerFunctionShortcut()
      return
    }
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
    NSWorkspace.shared.open(url)
  }

  static func keyboardShortcutPermissionGranted() -> Bool {
    CGPreflightListenEventAccess()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == continueAction,
          let message = response.notification.request.content.userInfo["message"] as? String else { return }
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first(where: { $0.title == "Astra" })?.makeKeyAndOrderFront(nil)
      var userInfo: [String: Any] = ["message": message]
      if let activityID = response.notification.request.content.userInfo["activityId"] as? String {
        userInfo["activityId"] = activityID
      }
      NotificationCenter.default.post(
        name: .openProactiveConversation,
        object: nil,
        userInfo: userInfo)
    }
  }
}

private enum ObserverState: String {
  case stopped
  case starting
  case running
  case stopping

  var title: String {
    switch self {
    case .stopped: return "已关闭"
    case .starting: return "正在启动"
    case .running: return "正在感知"
    case .stopping: return "正在停止"
    }
  }

  var color: Color {
    switch self {
    case .running: return .green
    case .starting, .stopping: return .orange
    case .stopped: return .secondary
    }
  }
}

private enum ActivityKind: String, Codable {
  case episode
  case noop
  case notification
  case shadow
  case duplicate
  case error

  var title: String {
    switch self {
    case .episode: return "已读取当前画面"
    case .noop: return "判断为无需打扰"
    case .notification: return "已完成"
    case .shadow: return "影子模式候选"
    case .duplicate: return "重复提醒已抑制"
    case .error: return "运行异常"
    }
  }

  var symbol: String {
    switch self {
    case .episode: return "eye"
    case .noop: return "moon.zzz"
    case .notification: return "checkmark.circle"
    case .shadow: return "bell.slash"
    case .duplicate: return "arrow.triangle.2.circlepath"
    case .error: return "exclamationmark.triangle"
    }
  }

  var tint: Color {
    switch self {
    case .episode: return .blue
    case .noop: return .secondary
    case .notification: return .green
    case .shadow: return .orange
    case .duplicate: return .secondary
    case .error: return .red
    }
  }
}

private struct ActivityRecord: Codable, Identifiable {
  let id: UUID
  let time: Date
  let kind: ActivityKind
  let app: String?
  let bundleId: String?
  let characters: Int?
  let inputTokens: Int?
  let outputTokens: Int?
  let message: String?
  var explicit: Bool? = nil
  var delivery: String? = nil
  var category: String? = nil
}

private struct StreamRecord: Decodable {
  let version: Int
  let time: String
  let type: String
  let state: String?
  let outcome: String?
  let app: String?
  let bundleId: String?
  let characters: Int?
  let inputTokens: Int?
  let outputTokens: Int?
  let message: String?
  let stage: String?
  let chatPort: Int?
  let chatToken: String?
  let requestId: String?
  let targetId: String?
  let action: String?
  let text: String?
  let explicit: Bool?
  let delivery: String?
  let category: String?
}

private struct ChatTurn: Codable, Identifiable {
  enum Role: String, Codable { case user, assistant }

  let id = UUID()
  let role: Role
  let text: String

  private enum CodingKeys: String, CodingKey { case role, text }
}

private struct FollowUpRequest: Encodable {
  let notification: String
  let turns: [ChatTurn]
}

private struct FollowUpResponse: Decodable {
  let text: String
}

private struct ConversationSession: Codable, Identifiable {
  let id: UUID
  let activityID: UUID?
  let notification: String
  var turns: [ChatTurn]
  var updatedAt: Date
}

private enum ExplicitRequest {
  case screen(editorTargetId: String?, instruction: String?)
  case selection(SelectedTextContext, editorTargetId: String?, instruction: String?)
}

@MainActor
private final class ObserverController: ObservableObject, @unchecked Sendable {
  @Published private(set) var state: ObserverState = .stopped
  @Published private(set) var activities: [ActivityRecord] = []
  @Published private(set) var conversations: [ConversationSession] = []
  @Published private(set) var lastError: String?
  @Published private(set) var needsScreenPermission = false
  @Published private(set) var needsNotificationPermission = false
  @Published private(set) var needsKeyboardShortcutPermission: Bool
  @Published private(set) var needsAccessibilityPermission = !AXIsProcessTrusted()
  @Published private(set) var shortcut: ShortcutDefinition
  @Published private(set) var instructionShortcut: ShortcutDefinition
  @Published private(set) var shortcutConflictMessage: String?
  @Published private(set) var instructionShortcutConflictMessage: String?
  @Published private(set) var chatPort: Int?
  @Published private(set) var chatToken: String?
  @Published private(set) var captureIntervalSeconds: Int
  @Published private(set) var allowsAgentExecution: Bool
  @Published private(set) var allowsEditorWrite: Bool
  @Published private(set) var canUndoEditorWrite = false
  @Published private(set) var pauseUntil: Date?
  @Published private(set) var excludedBundleIds: Set<String>
  @Published private(set) var foregroundAppName: String?

  private var process: Process?
  private var observer: ScreenObserver?
  private var observerInput: Pipe?
  private var standardOutput = Pipe()
  private var standardError = Pipe()
  private var outputBuffer = ""
  private var errorBuffer = ""
  private var intentionalStop = false
  private var requestedScreenPermission = false
  private var pendingExplicitRequest: ExplicitRequest?
  private var restartAfterStop = false
  private var cancellables = Set<AnyCancellable>()
  private var resumeWorkItem: DispatchWorkItem?

  init() {
    let savedInterval = UserDefaults.standard.integer(forKey: captureIntervalDefaultsKey)
    captureIntervalSeconds = [1, 5, 15, 60].contains(savedInterval) ? savedInterval : 15
    allowsAgentExecution = UserDefaults.standard.object(forKey: agentExecutionDefaultsKey) as? Bool ?? true
    allowsEditorWrite = UserDefaults.standard.object(forKey: editorWriteDefaultsKey) as? Bool ?? true
    let savedPause = UserDefaults.standard.object(forKey: pauseUntilDefaultsKey) as? Date
    pauseUntil = savedPause.map { $0 > Date() ? $0 : nil } ?? nil
    excludedBundleIds = Set(UserDefaults.standard.stringArray(forKey: excludedAppsDefaultsKey) ?? [])
    foregroundAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    let savedShortcut = ShortcutDefinition.load(key: shortcutDefaultsKey, default: .actionDefault)
    let savedInstructionShortcut = ShortcutDefinition.load(
      key: instructionShortcutDefaultsKey, default: .instructionDefault)
    shortcut = savedShortcut
    instructionShortcut = savedInstructionShortcut
    needsKeyboardShortcutPermission = (savedShortcut.kind == .doubleFunction
      || savedInstructionShortcut.kind == .doubleFunction)
      && !AppDelegate.keyboardShortcutPermissionGranted()
    shortcutConflictMessage = savedShortcut.kind == .doubleFunction && functionKeyHasSystemAction()
      ? "Fn 同时配置了系统操作，可能发生冲突。"
      : nil
    instructionShortcutConflictMessage = savedInstructionShortcut.kind == .doubleFunction && functionKeyHasSystemAction()
      ? "Fn 同时配置了系统操作，可能发生冲突。"
      : nil
    NotificationCenter.default.publisher(for: .forceProactiveCapture)
      .sink { [weak self] notification in
        let selection: SelectedTextContext?
        if let text = notification.userInfo?["selectedText"] as? String,
           let app = notification.userInfo?["app"] as? String,
           let bundleId = notification.userInfo?["bundleId"] as? String {
          selection = SelectedTextContext(text: text, app: app, bundleId: bundleId)
        } else {
          selection = nil
        }
        let editorTargetId = notification.userInfo?["editorTargetId"] as? String
        let instruction = notification.userInfo?["instruction"] as? String
        Task { @MainActor in
          self?.forceCapture(
            selection: selection,
            editorTargetId: editorTargetId,
            instruction: instruction)
        }
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .proactiveShortcutRegistrationFailed)
      .sink { [weak self] notification in
        Task { @MainActor in
          let message = notification.userInfo?["message"] as? String
          if notification.userInfo?["identifier"] as? Int == 2 {
            self?.instructionShortcutConflictMessage = message
          } else {
            self?.shortcutConflictMessage = message
          }
        }
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .cancelProactiveRequest)
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.forwardObserverEvent(["type": "cancel-explicit"])
        }
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        guard let self else { return }
        self.needsKeyboardShortcutPermission = (self.shortcut.kind == .doubleFunction
          || self.instructionShortcut.kind == .doubleFunction)
          && !AppDelegate.keyboardShortcutPermissionGranted()
        self.needsAccessibilityPermission = !AXIsProcessTrusted()
        self.shortcutConflictMessage = self.shortcut.kind == .doubleFunction && functionKeyHasSystemAction()
          ? "Fn 同时配置了系统操作，可能发生冲突。"
          : nil
        self.instructionShortcutConflictMessage = self.instructionShortcut.kind == .doubleFunction
          && functionKeyHasSystemAction() ? "Fn 同时配置了系统操作，可能发生冲突。" : nil
      }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
      .sink { [weak self] notification in
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != "ai.deepseek.proactive.local" else { return }
        Task { @MainActor in self?.foregroundAppName = app.localizedName }
      }
      .store(in: &cancellables)
    loadHistory()
    loadConversations()
    scheduleResumeIfNeeded()
  }

  func conversation(id: UUID) -> ConversationSession? {
    conversations.first(where: { $0.id == id })
  }

  func conversationID(for record: ActivityRecord) -> UUID {
    conversationID(notification: record.message ?? "", activityID: record.id)
  }

  func conversationID(notification: String, activityID: UUID? = nil) -> UUID {
    let resolvedActivityID = activityID ?? activities.last(where: {
      $0.kind == .notification && $0.message == notification
    })?.id
    if let resolvedActivityID,
       let session = conversations.first(where: { $0.activityID == resolvedActivityID }) {
      return session.id
    }
    if resolvedActivityID == nil,
       let session = conversations.last(where: { $0.notification == notification }) {
      return session.id
    }
    let session = ConversationSession(
      id: UUID(),
      activityID: resolvedActivityID,
      notification: notification,
      turns: [],
      updatedAt: Date())
    conversations.append(session)
    trimConversations()
    saveConversations()
    return session.id
  }

  func appendConversationTurn(_ turn: ChatTurn, to sessionID: UUID) {
    guard let index = conversations.firstIndex(where: { $0.id == sessionID }) else { return }
    conversations[index].turns.append(turn)
    if conversations[index].turns.count > maximumConversationTurns {
      conversations[index].turns.removeFirst(
        conversations[index].turns.count - maximumConversationTurns)
    }
    conversations[index].updatedAt = Date()
    saveConversations()
  }

  func removeConversationTurn(_ turnID: UUID, from sessionID: UUID) {
    guard let sessionIndex = conversations.firstIndex(where: { $0.id == sessionID }),
          let turnIndex = conversations[sessionIndex].turns.firstIndex(where: { $0.id == turnID }) else { return }
    conversations[sessionIndex].turns.remove(at: turnIndex)
    conversations[sessionIndex].updatedAt = Date()
    saveConversations()
  }

  var todayEpisodes: Int {
    todayRecords.filter { $0.kind == .episode }.count
  }

  var todayDecisions: Int {
    todayRecords.filter { $0.kind == .notification || $0.kind == .shadow }.count
  }

  var todayNotifications: Int {
    todayRecords.filter {
      $0.kind == .notification && $0.category == "result" && isPresentableReminder($0.message)
    }.count
  }

  var todayTokens: Int {
    todayRecords.filter { $0.kind != .noop }
      .reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) }
  }

  var isRunning: Bool {
    state == .running || state == .starting
  }

  var isTemporarilyPaused: Bool {
    guard let pauseUntil else { return false }
    return pauseUntil > Date()
  }

  var currentAppIsExcluded: Bool {
    guard let bundleId = currentExternalApplication()?.bundleIdentifier else { return false }
    return excludedBundleIds.contains(bundleId)
  }

  func startIfNeeded() {
    if isTemporarilyPaused {
      scheduleResumeIfNeeded()
    } else if state == .stopped {
      start()
    }
  }

  func forceCapture(
    selection: SelectedTextContext? = nil,
    editorTargetId: String? = nil,
    instruction: String? = nil
  ) {
    let request = selection.map {
      ExplicitRequest.selection($0, editorTargetId: editorTargetId, instruction: instruction)
    } ?? .screen(editorTargetId: editorTargetId, instruction: instruction)
    if state == .running {
      dispatch(request)
      return
    }
    pendingExplicitRequest = request
    if state == .stopped { start() }
  }

  func start() {
    guard state == .stopped else { return }
    clearTemporaryPause()
    lastError = nil
    needsScreenPermission = false
    state = .starting
    intentionalStop = false

    do {
      let repository = try resourcePath(named: "repository-path")
      let node = try resourcePath(named: "node-path")
      let child = Process()
      standardOutput = Pipe()
      standardError = Pipe()
      outputBuffer = ""
      errorBuffer = ""
      child.executableURL = URL(fileURLWithPath: node)
      child.currentDirectoryURL = URL(fileURLWithPath: repository, isDirectory: true)
      child.arguments = [
        "--import", "tsx/esm",
        "apps/cli/src/bin.ts",
        "--profile", "web",
        "--patch", "./packages/experimental/proactive-screen/cordis.source.patch.yml",
        "--no-open",
        "--port", "0",
      ]
      var environment = ProcessInfo.processInfo.environment
      // Tool capability is fixed for the lifetime of this child process. A UI
      // mode change restarts it so no previous agent session retains tools.
      environment["DSH_PERMISSION_MODE"] = allowsAgentExecution ? "danger-full-access" : "read-only"
      environment["DSH_PROACTIVE_ALLOW_AGENT_EXECUTION"] = allowsAgentExecution ? "1" : "0"
      environment["DSH_PROACTIVE_ALLOW_EDITOR_WRITE"] = allowsEditorWrite ? "1" : "0"
      environment["DSH_PROACTIVE_ACTIVITY_STREAM"] = "jsonl"
      environment["DSH_PROACTIVE_EXTERNAL_OBSERVER"] = "1"
      environment["DSH_PROACTIVE_NATIVE_NOTIFICATIONS"] = "1"
      environment.removeValue(forKey: "DSH_PROACTIVE_DIAGNOSTIC")
      child.environment = environment
      let observerInput = Pipe()
      child.standardInput = observerInput
      child.standardOutput = standardOutput
      child.standardError = standardError
      attachReaders()
      child.terminationHandler = { [weak self] terminated in
        let pid = terminated.processIdentifier
        let status = terminated.terminationStatus
        guard let controller = self else { return }
        Task { @MainActor in controller.processDidTerminate(pid: pid, status: status) }
      }
      try child.run()
      process = child
      self.observerInput = observerInput
      startScreenObserver()
      scheduleStartupTimeout(for: child)
    } catch {
      fail("无法启动：\(error.localizedDescription)")
      state = .stopped
      process = nil
    }
  }

  func stop() {
    intentionalStop = true
    if state != .stopped { state = .stopping }
    stopScreenObserver()
    observerInput?.fileHandleForWriting.closeFile()
    observerInput = nil
    guard let child = process, child.isRunning else {
      state = .stopped
      process = nil
      chatPort = nil
      chatToken = nil
      if restartAfterStop {
        restartAfterStop = false
        start()
      }
      return
    }
    child.terminate()
    let pid = child.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
      if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
    }
  }

  func shutdown() {
    resumeWorkItem?.cancel()
    intentionalStop = true
    restartAfterStop = false
    stopScreenObserver()
    observerInput?.fileHandleForWriting.closeFile()
    observerInput = nil
    guard let child = process, child.isRunning else { return }
    child.terminate()
    let deadline = Date().addingTimeInterval(1)
    while child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if child.isRunning {
      Darwin.kill(child.processIdentifier, SIGKILL)
      child.waitUntilExit()
    }
  }

  func pauseForOneHour() {
    pauseUntil = Date().addingTimeInterval(60 * 60)
    UserDefaults.standard.set(pauseUntil, forKey: pauseUntilDefaultsKey)
    scheduleResumeIfNeeded()
    stop()
  }

  func resumeNow() {
    clearTemporaryPause()
    if state == .stopped { start() }
  }

  func toggleCurrentAppExclusion() {
    guard let application = currentExternalApplication(),
          let bundleId = application.bundleIdentifier else { return }
    if excludedBundleIds.contains(bundleId) {
      excludedBundleIds.remove(bundleId)
    } else {
      excludedBundleIds.insert(bundleId)
    }
    UserDefaults.standard.set(Array(excludedBundleIds).sorted(), forKey: excludedAppsDefaultsKey)
  }

  func clearExcludedApps() {
    excludedBundleIds.removeAll()
    UserDefaults.standard.removeObject(forKey: excludedAppsDefaultsKey)
  }

  private func currentExternalApplication() -> NSRunningApplication? {
    let frontmost = NSWorkspace.shared.frontmostApplication
    return frontmost?.bundleIdentifier == "ai.deepseek.proactive.local" ? nil : frontmost
  }

  private func clearTemporaryPause() {
    resumeWorkItem?.cancel()
    resumeWorkItem = nil
    pauseUntil = nil
    UserDefaults.standard.removeObject(forKey: pauseUntilDefaultsKey)
  }

  private func scheduleResumeIfNeeded() {
    resumeWorkItem?.cancel()
    guard let pauseUntil, pauseUntil > Date() else {
      if self.pauseUntil != nil { clearTemporaryPause() }
      return
    }
    let item = DispatchWorkItem { [weak self] in
      Task { @MainActor in self?.resumeNow() }
    }
    resumeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + pauseUntil.timeIntervalSinceNow, execute: item)
  }

  func clearHistory() {
    activities = []
    conversations = []
    lastError = nil
    do {
      let urls = [try historyURL(), try conversationHistoryURL()]
      for url in urls {
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      }
    } catch {
      fail("无法清空记录：\(error.localizedDescription)")
    }
  }

  func undoLastEdit() {
    Task { @MainActor in
      let result = await EditorTargetStore.shared.undoLast()
      canUndoEditorWrite = EditorTargetStore.shared.canUndo
      if result.0 {
        append(ActivityRecord(
          id: UUID(), time: Date(), kind: .notification, app: nil, bundleId: nil,
          characters: nil, inputTokens: nil, outputTokens: nil, message: result.1,
          explicit: true, delivery: "inline", category: "result"))
        TriggerPulsePresenter.shared.showWorking()
        TriggerPulsePresenter.shared.finish(success: true)
      } else {
        lastError = result.1
        TriggerPulsePresenter.shared.showWorking()
        TriggerPulsePresenter.shared.finish(success: false)
      }
    }
  }

  func openTriggerScenario() {
    let now = Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    let departure = formatter.string(from: now.addingTimeInterval(23 * 60))
    let gateClose = formatter.string(from: now.addingTimeInterval(13 * 60))
    let current = formatter.string(from: now)
    let text = "今天 \(departure) 的 G123 高铁，\(gateClose) 停止检票。现在 \(current)，我还在家，去车站至少要 20 分钟。"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("今天的行程.txt")
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      NSWorkspace.shared.open(url)
    } catch {
      fail("无法打开测试场景：\(error.localizedDescription)")
    }
  }

  func openWritebackScenario() {
    let text = "这个方案是非常的有价值，能够帮助我们去提升整体的工作效率。"
    openEditorScenario(
      text: text,
      fileName: "一段待精简的草稿.txt",
      selectAll: true,
      // Keep the native diagnostic deterministic: it verifies selection
      // replacement even when the configured model is temporarily offline.
      instruction: "请将选中文字直接替换为：这个方案很有价值，能帮助我们提升整体工作效率。")
  }

  func openCursorWritebackScenario() {
    openEditorScenario(
      text: "项目结项文档\n",
      fileName: "光标写入测试.txt",
      selectAll: false,
      instruction: "请在当前编辑区光标处直接写入：写回测试成功。")
  }

  private func openEditorScenario(
    text: String,
    fileName: String,
    selectAll: Bool,
    instruction: String
  ) {
    // TextEdit keeps an open document's in-memory state even when its backing
    // file is overwritten. A unique fixture makes every diagnostic run fresh.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)-\(fileName)")
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      NSWorkspace.shared.open(url)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.TextEdit" else {
          self?.fail("测试编辑器没有置于前台，请重试。")
          return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
          let focusedValue else {
          self?.fail("无法读取测试编辑区，请检查辅助功能权限。")
          return
        }
        var range = selectAll
          ? CFRange(location: 0, length: text.utf16.count)
          : CFRange(location: text.utf16.count, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                focusedValue as! AXUIElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue) == .success else {
          self?.fail("无法选中测试文字，请重试。")
          return
        }
        NotificationCenter.default.post(
          name: .proactiveWritebackTestRequested,
          object: nil,
          userInfo: ["instruction": instruction])
      }
    } catch {
      fail("无法打开写回场景：\(error.localizedDescription)")
    }
  }

  func sendTestNotification() {
    Task {
      do {
        let granted = try await UNUserNotificationCenter.current()
          .requestAuthorization(options: [.alert, .sound])
        self.needsNotificationPermission = !granted
        if granted { self.deliverNotification(message: "通知链路工作正常。") }
      } catch {
        self.fail("无法请求通知权限：\(error.localizedDescription)")
      }
    }
  }

  func prepareNotifications() {
    Task {
      let center = UNUserNotificationCenter.current()
      let settings = await center.notificationSettings()
      do {
        if settings.authorizationStatus == .notDetermined {
          let granted = try await center.requestAuthorization(options: [.alert, .sound])
          self.needsNotificationPermission = !granted
        } else {
          self.needsNotificationPermission = settings.authorizationStatus == .denied
        }
      } catch {
        self.fail("无法请求通知权限：\(error.localizedDescription)")
      }
    }
  }

  func openScreenRecordingSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") else { return }
    NSWorkspace.shared.open(url)
  }

  func openNotificationSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
  }

  func openKeyboardSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
  }

  func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.needsAccessibilityPermission = !AXIsProcessTrusted()
    }
  }

  func setShortcut(_ value: ShortcutDefinition, for purpose: ShortcutPurpose) -> String? {
    guard value.isValid else { return "请按下一个包含修饰键的快捷键。" }
    let current = purpose == .action ? shortcut : instructionShortcut
    let other = purpose == .action ? instructionShortcut : shortcut
    if value == current { return nil }
    if value == other { return "两个入口不能使用同一个快捷键。" }
    if let conflict = validateShortcutRegistration(value) { return conflict }
    guard let data = try? JSONEncoder().encode(value) else { return "无法保存快捷键。" }
    let key = purpose == .action ? shortcutDefaultsKey : instructionShortcutDefaultsKey
    UserDefaults.standard.set(data, forKey: key)
    if purpose == .action { shortcut = value } else { instructionShortcut = value }
    needsKeyboardShortcutPermission = (shortcut.kind == .doubleFunction
      || instructionShortcut.kind == .doubleFunction)
      && !AppDelegate.keyboardShortcutPermissionGranted()
    let conflict = value.kind == .doubleFunction && functionKeyHasSystemAction()
      ? "Fn 同时配置了系统操作，可能发生冲突。"
      : nil
    if purpose == .action { shortcutConflictMessage = conflict }
    else { instructionShortcutConflictMessage = conflict }
    NotificationCenter.default.post(name: .proactiveShortcutChanged, object: nil)
    return nil
  }

  func requestKeyboardShortcutPermission() {
    NotificationCenter.default.post(name: .requestKeyboardShortcutPermission, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self else { return }
      self.needsKeyboardShortcutPermission = (self.shortcut.kind == .doubleFunction
        || self.instructionShortcut.kind == .doubleFunction)
        && !AppDelegate.keyboardShortcutPermissionGranted()
    }
  }

  func followUp(notification: String, turns: [ChatTurn]) async throws -> String {
    guard let chatPort, let chatToken else {
      throw NSError(domain: "ProactiveAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "请先打开感知，再继续对话。"])
    }
    guard let url = URL(string: "http://127.0.0.1:\(chatPort)/follow-up") else {
      throw NSError(domain: "ProactiveAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "对话服务地址无效。"])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(chatToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(FollowUpRequest(
      notification: notification,
      turns: Array(turns.suffix(6))))
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw NSError(domain: "ProactiveAI", code: 5, userInfo: [NSLocalizedDescriptionKey: "对话服务暂时不可用。"])
    }
    let reply = try JSONDecoder().decode(FollowUpResponse.self, from: data)
    guard !reply.text.isEmpty else {
      throw NSError(domain: "ProactiveAI", code: 6, userInfo: [NSLocalizedDescriptionKey: "没有收到有效回复。"])
    }
    return reply.text
  }

  func setCaptureInterval(seconds: Int) {
    guard [1, 5, 15, 60].contains(seconds), seconds != captureIntervalSeconds else { return }
    captureIntervalSeconds = seconds
    UserDefaults.standard.set(seconds, forKey: captureIntervalDefaultsKey)
    // The model and notification process stays alive. Only the stateless screenshot timer restarts.
    guard process?.isRunning == true else { return }
    stopScreenObserver()
    startScreenObserver()
  }

  var captureEffort: Int {
    switch captureIntervalSeconds {
    case 60: return 1
    case 15: return 2
    case 5: return 3
    default: return 4
    }
  }

  func setCaptureEffort(_ effort: Int) {
    let interval: Int
    switch effort {
    case 1: interval = 60
    case 2: interval = 15
    case 3: interval = 5
    default: interval = 1
    }
    setCaptureInterval(seconds: interval)
  }

  func setAgentExecutionAllowed(_ allowed: Bool) {
    guard allowed != allowsAgentExecution else { return }
    allowsAgentExecution = allowed
    UserDefaults.standard.set(allowed, forKey: agentExecutionDefaultsKey)
    guard state != .stopped else { return }
    restartAfterStop = true
    stop()
  }

  func setEditorWriteAllowed(_ allowed: Bool) {
    guard allowed != allowsEditorWrite else { return }
    allowsEditorWrite = allowed
    UserDefaults.standard.set(allowed, forKey: editorWriteDefaultsKey)
    guard state != .stopped else { return }
    restartAfterStop = true
    stop()
  }

  private var todayRecords: [ActivityRecord] {
    activities.filter { Calendar.current.isDateInToday($0.time) }
  }

  private func resourcePath(named name: String) throws -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else {
      throw NSError(domain: "ProactiveAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 \(name) 资源"])
    }
    return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func attachReaders() {
    standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      guard let controller = self else { return }
      Task { @MainActor in controller.consume(text, isErrorStream: false) }
    }
    standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      guard let controller = self else { return }
      Task { @MainActor in controller.consume(text, isErrorStream: true) }
    }
  }

  private func consume(_ text: String, isErrorStream: Bool) {
    if isErrorStream {
      errorBuffer += text
      consumeLines(from: &errorBuffer, parseActivities: true)
    } else {
      outputBuffer += text
      consumeLines(from: &outputBuffer, parseActivities: false)
    }
  }

  private func consumeLines(from buffer: inout String, parseActivities: Bool) {
    while let newline = buffer.firstIndex(of: "\n") {
      let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
      buffer.removeSubrange(...newline)
      if parseActivities, line.hasPrefix(activityPrefix) {
        consumeActivity(String(line.dropFirst(activityPrefix.count)))
      } else if parseActivities,
                line.localizedCaseInsensitiveContains("failed") || line.localizedCaseInsensitiveContains("error") {
        lastError = line
      }
    }
  }

  private func consumeActivity(_ json: String) {
    guard let data = json.data(using: .utf8),
          let stream = try? JSONDecoder().decode(StreamRecord.self, from: data),
          stream.version == 1 else { return }
    if stream.type == "native-action",
       let requestId = stream.requestId,
       let targetId = stream.targetId,
       let rawAction = stream.action,
       let action = EditorWriteMode(rawValue: rawAction),
       let text = stream.text {
      Task { @MainActor in
        let result = await EditorTargetStore.shared.perform(
          targetId: targetId, mode: action, text: text)
        self.forwardObserverEvent([
          "type": "native-action-result",
          "requestId": requestId,
          "ok": result.0,
          "message": result.1,
        ])
        self.canUndoEditorWrite = EditorTargetStore.shared.canUndo
      }
      return
    }
    if stream.type == "status" {
      if stream.state == "ready" {
        state = .running
        lastError = nil
        needsScreenPermission = false
        chatPort = stream.chatPort
        chatToken = stream.chatToken
        if let pendingExplicitRequest {
          self.pendingExplicitRequest = nil
          dispatch(pendingExplicitRequest)
        }
      }
      if stream.state == "stopped", state != .stopping {
        state = .stopped
        chatPort = nil
        chatToken = nil
      }
      return
    }

    let time = parseISODate(stream.time) ?? Date()
    let record: ActivityRecord
    var shouldStop = false
    if stream.type == "episode" {
      record = ActivityRecord(
        id: UUID(), time: time, kind: .episode, app: stream.app, bundleId: stream.bundleId,
        characters: stream.characters, inputTokens: nil, outputTokens: nil, message: nil)
    } else if stream.type == "decision" {
      // Completing the explicit interaction is independent from whether its
      // text survives the last presentation filter. Otherwise a safely
      // suppressed malformed answer leaves the pulse breathing indefinitely.
      if stream.explicit == true {
        TriggerPulsePresenter.shared.finish(success: stream.category != "status")
      }
      let proposedKind: ActivityKind
      switch stream.outcome {
      case "notified": proposedKind = .notification
      case "shadow": proposedKind = .shadow
      case "duplicate": proposedKind = .duplicate
      default: proposedKind = .noop
      }
      let kind = [.notification, .shadow].contains(proposedKind)
        && !isPresentableReminder(stream.message) ? ActivityKind.noop : proposedKind
      if kind == .noop { return }
      record = ActivityRecord(
        id: UUID(), time: time, kind: kind, app: stream.app, bundleId: stream.bundleId,
        characters: stream.characters, inputTokens: stream.inputTokens,
        outputTokens: stream.outputTokens, message: stream.message,
        explicit: stream.explicit, delivery: stream.delivery, category: stream.category)
      if kind == .notification, stream.delivery != "inline",
         let message = stream.message, !message.isEmpty {
        deliverNotification(message: message, app: stream.app, activityID: record.id)
      }
    } else if stream.type == "error" {
      if TriggerPulsePresenter.shared.isWorking {
        TriggerPulsePresenter.shared.finish(success: false)
      }
      let rawMessage = stream.message ?? "未知错误"
      let screenPermission = rawMessage.contains("screen-permission")
        || rawMessage.contains("Screen Recording permission")
        || (needsScreenPermission && rawMessage.contains("dsh.proactive-screen error 1"))
      if screenPermission { needsScreenPermission = true }
      if screenPermission { requestScreenRecordingPermissionIfNeeded() }
      shouldStop = screenPermission || rawMessage.contains("capture-stopped")
      let message = screenPermission
        ? "需要允许「Astra」录制屏幕；授权后重新打开感知。"
        : rawMessage
      lastError = message
      if activities.last?.kind == .error, activities.last?.message == message {
        if shouldStop { stop() }
        return
      }
      record = ActivityRecord(
        id: UUID(), time: time, kind: .error, app: stream.stage, bundleId: nil,
        characters: nil, inputTokens: nil, outputTokens: nil, message: message)
    } else {
      return
    }
    append(record)
    if shouldStop { stop() }
  }

  private func scheduleStartupTimeout(for child: Process) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak child] in
      guard let self, let child, self.process === child, self.state == .starting else { return }
      self.fail("启动超时，请检查模型配置或屏幕录制权限。")
      self.stop()
    }
  }

  private func requestScreenRecordingPermissionIfNeeded() {
    guard !requestedScreenPermission else { return }
    requestedScreenPermission = true
    guard !CGPreflightScreenCaptureAccess() else { return }
    CGRequestScreenCaptureAccess()
  }

  private func processDidTerminate(pid: Int32, status: Int32) {
    guard process?.processIdentifier == pid else { return }
    let expected = intentionalStop
    standardOutput.fileHandleForReading.readabilityHandler = nil
    standardError.fileHandleForReading.readabilityHandler = nil
    process = nil
    stopScreenObserver()
    observerInput?.fileHandleForWriting.closeFile()
    observerInput = nil
    state = .stopped
    chatPort = nil
    chatToken = nil
    if restartAfterStop {
      restartAfterStop = false
      start()
      return
    }
    if !expected, lastError == nil {
      let description = "观察器意外停止（退出码 \(status)）。"
      fail(description)
      append(ActivityRecord(
        id: UUID(), time: Date(), kind: .error, app: nil, bundleId: nil,
        characters: nil, inputTokens: nil, outputTokens: nil, message: description))
    }
  }

  private func append(_ record: ActivityRecord) {
    activities.append(record)
    if activities.count > maximumHistoryRecords {
      activities.removeFirst(activities.count - maximumHistoryRecords)
      rewriteHistory()
      return
    }
    do {
      let url = try historyURL()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      var data = try encoder.encode(record)
      data.append(0x0A)
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let handle = try FileHandle(forWritingTo: url)
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      lastError = "无法保存活动记录：\(error.localizedDescription)"
    }
  }

  private func loadHistory() {
    do {
      let url = try historyURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      let text = try String(contentsOf: url, encoding: .utf8)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      activities = text.split(separator: "\n")
        .suffix(maximumHistoryRecords)
        .compactMap { try? decoder.decode(ActivityRecord.self, from: Data($0.utf8)) }
    } catch {
      lastError = "无法读取活动记录：\(error.localizedDescription)"
    }
  }

  private func loadConversations() {
    do {
      let url = try conversationHistoryURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      conversations = try decoder.decode([ConversationSession].self, from: data)
      trimConversations()
    } catch {
      lastError = "无法读取对话记录：\(error.localizedDescription)"
    }
  }

  private func trimConversations() {
    guard conversations.count > maximumConversationSessions else { return }
    conversations = Array(conversations
      .sorted(by: { $0.updatedAt < $1.updatedAt })
      .suffix(maximumConversationSessions))
  }

  private func saveConversations() {
    do {
      trimConversations()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let url = try conversationHistoryURL()
      try encoder.encode(conversations).write(to: url, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      lastError = "无法保存对话记录：\(error.localizedDescription)"
    }
  }

  private func rewriteHistory() {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      var data = Data()
      for record in activities {
        data.append(try encoder.encode(record))
        data.append(0x0A)
      }
      try data.write(to: historyURL(), options: [.atomic])
    } catch {
      lastError = "无法整理活动记录：\(error.localizedDescription)"
    }
  }

  private func historyURL() throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ProactiveAI", isDirectory: true)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return base.appendingPathComponent("activity.jsonl")
  }

  private func conversationHistoryURL() throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ProactiveAI", isDirectory: true)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return base.appendingPathComponent("conversations.json")
  }

  private func parseISODate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private func fail(_ message: String) {
    lastError = message
  }

  private func startScreenObserver() {
    let observer = ScreenObserver(
      config: ObserverConfig(
        captureIntervalSeconds: Double(captureIntervalSeconds),
        maxTextCharacters: 1_600
      ),
      output: { [weak self] event in
        Task { @MainActor in self?.forwardObserverEvent(event) }
      })
    self.observer = observer
    Task {
      do {
        try await observer.start()
      } catch {
        // The observer has already sent a structured error through the same pipe.
      }
    }
  }

  private func stopScreenObserver() {
    let observer = observer
    self.observer = nil
    guard let observer else { return }
    Task { await observer.stop() }
  }

  private func dispatch(_ request: ExplicitRequest) {
    switch request {
    case .screen(let editorTargetId, let instruction):
      var metadata: [String: Any] = [:]
      if let editorTargetId { metadata["editorTargetId"] = editorTargetId }
      if let instruction, !instruction.isEmpty { metadata["instruction"] = instruction }
      observer?.captureNow(metadata: metadata)
    case .selection(let selection, let editorTargetId, let instruction):
      var event: [String: Any] = [
        "type": "episode",
        "time": ISO8601DateFormatter().string(from: Date()),
        "app": selection.app,
        "bundleId": selection.bundleId,
        "fingerprint": "selection-\(UUID().uuidString)",
        "text": selection.text,
        "forced": true,
        "context": "selection",
      ]
      if let editorTargetId { event["editorTargetId"] = editorTargetId }
      if let instruction, !instruction.isEmpty { event["instruction"] = instruction }
      forwardObserverEvent(event)
    }
  }

  private func forwardObserverEvent(_ sourceEvent: [String: Any]) {
    var event = sourceEvent
    if event["type"] as? String == "episode",
       event["forced"] as? Bool != true,
       let bundleId = event["bundleId"] as? String,
       excludedBundleIds.contains(bundleId) {
      return
    }
    if allowsEditorWrite,
       event["type"] as? String == "episode",
       event["editorTargetId"] == nil,
       event["forced"] as? Bool != true {
      let interaction = EditorTargetStore.shared.capture()
      if let targetId = interaction.editorTargetId,
         interaction.application?.bundleIdentifier == event["bundleId"] as? String {
        event["editorTargetId"] = targetId
      }
    }
    guard JSONSerialization.isValidJSONObject(event),
          let data = try? JSONSerialization.data(withJSONObject: event) else { return }
    observerInput?.fileHandleForWriting.write(data)
    observerInput?.fileHandleForWriting.write(Data("\n".utf8))
  }

  private func deliverNotification(message: String, app: String? = nil, activityID: UUID? = nil) {
    guard isPresentableReminder(message) else { return }
    let content = UNMutableNotificationContent()
    content.title = "Astra"
    if let app, !app.isEmpty { content.subtitle = app }
    content.body = notificationPreview(message)
    content.sound = .default
    content.categoryIdentifier = notificationCategory
    var userInfo: [String: Any] = ["message": message]
    if let activityID { userInfo["activityId"] = activityID.uuidString }
    content.userInfo = userInfo
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        Task { @MainActor in self.fail("无法发送系统通知：\(error.localizedDescription)") }
      }
    }
  }
}

private struct PermissionNotice: View {
  let symbol: String
  let title: String
  let detail: String
  let actionTitle: String
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(.orange)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      if prominent {
        Button(actionTitle, action: action)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      } else {
        Button(actionTitle, action: action)
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
    .padding(.vertical, 10)
  }
}

private struct ActivityRow: View {
  let record: ActivityRecord
  let onContinue: ((String) -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: record.category == "status" ? "exclamationmark.triangle" : record.kind.symbol)
        .foregroundStyle(record.category == "status" ? Color.orange : record.kind.tint)
        .frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(record.category == "status" ? "需要处理" : record.kind.title)
            .font(.subheadline.weight(.medium))
          Spacer()
          Text(record.time.formatted(date: .omitted, time: .shortened))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        if let message = record.message, !message.isEmpty {
          Text(message)
            .font(.subheadline)
            .textSelection(.enabled)
          if record.kind == .notification && record.category != "status" {
            Button("继续聊") { onContinue?(message) }
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }
        HStack(spacing: 10) {
          if let app = record.app { Text(app) }
          if let characters = record.characters { Text("\(characters) 字") }
          if let input = record.inputTokens, let output = record.outputTokens {
            Text("\(input + output) tokens")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }
}

private struct ReminderRow: View {
  let record: ActivityRecord
  let onContinue: (ActivityRecord) -> Void

  private var presentedMessage: String? {
    record.message
  }

  var body: some View {
    Button {
      if presentedMessage != nil { onContinue(record) }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "sparkles")
          .foregroundStyle(.secondary)
          .frame(width: 18, height: 18)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(record.app ?? "Astra")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            Spacer()
            Text(record.time.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          if let message = presentedMessage {
            Text(message)
              .font(.body)
              .lineLimit(3)
              .multilineTextAlignment(.leading)
          }
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .padding(.top, 3)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 9)
  }
}

private struct ChatBubble: View {
  let role: ChatTurn.Role
  let text: String
  @State private var copyFeedback: CopyFeedback?
  @State private var copyFeedbackID = UUID()

  private enum CopyFeedback {
    case copied
    case failed
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      if role == .user { Spacer(minLength: 72) }
      if role == .assistant {
        Image(systemName: "sparkles")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(.quaternary, in: Circle())
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(text)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if role == .assistant {
          Button {
            let feedbackID = UUID()
            copyFeedbackID = feedbackID
            withAnimation(.easeOut(duration: 0.15)) {
              copyFeedback = copyToPasteboard(text) ? .copied : .failed
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
              guard copyFeedbackID == feedbackID else { return }
              withAnimation(.easeOut(duration: 0.15)) {
                copyFeedback = nil
              }
            }
          } label: {
            Label(copyButtonTitle, systemImage: copyButtonIcon)
              .font(.caption.weight(.medium))
              .foregroundStyle(copyButtonColor)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(copyButtonColor.opacity(0.12), in: Capsule())
          }
          .buttonStyle(.plain)
          .help(copyFeedback == .copied ? "内容已复制到剪贴板" : "复制这条回复")
          .accessibilityLabel(copyButtonTitle)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      if role == .assistant { Spacer(minLength: 72) }
    }
  }

  private var bubbleColor: Color {
    role == .user ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor)
  }

  private var copyButtonTitle: String {
    switch copyFeedback {
    case .copied: return "已复制"
    case .failed: return "复制失败"
    case nil: return "复制"
    }
  }

  private var copyButtonIcon: String {
    switch copyFeedback {
    case .copied: return "checkmark"
    case .failed: return "exclamationmark.triangle"
    case nil: return "doc.on.doc"
    }
  }

  private var copyButtonColor: Color {
    switch copyFeedback {
    case .copied: return .green
    case .failed: return .red
    case nil: return .accentColor
    }
  }
}

private struct ConversationView: View {
  @ObservedObject var controller: ObserverController
  let sessionID: UUID
  @State private var draft = ""
  @State private var isSending = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles")
          .foregroundStyle(.secondary)
        Text("Astra")
          .font(.headline)
        Spacer()
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 14) {
            ChatBubble(
              role: .assistant,
              text: controller.conversation(id: sessionID)?.notification ?? "")
              .id("initial-notification")
            ForEach(controller.conversation(id: sessionID)?.turns ?? []) { turn in
              ChatBubble(role: turn.role, text: turn.text)
                .id(turn.id)
            }
          }
          .frame(maxWidth: 840)
          .frame(maxWidth: .infinity)
          .padding(18)
        }
        .onChange(of: controller.conversation(id: sessionID)?.turns.count ?? 0) { _ in
          guard let last = controller.conversation(id: sessionID)?.turns.last else { return }
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }

      if let error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 18)
          .padding(.bottom, 8)
      }

      Divider()

      HStack(alignment: .bottom, spacing: 10) {
        TextField("发送消息…", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .disabled(isSending)
          .onSubmit { send() }
        Button { send() } label: {
          if isSending {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.up")
              .font(.caption.weight(.bold))
          }
        }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
      }
      .frame(maxWidth: 840)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
    }
    .frame(minWidth: 520, minHeight: 440)
  }

  private func send() {
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty,
          let session = controller.conversation(id: sessionID) else { return }
    let userTurn = ChatTurn(role: .user, text: question)
    controller.appendConversationTurn(userTurn, to: sessionID)
    draft = ""
    error = nil
    isSending = true
    Task {
      do {
        let turns = Array(
          (controller.conversation(id: sessionID)?.turns ?? [])
            .suffix(maximumFollowUpContextTurns))
        let response = try await controller.followUp(notification: session.notification, turns: turns)
        controller.appendConversationTurn(ChatTurn(role: .assistant, text: response), to: sessionID)
      } catch {
        controller.removeConversationTurn(userTurn.id, from: sessionID)
        draft = question
        self.error = "暂时没能回复，请重试。"
      }
      isSending = false
    }
  }
}

private struct ShortcutEditorSheet: View {
  @ObservedObject var controller: ObserverController
  let purpose: ShortcutPurpose
  @Environment(\.dismiss) private var dismiss
  @State private var candidate: ShortcutDefinition
  @State private var issue: String?
  @State private var feedback: String?
  @State private var eventMonitor: Any?
  @State private var eventObserver: NSObjectProtocol?
  @State private var lastFunctionRecordingPress: Date?
  @State private var lastRecordingEventSignature: String?
  @State private var lastRecordingEventTimestamp: TimeInterval?
  @State private var lastAcceptedAt: Date?
  @State private var recordingStartedAt: Date?

  init(controller: ObserverController, purpose: ShortcutPurpose) {
    self.controller = controller
    self.purpose = purpose
    _candidate = State(initialValue: purpose == .action
      ? controller.shortcut
      : controller.instructionShortcut)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("\(purpose.title)快捷键")
          .font(.headline)
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: Circle())
      }

      VStack(spacing: 8) {
        Text(candidate.displayName)
          .font(.system(size: 24, weight: .medium, design: .rounded))
          .frame(maxWidth: .infinity)
        Text("按下新的组合键，或连按两次 Fn")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 92)
      .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

      Text("组合键需包含 ⌃、⌥、⌘、Shift 或 fn；单独使用 ⌘ 或 Shift 不会保存。")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let issue {
        Label(issue, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      if let feedback {
        Label(feedback, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }

      HStack {
        Button("使用 \(purpose.defaultShortcut.displayName)") {
          candidate = purpose.defaultShortcut
          lastAcceptedAt = Date()
          issue = nil
          feedback = "已选择 \(purpose.defaultShortcut.displayName)，保存后生效。"
        }
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          if let message = controller.setShortcut(candidate, for: purpose) {
            issue = message
          } else {
            dismiss()
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(20)
    .frame(width: 430)
    .onAppear { beginRecording() }
    .onDisappear { endRecording() }
  }

  private func beginRecording() {
    guard eventMonitor == nil, eventObserver == nil else { return }
    recordingStartedAt = Date()
    eventObserver = NotificationCenter.default.addObserver(
      forName: .proactiveShortcutRecordingEvent,
      object: nil,
      queue: .main
    ) { notification in
      guard let event = notification.object as? NSEvent else { return }
      _ = handleRecordingEvent(event)
    }
    NotificationCenter.default.post(name: .proactiveShortcutRecordingBegan, object: nil)
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      handleRecordingEvent(event) ? nil : event
    }
  }

  private func handleRecordingEvent(_ event: NSEvent) -> Bool {
    if let recordingStartedAt, Date().timeIntervalSince(recordingStartedAt) < 0.2 { return false }
    let signature = "\(event.type.rawValue):\(event.keyCode):\(carbonModifiers(from: event.modifierFlags))"
    if signature == lastRecordingEventSignature,
       let lastRecordingEventTimestamp,
       abs(event.timestamp - lastRecordingEventTimestamp) < 0.001 { return true }
    lastRecordingEventSignature = signature
    lastRecordingEventTimestamp = event.timestamp
    if event.type == .flagsChanged {
      guard event.keyCode == 63, event.modifierFlags.contains(.function) else { return false }
      let now = Date()
      if let lastFunctionRecordingPress,
         now.timeIntervalSince(lastFunctionRecordingPress) <= 0.75 {
        self.lastFunctionRecordingPress = nil
        candidate = .actionDefault
        issue = nil
        feedback = "已识别 Fn ×2，保存后生效。"
      } else {
        lastFunctionRecordingPress = now
        feedback = "再按一次 Fn。"
      }
      return true
    }
    guard event.type == .keyDown else { return false }
    if event.keyCode == 53, carbonModifiers(from: event.modifierFlags) == 0 {
      dismiss()
      return true
    }
    guard let value = shortcutDefinition(from: event) else {
      if lastAcceptedAt != nil { return true }
      feedback = nil
      issue = "请使用包含修饰键的组合，避免影响正常输入。"
      return true
    }
    candidate = value
    lastAcceptedAt = Date()
    issue = validateShortcutRegistration(value)
    feedback = issue == nil ? "已录入，保存后生效。" : nil
    return true
  }

  private func endRecording() {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
    eventObserver = nil
    lastFunctionRecordingPress = nil
    lastRecordingEventSignature = nil
    lastRecordingEventTimestamp = nil
    lastAcceptedAt = nil
    recordingStartedAt = nil
    NotificationCenter.default.post(name: .proactiveShortcutRecordingEnded, object: nil)
  }
}

private struct DashboardView: View {
  @ObservedObject var controller: ObserverController
  @Environment(\.openWindow) private var openWindow
  @State private var showReminders = false
  @State private var showDiagnostics = false
  @State private var shortcutEditorPurpose: ShortcutPurpose?

  private var reminders: [ActivityRecord] {
    Array(controller.activities
      .filter { $0.kind == .notification && $0.category == "result" && isPresentableReminder($0.message) }
      .suffix(maximumVisibleReminders)
      .reversed())
  }

  private var recentDiagnostics: [ActivityRecord] {
    Array(controller.activities
      .filter { $0.kind == .error || ($0.kind == .notification && $0.category == "status") }
      .suffix(12)
      .reversed())
  }

  private var perceptionBinding: Binding<Bool> {
    Binding(
      get: { controller.isRunning },
      set: { enabled in enabled ? controller.start() : controller.stop() })
  }

  private var captureEffortBinding: Binding<Int> {
    Binding(
      get: { controller.captureEffort },
      set: { controller.setCaptureEffort($0) })
  }

  private var agentExecutionBinding: Binding<Bool> {
    Binding(
      get: { controller.allowsAgentExecution },
      set: { controller.setAgentExecutionAllowed($0) })
  }

  private var editorWriteBinding: Binding<Bool> {
    Binding(
      get: { controller.allowsEditorWrite },
      set: { controller.setEditorWriteAllowed($0) })
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
              .font(.system(size: 19, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(width: 36, height: 36)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
              Text("Astra")
                .font(.headline)
              HStack(spacing: 6) {
                Circle().fill(controller.isTemporarilyPaused ? Color.secondary : controller.state.color)
                  .frame(width: 6, height: 6)
                Text(controller.isTemporarilyPaused ? "已暂停一小时" : controller.state.title)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Toggle("感知", isOn: perceptionBinding)
              .toggleStyle(.switch)
              .tint(.green)
              .controlSize(.small)
          }

          VStack(alignment: .leading, spacing: 9) {
            Text("试一下")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            HStack(spacing: 10) {
              Button(controller.shortcut.displayName) { shortcutEditorPurpose = .action }
                .buttonStyle(.bordered)
                .controlSize(.mini)
              Text("让 Astra 直接处理当前内容")
                .font(.subheadline)
            }
            HStack(spacing: 10) {
              Button(controller.instructionShortcut.displayName) { shortcutEditorPurpose = .instruction }
                .buttonStyle(.bordered)
                .controlSize(.mini)
              Text("输入一句要求后立即行动")
                .font(.subheadline)
            }
            Text("先选中文字时，Astra 只处理选中的内容。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .padding(.top, 16)

          Divider().padding(.vertical, 16)

          VStack(spacing: 12) {
            HStack {
              Text("感知强度").font(.subheadline)
              Spacer()
              Picker("感知强度", selection: captureEffortBinding) {
                Text("Light").tag(1)
                Text("Standard").tag(2)
                Text("Focus").tag(3)
                Text("High").tag(4)
              }
              .labelsHidden()
              .pickerStyle(.segmented)
              .frame(width: 300)
            }
            if let conflict = controller.shortcutConflictMessage
              ?? controller.instructionShortcutConflictMessage {
              HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(conflict)
                Button("修复") { controller.openKeyboardSettings() }
                  .buttonStyle(.link)
              }
              .font(.caption)
              .foregroundStyle(.orange)
            }
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("执行操作").font(.subheadline)
                Text(controller.allowsAgentExecution ? "完成低风险操作；重要操作先询问" : "只分析并给出结果")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Toggle("执行操作", isOn: agentExecutionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.small)
            }
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("写入编辑区").font(.subheadline)
                Text(!controller.allowsAgentExecution
                  ? "需先开启执行操作"
                  : controller.allowsEditorWrite ? "仅在意图明确、低风险时写入" : "只返回结果")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Toggle("写入编辑区", isOn: editorWriteBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.small)
                .disabled(!controller.allowsAgentExecution)
            }
            if controller.canUndoEditorWrite {
              HStack {
                Text("上次写入").font(.subheadline)
                Spacer()
                Button("撤销") { controller.undoLastEdit() }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 0) {
          if controller.needsScreenPermission || controller.needsKeyboardShortcutPermission
              || controller.needsAccessibilityPermission
              || controller.needsNotificationPermission || controller.lastError != nil {
            Divider().padding(.vertical, 14)
          }

          if controller.needsScreenPermission {
            PermissionNotice(
              symbol: "rectangle.inset.filled.and.person.filled",
              title: "允许查看屏幕内容",
              detail: "仅用于本机识别当前画面文字。",
              actionTitle: "打开设置",
              prominent: true,
              action: { controller.openScreenRecordingSettings() })
          }

          if controller.needsKeyboardShortcutPermission {
            PermissionNotice(
              symbol: "keyboard",
              title: "允许 \(controller.shortcut.displayName) 快捷触发",
              detail: "只识别主动触发，不记录键入内容。",
              actionTitle: "允许",
              prominent: false,
              action: { controller.requestKeyboardShortcutPermission() })
          }

          if controller.needsAccessibilityPermission {
            PermissionNotice(
              symbol: "text.cursor",
              title: "允许选区与编辑",
              detail: "读取主动选区，并在开启时原位写回。",
              actionTitle: "允许",
              prominent: false,
              action: { controller.requestAccessibilityPermission() })
          }

          if controller.needsNotificationPermission {
            PermissionNotice(
              symbol: "bell.slash",
              title: "允许接收提醒",
              detail: "关闭通知时，结果仍会保留在这里。",
              actionTitle: "打开设置",
              prominent: false,
              action: { controller.openNotificationSettings() })
          }

          if !controller.needsScreenPermission, controller.lastError != nil {
            Label("感知暂时不可用，请在高级设置中查看。", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.vertical, 8)
          }
        }

        VStack(alignment: .leading, spacing: 0) {
          Divider().padding(.vertical, 14)

          DisclosureGroup(isExpanded: $showReminders) {
            if reminders.isEmpty {
              Text("暂无值得提醒的内容")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            } else {
              LazyVStack(spacing: 0) {
                ForEach(reminders) { record in
                  ReminderRow(record: record) { record in
                    openWindow(value: controller.conversationID(for: record))
                  }
                  Divider().padding(.leading, 28)
                }
              }
              .padding(.top, 8)
            }
          } label: {
            HStack {
              Label("最近", systemImage: "checkmark.circle")
                .font(.subheadline.weight(.medium))
              Spacer()
              Text(reminders.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
          }

          Divider().padding(.vertical, 14)

          DisclosureGroup(isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 14) {
              Text("今日  \(controller.todayDecisions) 次处理  ·  \(controller.todayNotifications) 条结果  ·  \(controller.todayTokens) tokens")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              HStack(spacing: 8) {
                Button("打开测试场景") { controller.openTriggerScenario() }
                  .disabled(!controller.isRunning)
                Button("体验原位改写") { controller.openWritebackScenario() }
                  .disabled(!controller.isRunning || !controller.allowsAgentExecution
                    || !controller.allowsEditorWrite)
                Button("体验光标写入") { controller.openCursorWritebackScenario() }
                  .disabled(!controller.isRunning || !controller.allowsAgentExecution
                    || !controller.allowsEditorWrite)
                Button("测试通知") { controller.sendTestNotification() }
                Spacer()
                Button("清空记录", role: .destructive) { controller.clearHistory() }
                  .disabled(controller.activities.isEmpty)
              }
              if !controller.excludedBundleIds.isEmpty {
                HStack {
                  Text("已暂停感知 \(controller.excludedBundleIds.count) 个 App")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Spacer()
                  Button("全部恢复") { controller.clearExcludedApps() }
                    .buttonStyle(.link)
                }
              }
              if let error = controller.lastError {
                Text(error)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              if !recentDiagnostics.isEmpty {
                Divider()
                LazyVStack(spacing: 0) {
                  ForEach(recentDiagnostics) { record in
                    ActivityRow(record: record, onContinue: nil)
                    Divider().padding(.leading, 30)
                  }
                }
              }
            }
            .padding(.top, 12)
          } label: {
            Label("高级设置", systemImage: "slider.horizontal.3")
              .font(.subheadline.weight(.medium))
          }

        }
      }
      .padding(20)
    }
    .frame(minWidth: 500, minHeight: 430)
    .onAppear {
      controller.prepareNotifications()
      controller.startIfNeeded()
      showReminders = !reminders.isEmpty
    }
    .sheet(item: $shortcutEditorPurpose) { purpose in
      ShortcutEditorSheet(controller: controller, purpose: purpose)
    }
    .onReceive(NotificationCenter.default.publisher(for: .openProactiveConversation)) { notification in
      if let message = notification.userInfo?["message"] as? String {
        let activityID = (notification.userInfo?["activityId"] as? String).flatMap(UUID.init(uuidString:))
        openWindow(value: controller.conversationID(notification: message, activityID: activityID))
      }
    }
  }
}

private struct MenuContent: View {
  @ObservedObject var controller: ObserverController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("打开控制台") {
      openWindow(id: "dashboard")
      NSApp.activate(ignoringOtherApps: true)
    }
    Divider()
    Button(controller.isRunning ? "关闭感知" : "打开感知") {
      controller.isRunning ? controller.stop() : controller.start()
    }
    Button(controller.isTemporarilyPaused ? "继续感知" : "暂停 1 小时") {
      controller.isTemporarilyPaused ? controller.resumeNow() : controller.pauseForOneHour()
    }
    Button(controller.currentAppIsExcluded ? "恢复感知当前 App" : "暂停感知当前 App") {
      controller.toggleCurrentAppExclusion()
    }
    Button("撤销上次写入") { controller.undoLastEdit() }
      .disabled(!controller.canUndoEditorWrite)
    Button("打开触发场景") { controller.openTriggerScenario() }
      .disabled(!controller.isRunning)
    Divider()
    Button("退出") {
      controller.shutdown()
      NSApp.terminate(nil)
    }
  }
}

private struct MenuBarLabel: View {
  @ObservedObject var controller: ObserverController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(systemName: controller.isRunning ? "sparkles" : "sparkle")
      .onReceive(NotificationCenter.default.publisher(for: .openProactiveDashboard)) { _ in
        openWindow(id: "dashboard")
      }
  }
}

@main
@MainActor
private struct ProactiveAIApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var controller = ObserverController()

  var body: some Scene {
    Window("Astra", id: "dashboard") {
      DashboardView(controller: controller)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          controller.shutdown()
        }
    }
    .defaultSize(width: 560, height: 520)
    .windowResizability(.contentMinSize)

    WindowGroup("继续对话", for: UUID.self) { $sessionID in
      if let sessionID {
        ConversationView(controller: controller, sessionID: sessionID)
      }
    }
    .defaultSize(width: 620, height: 560)
    .windowResizability(.contentMinSize)

    MenuBarExtra {
      MenuContent(controller: controller)
    } label: {
      MenuBarLabel(controller: controller)
    }
  }
}
