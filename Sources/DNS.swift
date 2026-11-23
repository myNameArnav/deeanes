import Foundation
import SystemConfiguration

enum DNS {
    static let store = SCDynamicStoreCreate(nil, "deeanes" as CFString, nil, nil)

    @discardableResult
    static func run(_ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    struct Service { let id: String; let name: String; let active: Bool }

    private static func value(_ key: String) -> [String: Any]? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// Enabled, non-VPN services in the user's service order. VPNs (Tailscale etc.)
    /// manage their own DNS, so they're left alone.
    static func services() -> [Service] {
        let enabled = Set(run(["-listallnetworkservices"]).out
            .split(separator: "\n").map(String.init)
            .dropFirst()  // "An asterisk (*) denotes..."
            .filter { !$0.hasPrefix("*") && !$0.isEmpty })
        let order = value("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
        return order.compactMap { id in
            guard let name = value("Setup:/Network/Service/\(id)")?["UserDefinedName"] as? String,
                  enabled.contains(name),
                  value("Setup:/Network/Service/\(id)/Interface")?["Type"] as? String != "VPN"
            else { return nil }
            return Service(id: id, name: name, active: value("State:/Network/Service/\(id)/IPv4") != nil)
        }
    }

    /// The highest-priority service that's actually connected (ignoring VPNs).
    static func primary() -> Service? {
        let all = services()
        return all.first(where: \.active) ?? all.first
    }

    /// Servers manually set on a service; empty means automatic.
    static func configured(for service: Service) -> [String] {
        value("Setup:/Network/Service/\(service.id)/DNS")?["ServerAddresses"] as? [String] ?? []
    }

    /// Servers handed out by DHCP / router for a service.
    static func automatic(for service: Service) -> [String] {
        value("State:/Network/Service/\(service.id)/DNS")?["ServerAddresses"] as? [String] ?? []
    }

    /// What the resolver actually uses right now (may differ, e.g. Tailscale MagicDNS).
    static func effective() -> [String] {
        value("State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? []
    }

    /// Applies servers (empty = automatic) to every enabled service. Returns failures.
    static func apply(_ servers: [String]) -> [String: String] {
        var failures: [String: String] = [:]
        for s in services() {
            let r = run(["-setdnsservers", s.name] + (servers.isEmpty ? ["Empty"] : servers))
            if !r.ok || r.out.lowercased().contains("error") {
                failures[s.name] = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return failures
    }
}
