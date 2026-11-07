import Foundation
import Network
import GlassforceCore

/// Serves `MockSalesforce` over HTTP on 127.0.0.1 so a real browser (or web view) can load the
/// consent page during `--mock-salesforce`. Loopback only; nothing is reachable from the network.
final class MockServerHost: @unchecked Sendable {
    let mock: MockSalesforce
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.glassforce.mock-server")

    init(mock: MockSalesforce) { self.mock = mock }

    /// Starts listening and returns the base URL, e.g. http://127.0.0.1:53124
    func start(preferredPort: UInt16 = 17_420) throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: preferredPort)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let port = listener.port, listener.state == .ready else { throw URLError(.cannotConnectToHost) }
        self.listener = listener
        let base = URL(string: "http://127.0.0.1:\(port.rawValue)")!
        mock.baseURL = base
        return base
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer, base: self.mock.baseURL) {
                let (response, delay) = self.mock.handle(request)
                self.queue.asyncAfter(deadline: .now() + delay) { self.respond(connection, response) }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Parses one HTTP/1.1 request once headers (and any Content-Length body) have arrived.
    static func parse(_ data: Data, base: URL) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Canonicalize the few headers the mock reads.
            let canonical = ["authorization": "Authorization", "content-type": "Content-Type", "content-length": "Content-Length"][name.lowercased()] ?? name
            headers[canonical] = value
        }
        let length = Int(headers["Content-Length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        guard let url = URL(string: String(requestLine[1]), relativeTo: base)?.absoluteURL else { return nil }
        return HTTPRequest(method: String(requestLine[0]), url: url, headers: headers, body: length > 0 ? Data(body.prefix(length)) : nil)
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Status"
    }
}
