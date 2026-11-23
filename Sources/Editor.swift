import AppKit
import QuartzCore
import SwiftUI

struct EditorView: View {
    @ObservedObject var store = PresetStore.shared
    @StateObject private var drag = DragState()  // not @State: CLT builds lack the SwiftUI macro plugin

    var body: some View {
        VStack(spacing: 0) {
            // A plain stack, not a List: List is an NSTableView, which holds every click in a
            // text field for the double-click interval (~0.5 s) before it starts editing.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($store.presets) { $preset in
                        PresetRow(preset: $preset, drag: drag) {
                            store.presets.removeAll { $0.id == preset.id }
                        }
                        .onDrop(of: [.text], delegate: RowDrop(target: preset.id, drag: drag, store: store))
                        if preset.id != store.presets.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
    @ObservedObject var drag: DragState
    var onDelete: () -> Void
    private var invalid: [String] { preset.servers.filter { !isIPAddress($0) } }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .onDrag {
                    drag.start(preset.id)
                    return NSItemProvider(object: preset.id.uuidString as NSString)
                }
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
        .truncationMode(.tail)
        .padding(.vertical, 6)
        .opacity(drag.id == preset.id ? 0.4 : 1)
    }
}

final class DragState: ObservableObject {
    @Published var id: UUID?

    /// Drops outside a row never call performDrop, so also clear once the mouse button is released.
    func start(_ id: UUID) {
        self.id = id
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            t.invalidate()
            if self?.id == id { self?.id = nil }
        }
    }
}

/// Live reorder: the dragged row moves into place as it passes over other rows.
struct RowDrop: DropDelegate {
    let target: UUID
    let drag: DragState
    let store: PresetStore

    func dropEntered(info: DropInfo) {
        guard let d = drag.id, d != target,
              let from = store.presets.firstIndex(where: { $0.id == d }),
              let to = store.presets.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            store.presets.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { drag.id = nil; return true }
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

    /// Test hook: click every text field and print ms from mouse-down to the field taking focus.
    func timeClicks() {
        guard let w = window, let root = w.contentView else { return }
        func fields(_ v: NSView) -> [NSTextField] {
            (v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? [] + v.subviews.flatMap(fields)
        }
        let targets = fields(root).sorted { ($0.convert($0.bounds, to: nil).maxY, $1.convert($1.bounds, to: nil).minX) > ($1.convert($1.bounds, to: nil).maxY, $0.convert($0.bounds, to: nil).minX) }
        var i = 0
        func next() {
            guard i < targets.count else { exit(0) }
            let f = targets[i]; i += 1
            let r = f.convert(f.bounds, to: nil), pt = NSPoint(x: r.midX, y: r.midY)
            let start = CACurrentMediaTime()
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
            }
            func poll() {
                let editor = w.firstResponder as? NSText
                if (editor?.delegate as? NSTextField) === f {
                    print(String(format: "field %d: %.0f ms", i, (CACurrentMediaTime() - start) * 1000)); fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: next)
                } else if CACurrentMediaTime() - start > 3 {
                    print("field \(i): no focus after 3 s"); fflush(stdout); next()
                } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.002, execute: poll) }
            }
            poll()
        }
        next()
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
