import CoreGraphics

public enum ViewportScaling: Sendable, Equatable { case fit, oneToOne }

public struct GuestPoint: Sendable, Equatable {
    public var x: Int, y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// Where the guest surface sits inside a view, in view points with a top-left origin. Metal present,
/// the mouse mapping and the cursor overlay all derive from the same instance, so they cannot drift.
public struct ViewportTransform: Sendable, Equatable {
    public let scale: CGFloat
    public let origin: CGPoint
    public let surfaceSize: CGSize

    /// `backingScale` is the view's device-pixel ratio: `.oneToOne` means one guest pixel per *device*
    /// pixel, so on a 2x display it draws at half a point per pixel.
    public init(viewSize: CGSize, surfaceSize: CGSize, scaling: ViewportScaling, backingScale: CGFloat = 1) {
        self.surfaceSize = surfaceSize
        let pixel = scaling == .fit ? 1 : 1 / backingScale
        guard viewSize.width > 0, viewSize.height > 0, surfaceSize.width > 0, surfaceSize.height > 0 else {
            scale = pixel; origin = .zero; return
        }
        scale = scaling == .fit ? min(viewSize.width / surfaceSize.width, viewSize.height / surfaceSize.height) : pixel
        // Snap the centred origin to the device grid: a half-device-pixel offset would soften nearest
        // sampling, and rounding here keeps the mouse mapping, the overlay and the present in step.
        let x = (viewSize.width - surfaceSize.width * scale) / 2, y = (viewSize.height - surfaceSize.height * scale) / 2
        origin = CGPoint(x: (x * backingScale).rounded() / backingScale, y: (y * backingScale).rounded() / backingScale)
    }

    /// Guest pixel under a view point, clamped to the surface so dragging past the edge keeps working.
    public func guestPoint(fromView p: CGPoint) -> GuestPoint {
        let gx = ((p.x - origin.x) / scale).rounded(.down), gy = ((p.y - origin.y) / scale).rounded(.down)
        return GuestPoint(x: Int(min(max(gx, 0), max(surfaceSize.width - 1, 0))), y: Int(min(max(gy, 0), max(surfaceSize.height - 1, 0))))
    }

    public func viewRect(forGuest r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.origin.x * scale, y: origin.y + r.origin.y * scale, width: r.width * scale, height: r.height * scale)
    }
}
