import Foundation

public struct ParsedHTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var body: Data
}

public enum HTTPRequestParser {
    /// Returns `nil` until the headers and `Content-Length` body are fully buffered.
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
