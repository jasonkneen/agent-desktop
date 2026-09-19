import Foundation

struct PixelFormat: Equatable {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: Bool
    var trueColor: Bool
    var redMax: UInt16
    var greenMax: UInt16
    var blueMax: UInt16
    var redShift: UInt8
    var greenShift: UInt8
    var blueShift: UInt8

    static let serverDefault = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndian: Bool,
        trueColor: Bool,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count == 16 else {
            throw RFBError.protocolError("pixel format must be 16 bytes")
        }
        bitsPerPixel = bytes[0]
        depth = bytes[1]
        bigEndian = bytes[2] != 0
        trueColor = bytes[3] != 0
        redMax = UInt16.be(bytes[4], bytes[5])
        greenMax = UInt16.be(bytes[6], bytes[7])
        blueMax = UInt16.be(bytes[8], bytes[9])
        redShift = bytes[10]
        greenShift = bytes[11]
        blueShift = bytes[12]
    }

    var bytes: [UInt8] {
        [
            bitsPerPixel,
            depth,
            bigEndian ? 1 : 0,
            trueColor ? 1 : 0
        ] + redMax.beBytes + greenMax.beBytes + blueMax.beBytes + [
            redShift,
            greenShift,
            blueShift,
            0,
            0,
            0
        ]
    }

    func pixelBytes(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(bitsPerPixel / 8))
        appendPixelBytes(red: red, green: green, blue: blue, to: &bytes)
        return bytes
    }

    func cPixelBytes(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cPixelByteCount)
        appendCPixelBytes(red: red, green: green, blue: blue, to: &bytes)
        return bytes
    }

    func appendPixelBytes(red: UInt8, green: UInt8, blue: UInt8, to output: inout [UInt8]) {
        appendIntegerBytes(
            packedPixel(red: red, green: green, blue: blue),
            byteCount: Int(bitsPerPixel / 8),
            to: &output
        )
    }

    func appendCPixelBytes(red: UInt8, green: UInt8, blue: UInt8, to output: inout [UInt8]) {
        let pixel = packedPixel(red: red, green: green, blue: blue)
        appendCPixelValue(pixel, to: &output)
    }

    func appendCPixelValue(_ pixel: UInt32, to output: inout [UInt8]) {
        let byteCount = Int(bitsPerPixel / 8)

        guard usesThreeByteCPixel else {
            appendIntegerBytes(pixel, byteCount: byteCount, to: &output)
            return
        }

        if bigEndian {
            for index in stride(from: byteCount - 2, through: 0, by: -1) {
                output.append(UInt8((pixel >> UInt32(index * 8)) & 0xff))
            }
        } else {
            for index in 0..<(byteCount - 1) {
                output.append(UInt8((pixel >> UInt32(index * 8)) & 0xff))
            }
        }
    }

    var cPixelByteCount: Int {
        usesThreeByteCPixel ? 3 : Int(bitsPerPixel / 8)
    }

    private var usesThreeByteCPixel: Bool {
        bitsPerPixel == 32
            && depth <= 24
            && redMax <= 255
            && greenMax <= 255
            && blueMax <= 255
            && redShift < 24
            && greenShift < 24
            && blueShift < 24
    }

    func packedPixel(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        let redValue = scaled(UInt32(red), max: UInt32(redMax)) << UInt32(redShift)
        let greenValue = scaled(UInt32(green), max: UInt32(greenMax)) << UInt32(greenShift)
        let blueValue = scaled(UInt32(blue), max: UInt32(blueMax)) << UInt32(blueShift)
        return redValue | greenValue | blueValue
    }

    private func appendIntegerBytes(_ value: UInt32, byteCount: Int, to output: inout [UInt8]) {
        if bigEndian {
            for index in stride(from: byteCount - 1, through: 0, by: -1) {
                output.append(UInt8((value >> UInt32(index * 8)) & 0xff))
            }
        } else {
            for index in 0..<byteCount {
                output.append(UInt8((value >> UInt32(index * 8)) & 0xff))
            }
        }
    }

    private func scaled(_ component: UInt32, max: UInt32) -> UInt32 {
        guard max != 255 else {
            return component
        }
        return (component * max) / 255
    }
}

struct Framebuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra: [UInt8]
    let layout: VirtualDisplayLayout
    let sequence: UInt64?
    let dirtyRects: [Rect]?

    init(
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil,
        bgra: [UInt8],
        layout: VirtualDisplayLayout,
        sequence: UInt64? = nil,
        dirtyRects: [Rect]? = nil
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow ?? width * 4
        self.bgra = bgra
        self.layout = layout
        self.sequence = sequence
        self.dirtyRects = dirtyRects
    }
}

struct Rect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

protocol FramebufferSource {
    func capture() throws -> Framebuffer
}

protocol FramebufferSequenceSource {
    func currentSequence() throws -> UInt64?
}

protocol InputRecoverySource {
    func requestRecoveryAfterInput()
}

protocol CaptureFrameRateController {
    func registerCaptureRateConsumer(_ consumer: ObjectIdentifier, fps: Int)
    func updateCaptureRate(
        _ fps: Int,
        consumer: ObjectIdentifier,
        reconfigureCapture: Bool
    )
    func unregisterCaptureRateConsumer(_ consumer: ObjectIdentifier)
}

protocol InputController {
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout)
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool)
    func releaseKeys()
}

protocol ClipboardBridge {
    func localTextIfChanged() -> String?
    func setRemoteText(_ text: String)
}

enum RFBError: LocalizedError {
    case protocolError(String)
    case socketError(String)
    case unsupportedPixelFormat(PixelFormat)
    case captureFailed(String)
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .protocolError(let message):
            return "protocol error: \(message)"
        case .socketError(let message):
            return "socket error: \(message)"
        case .unsupportedPixelFormat(let format):
            return "unsupported pixel format: \(format)"
        case .captureFailed(let message):
            return "capture failed: \(message)"
        case .authenticationFailed:
            return "authentication failed"
        }
    }
}

extension UInt16 {
    static func be(_ high: UInt8, _ low: UInt8) -> UInt16 {
        (UInt16(high) << 8) | UInt16(low)
    }

    var beBytes: [UInt8] {
        [UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
    }
}

extension UInt32 {
    static func be(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    var beBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
    }
}
