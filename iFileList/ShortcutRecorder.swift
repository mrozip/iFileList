import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records the global search shortcut: click, then press the keys. Escape cancels and Delete
/// removes the shortcut. The current shortcut is switched off meanwhile, so pressing it again
/// records it instead of hiding the app.
struct ShortcutRecorder: View {
    @Bindable var model: AppModel
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Type Shortcut…" : model.globalShortcut?.displayName ?? "None")
                    .frame(minWidth: 100)
            }
            if model.globalShortcut != nil && !isRecording {
                Button {
                    model.globalShortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove the shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
        // Closing Settings keeps its panes alive, so they don't disappear.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if isRecording { stopRecording() }
        }
    }

    private func startRecording() {
        isRecording = true
        model.suspendsGlobalShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        model.suspendsGlobalShortcut = false
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(GlobalShortcut.relevantModifiers)
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            stopRecording()
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            model.globalShortcut = nil
            stopRecording()
        default:
            // Keys without ⌘, ⌃ or ⌥ would trigger while typing; keep waiting for a usable one.
            guard let shortcut = GlobalShortcut(event: event) else {
                NSSound.beep()
                return
            }
            model.globalShortcut = shortcut
            stopRecording()
        }
    }
}
