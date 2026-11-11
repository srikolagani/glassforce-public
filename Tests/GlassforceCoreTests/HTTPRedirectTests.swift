import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GlassforceCore

@Suite("HTTP redirect refusal")
struct HTTPRedirectTests {
    @Test(arguments: [301, 302, 303, 307, 308])
    func productionSessionRejectsRedirects(status: Int) async throws {
        let session = URLSessionTransport.session
        let delegate = try #require(session.delegate as? RefuseHTTPRedirects)
        let source = URL(string: "https://login.salesforce.com/services/oauth2/token")!
        // This task is never resumed: exercise the installed delegate without I/O.
        let task = session.dataTask(with: source)
        defer { task.cancel() }
        for target in [source, URL(string: "https://external.example/token")!] {
            let response = try #require(HTTPURLResponse(url: source, statusCode: status,
                                                       httpVersion: nil,
                                                       headerFields: ["Location": target.absoluteString]))
            let refused = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                    newRequest: URLRequest(url: target)) { request in
                    continuation.resume(returning: request == nil)
                }
            }
            #expect(refused)
        }
    }
}
