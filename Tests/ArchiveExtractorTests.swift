import Foundation
import XCTest
import libzstd

@testable import Unzstd

final class ArchiveExtractorTests: XCTestCase {
  private var directory: URL!
  private let files = FileManager.default

  override func setUpWithError() throws {
    directory = files.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try files.removeItem(at: directory)
  }

  func testPlainFileAndNameCollisions() throws {
    let content = Data("A plain Zstandard file.\n".utf8)
    let source = try compressed(content, named: "notes.txt.zst")
    let existing = directory.appendingPathComponent("notes.txt")
    try Data("keep me".utf8).write(to: existing)
    let first = try extract(source)
    let second = try extract(source)
    XCTAssertEqual(first.lastPathComponent, "notes 2.txt")
    XCTAssertEqual(second.lastPathComponent, "notes 3.txt")
    XCTAssertEqual(try Data(contentsOf: first), content)
    XCTAssertEqual(try Data(contentsOf: second), content)
    XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")
    XCTAssertTrue(files.fileExists(atPath: source.path))
    try assertNoPartialOutput()
  }

  func testEmptyConcatenatedAndHighlyCompressedFrames() throws {
    let empty = try compressed(Data(), named: "empty.zst")
    XCTAssertEqual(try Data(contentsOf: extract(empty)), Data())

    var frames = try compress(Data("first".utf8))
    // A skippable frame between two independent Zstandard frames.
    frames.append(contentsOf: [0x50, 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 1, 2, 3])
    frames.append(try compress(Data("second".utf8)))
    let source = directory.appendingPathComponent("frames.zstd")
    try frames.write(to: source)
    XCTAssertEqual(try Data(contentsOf: extract(source)), Data("firstsecond".utf8))

    let big = Data(repeating: 65, count: 4 * 1024 * 1024)
    let bigSource = try compressed(big, named: "large.ZST")
    XCTAssertEqual(try Data(contentsOf: extract(bigSource)), big)
  }

  func testMaximumWindowSize() throws {
    // A 2 GiB window with two 128 KiB RLE blocks. The known content size keeps
    // allocation small, while exceeding the output buffer forces streaming mode.
    let frame = Data([
      0x28, 0xb5, 0x2f, 0xfd,  // Zstandard magic.
      0x80, 0xa8,  // Four-byte content size; windowLog = 31.
      0x00, 0x00, 0x04, 0x00,  // 256 KiB of decompressed data.
      0x02, 0x00, 0x10, 0x41,  // 128 KiB of A, non-final block.
      0x03, 0x00, 0x10, 0x41,  // 128 KiB of A, final block.
    ])
    let source = directory.appendingPathComponent("large-window.zst")
    try frame.write(to: source)
    XCTAssertEqual(try Data(contentsOf: extract(source)), Data(repeating: 0x41, count: 256 * 1024))
  }

  func testAppBundlePreservesExecutableAndSymlinks() throws {
    let contents = directory.appendingPathComponent(
      "input/Demo.app/Contents/MacOS", isDirectory: true)
    try files.createDirectory(at: contents, withIntermediateDirectories: true)
    let binary = contents.appendingPathComponent("Demo")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    try files.createSymbolicLink(
      atPath: contents.appendingPathComponent("Current").path, withDestinationPath: "Demo")
    let source = try tarFixture(named: "application.tar.zst")
    let result = try extract(source)
    XCTAssertEqual(result.lastPathComponent, "Demo.app")
    XCTAssertTrue(
      files.isExecutableFile(atPath: result.appendingPathComponent("Contents/MacOS/Demo").path))
    XCTAssertEqual(
      try files.destinationOfSymbolicLink(
        atPath: result.appendingPathComponent("Contents/MacOS/Current").path), "Demo")
    try assertNoPartialOutput()
  }

  func testMultipleRootsAndTarAliases() throws {
    let input = directory.appendingPathComponent("input", isDirectory: true)
    try files.createDirectory(at: input, withIntermediateDirectories: true)
    try Data("one".utf8).write(to: input.appendingPathComponent("one.txt"))
    try Data("two".utf8).write(to: input.appendingPathComponent("two\nwith newline.txt"))
    for name in ["bundle.tar.zst", "bundle.tar.zstd", "bundle.tzst"] {
      let result = try extract(tarFixture(named: name))
      XCTAssertEqual(
        try Data(contentsOf: result.appendingPathComponent("one.txt")), Data("one".utf8))
      XCTAssertEqual(
        try Data(contentsOf: result.appendingPathComponent("two\nwith newline.txt")),
        Data("two".utf8))
    }
  }

  func testCorruptAndTruncatedInputsLeaveNoOutput() throws {
    let source = directory.appendingPathComponent("broken.zst")
    let valid = try compress(Data(repeating: 42, count: 500_000))
    for data in [Data(), Data("not zstd".utf8), Data(valid.dropLast()), valid + Data([0xff])] {
      try data.write(to: source)
      XCTAssertThrowsError(try extract(source))
      XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent("broken").path))
      try assertNoPartialOutput()
    }
    let invalidTar = try compressed(Data("not a tar".utf8), named: "broken.tar.zst")
    XCTAssertThrowsError(try extract(invalidTar))
    try assertNoPartialOutput()
  }

  func testTarWithLargeRecordPadding() throws {
    let content = Data("padded tar".utf8)
    let tar =
      tarEntry(name: "padded.txt", data: content) + Data(repeating: 0, count: 4 * 1024 * 1024)
    let source = try compressed(tar, named: "padded.tar.zst")
    XCTAssertEqual(try Data(contentsOf: extract(source)), content)

    // Even after tar closes its input, invalid trailing Zstandard data must fail.
    let damaged = directory.appendingPathComponent("damaged.tar.zst")
    try (Data(contentsOf: source) + Data([0xff])).write(to: damaged)
    XCTAssertThrowsError(try extract(damaged))
    try assertNoPartialOutput()
  }

  func testTraversalAndSymlinkEscapesAreRejected() throws {
    let outside = directory.appendingPathComponent("outside", isDirectory: true)
    try files.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("original".utf8).write(to: sentinel)

    // payload lives two levels beneath directory; this must never overwrite sentinel.
    let traversal = tarEntry(name: "../../outside/sentinel", data: Data("overwrite".utf8))
    let symlink =
      tarEntry(name: "escape", type: 50, link: outside.path)
      + tarEntry(name: "escape/sentinel", data: Data("overwrite".utf8))
    let hardlink =
      tarEntry(name: "hardlink", type: 49, link: "../../outside/sentinel")
      + tarEntry(name: "hardlink", data: Data("overwrite".utf8))
    for (index, archive) in [traversal, symlink, hardlink].enumerated() {
      let source = try compressed(
        archive + Data(repeating: 0, count: 1024), named: "unsafe\(index).tar.zst")
      XCTAssertThrowsError(try extract(source))
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
      try assertNoPartialOutput()
    }
  }

  func testCancellationCleansUpPlainAndTarOutput() throws {
    var generator: UInt64 = 123
    let noisy = Data(
      (0..<(2 * 1024 * 1024)).map { _ -> UInt8 in
        generator = generator &* 6_364_136_223_846_793_005 &+ 1
        return UInt8(truncatingIfNeeded: generator >> 32)
      })
    let tar = tarEntry(name: "large.bin", data: noisy) + Data(repeating: 0, count: 1024)
    for (name, data) in [("cancel.zst", noisy), ("cancel.tar.zst", tar)] {
      let source = try compressed(data, named: name)
      let token = ExtractionCancellation()
      XCTAssertThrowsError(
        try ArchiveExtractor.extract(source, cancellation: token) { _ in token.cancel() }
      ) {
        XCTAssertTrue($0 is CancellationError)
      }
      XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent("cancel").path))
      XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent("large.bin").path))
      try assertNoPartialOutput()
    }
  }

  func testQuarantineIsInherited() throws {
    var source = try compressed(Data("download".utf8), named: "download.zst")
    var values = URLResourceValues()
    values.quarantineProperties = [
      "LSQuarantineAgentName": "Unzstd Tests",
      "LSQuarantineType": "LSQuarantineTypeOtherDownload",
      "LSQuarantineTimeStamp": Date(),
    ]
    try source.setResourceValues(values)
    let result = try extract(source)
    XCTAssertNotNil(
      try result.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
  }

  private func extract(_ source: URL) throws -> URL {
    try ArchiveExtractor.extract(source, cancellation: ExtractionCancellation()) { _ in }
  }

  private func compressed(_ data: Data, named name: String) throws -> URL {
    let source = directory.appendingPathComponent(name)
    try compress(data).write(to: source)
    return source
  }

  private func compress(_ data: Data) throws -> Data {
    var output = Data(count: ZSTD_compressBound(data.count))
    let size = output.count
    let count = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        ZSTD_compress(destination.baseAddress, size, source.baseAddress, data.count, 1)
      }
    }
    guard ZSTD_isError(count) == 0 else {
      throw ExtractionError.message("Fixture compression failed")
    }
    output.count = count
    return output
  }

  private func tarFixture(named name: String) throws -> URL {
    let tarURL = directory.appendingPathComponent("fixture.tar")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = [
      "-cf", tarURL.path, "-C", directory.appendingPathComponent("input").path, ".",
    ]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return try compressed(Data(contentsOf: tarURL), named: name)
  }

  private func assertNoPartialOutput(file: StaticString = #filePath, line: UInt = #line) throws {
    let names = try files.contentsOfDirectory(atPath: directory.path)
    XCTAssertFalse(names.contains { $0.hasPrefix(".unzstd-") }, file: file, line: line)
  }

  /// Minimal ustar fixtures let us test paths tar itself refuses to create.
  private func tarEntry(name: String, type: UInt8 = 48, link: String = "", data: Data = Data())
    -> Data
  {
    var header = Data(repeating: 0, count: 512)
    func field(_ string: String, at offset: Int) {
      let bytes = Array(string.utf8)
      header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
    field(name, at: 0)
    field("0000644", at: 100)
    field("0000000", at: 108)
    field("0000000", at: 116)
    field(String(format: "%011o", data.count), at: 124)
    field("00000000000", at: 136)
    field("        ", at: 148)
    header[156] = type
    field(link, at: 157)
    field("ustar", at: 257)
    field("00", at: 263)
    field(String(format: "%06o\0 ", header.reduce(0) { $0 + Int($1) }), at: 148)
    return header + data + Data(repeating: 0, count: (512 - data.count % 512) % 512)
  }
}
