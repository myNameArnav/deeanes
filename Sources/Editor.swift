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
    @ObservedObject var store = PresetStore.shared
    var onDelete: () -> Void

    private var statuses: [(entry: String, status: EntryStatus)] {
        preset.entries.map { ($0, store.status(of: $0, in: preset)) }
    }
    private var hasError: Bool {
        statuses.contains { if case .invalid = $0.status { return true }; if case .failed = $0.status { return true }; return false }
    }
    /// One line per entry that needs explaining; plain IPs speak for themselves.
    private var serversHelp: String {
        let lines = statuses.compactMap { e, s -> String? in
            switch s {
            case .ip: return nil
            case .resolved(let ips): return "\(e) → \(ips.joined(separator: ", "))"
            case .resolving: return "\(e): resolving…"
            case .failed(let why): return "\(e): couldn't resolve (\(why))"
            case .invalid: return "\(e): not an IP address or hostname"
            }
        }
        return lines.isEmpty ? "IP addresses or hostnames, separated by commas or spaces" : lines.joined(separator: "\n")
    }

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
            Field(placeholder: "Name", text: $preset.name)
                .frame(width: 130)
            Field(placeholder: derivedBadge(preset.name), text: Binding(
                get: { preset.badge ?? "" },
                set: { preset.badge = $0.isEmpty ? nil : String($0.prefix(2)) }))
                .frame(width: 44)
                .help("Label shown next to the menu bar icon while this is active")
            Field(placeholder: "1.1.1.1, dns.example.com", text: $preset.serversText, isError: hasError)
                .help(serversHelp)
            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove")
        }
        .padding(.vertical, 6)
        .opacity(drag.id == preset.id ? 0.4 : 1)
    }
}

/// A text field that ends in "…" when idle and scrolls while you edit. SwiftUI's TextField can't:
/// with .truncationMode the cell isn't scrollable, so the caret walks off the right edge and the
/// text never follows it. AppKit cells can't truncate and scroll at once, so switch on focus.
struct Field: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var isError = false

    func makeNSView(context: Context) -> ScrollingTextField {
        let f = ScrollingTextField()
        f.bezelStyle = .roundedBezel
        f.isBezeled = true
        f.usesSingleLineMode = true
        f.cell?.wraps = false
        f.idle()
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: ScrollingTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
        f.textColor = isError ? .systemRed : .labelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: Field
        init(_ parent: Field) { self.parent = parent }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
            // The binding may rewrite the value (the badge keeps 2 characters).
            if f.stringValue != parent.text { f.stringValue = parent.text }
        }
    }
}

final class ScrollingTextField: NSTextField {
    func idle() { cell?.lineBreakMode = .byTruncatingTail; needsDisplay = true }

    override func becomeFirstResponder() -> Bool {
        cell?.isScrollable = true  // must be set before the field editor is set up
        return super.becomeFirstResponder()
    }
    override func textDidEndEditing(_ n: Notification) {
        super.textDidEndEditing(n)
        idle()
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

    private func fields(_ v: NSView) -> [NSTextField] {
        (v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? [] + v.subviews.flatMap(fields)
    }

    /// Test hook: type into the last row's servers field one key at a time, like a person would.
    func type(_ text: String, then done: @escaping () -> Void) {
        guard let w = window, let root = w.contentView,
              let field = fields(root).max(by: { a, b in
                  let ra = a.convert(a.bounds, to: nil), rb = b.convert(b.bounds, to: nil)
                  return (-ra.minY, ra.minX) < (-rb.minY, rb.minX) })  // bottom row, rightmost
        else { return }
        w.makeFirstResponder(field)
        var keys = Array(text)
        func next() {
            guard !keys.isEmpty else { return done() }
            let c = String(keys.removeFirst())
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: next)
        }
        next()
    }

    /// Test hook: focus the longest field, put the caret at the start, press → (real key events)
    /// until the end, and print whether the caret stayed inside the visible part of the field.
    func arrowRight(then done: @escaping () -> Void) {
        guard let w = window, let root = w.contentView,
              let field = fields(root).max(by: { $0.stringValue.count < $1.stringValue.count }) else { return }
        w.makeFirstResponder(field)
        guard let ed = field.currentEditor() as? NSTextView else { return }
        ed.setSelectedRange(NSRange(location: 0, length: 0))
        let cell = field.cell!
        print("cell scrollable:", cell.isScrollable, "wraps:", cell.wraps, "lineBreak:", cell.lineBreakMode.rawValue,
              "| editor horizontallyResizable:", ed.isHorizontallyResizable); fflush(stdout)
        let len = field.stringValue.count
        var hidden = 0, presses = 0
        func next() {
            let loc = ed.selectedRange().location
            if loc > 0, let lm = ed.layoutManager, let tc = ed.textContainer {
                let g = lm.glyphIndexForCharacter(at: loc - 1)
                let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                let x = field.convert(NSPoint(x: r.maxX + ed.textContainerOrigin.x, y: 0), from: ed).x
                if x > field.bounds.maxX - 2 { hidden += 1 }
            }
            guard presses < len + 3 else {
                print("caret at \(ed.selectedRange().location)/\(len), hidden after \(hidden) of \(presses) presses"); fflush(stdout)
                for type in [NSEvent.EventType.keyDown, .keyUp] {  // Tab out: the field should go back to "…"
                    NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: w.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print("after Tab: editing:", field.currentEditor() != nil, "lineBreak:", cell.lineBreakMode.rawValue); fflush(stdout)
                    done()
                }
                return
            }
            presses += 1
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let c = String(UnicodeScalar(NSRightArrowFunctionKey)!)
                NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 124)!, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: next)
        }
        next()
    }

    /// Test hook: click every text field and print ms from mouse-down to the field taking focus.
    func timeClicks() {
        guard let w = window, let root = w.contentView else { return }
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
