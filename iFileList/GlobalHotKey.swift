import AppKit
import Carbon.HIToolbox

/// A key combination that works system-wide, saved as its virtual key code and modifiers so it
/// doesn't depend on the keyboard layout. `key` is the key's name as recorded, for display.
struct GlobalShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var key: String

    static let defaultShortcut = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: [.control, .option], key: "Space")

    /// The modifiers a shortcut can use; Caps Lock, Fn and the rest are ignored.
    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
        self.key = key
    }

    /// The shortcut for a key press, or nil if it can't be one: it needs ⌘, ⌃ or ⌥ unless the key
    /// is a function key, so typing never triggers it.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        let keyCode = Int(event.keyCode)
        let isFunctionKey = Self.functionKeyNames[keyCode] != nil
        guard isFunctionKey || !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        let name = Self.specialKeyNames[keyCode] ?? Self.functionKeyNames[keyCode]
            ?? event.characters(byApplyingModifiers: [])?.uppercased()
        guard let name, !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers, key: name)
    }

    /// "⌃⌥Space": modifiers in the order menus show them, then the key.
    var displayName: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// The same shortcut as a menu item's key equivalent, or nil for keys menus can't show.
    var menuKeyEquivalent: String? {
        switch Int(keyCode) {
        case kVK_Space: " "
        case kVK_Return: "\r"
        case kVK_Tab: "\t"
        case kVK_Delete: "\u{8}"
        case kVK_ForwardDelete: "\u{7F}"
        case kVK_Escape: "\u{1B}"
        case kVK_LeftArrow: Self.functionKey(NSLeftArrowFunctionKey)
        case kVK_RightArrow: Self.functionKey(NSRightArrowFunctionKey)
        case kVK_UpArrow: Self.functionKey(NSUpArrowFunctionKey)
        case kVK_DownArrow: Self.functionKey(NSDownArrowFunctionKey)
        case kVK_Home: Self.functionKey(NSHomeFunctionKey)
        case kVK_End: Self.functionKey(NSEndFunctionKey)
        case kVK_PageUp: Self.functionKey(NSPageUpFunctionKey)
        case kVK_PageDown: Self.functionKey(NSPageDownFunctionKey)
        default: key.count == 1 ? key.lowercased() : nil
        }
    }

    private static func functionKey(_ key: Int) -> String {
        UnicodeScalar(key).map { String(Character($0)) } ?? ""
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    // MARK: Saving

    init?(dictionary: [String: Any]) {
        guard let keyCode = dictionary["keyCode"] as? Int, let modifiers = dictionary["modifiers"] as? Int,
              let key = dictionary["key"] as? String
        else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)), key: key)
    }

    var dictionary: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue), "key": key]
    }

    // MARK: Key names

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
    ]

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// One system-wide hotkey through Carbon's `RegisterEventHotKey`, which, unlike an event tap,
/// needs no Accessibility permission. Carbon delivers the presses on the main thread.
///
/// The handler holds an unretained reference, so an instance must outlive its registration;
/// `AppModel` keeps its one for the app's lifetime.
@MainActor
final class GlobalHotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Replaces the registered shortcut. Returns false if it couldn't be registered, usually
    /// because another app already uses it.
    @discardableResult
    func register(_ shortcut: GlobalShortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        guard installHandler() else { return false }
        let id = EventHotKeyID(signature: OSType(0x6946_4C53), id: 1)  // 'iFLS'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        return status == noErr
    }
}
