import SpiceWire

public struct PaletteCache: Sendable {
    private var palettes: [UInt64: SpicePalette] = [:]
    public init() {}
    public subscript(id: UInt64) -> SpicePalette? { palettes[id] }
    public mutating func store(_ palette: SpicePalette) { palettes[palette.id] = palette }
    public mutating func remove(_ id: UInt64) { palettes[id] = nil }
    public mutating func removeAll() { palettes.removeAll() }
}
