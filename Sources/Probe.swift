import Foundation

/// Sends real DNS queries over UDP/53 to measure servers and inspect their answers.
enum Probe {
    struct Reply { let ms: Double; let bytes: [UInt8] }

    /// One A query for `name` to `server`. nil if nothing answered within the timeout.
    static func query(_ server: String, name: String = "apple.com", timeout: Int32 = 1000) -> Reply? {
        var sa4 = sockaddr_in(), sa6 = sockaddr_in6()
        let isV6: Bool
        if inet_pton(AF_INET, server, &sa4.sin_addr) == 1 {
            isV6 = false
            sa4.sin_family = sa_family_t(AF_INET)
            sa4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa4.sin_port = UInt16(53).bigEndian
        } else if inet_pton(AF_INET6, server, &sa6.sin6_addr) == 1 {
            isV6 = true
            sa6.sin6_family = sa_family_t(AF_INET6)
            sa6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa6.sin6_port = UInt16(53).bigEndian
        } else { return nil }

        let fd = socket(isV6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let id = UInt16.random(in: 0...UInt16.max)
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q += label.utf8 }
        q += [0, 0, 1, 0, 1]  // root, type A, class IN

        let start = DispatchTime.now().uptimeNanoseconds
        let sent: Int = isV6
            ? withUnsafePointer(to: &sa6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, q, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            : withUnsafePointer(to: &sa4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, q, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard sent == q.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let elapsed = Int32((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard elapsed < timeout, poll(&pfd, 1, timeout - elapsed) > 0 else { return nil }
            let n = recv(fd, &buf, buf.count, 0)
            if n >= 12, buf[0] == UInt8(id >> 8), buf[1] == UInt8(id & 0xff) {
                return Reply(ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                             bytes: Array(buf[0..<n]))
            }
            if n < 0 { return nil }
        }
    }

    /// First reply from any of the servers (= the fastest), all queried at once.
    /// Returns as soon as one answers, so dead servers (e.g. IPv6 without a v6 route) don't stall it.
    static func first(_ servers: [String], name: String = "apple.com") -> Reply? {
        guard !servers.isEmpty else { return nil }
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var winner: Reply?
        var remaining = servers.count
        for server in servers {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = query(server, name: name)
                lock.lock()
                remaining -= 1
                let signal = winner == nil && (r != nil || remaining == 0)
                if winner == nil, let r { winner = r }
                lock.unlock()
                if signal { done.signal() }
            }
        }
        done.wait()
        lock.lock(); defer { lock.unlock() }
        return winner
    }

    /// Does this resolver block ads? Asks for a well-known ad domain that really resolves:
    /// NXDOMAIN, an empty answer, or a 0.0.0.0 / 127.x sinkhole means it was blocked.
    static func blocksAds(_ servers: [String]) -> Bool? {
        guard let r = first(servers, name: "doubleclick.net") else { return nil }
        let b = r.bytes
        let rcode = b[3] & 0x0f
        if rcode == 3 { return true }
        guard rcode == 0 else { return nil }
        let addrs = aRecords(b)
        return addrs.isEmpty || addrs.contains { $0 == [0, 0, 0, 0] || $0.first == 127 }
    }

    /// Is something on the network answering DNS on behalf of servers it shouldn't?
    /// 192.0.2.1 is reserved for documentation and never routed, so any reply means interception.
    static func intercepted() -> Bool { query("192.0.2.1", timeout: 800) != nil }

    /// IPv4 addresses in the answer section of a reply.
    static func aRecords(_ b: [UInt8]) -> [[UInt8]] {
        func skipName(_ i: inout Int) {
            while i < b.count {
                let len = Int(b[i])
                if len == 0 { i += 1; return }
                if len & 0xc0 == 0xc0 { i += 2; return }  // compression pointer
                i += len + 1
            }
        }
        let qd = Int(b[4]) << 8 | Int(b[5]), an = Int(b[6]) << 8 | Int(b[7])
        var i = 12
        for _ in 0..<qd { skipName(&i); i += 4 }
        var out: [[UInt8]] = []
        for _ in 0..<an {
            skipName(&i)
            guard i + 10 <= b.count else { break }
            let type = Int(b[i]) << 8 | Int(b[i + 1])
            let len = Int(b[i + 8]) << 8 | Int(b[i + 9])
            i += 10
            guard i + len <= b.count else { break }
            if type == 1 && len == 4 { out.append(Array(b[i..<i + 4])) }
            i += len
        }
        return out
    }
}
