import Foundation
import Network

enum OAuthLoopbackError: Error, Equatable {
    case portBusy(UInt16)
    case timedOut
    case cancelled
    case badCallback
}

/// A one-shot localhost HTTP server that captures an OAuth redirect.
///
/// Registered redirects we listen on, never invent: ChatGPT
/// `http://localhost:1455/auth/callback`, Antigravity
/// `http://127.0.0.1:51121/callback`, Claude `http://localhost:54545/callback`,
/// Grok `http://127.0.0.1:56121/callback`.
enum OAuthLoopback {
    static func waitForCode(
        host: String,
        port: UInt16,
        path: String,
        expectedState: String,
        timeout: TimeInterval = 180
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var settled = false
            func finish(_ result: Result<String, Error>) {
                guard !settled else { return }
                settled = true
                listener?.cancel()
                continuation.resume(with: result)
            }

            var listener: NWListener?
            do {
                listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            } catch {
                continuation.resume(throwing: OAuthLoopbackError.portBusy(port))
                return
            }
            guard let listener else {
                continuation.resume(throwing: OAuthLoopbackError.portBusy(port))
                return
            }

            listener.stateUpdateHandler = { state in
                if case .failed = state {
                    finish(.failure(OAuthLoopbackError.portBusy(port)))
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    let html = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/html; charset=utf-8\r
                    Connection: close\r
                    \r
                    <!doctype html><title>Codenotch</title>\
                    <p>Signed in. You can close this window and return to Codenotch.</p>
                    """
                    connection.send(content: Data(html.utf8),
                                    isComplete: true,
                                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    do {
                        let code = try parseCode(from: request, path: path, expectedState: expectedState)
                        finish(.success(code))
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
            listener.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(OAuthLoopbackError.timedOut))
            }
        }
    }

    static func parseCode(from request: String, path: String, expectedState: String) throws -> String {
        let line = request.split(separator: "\r\n", maxSplits: 1).first
            .map(String.init) ?? request
        guard line.hasPrefix("GET ") else { throw OAuthLoopbackError.badCallback }
        let target = line
            .dropFirst(4)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        guard let url = URL(string: "http://loopback\(target)") else {
            throw OAuthLoopbackError.badCallback
        }
        let callbackPath = url.path
        guard callbackPath == path || callbackPath == path + "/" else {
            throw OAuthLoopbackError.badCallback
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first(where: { $0.name == "state" })?.value
        guard state == expectedState else { throw OAuthLoopbackError.badCallback }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw OAuthLoopbackError.badCallback }
        return code
    }
}
