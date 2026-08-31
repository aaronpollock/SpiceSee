import Testing
import SpiceWire
import SpiceMedia

/// `SpiceKitBackend.translate` maps `SpiceMedia.StreamFrame` geometry into the seam's `GuestRect`.
/// Asymmetric values (x≠y, width≠height) so a top/left or width/height transposition fails here.
@Suite struct StreamSeamTests {
    @Test func streamFrameMapsToSeamGeometry() {
        let f = SpiceMedia.StreamFrame(streamID: 3, surfaceID: 0,
                                       dest: SpiceRect(top: 10, left: 20, bottom: 58, right: 84),
                                       clip: .rects([SpiceRect(top: 10, left: 20, bottom: 30, right: 40)]),
                                       width: 64, height: 48, pixels: [UInt8](repeating: 0, count: 64 * 48 * 4))
        let u = SpiceKitBackend.translate(f, viewportID: 0)
        #expect(u.dest == GuestRect(x: 20, y: 10, width: 64, height: 48))
        #expect(u.clip == [GuestRect(x: 20, y: 10, width: 20, height: 20)])
        #expect(u.streamID == 3)
        #expect(u.viewportID == 0)
        #expect(u.width == 64)
        #expect(u.height == 48)
    }

    @Test func noneClipMapsToNil() {
        let f = SpiceMedia.StreamFrame(streamID: 1, surfaceID: 0,
                                       dest: SpiceRect(top: 0, left: 0, bottom: 1, right: 1),
                                       clip: .none, width: 1, height: 1, pixels: [0, 0, 0, 255])
        #expect(SpiceKitBackend.translate(f, viewportID: 0).clip == nil)
    }
}
