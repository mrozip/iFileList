import SwiftUI

/// The About window: app name, version, project link and copyright, nothing else.
struct AboutView: View {
    static let windowID = "about"
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
        .background(ZoomButtonDisabler())
    }
}

/// Disables the window's zoom button, which SwiftUI leaves on even for fixed-size windows.
private struct ZoomButtonDisabler: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}

/// The "About iFileList" menu item, opening `AboutView` instead of the standard panel.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About iFileList") { openWindow(id: AboutView.windowID) }
    }
}
