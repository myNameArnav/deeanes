import AppKit
import Combine
import ServiceManagement
import SystemConfiguration

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // variableLength sizes the item to its icon (+ badge) plus standard padding.
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let env = ProcessInfo.processInfo.environment

    /// Menu items that show a latency, with the servers they probe.
    var probed: [(item: NSMenuItem, name: String, servers: [String])] = []
    /// Recent checks per server list: (time, ms), ms = -1 when nothing answered. In memory only.
    var samples: [[String]: [(at: Date, ms: Double)]] = [:]
    static let window: TimeInterval = 30  // seconds of samples used for jitter and loss
    /// Server list DNS is set to right now (as its preset lists it, so it shares samples with its menu row).
    var activeServers: [String] = []
    /// Menu bar icon before any loss tint.
    var icon = NSImage()
    /// Menu bar tooltip without the loss note.
    var baseTip = ""
    /// While the menu is closed, the active servers alone are checked this often, so the icon can
    /// turn red on packet loss. One UDP query, so it costs next to nothing.
    static let backgroundEvery: TimeInterval = 5
    var backgroundTimer: Timer?
    /// Whether each server list blocks ads, checked once per menu open and remembered across
    /// launches so the menu can size itself for the tags it will show.
    var adBlock: [[String]: Bool] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: "adBlock") as? [String: Bool] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.map { (parseServers($0.key), $0.value) })
        }
        set {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.joined(separator: ","), $0.value) }),
                                      forKey: "adBlock")
        }
    }
    /// Encrypted protocols macOS uses for each server list via DDR (e.g. ["DoH", "DoT"]; empty = plain),
    /// checked once per menu open and remembered across launches, like `adBlock`.
    var encryption: [[String]: [String]] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: "encryption") as? [String: [String]] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.map { (parseServers($0.key), $0.value) })
        }
        set {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.joined(separator: ","), $0.value) }),
                                      forKey: "encryption")
        }
    }
    var interceptItem: NSMenuItem?
    var tabStop: CGFloat = 200

    var pollTimer: Timer?
    var inFlight = 0
    var watcher: SCDynamicStore?
    var presetSub: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        let img = NSImage(systemSymbolName: "network", accessibilityDescription: "DNS")
        img?.isTemplate = true
        item.button?.image = img
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        watchDNS()
        presetSub = PresetStore.shared.$presets.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateBadge() }
        updateBadge()
        let t = Timer(timeInterval: Self.backgroundEvery, repeats: true) { [weak self] _ in self?.checkActive() }
        RunLoop.main.add(t, forMode: .common)
        backgroundTimer = t
        checkActive()
        runTestHooks()
    }

    // MARK: Menu bar badge

    /// Re-reads DNS whenever macOS's network configuration changes, so the badge follows
    /// changes made anywhere (System Settings, networksetup, this app).
    func watchDNS() {
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        watcher = SCDynamicStoreCreate(nil, "deeanes-watch" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().updateBadge()
        }, &ctx)
        guard let watcher else { return }
        SCDynamicStoreSetNotificationKeys(watcher, nil,
            ["Setup:/Network/Service/.*/DNS", "State:/Network/Global/IPv4"] as CFArray)
        SCDynamicStoreSetDispatchQueue(watcher, .main)
    }

    func updateBadge() {
        let current = DNS.primary().map(DNS.configured(for:)) ?? []
        let match = current.isEmpty ? nil
            : PresetStore.shared.presets.first { $0.isValid && Set($0.servers) == Set(current) }
        let text = match?.shortName ?? ""
        icon = Icon.make(badge: text)
        if env["DEEANES_LOG_BADGE"] != nil { print("badge:", text.isEmpty ? "(none)" : text); fflush(stdout) }
        baseTip = match.map { "DNS: \($0.name)" } ?? (current.isEmpty ? "DNS: Automatic" : "DNS: \(current.joined(separator: ", "))")
        let active = match?.servers ?? (current.isEmpty ? DNS.primary().map(DNS.automatic(for:)) ?? [] : current)
        activeServers = env["DEEANES_ACTIVE_SERVERS"].map(parseServers) ?? active
        updateHealth()
    }

    /// Tints the icon red while the active servers dropped any check in the last `window` seconds.
    func updateHealth() {
        let now = Date()
        let recent = (samples[activeServers] ?? []).filter { now.timeIntervalSince($0.at) < Self.window }
        let lost = recent.filter { $0.ms < 0 }.count
        item.button?.image = lost > 0 ? Icon.tinted(icon, .systemRed) : icon
        item.button?.toolTip = lost == 0 ? baseTip
            : baseTip + "\n\(Int((Double(lost) / Double(recent.count) * 100).rounded()))% packet loss in the last \(Int(Self.window)) s"
        if env["DEEANES_LOG_BADGE"] != nil { print("loss:", lost, "/", recent.count); fflush(stdout) }
    }

    /// Background check of the active servers; the menu's own 1 s polling covers them while it's open.
    func checkActive() {
        let servers = activeServers
        guard pollTimer == nil, !servers.isEmpty else { updateHealth(); return }
        DispatchQueue.global(qos: .utility).async {
            let ms = Probe.first(servers)?.ms
            RunLoop.main.perform(inModes: [.common]) {
                self.record(servers, ms)
                self.updateHealth()
            }
        }
    }

    /// Adds a check result (nil = nothing answered) and drops samples older than `window`.
    @discardableResult
    func record(_ servers: [String], _ ms: Double?) -> [(at: Date, ms: Double)] {
        let now = Date()
        var list = (samples[servers] ?? []).filter { now.timeIntervalSince($0.at) < Self.window }
        list.append((now, ms ?? -1))
        samples[servers] = list
        return list
    }

    // MARK: Menu lifecycle

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    /// While the menu is open, re-check latency every second so it reads live.
    func menuWillOpen(_ menu: NSMenu) {
        measure(full: true)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.inFlight == 0 else { return }  // skip a tick if the last one is still out
            self.measure(full: false)
        }
        RunLoop.main.add(t, forMode: .common)  // .common keeps it firing during menu tracking
        pollTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func rebuild() {
        menu.removeAllItems()
        probed = []
        let primary = DNS.primary()
        let current = primary.map(DNS.configured(for:)) ?? []
        let effective = DNS.effective()
        let presets = PresetStore.shared.presets

        // Fixed tab stop wide enough for the longest name, so values arriving don't resize the menu.
        // Rows only reserve room for the lock and shield if they have them or haven't been checked yet.
        let font = NSFont.menuFont(ofSize: 0)
        let known = adBlock, knownEnc = encryption
        let dhcpServers = primary.map(DNS.automatic(for:)) ?? []
        let rows = [("Automatic", dhcpServers)] + presets.map { ($0.name, $0.servers) }
        let widest = rows.map { name, servers in
            (name as NSString).size(withAttributes: [.font: font]).width
                + (knownEnc[servers]?.isEmpty == true ? 0 : lockTag.size().width)
                + (known[servers] == false ? 0 : adTag.size().width)
        }.max() ?? 100
        // Latency is right-aligned, so the stop sits after the widest name + a gap + the widest value.
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let w = { (t: String) in ceil((t as NSString).size(withAttributes: [.font: digits]).width) }
        tabStop = ceil(widest) + 20 + w("999 ms")
        jitterColumn = 14 + w("50% loss")

        // Keep the header short so it never sets the menu width: preset name, or first address + count.
        let match = current.isEmpty ? nil : presets.first { $0.isValid && Set($0.servers) == Set(current) }
        let summary = current.isEmpty ? "Automatic"
            : match?.name ?? (current[0] + (current.count > 1 ? " +\(current.count - 1)" : ""))
        let header = info("\(primary?.name ?? "Network"): \(summary)")
        header.toolTip = current.isEmpty ? nil : current.joined(separator: "\n")
        menu.addItem(header)
        if !effective.isEmpty && effective != current {
            // Show one address (named when it's Tailscale); the full list is in the tooltip.
            let who = effective.first == "100.100.100.100" ? "Tailscale" : effective[0]
            let it = info("In use: \(who)")
            it.toolTip = "Another app (usually a VPN) is answering DNS queries:\n" + effective.joined(separator: "\n")
            menu.addItem(it)
        }
        // Only shown when something is actually intercepting DNS.
        let ic = info("")
        ic.attributedTitle = NSAttributedString(string: "Network is intercepting DNS", attributes: [
            .font: font, .foregroundColor: NSColor.systemRed])
        ic.toolTip = "A query to an address that can't be a DNS server (192.0.2.1) got an answer, "
            + "so your network or ISP is answering DNS itself and may ignore the servers you pick."
        ic.isHidden = true
        interceptItem = ic
        menu.addItem(ic)
        menu.addItem(.separator())

        let dhcp = primary.map(DNS.automatic(for:)) ?? []
        let auto = presetItem("Automatic", servers: [], probe: dhcp)
        auto.toolTip = dhcp.isEmpty ? "Use the servers your router hands out (DHCP)"
                                    : notes(dhcp) + "Servers your router hands out (DHCP):\n" + dhcp.joined(separator: "\n")
        auto.state = current.isEmpty ? .on : .off
        menu.addItem(auto)

        for p in presets {
            let it = presetItem(p.name.isEmpty ? "Untitled" : p.name, servers: p.servers, probe: p.isValid ? p.servers : [])
            it.isEnabled = p.isValid
            it.toolTip = !p.isValid ? "Fix this entry in Edit Servers…" : notes(p.servers) + p.servers.joined(separator: "\n")
            it.state = p.isValid && Set(p.servers) == Set(current) ? .on : .off
            menu.addItem(it)
        }

        refreshTitles()

        menu.addItem(.separator())
        menu.addItem(action("Edit Servers…", #selector(editServers)))
        let login = action("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Quit", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    func info(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func action(_ title: String, _ sel: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    func presetItem(_ name: String, servers: [String], probe: [String]) -> NSMenuItem {
        let it = action(name, #selector(choose(_:)))
        it.representedObject = servers
        if !probe.isEmpty { probed.append((it, name, probe)) }
        return it
    }

    /// Tooltip lines for what a server list does beyond plain DNS.
    func notes(_ servers: [String]) -> String {
        var lines: [String] = []
        if let enc = encryption[servers], !enc.isEmpty {
            lines.append("Encrypted: macOS upgrades it to \(enc.joined(separator: " and ")) automatically")
        }
        if adBlock[servers] == true { lines.append("Blocks ads") }
        return lines.map { $0 + "\n" }.joined()
    }

    // MARK: Rows

    /// " [lock]" after names of servers macOS talks to over encrypted DNS.
    lazy var lockTag = symbolTag("lock.fill", "Encrypted")
    /// " [shield]" after names of servers that block ads.
    lazy var adTag = symbolTag("shield.fill", "Blocks ads")

    func symbolTag(_ symbol: String, _ label: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let cfg = NSImage.SymbolConfiguration(pointSize: font.pointSize - 2, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        let s = NSMutableAttributedString(string: " ", attributes: [.font: font])
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(cfg) {
            let att = NSTextAttachment()
            att.image = img
            att.bounds = NSRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
            s.append(NSAttributedString(attachment: att))
        }
        return s
    }
    var jitterColumn: CGFloat = 64

    func refreshTitles() {
        for e in probed {
            e.item.attributedTitle = title(e.name, samples[e.servers] ?? [], servers: e.servers)
        }
    }

    /// Name [lock] [shield] | 40 ms | ±3 ms (or "8% loss" when checks went unanswered) — fixed tab stops,
    /// so values updating never resize the menu.
    func title(_ name: String, _ recent: [(at: Date, ms: Double)], servers: [String]) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: tabStop),
                         NSTextTab(textAlignment: .right, location: tabStop + jitterColumn)]
        let font = NSFont.menuFont(ofSize: 0)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let s = NSMutableAttributedString(string: name, attributes: [.font: font])
        if encryption[servers]?.isEmpty == false { s.append(lockTag) }
        if adBlock[servers] == true { s.append(adTag) }
        func col(_ text: String, _ color: NSColor) {
            s.append(NSAttributedString(string: "\t" + text, attributes: [.font: digits, .foregroundColor: color]))
        }

        let latest = recent.last?.ms
        switch latest {
        case nil: col("…", .tertiaryLabelColor)
        case let ms? where ms < 0: col("Offline", .systemRed)
        case let ms?: col("\(Int(ms.rounded())) ms", .secondaryLabelColor)
        }

        // Jitter: average change between consecutive answers. Loss: share of checks with no answer.
        let ok = recent.map(\.ms).filter { $0 >= 0 }
        let jitter = ok.count >= 3
            ? zip(ok, ok.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(ok.count - 1) : nil
        // Loss matters more than jitter, so it takes the column when present.
        let lost = recent.count - ok.count
        if lost > 0 {
            col("\(Int((Double(lost) / Double(recent.count) * 100).rounded()))% loss", .systemRed)
        } else {
            col(jitter.map { "±\(Int($0.rounded())) ms" } ?? "", .tertiaryLabelColor)
        }

        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        return s
    }

    // MARK: Measuring

    /// Probes every listed server set in parallel. `full` also checks ad blocking and
    /// interception, which don't change second to second, so those run once per open.
    func measure(full: Bool, done: (() -> Void)? = nil) {
        let group = DispatchGroup()
        let finish = {
            self.inFlight -= 1
            group.leave()
        }
        for entry in probed {
            inFlight += 1
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let ms = Probe.first(entry.servers)?.ms
                let ads = full ? Probe.blocksAds(entry.servers) : nil
                // Run-loop block in common modes so it lands while the menu is being tracked.
                RunLoop.main.perform(inModes: [.common]) {
                    defer { finish() }
                    let list = self.record(entry.servers, ms)
                    if entry.servers == self.activeServers { self.updateHealth() }
                    if let ads { self.adBlock[entry.servers] = ads }
                    if let row = self.probed.first(where: { $0.servers == entry.servers }) {
                        row.item.attributedTitle = self.title(row.name, list, servers: row.servers)
                    }
                }
            }
        }
        // Encryption needs TLS handshakes, so it runs on its own and never holds up latency.
        // It isn't counted in inFlight, so the 1 s ticks keep going while it runs.
        for entry in probed where full {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let enc = Encryption.check(entry.servers)
                RunLoop.main.perform(inModes: [.common]) {
                    defer { group.leave() }
                    if let enc { self.encryption[entry.servers] = enc }
                    self.refreshTitles()
                }
            }
        }
        if full {
            inFlight += 1
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let hit = Probe.intercepted()
                RunLoop.main.perform(inModes: [.common]) {
                    defer { finish() }
                    self.interceptItem?.isHidden = !hit
                }
            }
        }
        group.notify(queue: .main) { done?() }
    }

    // MARK: Actions

    @objc func choose(_ sender: NSMenuItem) {
        let failures = DNS.apply(sender.representedObject as? [String] ?? [])
        updateBadge()
        if !failures.isEmpty {
            alert("Couldn't set DNS on some services",
                  failures.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        }
    }

    @objc func editServers() { EditorWindow.shared.show() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change login item", error.localizedDescription)
        }
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: Test hooks (env-gated, inert in normal use)

    func runTestHooks() {
        if env["DEEANES_OPEN_MENU"] != nil {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in self.item.button?.performClick(nil) }
        }
        if let title = env["DEEANES_SELECT"] {
            rebuild()
            if let it = menu.items.first(where: { $0.title == title }), let a = it.action {
                NSApp.sendAction(a, to: it.target, from: it)
            }
        }
        if env["DEEANES_PRINT_MENU"] != nil {
            rebuild()
            measure(full: true) {
                for it in self.menu.items where !it.isHidden {
                    print(it.isSeparatorItem ? "---" : "\(it.state == .on ? "✓" : " ") \(it.attributedTitle?.string ?? it.title)")
                }
                if let p = self.env["DEEANES_ICON_PNG"], let img = self.item.button?.image {
                    // Render the template icon white-on-dark and dark-on-light at 8x for inspection.
                    let scale: CGFloat = 8, sz = img.size
                    let out = NSImage(size: NSSize(width: sz.width * scale * 2 + 24, height: sz.height * scale + 16), flipped: false) { _ in
                        for (i, (bg, fg)) in [(NSColor.black, NSColor.white), (NSColor.white, NSColor.black)].enumerated() {
                            let r = NSRect(x: CGFloat(i) * (sz.width * scale + 16) + 4, y: 8, width: sz.width * scale, height: sz.height * scale)
                            bg.setFill(); r.insetBy(dx: -4, dy: -4).fill()
                            let tinted = NSImage(size: sz, flipped: false) { rr in
                                img.draw(in: rr); fg.set(); rr.fill(using: .sourceAtop); return true }
                            tinted.draw(in: r)
                        }
                        return true
                    }
                    let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
                }
                print("badge:", self.item.button?.title ?? "", "menu width:", self.menu.size.width)
                exit(0)
            }
        }
        if let list = env["DEEANES_CHECK_ENCRYPTION"] {
            for server in parseServers(list) {
                let eps = Encryption.designated(server)
                print(server, "advertises:", eps.map { $0.map { "\($0.target)[\($0.alpn.joined(separator: ","))]" }.joined(separator: " ") } ?? "no reply",
                      "| macOS uses:", Encryption.check([server]).map { $0.isEmpty ? "plain" : $0.joined(separator: ", ") } ?? "unknown")
            }
            exit(0)
        }
        if let path = env["DEEANES_EDITOR_SNAPSHOT"] {
            EditorWindow.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                EditorWindow.shared.snapshot(to: path)
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
