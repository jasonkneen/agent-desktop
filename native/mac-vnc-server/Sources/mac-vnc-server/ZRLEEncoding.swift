import Foundation
import zlib

final class ZRLEEncoder {
    final class Transaction {
        private unowned let parent: ZRLEEncoder
        private var stream = z_stream()
        private var initialized = false
        private var pendingOutput: [UInt8]
        private let compressionLevel: Int32

        fileprivate init(parent: ZRLEEncoder) throws {
            self.parent = parent
            pendingOutput = parent.pendingOutput
            compressionLevel = parent.compressionLevel

            let status = zlib.deflateCopy(&stream, &parent.stream)
            guard status == Z_OK else {
                throw RFBError.protocolError("ZRLE deflateCopy failed with status \(status)")
            }
            initialized = true
        }

        deinit {
            if initialized {
                zlib.deflateEnd(&stream)
            }
        }

        func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
            guard pixelFormat.trueColor, pixelFormat.bitsPerPixel == 32 else {
                throw RFBError.unsupportedPixelFormat(pixelFormat)
            }

            ZRLEEncoder.tileBytes(
                rect: rect,
                framebuffer: framebuffer,
                pixelFormat: pixelFormat,
                into: &parent.rawBuffer
            )
            let compressed = try ZRLEEncoder.deflate(
                &parent.rawBuffer,
                stream: &stream,
                pendingOutput: &pendingOutput,
                outputChunk: &parent.outputChunk
            )
            return UInt32(compressed.count).beBytes + compressed
        }

        fileprivate func copyState(
            to destination: UnsafeMutablePointer<z_stream>
        ) throws -> (pendingOutput: [UInt8], compressionLevel: Int32) {
            stream.next_in = nil
            stream.avail_in = 0
            stream.next_out = nil
            stream.avail_out = 0
            let status = zlib.deflateCopy(destination, &stream)
            guard status == Z_OK else {
                throw RFBError.protocolError("ZRLE deflateCopy failed with status \(status)")
            }
            return (pendingOutput, compressionLevel)
        }
    }

    private var stream = z_stream()
    private var initialized = false
    private var compressionLevel = Int32(Z_BEST_SPEED)
    private var pendingOutput: [UInt8] = []
    fileprivate var rawBuffer: [UInt8] = []
    fileprivate var outputChunk = [UInt8](repeating: 0, count: 16 * 1024)

    init() throws {
        let status = deflateInit_(&stream, Z_BEST_SPEED, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw RFBError.protocolError("ZRLE deflateInit failed with status \(status)")
        }
        initialized = true
    }

    deinit {
        if initialized {
            deflateEnd(&stream)
        }
    }

    func setCompressionLevel(_ level: Int32) throws {
        guard (0...9).contains(Int(level)) else {
            throw RFBError.protocolError("invalid zlib compression level \(level)")
        }
        guard level != compressionLevel else {
            return
        }

        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        stream.next_in = nil
        stream.avail_in = 0

        repeat {
            let before = stream.total_out
            let chunkCount = chunk.count
            let status = chunk.withUnsafeMutableBytes { outputPointer in
                stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkCount)
                return zlib.deflateParams(&stream, level, Z_DEFAULT_STRATEGY)
            }

            guard status == Z_OK else {
                throw RFBError.protocolError("ZRLE deflateParams failed with status \(status)")
            }

            let produced = Int(stream.total_out - before)
            if produced > 0 {
                pendingOutput.append(contentsOf: chunk.prefix(produced))
            }
        } while stream.avail_out == 0

        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0
        compressionLevel = level
    }

    func beginTransaction() throws -> Transaction {
        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0
        return try Transaction(parent: self)
    }

    func commit(_ transaction: Transaction) throws {
        var oldStream = stream
        deflateEnd(&oldStream)
        stream = z_stream()
        initialized = false
        let metadata = try withUnsafeMutablePointer(to: &stream) { destination in
            try transaction.copyState(to: destination)
        }
        pendingOutput = metadata.pendingOutput
        compressionLevel = metadata.compressionLevel
        initialized = true
    }

    func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
        guard pixelFormat.trueColor, pixelFormat.bitsPerPixel == 32 else {
            throw RFBError.unsupportedPixelFormat(pixelFormat)
        }

        Self.tileBytes(
            rect: rect,
            framebuffer: framebuffer,
            pixelFormat: pixelFormat,
            into: &rawBuffer
        )
        let compressed = try Self.deflate(
            &rawBuffer,
            stream: &stream,
            pendingOutput: &pendingOutput,
            outputChunk: &outputChunk
        )
        return UInt32(compressed.count).beBytes + compressed
    }

    private static func deflate(
        _ bytes: inout [UInt8],
        stream: inout z_stream,
        pendingOutput: inout [UInt8],
        outputChunk: inout [UInt8]
    ) throws -> [UInt8] {
        var output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        output.reserveCapacity(max(1024, bytes.count / 3))

        let inputCount = bytes.count
        try bytes.withUnsafeMutableBytes { inputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(inputCount)

            repeat {
                let chunkCount = outputChunk.count
                let before = stream.total_out
                let status = outputChunk.withUnsafeMutableBytes { outputPointer in
                    stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkCount)
                    return zlib.deflate(&stream, Z_SYNC_FLUSH)
                }

                guard status == Z_OK else {
                    throw RFBError.protocolError("ZRLE deflate failed with status \(status)")
                }

                let produced = Int(stream.total_out - before)
                if produced > 0 {
                    output.append(contentsOf: outputChunk.prefix(produced))
                }
            } while stream.avail_out == 0
        }
        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0

        return output
    }

    fileprivate static func tileBytes(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) -> [UInt8] {
        var bytes: [UInt8] = []
        tileBytes(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat, into: &bytes)
        return bytes
    }

    fileprivate static func tileBytes(
        rect: Rect,
        framebuffer: Framebuffer,
        pixelFormat: PixelFormat,
        into bytes: inout [UInt8]
    ) {
        bytes.removeAll(keepingCapacity: true)
        bytes.reserveCapacity(rect.width * rect.height * pixelFormat.cPixelByteCount)

        var tileOutput: [UInt8] = []
        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileHeight = min(64, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileWidth = min(64, rect.x + rect.width - tileX)
                tileOutput.removeAll(keepingCapacity: true)
                tileOutput.reserveCapacity(1 + tileWidth * tileHeight * pixelFormat.cPixelByteCount)
                encodeTile(
                    rect: Rect(x: tileX, y: tileY, width: tileWidth, height: tileHeight),
                    framebuffer: framebuffer,
                    pixelFormat: pixelFormat,
                    into: &tileOutput
                )
                bytes.append(contentsOf: tileOutput)
                tileX += 64
            }
            tileY += 64
        }
    }

    private static func encodeTile(
        rect: Rect,
        framebuffer: Framebuffer,
        pixelFormat: PixelFormat,
        into output: inout [UInt8]
    ) {
        var pixels: [UInt32] = []
        pixels.reserveCapacity(rect.width * rect.height)

        var palette: [UInt32] = []
        palette.reserveCapacity(16)
        var paletteIndices: [UInt32: UInt8] = [:]
        paletteIndices.reserveCapacity(16)

        for row in rect.y..<(rect.y + rect.height) {
            for column in rect.x..<(rect.x + rect.width) {
                let offset = row * framebuffer.bytesPerRow + column * 4
                let blue = framebuffer.bgra[offset]
                let green = framebuffer.bgra[offset + 1]
                let red = framebuffer.bgra[offset + 2]
                let pixel = pixelFormat.packedPixel(red: red, green: green, blue: blue)
                pixels.append(pixel)
                if paletteIndices[pixel] == nil {
                    guard palette.count < 16 else {
                        continue
                    }
                    paletteIndices[pixel] = UInt8(palette.count)
                    palette.append(pixel)
                }
            }
        }

        var best = rawTile(pixels: pixels, pixelFormat: pixelFormat)
        if palette.count == 1 {
            let solid = solidTile(pixel: palette[0], pixelFormat: pixelFormat)
            if solid.count < best.count {
                best = solid
            }
        } else if (2...16).contains(palette.count) {
            let packed = packedPaletteTile(
                pixels: pixels,
                palette: palette,
                paletteIndices: paletteIndices,
                pixelFormat: pixelFormat,
                width: rect.width
            )
            if packed.count < best.count {
                best = packed
            }

            let paletteRLE = paletteRLETile(
                pixels: pixels,
                palette: palette,
                paletteIndices: paletteIndices,
                pixelFormat: pixelFormat
            )
            if paletteRLE.count < best.count {
                best = paletteRLE
            }
        }

        let plainRLE = plainRLETile(pixels: pixels, pixelFormat: pixelFormat)
        if plainRLE.count < best.count {
            best = plainRLE
        }
        output.append(contentsOf: best)
    }

    private static func rawTile(pixels: [UInt32], pixelFormat: PixelFormat) -> [UInt8] {
        var output: [UInt8] = [0]
        output.reserveCapacity(1 + pixels.count * pixelFormat.cPixelByteCount)
        for pixel in pixels {
            pixelFormat.appendCPixelValue(pixel, to: &output)
        }
        return output
    }

    private static func solidTile(pixel: UInt32, pixelFormat: PixelFormat) -> [UInt8] {
        var output: [UInt8] = [1]
        output.reserveCapacity(1 + pixelFormat.cPixelByteCount)
        pixelFormat.appendCPixelValue(pixel, to: &output)
        return output
    }

    private static func packedPaletteTile(
        pixels: [UInt32],
        palette: [UInt32],
        paletteIndices: [UInt32: UInt8],
        pixelFormat: PixelFormat,
        width: Int
    ) -> [UInt8] {
        let bitsPerIndex: Int
        switch palette.count {
        case 2:
            bitsPerIndex = 1
        case 3...4:
            bitsPerIndex = 2
        default:
            bitsPerIndex = 4
        }

        var output: [UInt8] = [UInt8(palette.count)]
        output.reserveCapacity(
            1 + palette.count * pixelFormat.cPixelByteCount
                + ((width * bitsPerIndex + 7) / 8) * max(1, pixels.count / max(1, width))
        )
        for pixel in palette {
            pixelFormat.appendCPixelValue(pixel, to: &output)
        }

        var index = 0
        let height = pixels.count / width
        for _ in 0..<height {
            var packed: UInt8 = 0
            var bits = 0
            for _ in 0..<width {
                packed = (packed << UInt8(bitsPerIndex))
                    | (paletteIndices[pixels[index]] ?? 0)
                bits += bitsPerIndex
                index += 1
                if bits == 8 {
                    output.append(packed)
                    packed = 0
                    bits = 0
                }
            }
            if bits > 0 {
                output.append(packed << UInt8(8 - bits))
            }
        }
        return output
    }

    private static func plainRLETile(pixels: [UInt32], pixelFormat: PixelFormat) -> [UInt8] {
        var output: [UInt8] = [128]
        var index = 0
        while index < pixels.count {
            let pixel = pixels[index]
            var end = index + 1
            while end < pixels.count, pixels[end] == pixel {
                end += 1
            }
            pixelFormat.appendCPixelValue(pixel, to: &output)
            appendRunLength(end - index, to: &output)
            index = end
        }
        return output
    }

    private static func paletteRLETile(
        pixels: [UInt32],
        palette: [UInt32],
        paletteIndices: [UInt32: UInt8],
        pixelFormat: PixelFormat
    ) -> [UInt8] {
        var output: [UInt8] = [UInt8(128 + palette.count)]
        output.reserveCapacity(1 + palette.count * pixelFormat.cPixelByteCount + pixels.count)
        for pixel in palette {
            pixelFormat.appendCPixelValue(pixel, to: &output)
        }

        var index = 0
        while index < pixels.count {
            let pixel = pixels[index]
            var end = index + 1
            while end < pixels.count, pixels[end] == pixel {
                end += 1
            }
            output.append(paletteIndices[pixel] ?? 0)
            appendRunLength(end - index, to: &output)
            index = end
        }
        return output
    }

    private static func appendRunLength(_ length: Int, to output: inout [UInt8]) {
        var remaining = max(0, length - 1)
        while remaining >= 255 {
            output.append(255)
            remaining -= 255
        }
        output.append(UInt8(remaining))
    }
}
