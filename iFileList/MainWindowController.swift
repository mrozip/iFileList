import AppKit
import SwiftUI

/// The main window: `ContentView` in an AppKit window, with its toolbar and search field bridged
/// from SwiftUI. Handles the menu bar's commands that need the window but not the list.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let identifier = NSUserInterfaceItemIdentifier("main")

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let content = NSHostingController(rootView: ContentView(model: model).frame(minWidth: 600, minHeight: 300))
        content.sceneBridgingOptions = [.toolbars, .title]
        content.sizingOptions = .minSize

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.contentViewController = content
        window.title = "iFileList"
        window.identifier = Self.identifier
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        // The frame SwiftUI saved under the same name before.
        window.setFrameAutosaveName("main")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        model.windowDidDisappear()
    }

    // MARK: Menu bar

    @objc func newFolder(_ sender: Any?) {
        model.newFolder()
    }

    @objc func findFiles(_ sender: Any?) {
        model.focusSearch()
    }

    @objc func filterByFolder(_ sender: Any?) {
        model.showsFolderPicker = true
    }

    @objc func clearFilters(_ sender: Any?) {
        model.clearFilters()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newFolder(_:)): model.hasTargetFolder
        case #selector(findFiles(_:)), #selector(filterByFolder(_:)): !model.showsAccessOnboarding
        case #selector(clearFilters(_:)): model.hasFilters
        default: true
        }
    }
}
