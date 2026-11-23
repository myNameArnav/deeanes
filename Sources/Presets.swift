import Foundation

struct Preset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Short label shown next to the menu bar icon while this preset is active. nil = derived from name.
    var badge: String?
    /// Raw text as typed in the editor: IP addresses and/or hostnames.
    var serversText: String
    /// Cached lookups for the hostnames in `serversText` (lowercased host -> IPs). macOS only takes IPs
    /// as DNS servers, so hostnames are resolved once, when typed, and applied from this cache. That keeps
    /// switching working while the current DNS is broken, and the active check mark stable for names
    /// whose answers rotate. Optional so presets saved before hostnames were supported still decode.
    var resolved: [String: [String]]?

    init(name: String, servers: [String]) {
        self.name = name
        serversText = servers.joined(separator: ", ")
    }

    /// Tokens as typed, IPs and hostnames.
    var entries: [String] { parseServers(serversText) }

    /// Hostname entries, normalised (lowercase, no trailing dot).
    var hostnames: [String] { unique(entries.filter { !isIPAddress($0) }.map(hostKey).filter(isHostname)) }

    /// IPs to hand to macOS: literal IPs plus the cached addresses of hostnames, in typed order.
    var servers: [String] {
        unique(entries.flatMap { isIPAddress($0) ? [$0] : (resolved?[hostKey($0)] ?? []) })
    }

    var shortName: String {
        if let badge, !badge.isEmpty { return badge }
        return derivedBadge(name)
    }

    var isValid: Bool {
        !entries.isEmpty && entries.allSatisfy { isIPAddress($0) || resolved?[hostKey($0)]?.isEmpty == false }
    }
}

let defaultPresets: [Preset] = [
    Preset(name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]),
    Preset(name: "Google", servers: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]),
    Preset(name: "Quad9", servers: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]),
]

/// "Cloudflare" -> "CF", "AdGuard" -> "AG", "Google" -> "G".
func derivedBadge(_ name: String) -> String {
    let known = ["cloudflare": "CF", "google": "G", "quad9": "Q9", "adguard": "AG", "opendns": "OD"]
    if let k = known[name.lowercased()] { return k }
    let caps = name.filter(\.isUppercase)
    if caps.count >= 2 { return String(caps.prefix(2)) }
    return name.first.map { String($0).uppercased() } ?? ""
}

func isIPAddress(_ s: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
}

func hostKey(_ s: String) -> String {
    let l = s.lowercased()
    return l.hasSuffix(".") ? String(l.dropLast()) : l
}

/// A fully qualified name like dns.example.com: at least two LDH labels and a non-numeric TLD,
/// so a half-typed IP ("1.1.1") isn't taken for one.
func isHostname(_ s: String) -> Bool {
    let labels = hostKey(s).split(separator: ".", omittingEmptySubsequences: false)
    guard s.count <= 253, labels.count >= 2, let tld = labels.last, !tld.allSatisfy(\.isNumber) else { return false }
    return labels.allSatisfy { l in
        (1...63).contains(l.count) && l.first != "-" && l.last != "-"
            && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

func parseServers(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
}

func unique(_ xs: [String]) -> [String] {
    var seen = Set<String>()
    return xs.filter { seen.insert($0).inserted }
}

/// A/AAAA addresses for a hostname via the system resolver, or the reason it failed. Blocking.
func lookup(_ host: String) -> Result<[String], LookupError> {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_DGRAM  // one result per address instead of one per socket type
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, nil, &hints, &res)
    guard rc == 0 else {
        return .failure(LookupError(message: rc == EAI_NONAME ? "no such host" : String(cString: gai_strerror(rc)).lowercased()))
    }
    defer { freeaddrinfo(res) }
    var ips: [String] = []
    var p = res
    while let ai = p {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: buf)
            if isIPAddress(ip) { ips.append(ip) }  // skips scoped link-local (fe80::1%en0)
        }
        p = ai.pointee.ai_next
    }
    // IPv4 first, matching how the built-in presets list them.
    let v4 = ips.filter { !$0.contains(":") }, v6 = ips.filter { $0.contains(":") }
    return ips.isEmpty ? .failure(LookupError(message: "no addresses")) : .success(unique(v4 + v6))
}

struct LookupError: Error { let message: String }

/// What a single typed entry currently means.
enum EntryStatus: Equatable {
    case ip
    case resolved([String])
    case resolving
    case failed(String)
    case invalid
}

/// The user's editable list, persisted in UserDefaults.
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    private let key = "presets"

    @Published var presets: [Preset] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: key)
            if !writingCache { scheduleLookups() }  // only edits trigger lookups, not our own cache writes
        }
    }
    /// Hostnames whose last lookup failed, with the reason. Not persisted: retried on launch and edits.
    @Published private(set) var failures: [String: String] = [:]
    private var inFlight = Set<String>()
    private var pending: DispatchWorkItem?
    private var writingCache = false

    private func writeCache(_ updated: [Preset]) {
        guard updated != presets else { return }
        writingCache = true
        presets = updated
        writingCache = false
    }

    private init() {
        presets = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? defaultPresets
        scheduleLookups()
    }

    func restoreDefaults() { presets = defaultPresets.map { Preset(name: $0.name, servers: $0.servers) } }

    func status(of entry: String, in preset: Preset) -> EntryStatus {
        if isIPAddress(entry) { return .ip }
        let host = hostKey(entry)
        guard isHostname(host) else { return .invalid }
        if let ips = preset.resolved?[host], !ips.isEmpty { return .resolved(ips) }
        if let why = failures[host], !inFlight.contains(host) { return .failed(why) }
        return .resolving
    }

    /// Debounced so a half-typed name doesn't fire a lookup per keystroke.
    private func scheduleLookups() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runLookups() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func runLookups() {
        // Drop cache entries for hostnames that were edited away.
        var pruned = presets
        for i in pruned.indices {
            let hosts = Set(pruned[i].hostnames)
            let kept = pruned[i].resolved?.filter { hosts.contains($0.key) }
            pruned[i].resolved = kept?.isEmpty == false ? kept : nil
        }
        writeCache(pruned)

        let missing = Set(presets.flatMap { p in p.hostnames.filter { p.resolved?[$0] == nil } }).subtracting(inFlight)
        guard !missing.isEmpty else { return }
        if ProcessInfo.processInfo.environment["DEEANES_LOG_LOOKUPS"] != nil { print("lookup:", missing.sorted()); fflush(stdout) }
        inFlight.formUnion(missing)
        objectWillChange.send()  // failed -> resolving
        for host in missing {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = lookup(host)
                DispatchQueue.main.async { self.finish(host, result) }
            }
        }
    }

    private func finish(_ host: String, _ result: Result<[String], LookupError>) {
        inFlight.remove(host)
        switch result {
        case .success(let ips):
            failures[host] = nil
            var updated = presets
            for i in updated.indices where updated[i].hostnames.contains(host) {
                updated[i].resolved = (updated[i].resolved ?? [:]).merging([host: ips]) { _, new in new }
            }
            if updated == presets { objectWillChange.send() } else { writeCache(updated) }
        case .failure(let e):
            failures[host] = e.message
        }
    }
}
