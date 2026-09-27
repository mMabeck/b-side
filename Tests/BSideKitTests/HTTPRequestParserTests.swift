import Foundation
import Testing

@testable import BSideKit

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {
    @Test("Parses a complete request with a body")
    func parsesCompleteRequest() {
        let body = #"{"type":"tool_execution_end"}"#
        let raw = "POST /subagents/1/c1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let result = HTTPRequestParser.parse(Data(raw.utf8))
        #expect(result != nil)
        #expect(result?.request.method == "POST")
        #expect(result?.request.path == "/subagents/1/c1/events")
        #expect(result?.request.body == Data(body.utf8))
        #expect(result?.consumed == raw.utf8.count)
    }

    @Test("Returns nil when the body is not fully buffered yet")
    func returnsNilForIncompleteBody() {
        let raw = "POST /subagents/1/c1/events HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"partial\":"
        #expect(HTTPRequestParser.parse(Data(raw.utf8)) == nil)
    }

}
