public struct ImageCache: Sendable {
    private var images: [UInt64: DecodedImage] = [:]
    public init() {}
    public subscript(id: UInt64) -> DecodedImage? { images[id] }
    public mutating func store(_ img: DecodedImage, id: UInt64) { images[id] = img }
    public mutating func remove(_ id: UInt64) { images[id] = nil }
    public mutating func removeAll() { images.removeAll() }
}
