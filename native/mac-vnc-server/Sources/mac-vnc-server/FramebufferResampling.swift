import Accelerate
import CoreGraphics
import Foundation

enum FramebufferResampling {
    static func scale(_ framebuffer: Framebuffer, factor: CGFloat) throws -> Framebuffer {
        guard factor > 0 else {
            throw RFBError.captureFailed("framebuffer scale must be positive")
        }

        guard abs(factor - 1) > .ulpOfOne else {
            return framebuffer
        }

        let targetLayout: VirtualDisplayLayout
        if framebuffer.layout.displays.isEmpty {
            targetLayout = VirtualDisplayLayout(
                displays: [],
                origin: framebuffer.layout.origin,
                scale: framebuffer.layout.scale * factor,
                width: max(1, Int((CGFloat(framebuffer.width) * factor).rounded())),
                height: max(1, Int((CGFloat(framebuffer.height) * factor).rounded()))
            )
        } else {
            targetLayout = VirtualDisplayLayout(
                displays: framebuffer.layout.displays,
                scaleOverride: framebuffer.layout.scale * factor
            )
        }

        let targetBytesPerRow = targetLayout.width * 4
        var pixels = [UInt8](repeating: 0, count: targetBytesPerRow * targetLayout.height)
        let status = framebuffer.bgra.withUnsafeBytes { sourceBytes in
            pixels.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBaseAddress = sourceBytes.baseAddress,
                      let destinationBaseAddress = destinationBytes.baseAddress else {
                    return kvImageNullPointerArgument
                }

                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBaseAddress),
                    height: vImagePixelCount(framebuffer.height),
                    width: vImagePixelCount(framebuffer.width),
                    rowBytes: framebuffer.bytesPerRow
                )
                var destination = vImage_Buffer(
                    data: destinationBaseAddress,
                    height: vImagePixelCount(targetLayout.height),
                    width: vImagePixelCount(targetLayout.width),
                    rowBytes: targetBytesPerRow
                )

                return vImageScale_ARGB8888(
                    &source,
                    &destination,
                    nil,
                    vImage_Flags(kvImageHighQualityResampling)
                )
            }
        }

        guard status == kvImageNoError else {
            throw RFBError.captureFailed("framebuffer scaling failed with status \(status)")
        }

        return Framebuffer(
            width: targetLayout.width,
            height: targetLayout.height,
            bytesPerRow: targetBytesPerRow,
            bgra: pixels,
            layout: targetLayout,
            sequence: framebuffer.sequence,
            dirtyRects: scaledDirtyRects(
                framebuffer.dirtyRects,
                xScale: CGFloat(targetLayout.width) / CGFloat(framebuffer.width),
                yScale: CGFloat(targetLayout.height) / CGFloat(framebuffer.height),
                width: targetLayout.width,
                height: targetLayout.height
            )
        )
    }

    private static func scaledDirtyRects(
        _ dirtyRects: [Rect]?,
        xScale: CGFloat,
        yScale: CGFloat,
        width: Int,
        height: Int
    ) -> [Rect]? {
        guard let dirtyRects else {
            return nil
        }

        return dirtyRects.compactMap { dirtyRect in
            let x0 = max(0, Int((CGFloat(dirtyRect.x) * xScale).rounded(.down)))
            let y0 = max(0, Int((CGFloat(dirtyRect.y) * yScale).rounded(.down)))
            let x1 = min(width, Int((CGFloat(dirtyRect.x + dirtyRect.width) * xScale).rounded(.up)))
            let y1 = min(height, Int((CGFloat(dirtyRect.y + dirtyRect.height) * yScale).rounded(.up)))
            guard x1 > x0, y1 > y0 else {
                return nil
            }
            return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
}
