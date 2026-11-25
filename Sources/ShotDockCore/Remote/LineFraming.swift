import Foundation

/// One JSON message per line ("JSON lines"), as MCP's stdio transport does.
/// JSON escapes newlines inside strings, so a raw "\n" always ends a message.
public struct LineBuffer: Sendable {
    /// A message longer than this is an error rather than a memory leak.
    public static let maxLineLength = 64 << 20

    private var pending = Data()

    public init() {}

    public struct LineTooLong: Error {}

    /// Adds bytes and returns the complete lines, without their newline;
    /// blank lines are skipped.
    public mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = pending[pending.startIndex..<newline]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        if pending.count > Self.maxLineLength { pending = Data(); throw LineTooLong() }
        return lines
    }

    /// Whatever is left without a final newline (the last message of a stream).
    public mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) ? nil : pending
    }
}

public enum LineFraming {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The value as one line of JSON, newline included.
    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
