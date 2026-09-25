import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key plus modifiers, as recorded in Settings.
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt
    /// How the key itself reads, e.g. "Space" or "K".
    var key: String

    static let standard = HotKeyShortcut(keyCode: UInt32(kVK_Space),
                                         modifiers: NSEvent.ModifierFlags.option.rawValue,
                                         key: "Space")

    private var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// nil when the key can't be a global shortcut: it needs ⌘, ⌥ or ⌃, unless it's a function key.
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.functionKeys[code] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let key = Self.functionKeys[code] ?? Self.namedKeys[code]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
        guard let key, !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: flags.rawValue, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// The system-wide shortcut that shows and hides the panel. Carbon hot keys work from any app
/// without the Accessibility permission a global key monitor would need.
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    @Published private(set) var shortcut: HotKeyShortcut?
    /// The system refused the shortcut, usually because another app holds it.
    @Published private(set) var registrationFailed = false
    var onPress: () -> Void = {}

    private let storageKey = "globalHotKey"
    private var hotKeyRef: EventHotKeyRef?
    private var isHandlerInstalled = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            shortcut = (try? JSONDecoder().decode(HotKeyShortcut?.self, from: data)) ?? nil
        } else {
            shortcut = .standard
        }
    }

    func start() {
        installHandler()
        register()
    }

    /// nil turns the shortcut off.
    func set(_ newShortcut: HotKeyShortcut?) {
        shortcut = newShortcut
        if let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        register()
    }

    /// While a new shortcut is being recorded, the current one must not fire.
    func suspend() {
        unregister()
    }

    func resume() {
        register()
    }

    private func register() {
        unregister()
        registrationFailed = false
        guard let shortcut else { return }
        let id = EventHotKeyID(signature: OSType(0x5744_4B31), id: 1)  // "WDK1"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            registrationFailed = true
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandler() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyCenter.shared.onPress() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A button that shows the global shortcut, and records a new one when clicked.
struct ShortcutRecorder: View {
    @ObservedObject private var center = HotKeyCenter.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording ? "Type a shortcut…" : center.shortcut?.display ?? "Not Set")
                        .monospacedDigit()
                        .frame(minWidth: 120)
                }
                if center.shortcut != nil, !isRecording {
                    Button {
                        center.set(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Shortcut")
                }
            }
            if center.registrationFailed {
                Text("Another app is using this shortcut.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        center.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
            } else if let shortcut = HotKeyShortcut(event: event) {
                center.set(shortcut)
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        center.resume()
    }
}
