import AppKit
import SwiftUI

@main
struct UnzstdApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Settings { EmptyView() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let model = ExtractionModel()
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMenu()
    showWindow()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    showWindow()
    model.open(urls)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model.isBusy else { return .terminateNow }
    model.cancelAll()
    Task {
      while model.isBusy {
        try? await Task.sleep(for: .milliseconds(50))
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    model.cancelAll()
    return true
  }

  private func showWindow() {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 184),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
      )
      window.title = "Unzstd"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: ContentView(model: model))
      window.delegate = self
      window.center()
      self.window = window
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func installMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About Unzstd", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Unzstd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let openItem = fileMenu.addItem(
      withTitle: "Open…", action: #selector(openFiles), keyEquivalent: "o")
    openItem.target = self
    let defaultItem = fileMenu.addItem(
      withTitle: "Use Unzstd for Zstandard Files…", action: #selector(makeDefault),
      keyEquivalent: "")
    defaultItem.target = self
    fileMenu.addItem(.separator())
    fileMenu.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    menu.addItem(fileItem)
    NSApp.mainMenu = menu
  }

  @objc private func openFiles() {
    showWindow()
    model.chooseFiles()
  }

  @objc private func makeDefault() {
    model.makeDefault()
  }
}
