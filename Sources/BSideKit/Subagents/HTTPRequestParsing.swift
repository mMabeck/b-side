import Foundation

/// A minimal HTTP/1.1 request, parsed from raw bytes. Only what the local
/// subagent-event endpoint needs: method, path, and body.
public struct ParsedHTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var body: Data
}

/// Hand-rolled HTTP/1.1 request parsing, kept pure and separate from the
/// socket so it can be unit tested without a live connection.
public enum HTTPRequestParser {
    /// Parses one request from the front of `data`. Returns `nil` if the
    /// headers (or, once known, the body per `Content-Length`) are not yet
    /// fully buffered — the caller should wait for more bytes and retry.
    /// On success, also returns how many bytes of `data` the request consumed.
    public static func parse(_ data: Data) -> (request: ParsedHTTPRequest, consumed: Int)? {
        let headerTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headerEnd = range(of: headerTerminator, in: data) else { return nil }

        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let availableBody = data.distance(from: bodyStart, to: data.endIndex)
        guard availableBody >= contentLength else { return nil }

        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = data[bodyStart..<bodyEnd]
        let consumed = data.distance(from: data.startIndex, to: bodyEnd)
        return (ParsedHTTPRequest(method: method, path: path, body: Data(body)), consumed)
    }

    private static func range(of pattern: [UInt8], in data: Data) -> Range<Data.Index>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        var index = data.startIndex
        let lastPossible = data.index(data.endIndex, offsetBy: -pattern.count)
        while index <= lastPossible {
            if data[index..<data.index(index, offsetBy: pattern.count)].elementsEqual(pattern) {
                return index..<data.index(index, offsetBy: pattern.count)
            }
            index = data.index(after: index)
        }
        return nil
    }
}
