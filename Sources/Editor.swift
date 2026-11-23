import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var store = PresetStore.shared

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach($store.presets) { $preset in
                    PresetRow(preset: $preset) {
                        store.presets.removeAll { $0.id == preset.id }
                    }
                }
                .onMove { store.presets.move(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            HStack {
                Button {
                    store.presets.append(Preset(name: "", servers: []))
                } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Button("Restore Defaults") {
                    let a = NSAlert()
                    a.messageText = "Replace your list with the default servers?"
                    a.addButton(withTitle: "Restore")
                    a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { store.restoreDefaults() }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 580, minHeight: 320)
    }
}

struct PresetRow: View {
    @Binding var preset: Preset
    var onDelete: () -> Void
    private var invalid: [String] { preset.servers.filter { !isIPAddress($0) } }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            TextField("Name", text: $preset.name)
                .frame(width: 130)
            TextField(derivedBadge(preset.name), text: Binding(
                get: { preset.badge ?? "" },
                set: { preset.badge = $0.isEmpty ? nil : String($0.prefix(2)) }))
                .frame(width: 44)
                .help("Label shown next to the menu bar icon while this is active")
            TextField("1.1.1.1, 2606:4700:4700::1111", text: $preset.serversText)
                .foregroundStyle(invalid.isEmpty ? Color.primary : Color.red)
                .help(invalid.isEmpty ? "Separate addresses with commas or spaces"
                                      : "Not an IP address: \(invalid.joined(separator: ", "))")
            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove")
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 2)
    }
}

final class EditorWindow {
    static let shared = EditorWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "DNS Servers"
            w.contentView = NSHostingView(rootView: EditorView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Test hook: screenshot the real window, as the window server draws it.
    func snapshot(to path: String) {
        guard let w = window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(w.windowNumber)", path]
        try? p.run()
        p.waitUntilExit()
    }
}
