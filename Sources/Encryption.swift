import Foundation
import Network
import Security

/// Encrypted DNS via DDR (RFC 9462, "Discovery of Designated Resolvers").
///
/// macOS 13+ asks each plain DNS server for `_dns.resolver.arpa` (SVCB). If the server names an
/// encrypted endpoint whose TLS certificate also covers the server's own IP address, macOS sends
/// queries over DoH or DoT instead of plain UDP. Deeanes doesn't change how DNS is set; it runs the
/// same discovery and verification so it can show which servers macOS will upgrade.
enum Encryption {
    struct Endpoint { let target: String; let alpn: [String]; let port: UInt16? }

    /// Protocols macOS will use for these servers ("DoH", "DoT"), checked on the first server
    /// that answers. Empty = stays plain. nil = no server answered, so nothing is known.
    static func check(_ servers: [String]) -> [String]? {
        for server in servers {
            guard let endpoints = designated(server) else { continue }
            var verified: [String] = []
            // macOS uses DoH and DoT. DoQ is advertised by some servers but macOS doesn't use it.
            for (proto, alpns, port, alpn) in [("DoH", ["h2", "h3", "http/1.1"], UInt16(443), "h2"),
                                               ("DoT", ["dot"], UInt16(853), "dot")] {
                guard let ep = endpoints.first(where: { !Set($0.alpn).isDisjoint(with: alpns) }) else { continue }
                if verify(server, target: ep.target, port: ep.port ?? port, alpn: alpn) { verified.append(proto) }
            }
            return verified
        }
        return nil
    }

    /// Encrypted endpoints the server advertises. nil = no reply; empty = replied without any.
    static func designated(_ server: String) -> [Endpoint]? {
        guard let r = Probe.query(server, name: "_dns.resolver.arpa", type: 64, timeout: 1500) else { return nil }
        let b = r.bytes
        guard b[3] & 0x0f == 0 else { return [] }
        return Probe.records(b, type: 64).compactMap(parseSVCB)
    }

    /// Connects to the server's own IP with TLS (SNI = the advertised name) and accepts only a
    /// certificate that is trusted and lists that IP address, which is what macOS requires.
    static func verify(_ server: String, target: String, port: UInt16, alpn: String, timeout: TimeInterval = 2) -> Bool {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(sec, target)
        sec_protocol_options_add_tls_application_protocol(sec, alpn)
        let queue = DispatchQueue(label: "deeanes.verify")
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(t, SecPolicyCreateSSL(true, server as CFString))
            complete(SecTrustEvaluateWithError(t, nil))
        }, queue)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(server), port: nwPort, using: NWParameters(tls: tls))
        let done = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; done.signal()
            case .failed, .waiting, .cancelled: done.signal()
            default: break
            }
        }
        conn.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        conn.stateUpdateHandler = nil
        conn.cancel()
        return queue.sync { ok }
    }

    /// SVCB rdata: priority, target name, then key/value params (1 = alpn, 3 = port).
    static func parseSVCB(_ rd: ArraySlice<UInt8>) -> Endpoint? {
        let d = Array(rd)
        guard d.count >= 3, d[0] != 0 || d[1] != 0 else { return nil }  // priority 0 = alias form
        var i = 2
        var labels: [String] = []
        while i < d.count, d[i] != 0 {
            let len = Int(d[i])
            guard i + 1 + len <= d.count else { return nil }
            labels.append(String(decoding: d[i + 1..<i + 1 + len], as: UTF8.self))
            i += 1 + len
        }
        i += 1
        var alpn: [String] = [], port: UInt16?
        while i + 4 <= d.count {
            let key = Int(d[i]) << 8 | Int(d[i + 1]), len = Int(d[i + 2]) << 8 | Int(d[i + 3])
            i += 4
            guard i + len <= d.count else { break }
            let v = Array(d[i..<i + len])
            if key == 1 {
                var j = 0
                while j < v.count { let l = Int(v[j]); alpn.append(String(decoding: v[min(j + 1, v.count)..<min(j + 1 + l, v.count)], as: UTF8.self)); j += 1 + l }
            } else if key == 3, len == 2 {
                port = UInt16(v[0]) << 8 | UInt16(v[1])
            }
            i += len
        }
        return labels.isEmpty ? nil : Endpoint(target: labels.joined(separator: "."), alpn: alpn, port: port)
    }
}
