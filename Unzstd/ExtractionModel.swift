import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class ExtractionModel: ObservableObject {
  @Published private(set) var title = "Expand a Zstandard file"
  @Published private(set) var detail = "Drop a .zst or .tar.zst file here, or choose Open."
  @Published private(set) var progress = 0.0
  @Published private(set) var isBusy = false
  @Published private(set) var isCancelling = false
  @Published private(set) var pendingCount = 0
  @Published private(set) var error: String?
  @Published private(set) var lastOutput: URL?

  private var queue: [URL] = []
  private var currentURL: URL?
  private var cancellation: ExtractionCancellation?
  private var outputs: [URL] = []
  private var failures: [String] = []

  static let contentTypes = [
    UTType(importedAs: "org.zstandard.zstd"),
    UTType(importedAs: "org.zstandard.tar-zstd"),
  ]

  func chooseFiles() {
    let panel = NSOpenPanel()
    panel.directoryURL =
      FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    panel.allowedContentTypes = Self.contentTypes
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.prompt = "Expand"
    panel.begin { [weak self] response in
      if response == .OK { self?.open(panel.urls) }
    }
  }

  func open(_ urls: [URL]) {
    guard !isCancelling else { return }
    if !isBusy {
      outputs = []
      failures = []
      lastOutput = nil
      error = nil
    }
    for url in urls {
      guard url.isFileURL, ArchiveExtractor.supports(url) else {
        failures.append("\(url.lastPathComponent): Choose a .zst, .zstd, or .tzst file.")
        continue
      }
      let url = url.standardizedFileURL
      if currentURL != url && !queue.contains(url) { queue.append(url) }
    }
    pendingCount = queue.count
    if !isBusy { startNext() }
  }

  func cancelAll() {
    queue.removeAll()
    pendingCount = 0
    guard isBusy else { return }
    isCancelling = true
    detail = "Cancelling…"
    cancellation?.cancel()
  }

  func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func makeDefault() {
    Task {
      do {
        for type in Self.contentTypes {
          try await NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpen: type)
        }
      } catch {
        let alert = NSAlert(error: error)
        alert.runModal()
      }
    }
  }

  private func startNext() {
    guard !queue.isEmpty else {
      isBusy = false
      currentURL = nil
      cancellation = nil
      if isCancelling {
        title = "Extraction cancelled"
        detail = "The original files have been kept."
        isCancelling = false
      } else if !failures.isEmpty {
        title =
          failures.count == 1
          ? "Couldn’t expand the file" : "\(failures.count) files couldn’t be expanded"
        error = failures.joined(separator: "\n")
      } else if !outputs.isEmpty {
        title = outputs.count == 1 ? "Extraction complete" : "Expanded \(outputs.count) files"
        detail = "Saved beside the original \(outputs.count == 1 ? "file" : "files")."
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
      }
      return
    }

    let source = queue.removeFirst()
    let cancellation = ExtractionCancellation()
    self.cancellation = cancellation
    currentURL = source
    pendingCount = queue.count
    isBusy = true
    progress = 0
    error = nil
    title = "Expanding “\(source.lastPathComponent)”"
    detail = "Preparing…"

    Task {
      do {
        let output = try await Task.detached(priority: .userInitiated) {
          try ArchiveExtractor.extract(source, cancellation: cancellation) { fraction in
            Task { @MainActor in
              guard self.currentURL == source, !self.isCancelling else { return }
              self.progress = fraction
              self.detail = fraction >= 0.99 ? "Finishing…" : "Expanding…"
            }
          }
        }.value
        outputs.append(output)
        lastOutput = output
        progress = 1
      } catch is CancellationError {
        isCancelling = true
      } catch {
        failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
      }
      startNext()
    }
  }
}
