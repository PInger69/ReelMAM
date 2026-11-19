import Foundation

/// A parsed HTTP/1.1 request. The server only ever reads, so there is no body.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var keepAlive: Bool

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], keepAlive: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.keepAlive = keepAlive
    }

    public var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }
}

public enum HTTPParseResult: Sendable {
    case incomplete
    /// A complete request and how many bytes of the buffer it used.
    case request(HTTPRequest, consumed: Int)
    case invalid(status: Int)
}

public enum HTTPRequestParser {
    public static let maxHeaderBytes = 16 * 1024

    public static func parse(_ data: Data) -> HTTPParseResult {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: terminator) else {
            return data.count > maxHeaderBytes ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .invalid(status: 431) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else {
            return .invalid(status: 400)
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .invalid(status: 400) }
            let name = line[line.startIndex..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Read-only service: nothing it accepts has a body.
        if headers["transfer-encoding"] != nil { return .invalid(status: 400) }
        if let length = headers["content-length"], length != "0" { return .invalid(status: 400) }

        guard let components = URLComponents(string: "http://x" + requestLine[1]) else { return .invalid(status: 400) }
        let path = components.percentEncodedPath.removingPercentEncoding ?? ""
        guard !path.contains("\0") else { return .invalid(status: 400) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }

        let http11 = requestLine[2] == "HTTP/1.1"
        let connection = headers["connection"]?.lowercased()
        let keepAlive = http11 ? connection != "close" : connection == "keep-alive"
        let request = HTTPRequest(method: requestLine[0].uppercased(), path: path, query: query,
                                  headers: headers, keepAlive: keepAlive)
        return .request(request, consumed: end.upperBound - data.startIndex)
    }
}

/// What an HTTP response carries. A file is streamed from disk, never loaded whole.
public enum HTTPBody: Sendable {
    case none
    /// Answer to HEAD: the headers of the full response, with this Content-Length and no body.
    case headOnly(length: UInt64)
    case data(Data)
    case file(path: String, offset: UInt64, length: UInt64)

    public var length: UInt64 {
        switch self {
        case .none: return 0
        case .headOnly(let length): return length
        case .data(let data): return UInt64(data.count)
        case .file(_, _, let length): return length
        }
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: HTTPBody
    /// Called once by the server when the response has been sent or the connection broke:
    /// the bytes of body actually written, and whether all of them were.
    public var onFinish: (@Sendable (_ bytesSent: Int64, _ completed: Bool) -> Void)?

    public init(status: Int, headers: [(String, String)] = [], body: HTTPBody = .none) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    public static func error(_ status: Int, _ message: String, extra: [(String, String)] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return HTTPResponse(status: status,
                            headers: [("Content-Type", "application/json")] + extra,
                            body: .data(body))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 416: return "Range Not Satisfiable"
        case 428: return "Precondition Required"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    /// The status line and headers, ready to write to the socket.
    func serializedHead(keepAlive: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers where name.lowercased() != "content-length" && name.lowercased() != "connection" {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.length)\r\n"
        text += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(text.utf8)
    }
}

/// A single `Range: bytes=` request, resolved against a file size.
public enum ByteRange: Equatable {
    case whole
    case partial(start: UInt64, end: UInt64)   // inclusive
    case unsatisfiable

    public static func parse(_ header: String?, size: UInt64) -> ByteRange {
        guard let header else { return .whole }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = String(value.dropFirst(6))
        // Several ranges at once are legal to ignore; the response is then the whole file.
        guard !spec.contains(",") else { return .whole }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .whole }
        if parts[0].isEmpty {
            // Suffix: the last N bytes.
            guard let n = UInt64(parts[1]), n > 0 else { return .unsatisfiable }
            guard size > 0 else { return .unsatisfiable }
            return .partial(start: size - min(n, size), end: size - 1)
        }
        guard let start = UInt64(parts[0]), start < size else { return .unsatisfiable }
        if parts[1].isEmpty { return .partial(start: start, end: size - 1) }
        guard let end = UInt64(parts[1]), end >= start else { return .whole }
        return .partial(start: start, end: min(end, size - 1))
    }
}
