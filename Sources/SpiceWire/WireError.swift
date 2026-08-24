public enum WireError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case badOffset(Int)
    case badValue(field: String, value: UInt64)
    case unsupported(String)
}
