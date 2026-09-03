import Foundation

private let observer = ScreenObserver(config: .parse())
Task {
  do {
    try await observer.start()
  } catch {
    let payload: [String: Any] = ["type": "error", "code": "startup", "message": error.localizedDescription]
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(1)
  }
}
dispatchMain()
