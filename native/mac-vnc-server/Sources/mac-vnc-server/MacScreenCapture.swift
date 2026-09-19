import ApplicationServices
import CoreGraphics
import Foundation

final class MacScreenCapture: FramebufferSource {
    private let scale: CGFloat

    init(scale: Double = 1) {
        self.scale = CGFloat(scale)
    }

    func capture() throws -> Framebuffer {
        let displayIDs = try activeDisplayIDs()
        let displays = displayIDs.compactMap { displayID -> (VirtualDisplay, CGImage)? in
            guard let image = CGDisplayCreateImage(displayID) else {
                return nil
            }
            let bounds = CGDisplayBounds(displayID)
            let display = VirtualDisplay(
                id: displayID,
                bounds: bounds,
                pixelWidth: image.width,
                pixelHeight: image.height
            )
            return (display, image)
        }

        guard !displays.isEmpty else {
            throw RFBError.captureFailed("no capturable displays; check Screen Recording permission")
        }

        let layout = VirtualDisplayLayout(displays: displays.map(\.0), scaleOverride: scale)
        let bytesPerRow = layout.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * layout.height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: layout.width,
            height: layout.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw RFBError.captureFailed("could not create framebuffer context")
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        context.interpolationQuality = .low

        for (display, image) in displays {
            let rect = layout.framebufferRect(for: display)
            let drawRect = CGRect(
                x: rect.minX,
                y: CGFloat(layout.height) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            context.draw(image, in: drawRect)
        }

        return Framebuffer(width: layout.width, height: layout.height, bytesPerRow: bytesPerRow, bgra: pixels, layout: layout)
    }

    static func printDisplayDiagnostics() {
        do {
            let displayIDs = try activeDisplayIDs()
            print("Displays: \(displayIDs.count)")
            for (index, displayID) in displayIDs.enumerated() {
                let bounds = CGDisplayBounds(displayID)
                let width = CGDisplayPixelsWide(displayID)
                let height = CGDisplayPixelsHigh(displayID)
                print("- display=\(index + 1) id=\(displayID) bounds=\(bounds) pixels=\(width)x\(height)")
            }
        } catch {
            print("Displays: unavailable (\(error.localizedDescription))")
        }
    }

    static func activeDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &count)
        guard result == .success else {
            throw RFBError.captureFailed("CGGetActiveDisplayList failed: \(result.rawValue)")
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        result = CGGetActiveDisplayList(count, &displays, &count)
        guard result == .success else {
            throw RFBError.captureFailed("CGGetActiveDisplayList failed: \(result.rawValue)")
        }

        return Array(displays.prefix(Int(count)))
    }

    private func activeDisplayIDs() throws -> [CGDirectDisplayID] {
        try Self.activeDisplayIDs()
    }
}
