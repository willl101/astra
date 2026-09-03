import AppKit
import CoreImage
import CoreMedia
import CoreGraphics
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit
import Vision

private let screenObserverLogger = Logger(subsystem: "ai.deepseek.proactive.local", category: "capture")

@available(macOS 12.3, *)
final class OneShotVisibleRegionCapture: NSObject, SCStreamOutput, SCStreamDelegate {
  private let sampleQueue = DispatchQueue(label: "dsh.proactive-screen.single-frame")
  private let imageContext = CIContext(options: nil)
  private let lock = NSLock()
  private var stream: SCStream?
  private var continuation: CheckedContinuation<CGImage?, Never>?
  private var finished = false

  func capture(windowID: CGWindowID) async -> CGImage? {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let window = content.windows.first(where: { $0.windowID == windowID }),
            let display = content.displays.max(by: { left, right in
              let leftIntersection = left.frame.intersection(window.frame)
              let rightIntersection = right.frame.intersection(window.frame)
              return leftIntersection.width * leftIntersection.height
                < rightIntersection.width * rightIntersection.height
            }) else { return nil }
      let visibleFrame = window.frame.intersection(display.frame)
      guard !visibleFrame.isNull, visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
      let configuration = SCStreamConfiguration()
      configuration.width = max(1, Int(visibleFrame.width * 2))
      configuration.height = max(1, Int(visibleFrame.height * 2))
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.queueDepth = 3
      configuration.scalesToFit = true
      configuration.showsCursor = false
      configuration.sourceRect = CGRect(
        x: visibleFrame.minX - display.frame.minX,
        y: visibleFrame.minY - display.frame.minY,
        width: visibleFrame.width,
        height: visibleFrame.height)
      let filter = SCContentFilter(
        display: display,
        excludingApplications: [],
        exceptingWindows: [])
      screenObserverLogger.info("ScreenCaptureKit using composed foreground region")
      let stream = SCStream(
        filter: filter,
        configuration: configuration,
        delegate: self)
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
      self.stream = stream
      return await withCheckedContinuation { continuation in
        self.continuation = continuation
        Task {
          do { try await stream.startCapture() }
          catch { self.finish(nil) }
        }
        sampleQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(nil) }
      }
    } catch {
      return nil
    }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sampleBuffer.isValid,
          let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let statusRaw = attachmentsArray.first?[.status] as? Int,
          let status = SCFrameStatus(rawValue: statusRaw) else { return }
    screenObserverLogger.debug("ScreenCaptureKit frame status: \(statusRaw)")
    guard status == .complete,
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
    finish(cgImage)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    finish(nil)
  }

  private func finish(_ image: CGImage?) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    let stream = self.stream
    self.stream = nil
    lock.unlock()
    continuation?.resume(returning: image)
    if let stream { Task { try? await stream.stopCapture() } }
  }
}

struct ObserverConfig {
  let captureIntervalSeconds: Double
  let maxTextCharacters: Int

  static func parse() -> ObserverConfig {
    let values = CommandLine.arguments.dropFirst().reduce(into: [String: String]()) { result, argument in
      guard let separator = argument.firstIndex(of: "=") else { return }
      result[String(argument[..<separator])] = String(argument[argument.index(after: separator)...])
    }
    return ObserverConfig(
      captureIntervalSeconds: Double(values["--capture-interval-seconds"] ?? "15") ?? 15,
      maxTextCharacters: Int(values["--max-text-characters"] ?? "6000") ?? 6000
    )
  }
}

private struct SnapshotTarget {
  let windowID: CGWindowID?
  let windowBounds: CGRect?
  let displayID: CGDirectDisplayID?
  let app: String
  let bundleID: String
  let captureBlocked: Bool
  let captureLimited: Bool
}

/// Captures the visible foreground region in memory instead of keeping a video stream alive.
/// Every scheduled image is OCRed; snapshots and OCR text are never written to disk.
final class ScreenObserver: NSObject {
  private let config: ObserverConfig
  private let output: ([String: Any]) -> Void
  private let queue = DispatchQueue(label: "dsh.proactive-screen.snapshot", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var isCapturing = false
  private var pendingForcedMetadata: [String: Any]?
  private var lastTextFingerprint: UInt64?

  init(config: ObserverConfig, output: @escaping ([String: Any]) -> Void = writeNDJSON) {
    self.config = config
    self.output = output
  }

  func start() async throws {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now(),
      repeating: .milliseconds(Int(max(config.captureIntervalSeconds, 1) * 1_000)),
      leeway: .seconds(1)
    )
    timer.setEventHandler { [weak self] in self?.requestSnapshot(force: false, metadata: nil) }
    self.timer = timer
    timer.resume()
    emit(["type": "ready", "mode": "on-demand", "intervalSeconds": config.captureIntervalSeconds])
  }

  func stop() async {
    queue.sync {
      timer?.setEventHandler {}
      timer?.cancel()
      timer = nil
      pendingForcedMetadata = nil
    }
  }

  func captureNow(metadata: [String: Any] = [:]) {
    queue.async { [weak self] in self?.requestSnapshot(force: true, metadata: metadata) }
  }

  private func requestSnapshot(force: Bool, metadata: [String: Any]?) {
    guard timer != nil else { return }
    if force { screenObserverLogger.info("Forced capture requested") }
    if isCapturing {
      if force {
        pendingForcedMetadata = metadata ?? [:]
        screenObserverLogger.info("Forced capture queued behind an active capture")
      }
      return
    }
    isCapturing = true
    Task { [weak self] in
      guard let self else { return }
      do {
        guard let target = await self.makeSnapshotTarget(force: force) else {
          if force { screenObserverLogger.notice("Forced capture skipped for the foreground application") }
          self.queue.async { self.completeCapture() }
          return
        }
        if target.captureBlocked {
          self.queue.async { self.completeCapture() }
          return
        }
        if force {
          screenObserverLogger.info("Forced capture target: \(target.app, privacy: .public) [\(target.bundleID, privacy: .public)]")
        }
        guard let image = await self.captureImage(target) else {
          throw NSError(domain: "dsh.proactive-screen", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to capture a screenshot."])
        }
        self.queue.async {
          self.handle(image: image, target: target, force: force, metadata: metadata)
        }
      } catch {
        self.queue.async {
          self.completeCapture()
          let code = CGPreflightScreenCaptureAccess() ? "screenshot" : "screen-permission"
          self.emit(["type": "error", "code": code, "message": error.localizedDescription])
        }
      }
    }
  }

  private func completeCapture() {
    isCapturing = false
    guard let metadata = pendingForcedMetadata else { return }
    pendingForcedMetadata = nil
    requestSnapshot(force: true, metadata: metadata)
  }

  private func makeSnapshotTarget(force: Bool) async -> SnapshotTarget? {
    let application = await MainActor.run { NSWorkspace.shared.frontmostApplication }
    let bundleID = application?.bundleIdentifier ?? "unknown"
    let appName = application?.localizedName ?? "Unknown"
    if isSensitiveApplication(bundleID: bundleID, name: appName) {
      if force {
        emit([
          "type": "unavailable",
          "code": bundleID == "ai.deepseek.proactive.local"
            ? "assistant-window" : "sensitive-application",
          "app": appName,
          "bundleId": bundleID,
          "forced": true,
        ])
      } else {
        emit(["type": "skipped", "reason": "sensitive-application", "app": appName, "bundleId": bundleID])
      }
      return nil
    }
    if let window = frontmostWindow(for: application?.processIdentifier) {
      if force, window.sharingState == 0 {
        screenObserverLogger.notice(
          "Foreground window is not shareable; forced capture falling back to its visible display")
        return SnapshotTarget(
          windowID: nil,
          windowBounds: nil,
          displayID: displayContaining(window.bounds),
          app: appName,
          bundleID: bundleID,
          captureBlocked: false,
          captureLimited: true)
      }
      return SnapshotTarget(
        windowID: window.id,
        windowBounds: window.bounds,
        displayID: nil,
        app: appName,
        bundleID: bundleID,
        captureBlocked: window.sharingState == 0,
        captureLimited: false
      )
    }
    return SnapshotTarget(
      windowID: nil,
      windowBounds: nil,
      displayID: CGMainDisplayID(),
      app: appName,
      bundleID: bundleID,
      captureBlocked: false,
      captureLimited: false
    )
  }

  private func displayContaining(_ bounds: CGRect) -> CGDirectDisplayID {
    var displayID = CGMainDisplayID()
    var displayCount: UInt32 = 0
    let point = CGPoint(x: bounds.midX, y: bounds.midY)
    let result = CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount)
    return result == .success && displayCount > 0 ? displayID : CGMainDisplayID()
  }

  private func frontmostWindow(for processID: pid_t?) -> (id: CGWindowID, bounds: CGRect, sharingState: Int)? {
    guard let processID,
          let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }
    let candidate = records.compactMap { record -> (id: CGWindowID, bounds: CGRect, sharingState: Int, area: CGFloat)? in
      guard let ownerPID = record[kCGWindowOwnerPID as String] as? Int,
            ownerPID == Int(processID),
            let layer = record[kCGWindowLayer as String] as? Int,
            layer == 0,
            let identifier = record[kCGWindowNumber as String] as? NSNumber,
            let sharingState = record[kCGWindowSharingState as String] as? Int,
            let bounds = record[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
      let rectangle = CGRect(
        x: bounds["X"] ?? 0,
        y: bounds["Y"] ?? 0,
        width: bounds["Width"] ?? 0,
        height: bounds["Height"] ?? 0)
      let area = rectangle.width * rectangle.height
      return area > 1 ? (identifier.uint32Value, rectangle, sharingState, area) : nil
    }.max(by: { $0.area < $1.area })
    return candidate.map { ($0.id, $0.bounds, $0.sharingState) }
  }

  private func captureImage(_ target: SnapshotTarget) async -> CGImage? {
    if let windowID = target.windowID, let bounds = target.windowBounds {
      if #available(macOS 12.3, *),
         let image = await OneShotVisibleRegionCapture().capture(windowID: windowID) {
        return image
      }
      return CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
    }
    if let displayID = target.displayID {
      return CGDisplayCreateImage(displayID)
    }
    return nil
  }

  private func handle(
    image: CGImage,
    target: SnapshotTarget,
    force: Bool,
    metadata: [String: Any]?
  ) {
    defer { completeCapture() }
    let now = Date()
    guard let text = recognizeText(in: image), !text.isEmpty else {
      if force {
        screenObserverLogger.notice("Forced capture OCR returned no text")
        let placeholder = "当前画面未识别到清晰文字。"
        let fingerprint = fnv1a(placeholder)
        lastTextFingerprint = fingerprint
        var episode: [String: Any] = [
          "type": "episode",
          "time": ISO8601DateFormatter().string(from: now),
          "app": target.app,
          "bundleId": target.bundleID,
          "fingerprint": String(fingerprint, radix: 16),
          "text": placeholder,
          "forced": true,
        ]
        for (key, value) in metadata ?? [:] { episode[key] = value }
        if target.captureLimited { episode["captureScope"] = "display-fallback" }
        emit(episode)
      }
      return
    }
    if force { screenObserverLogger.info("Forced capture OCR produced \(text.count) characters") }
    let fingerprint = fnv1a(text)
    guard force || fingerprint != lastTextFingerprint else { return }
    lastTextFingerprint = fingerprint
    var episode: [String: Any] = [
      "type": "episode",
      "time": ISO8601DateFormatter().string(from: now),
      "app": target.app,
      "bundleId": target.bundleID,
      "fingerprint": String(fingerprint, radix: 16),
      "text": String(text.prefix(config.maxTextCharacters)),
      "forced": force,
    ]
    for (key, value) in metadata ?? [:] { episode[key] = value }
    if target.captureLimited { episode["captureScope"] = "display-fallback" }
    emit(episode)
  }

  private func recognizeText(in image: CGImage) -> String? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
    do {
      try handler.perform([request])
    } catch {
      emit(["type": "error", "code": "ocr", "message": error.localizedDescription])
      return nil
    }
    let observations = (request.results ?? []).sorted {
      if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 {
        return $0.boundingBox.midY > $1.boundingBox.midY
      }
      return $0.boundingBox.minX < $1.boundingBox.minX
    }
    return observations.compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isSensitiveApplication(bundleID: String, name: String) -> Bool {
    let blocked = [
      "com.1password.1password",
      "com.agilebits.onepassword7",
      "com.bitwarden.desktop",
      "com.apple.keychainaccess",
      "com.apple.Passwords",
      "com.apple.SecurityAgent",
      "com.apple.loginwindow",
      "com.apple.UserNotificationCenter",
      "ai.deepseek.proactive.local",
    ]
    let lowerName = name.lowercased()
    return blocked.contains(bundleID)
      || lowerName.contains("password")
      || lowerName.contains("keychain")
      || lowerName.contains("密码")
  }

  private func fnv1a(_ text: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return hash
  }

  private func emit(_ value: [String: Any]) {
    output(value)
  }
}

private func writeNDJSON(_ value: [String: Any]) {
  guard JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value),
        let line = String(data: data, encoding: .utf8) else { return }
  FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
