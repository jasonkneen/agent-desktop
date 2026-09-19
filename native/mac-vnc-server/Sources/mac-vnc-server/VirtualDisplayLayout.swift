import CoreGraphics
import Foundation

struct VirtualDisplay: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

struct VirtualDisplayLayout: Equatable {
    let displays: [VirtualDisplay]
    let origin: CGPoint
    let scale: CGFloat
    let width: Int
    let height: Int

    static let empty = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)

    init(displays: [VirtualDisplay], scaleOverride: CGFloat? = nil) {
        self.displays = displays

        guard let first = displays.first else {
            origin = .zero
            scale = 1
            width = 1
            height = 1
            return
        }

        var union = first.bounds
        var maxScale: CGFloat = 1
        for display in displays {
            union = union.union(display.bounds)
            if display.bounds.width > 0 {
                maxScale = max(maxScale, CGFloat(display.pixelWidth) / display.bounds.width)
            }
            if display.bounds.height > 0 {
                maxScale = max(maxScale, CGFloat(display.pixelHeight) / display.bounds.height)
            }
        }

        origin = union.origin
        scale = scaleOverride ?? maxScale
        width = max(1, Int(ceil(union.width * scale)))
        height = max(1, Int(ceil(union.height * scale)))
    }

    init(displays: [VirtualDisplay], origin: CGPoint, scale: CGFloat, width: Int, height: Int) {
        self.displays = displays
        self.origin = origin
        self.scale = scale
        self.width = width
        self.height = height
    }

    func framebufferRect(for display: VirtualDisplay) -> CGRect {
        CGRect(
            x: (display.bounds.minX - origin.x) * scale,
            y: (display.bounds.minY - origin.y) * scale,
            width: display.bounds.width * scale,
            height: display.bounds.height * scale
        )
    }

    func globalPoint(framebufferX: Int, framebufferY: Int) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(framebufferX) / scale,
            y: origin.y + CGFloat(framebufferY) / scale
        )
    }
}
