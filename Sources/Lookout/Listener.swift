import Foundation
import Network

/// Settings in ~/.lookout/config.json. Created with a random token on first launch.
struct ListenerConfig: Codable {
    var enabled: Bool = true
    var port: UInt16 = 47821
    var token: String = ListenerConfig.randomToken()

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func load(from url: URL) -> ListenerConfig {
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(ListenerConfig.self, from: data) {
            return config
        }
        let config = ListenerConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return config
    }
}

/// A small HTTP server bound only to this Mac's Tailscale address, so agents on
/// other machines in your tailnet can report to Lookout.
///
///   POST /event      body = a lookout-report file (header line + payload);
///                    needs "Authorization: Bearer <token>"
///   GET  /reporter   the lookout-report script, for setting up another machine
///   GET  /installer  the lookout-hooks.py installer
final class Listener: ObservableObject {
    @Published private(set) var address: String?

    let config: ListenerConfig
    private let inbox: URL
    private var listener: NWListener?
    private var retry: Timer?
    private let queue = DispatchQueue(label: "lookout.listener")
    private static let maxBody = 2 * 1024 * 1024

    init(home: URL, inbox: URL) {
        self.config = ListenerConfig.load(from: home.appendingPathComponent("config.json"))
        self.inbox = inbox
    }

    var baseURL: String? { address.map { "http://\($0):\(config.port)" } }

    func start() {
        guard config.enabled else { return }
        bind()
        // Tailscale may come up after Lookout, or its address may change.
        retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Self.tailscaleAddress() != self.address { self.bind() }
        }
    }

    private func bind() {
        listener?.cancel()
        listener = nil
        address = nil
        guard let ip = Self.tailscaleAddress(), let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: port)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: self?.address = ip
                case .failed(let error):
                    NSLog("Lookout: listener failed on \(ip):\(port): \(error)")
                    self?.address = nil
                default: break
                }
            }
        }
        l.start(queue: queue)
        listener = l
    }

    /// The IPv4 address in Tailscale's 100.64.0.0/10 range, if any interface has one.
    static func tailscaleAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let b = withUnsafeBytes(of: addr) { Array($0) }
            if b[0] == 100, (64...127).contains(b[1]) {
                return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            }
        }
        return nil
    }

    // MARK: HTTP

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
        // Drop connections that never finish a request.
        queue.asyncAfter(deadline: .now() + 10) { conn.cancel() }
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxBody + 16384 { return self.respond(conn, 413, "too large") }
            if let request = Request(buffer) {
                if request.body.count >= request.contentLength {
                    return self.route(conn, request)
                }
            }
            if done || error != nil { return conn.cancel() }
            self.receive(conn, buffer: buffer)
        }
    }

    private func route(_ conn: NWConnection, _ r: Request) {
        switch (r.method, r.path) {
        case ("POST", "/event"):
            guard r.headers["authorization"] == "Bearer \(config.token)" else {
                return respond(conn, 401, "unauthorized")
            }
            let body = r.body.prefix(r.contentLength)
            guard body.first == UInt8(ascii: "{") else { return respond(conn, 400, "bad event") }
            let name = "\(Int(Date().timeIntervalSince1970))-remote-\(UUID().uuidString.prefix(8)).json"
            let tmp = inbox.appendingPathComponent(".tmp-\(name)")
            do {
                try Data(body).write(to: tmp)
                try FileManager.default.moveItem(at: tmp, to: inbox.appendingPathComponent(name))
                respond(conn, 204, "")
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                respond(conn, 500, "write failed")
            }
        case ("GET", "/reporter"):
            serveResource(conn, "lookout-report")
        case ("GET", "/installer"):
            serveResource(conn, "lookout-hooks.py")
        default:
            respond(conn, 404, "not found")
        }
    }

    private func serveResource(_ conn: NWConnection, _ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: url)
        else { return respond(conn, 404, "not found") }
        respond(conn, 200, data, type: "text/plain; charset=utf-8")
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ text: String) {
        respond(conn, status, Data(text.utf8), type: "text/plain; charset=utf-8")
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ body: Data, type: String) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: \(type)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

private struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var contentLength: Int
    var body: Data

    init?(_ buffer: Data) {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        method = String(first[0])
        path = String(first[1].split(separator: "?").first ?? "")
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = h
        contentLength = min(Int(h["content-length"] ?? "0") ?? 0, 2 * 1024 * 1024)
        body = buffer[end.upperBound...]
    }
}
