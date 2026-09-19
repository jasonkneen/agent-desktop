import Foundation

enum RawEncoding {
    static func recommendedTileSize(requested: Rect, dirtyRects: [Rect]?) -> Int {
        guard let dirtyRects, !dirtyRects.isEmpty else {
            return 64
        }

        let requestedArea = max(0, requested.width) * max(0, requested.height)
        guard requestedArea > 0 else {
            return 64
        }

        var dirtyArea = 0
        for dirtyRect in dirtyRects {
            let x0 = max(requested.x, dirtyRect.x)
            let y0 = max(requested.y, dirtyRect.y)
            let x1 = min(requested.x + requested.width, dirtyRect.x + dirtyRect.width)
            let y1 = min(requested.y + requested.height, dirtyRect.y + dirtyRect.height)
            if x1 > x0, y1 > y0 {
                dirtyArea += (x1 - x0) * (y1 - y0)
            }
        }

        if dirtyArea * 64 <= requestedArea {
            return 16
        }
        if dirtyArea * 16 <= requestedArea {
            return 32
        }
        return 64
    }

    static func rectangles(
        current: Framebuffer,
        previous: Framebuffer?,
        requested: Rect,
        incremental: Bool,
        dirtyRects: [Rect]? = nil,
        tileSize: Int = 64
    ) -> [Rect] {
        let clipped = clip(requested, width: current.width, height: current.height)
        guard clipped.width > 0, clipped.height > 0 else {
            return []
        }

        guard incremental, let previous, previous.width == current.width, previous.height == current.height else {
            return [clipped]
        }

        let trustDirtyRects = shouldTrustDirtyRects(dirtyRects, within: clipped)
        var rects: [Rect] = []
        var activeRuns: [TileRunKey: Int] = [:]
        var y = clipped.y
        while y < clipped.y + clipped.height {
            var x = clipped.x
            let h = min(tileSize, clipped.y + clipped.height - y)
            var nextActiveRuns: [TileRunKey: Int] = [:]
            while x < clipped.x + clipped.width {
                let w = min(tileSize, clipped.x + clipped.width - x)
                var run = Rect(x: x, y: y, width: w, height: h)
                guard isDirtyCandidate(run, dirtyRects: dirtyRects),
                      trustDirtyRects || hasChanges(rect: run, current: current, previous: previous) else {
                    x += tileSize
                    continue
                }

                x += tileSize
                while x < clipped.x + clipped.width {
                    let nextWidth = min(tileSize, clipped.x + clipped.width - x)
                    let next = Rect(x: x, y: y, width: nextWidth, height: h)
                    guard isDirtyCandidate(next, dirtyRects: dirtyRects),
                          trustDirtyRects || hasChanges(rect: next, current: current, previous: previous) else {
                        break
                    }
                    run.width += next.width
                    x += tileSize
                }

                let key = TileRunKey(x: run.x, width: run.width)
                if let index = activeRuns[key],
                   rects[index].y + rects[index].height == run.y {
                    rects[index].height += run.height
                    nextActiveRuns[key] = index
                } else {
                    nextActiveRuns[key] = rects.count
                    rects.append(run)
                }
            }
            activeRuns = nextActiveRuns
            y += tileSize
        }

        return rects
    }

    static func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
        var output: [UInt8] = []
        try encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat, into: &output)
        return output
    }

    static func encode(
        rect: Rect,
        framebuffer: Framebuffer,
        pixelFormat: PixelFormat,
        into output: inout [UInt8]
    ) throws {
        guard pixelFormat.trueColor else {
            throw RFBError.unsupportedPixelFormat(pixelFormat)
        }
        guard pixelFormat.bitsPerPixel == 32 || pixelFormat.bitsPerPixel == 16 || pixelFormat.bitsPerPixel == 8 else {
            throw RFBError.unsupportedPixelFormat(pixelFormat)
        }

        output.removeAll(keepingCapacity: true)
        if pixelFormat == .serverDefault {
            encodeServerDefault(rect: rect, framebuffer: framebuffer, into: &output)
            return
        }

        output.reserveCapacity(rect.width * rect.height * Int(pixelFormat.bitsPerPixel / 8))

        for row in rect.y..<(rect.y + rect.height) {
            for column in rect.x..<(rect.x + rect.width) {
                let offset = row * framebuffer.bytesPerRow + column * 4
                let blue = framebuffer.bgra[offset]
                let green = framebuffer.bgra[offset + 1]
                let red = framebuffer.bgra[offset + 2]
                pixelFormat.appendPixelBytes(red: red, green: green, blue: blue, to: &output)
            }
        }
    }

    private static func encodeServerDefault(
        rect: Rect,
        framebuffer: Framebuffer,
        into output: inout [UInt8]
    ) {
        let rowByteCount = rect.width * 4
        output.append(contentsOf: repeatElement(0, count: rowByteCount * rect.height))

        output.withUnsafeMutableBytes { destination in
            framebuffer.bgra.withUnsafeBytes { source in
                for row in 0..<rect.height {
                    let sourceOffset = (rect.y + row) * framebuffer.bytesPerRow + rect.x * 4
                    let destinationOffset = row * rowByteCount
                    memcpy(
                        destination.baseAddress!.advanced(by: destinationOffset),
                        source.baseAddress!.advanced(by: sourceOffset),
                        rowByteCount
                    )

                    for alphaOffset in stride(from: destinationOffset + 3, to: destinationOffset + rowByteCount, by: 4) {
                        destination[alphaOffset] = 0
                    }
                }
            }
        }

    }

    private static func hasChanges(rect: Rect, current: Framebuffer, previous: Framebuffer) -> Bool {
        current.bgra.withUnsafeBytes { currentBytes in
            previous.bgra.withUnsafeBytes { previousBytes in
                for row in rect.y..<(rect.y + rect.height) {
                    let currentStart = row * current.bytesPerRow + rect.x * 4
                    let previousStart = row * previous.bytesPerRow + rect.x * 4
                    let byteCount = rect.width * 4
                    if memcmp(
                        currentBytes.baseAddress!.advanced(by: currentStart),
                        previousBytes.baseAddress!.advanced(by: previousStart),
                        byteCount
                    ) != 0 {
                        return true
                    }
                }
                return false
            }
        }
    }

    private static func isDirtyCandidate(_ rect: Rect, dirtyRects: [Rect]?) -> Bool {
        guard let dirtyRects else {
            return true
        }
        return dirtyRects.contains { dirtyRect in
            rect.x < dirtyRect.x + dirtyRect.width
                && dirtyRect.x < rect.x + rect.width
                && rect.y < dirtyRect.y + dirtyRect.height
                && dirtyRect.y < rect.y + rect.height
        }
    }

    private static func shouldTrustDirtyRects(_ dirtyRects: [Rect]?, within requested: Rect) -> Bool {
        guard let dirtyRects, !dirtyRects.isEmpty else {
            return false
        }

        let requestedArea = requested.width * requested.height
        guard requestedArea > 0 else {
            return false
        }

        var dirtyArea = 0
        for dirtyRect in dirtyRects {
            let x0 = max(requested.x, dirtyRect.x)
            let y0 = max(requested.y, dirtyRect.y)
            let x1 = min(requested.x + requested.width, dirtyRect.x + dirtyRect.width)
            let y1 = min(requested.y + requested.height, dirtyRect.y + dirtyRect.height)
            if x1 > x0, y1 > y0 {
                dirtyArea = min(requestedArea, dirtyArea + (x1 - x0) * (y1 - y0))
            }
            if dirtyArea * 4 >= requestedArea {
                return true
            }
        }

        return false
    }

    private static func clip(_ rect: Rect, width: Int, height: Int) -> Rect {
        let x0 = max(0, rect.x)
        let y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width)
        let y1 = min(height, rect.y + rect.height)
        return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private struct TileRunKey: Hashable {
        let x: Int
        let width: Int
    }
}
