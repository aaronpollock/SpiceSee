public protocol ByteSource: Sendable { func read(exactly n: Int) async throws -> [UInt8] }
public protocol ByteSink: Sendable { func write(_ bytes: [UInt8]) async throws }
public typealias Transport = ByteSource & ByteSink

public actor InMemoryTransport: Transport {
    private let input: [UInt8]
    private var cursor = 0
    public private(set) var written: [UInt8] = []
    public init(input: [UInt8]) { self.input = input }
    public func read(exactly n: Int) throws -> [UInt8] {
        guard input.count - cursor >= n else { throw SpiceError(.closed, underlying: "EOF") }
        defer { cursor += n }
        return Array(input[cursor ..< cursor + n])
    }
    public func write(_ bytes: [UInt8]) { written.append(contentsOf: bytes) }
}
