import AppKit
import SwiftUI

/// The About window: app name, version, project link and copyright, nothing else.
struct AboutView: View {
    static let projectURL = URL(string: "https://github.com/mrozip/iFileList")!

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "iFileList"
    }

    /// "Version 0.1 (1)", like the standard About panel: the marketing version, then the build.
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? "Version \(short)" : "Version \(short) (\(build))"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.bottom, 6)
            Text(appName)
                .font(.title3.bold())
            Text(version)
                .foregroundStyle(.secondary)
            Link(Self.projectURL.absoluteString, destination: Self.projectURL)
            Text(copyright)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 48)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }
}

/// Hosts `AboutView` in a fixed-size window without a title bar, left out of the Window menu.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let content = NSHostingController(rootView: AboutView())
        content.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "About iFileList"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
