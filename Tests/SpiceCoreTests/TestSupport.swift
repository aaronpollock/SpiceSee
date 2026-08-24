import SpiceWire

extension SpiceReader {
    func u32Unchecked() -> UInt32 { var c = self; return (try? c.u32()) ?? 0 }
}
