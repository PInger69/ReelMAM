import Foundation
import StradaMAMCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ExternalAnalysisError: Error, LocalizedError {
    case badAddress(String)
    case rejected(Int)
    case unreadableReply

    public var errorDescription: String? {
        switch self {
        case .badAddress(let url): return "“\(url)” is not a valid https address."
        case .rejected(let status): return "The A.I. hook answered with status \(status)."
        case .unreadableReply: return "The A.I. hook's reply could not be understood."
        }
    }
}

/// Sends a clip's description to an external A.I. hook and reads its reply.
public enum ExternalAnalysisClient {
    /// Only https addresses are accepted, except for a service on this same computer.
    static func endpoint(for hook: AnalysisHook) throws -> URL {
        guard let url = URL(string: hook.url.trimmingCharacters(in: .whitespaces)), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        else { throw ExternalAnalysisError.badAddress(hook.url) }
        return url
    }

    public static func makeRequest(hook: AnalysisHook, token: String?,
                                   body: ExternalAnalysisRequest) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(for: hook))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public static func send(hook: AnalysisHook, token: String?,
                            body: ExternalAnalysisRequest) async throws -> ExternalAnalysisResponse {
        let request = try makeRequest(hook: hook, token: token, body: body)
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: error ?? ExternalAnalysisError.unreadableReply)
                }
            }.resume()
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw ExternalAnalysisError.rejected(status)
        }
        guard let reply = try? JSONDecoder().decode(ExternalAnalysisResponse.self, from: data) else {
            throw ExternalAnalysisError.unreadableReply
        }
        return reply
    }
}
