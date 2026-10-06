import Foundation
import libzstd

/// Cancellation also stops tar, unblocking the decoder if it is writing to a full pipe.
final class ExtractionCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var process: Process?

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    if let process, process.isRunning { process.terminate() }
  }

  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }

  func run(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
    try process.run()
    self.process = process
  }

  func clearProcess() {
    lock.lock()
    defer { lock.unlock() }
    process = nil
  }
}

enum ExtractionError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}

enum ArchiveExtractor {
  static func supports(_ url: URL) -> Bool {
    ["zst", "zstd", "tzst"].contains(url.pathExtension.lowercased())
  }

  static func extract(
    _ source: URL,
    cancellation: ExtractionCancellation,
    progress: @Sendable (Double) -> Void
  ) throws -> URL {
    try cancellation.check()
    let files = FileManager.default
    let values = try source.resourceValues(forKeys: [
      .isRegularFileKey, .fileSizeKey, .quarantinePropertiesKey,
    ])
    guard supports(source), values.isRegularFile == true else {
      throw ExtractionError.message("Choose a Zstandard-compressed file.")
    }
    let parent = source.deletingLastPathComponent()
    var template = Array(parent.appendingPathComponent(".unzstd-XXXXXX").path.utf8CString)
    guard let directory = mkdtemp(&template) else { throw posixError() }
    let staging = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    defer { try? files.removeItem(at: staging) }

    let name = source.lastPathComponent.lowercased()
    let isTar = name.hasSuffix(".tar.zst") || name.hasSuffix(".tar.zstd") || name.hasSuffix(".tzst")
    let payload = staging.appendingPathComponent("payload", isDirectory: isTar)
    if isTar {
      try files.createDirectory(at: payload, withIntermediateDirectories: false)
      try extractTar(
        source, to: payload, staging: staging, size: values.fileSize ?? 0,
        cancellation: cancellation, progress: progress)
    } else {
      guard files.createFile(atPath: payload.path, contents: nil) else { throw posixError() }
      let output = try FileHandle(forWritingTo: payload)
      defer { try? output.close() }
      try decompress(
        source, to: output, size: values.fileSize ?? 0,
        cancellation: cancellation, progress: progress)
    }
    try cancellation.check()

    var item = payload
    var outputName = source.deletingPathExtension().lastPathComponent
    if isTar {
      if name.hasSuffix(".tzst") {
        outputName = source.deletingPathExtension().lastPathComponent
      } else {
        outputName = source.deletingPathExtension().deletingPathExtension().lastPathComponent
      }
      let children = try files.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
      if children.count == 1 {
        item = children[0]
        outputName = item.lastPathComponent
      }
    }
    if outputName.isEmpty || outputName == "." || outputName == ".." {
      outputName = "Expanded Archive"
    }
    try propagateQuarantine(values.quarantineProperties, to: item, cancellation: cancellation)
    try cancellation.check()
    let result = try moveWithoutOverwriting(item, to: parent.appendingPathComponent(outputName))
    progress(1)
    return result
  }

  private static func decompress(
    _ source: URL, to output: FileHandle, size: Int,
    allowsEarlyPipeClose: Bool = false,
    cancellation: ExtractionCancellation, progress: @Sendable (Double) -> Void
  ) throws {
    guard let stream = ZSTD_createDStream() else {
      throw ExtractionError.message("There isn’t enough memory to expand this file.")
    }
    defer { ZSTD_freeDStream(stream) }
    try checkZstd(ZSTD_initDStream(stream))
    let windowBounds = ZSTD_dParam_getBounds(ZSTD_d_windowLogMax)
    try checkZstd(windowBounds.error)
    try checkZstd(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, windowBounds.upperBound))
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let capacity = ZSTD_DStreamOutSize()
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
    defer { buffer.deallocate() }
    var consumed = 0
    var remaining = 1
    var lastUpdate = Date.distantPast
    var outputIsOpen = true

    while let data = try input.read(upToCount: ZSTD_DStreamInSize()), !data.isEmpty {
      try cancellation.check()
      try data.withUnsafeBytes { bytes in
        var sourceBuffer = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
        // A full output buffer may need draining even after all input has been consumed.
        var needsDrain = true
        while sourceBuffer.pos < sourceBuffer.size || needsDrain {
          try cancellation.check()
          var destination = ZSTD_outBuffer(dst: buffer, size: capacity, pos: 0)
          remaining = ZSTD_decompressStream(stream, &destination, &sourceBuffer)
          try checkZstd(remaining)
          if destination.pos > 0, outputIsOpen {
            do {
              try output.write(
                contentsOf: Data(bytesNoCopy: buffer, count: destination.pos, deallocator: .none))
            } catch let error as NSError {
              let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
              guard allowsEarlyPipeClose, underlying.domain == NSPOSIXErrorDomain,
                underlying.code == Int(EPIPE)
              else { throw error }
              // tar can finish before record padding ends. Still decode the rest
              // to verify every Zstandard frame and checksum before publishing.
              outputIsOpen = false
            }
          }
          needsDrain = destination.pos == capacity && remaining != 0
          if Date().timeIntervalSince(lastUpdate) >= 0.05 {
            progress(min(0.99, Double(consumed + sourceBuffer.pos) / Double(max(size, 1))))
            lastUpdate = Date()
          }
        }
      }
      consumed += data.count
    }
    try cancellation.check()
    guard consumed > 0, remaining == 0 else {
      throw ExtractionError.message("The file is incomplete or isn’t a valid Zstandard file.")
    }
    progress(0.99)
  }

  private static func extractTar(
    _ source: URL, to destination: URL, staging: URL, size: Int,
    cancellation: ExtractionCancellation, progress: @Sendable (Double) -> Void
  ) throws {
    let pipe = Pipe()
    guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw posixError()
    }
    let errorURL = staging.appendingPathComponent("tar-errors")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let errors = try FileHandle(forWritingTo: errorURL)
    defer { try? errors.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    // bsdtar's default path and symlink checks stay enabled (never pass -P).
    // It also preserves executable bits and macOS metadata in application bundles.
    process.arguments = [
      "-x", "-f", "-", "-C", destination.path, "--no-same-owner", "--no-same-permissions",
    ]
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try cancellation.run(process)
    defer { cancellation.clearProcess() }
    try pipe.fileHandleForReading.close()

    var decodingError: Error?
    do {
      try decompress(
        source, to: pipe.fileHandleForWriting, size: size,
        allowsEarlyPipeClose: true,
        cancellation: cancellation, progress: progress)
    } catch {
      decodingError = error
      if process.isRunning { process.terminate() }
    }
    try? pipe.fileHandleForWriting.close()
    process.waitUntilExit()
    try cancellation.check()
    let diagnostics = try FileHandle(forReadingFrom: errorURL)
    defer { try? diagnostics.close() }
    let message = String(decoding: try diagnostics.read(upToCount: 4096) ?? Data(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let decodingError {
      if !message.isEmpty { throw ExtractionError.message(message) }
      throw decodingError
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw ExtractionError.message(
        message.isEmpty ? "The tar archive couldn’t be expanded." : message)
    }
  }

  private static func propagateQuarantine(
    _ quarantine: [String: Any]?, to root: URL, cancellation: ExtractionCancellation
  ) throws {
    guard let quarantine, !quarantine.isEmpty else { return }
    func apply(to url: URL) throws {
      try cancellation.check()
      guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        return
      }
      var url = url
      var values = URLResourceValues()
      values.quarantineProperties = quarantine
      try url.setResourceValues(values)
    }
    try apply(to: root)
    if let children = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
    {
      for case let child as URL in children { try apply(to: child) }
    }
  }

  private static func moveWithoutOverwriting(_ source: URL, to proposed: URL) throws -> URL {
    var suffix = 1
    while true {
      let candidate: URL
      if suffix == 1 {
        candidate = proposed
      } else {
        let ext = proposed.pathExtension
        let stem =
          ext.isEmpty
          ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
        candidate = proposed.deletingLastPathComponent()
          .appendingPathComponent("\(stem) \(suffix)\(ext.isEmpty ? "" : ".\(ext)")")
      }
      // Atomic and exclusive: another extraction or Finder can create a name at any time.
      if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
      guard errno == EEXIST else { throw posixError() }
      suffix += 1
    }
  }

  private static func checkZstd(_ result: Int) throws {
    if ZSTD_isError(result) != 0 {
      throw ExtractionError.message("Zstandard: \(String(cString: ZSTD_getErrorName(result)))")
    }
  }

  private static func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}
