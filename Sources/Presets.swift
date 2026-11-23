import Foundation

struct Preset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Short label shown next to the menu bar icon while this preset is active. nil = derived from name.
    var badge: String?
    /// Raw text as typed in the editor; `servers` is parsed from it.
    var serversText: String

    init(name: String, servers: [String]) {
        self.name = name
        serversText = servers.joined(separator: ", ")
    }

    var servers: [String] { parseServers(serversText) }

    var shortName: String {
        if let badge, !badge.isEmpty { return badge }
        return derivedBadge(name)
    }

    var isValid: Bool { !servers.isEmpty && servers.allSatisfy(isIPAddress) }
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

func parseServers(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
}

/// The user's editable list, persisted in UserDefaults.
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    private let key = "presets"

    @Published var presets: [Preset] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: key) }
    }

    private init() {
        presets = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? defaultPresets
    }

    func restoreDefaults() { presets = defaultPresets.map { Preset(name: $0.name, servers: $0.servers) } }
}
