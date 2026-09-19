import Foundation

struct ServerConfig {
    let bindAddress: String
    let port: UInt16
    let password: String?
    let passwordFromConfig: Bool
    let fps: Int
    let scale: Double
    let encodingPreference: EncodingPreference
    let displaySelection: DisplaySelection
    let verbose: Bool
    let clipboardSync: Bool
    let adaptiveStreaming: Bool
    let adaptiveFrameRate: Bool
}

enum DisplaySelection: Equatable {
    case automatic
    case all
    case display(Int)
}

enum EncodingPreference: String {
    case auto
    case zrle
    case zlib
    case raw
}

enum RFBEncoding: Int32 {
    case raw = 0
    case zlib = 6
    case zrle = 16
}

enum RFBStandardEncoding {
    static let copyRect: Int32 = 1
    static let tight: Int32 = 7
}

enum RFBPseudoEncoding {
    static let xCursor: Int32 = -240
    static let richCursor: Int32 = -239
    static let desktopSize: Int32 = -223
    static let extendedDesktopSize: Int32 = -308
}

struct RFBClientCapabilities: Equatable {
    let advertisedEncodings: [Int32]
    let supportsRaw: Bool
    let supportsCopyRect: Bool
    let supportsTight: Bool
    let supportsZlib: Bool
    let supportsZRLE: Bool
    let supportsXCursor: Bool
    let supportsRichCursor: Bool
    let supportsDesktopSize: Bool
    let supportsExtendedDesktopSize: Bool
    let isAppleScreenSharingClient: Bool

    init(encodings: [Int32]) {
        advertisedEncodings = encodings
        supportsRaw = encodings.contains(RFBEncoding.raw.rawValue)
        supportsCopyRect = encodings.contains(RFBStandardEncoding.copyRect)
        supportsTight = encodings.contains(RFBStandardEncoding.tight)
        supportsZlib = encodings.contains(RFBEncoding.zlib.rawValue)
        supportsZRLE = encodings.contains(RFBEncoding.zrle.rawValue)
        supportsXCursor = encodings.contains(RFBPseudoEncoding.xCursor)
        supportsRichCursor = encodings.contains(RFBPseudoEncoding.richCursor)
        supportsDesktopSize = encodings.contains(RFBPseudoEncoding.desktopSize)
        supportsExtendedDesktopSize = encodings.contains(RFBPseudoEncoding.extendedDesktopSize)
        isAppleScreenSharingClient = encodings.contains(1011)
            || encodings.contains(1002)
            || encodings.contains(1100)
            || encodings.contains(1104)
    }

    var summary: String {
        let names = [
            supportsRaw ? "raw" : nil,
            supportsCopyRect ? "copyrect" : nil,
            supportsTight ? "tight" : nil,
            supportsZlib ? "zlib" : nil,
            supportsZRLE ? "zrle" : nil,
            supportsXCursor || supportsRichCursor ? "cursor" : nil,
            supportsDesktopSize || supportsExtendedDesktopSize ? "resize" : nil
        ].compactMap { $0 }

        return "encodings=[\(advertisedEncodings.map(String.init).joined(separator: ","))] " +
            "features=[\(names.joined(separator: ","))] " +
            "apple=\(isAppleScreenSharingClient)"
    }

    var supportsDynamicResize: Bool {
        supportsDesktopSize && !isAppleScreenSharingClient
    }
}

final class RFBServer {
    private let config: ServerConfig
    private let capture: FramebufferSource
    private let input: InputController
    private let clipboard: ClipboardBridge
    private let logger: ServerLogger

    init(
        config: ServerConfig,
        capture: FramebufferSource,
        input: InputController,
        clipboard: ClipboardBridge,
        logger: ServerLogger
    ) {
        self.config = config
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
        self.logger = logger
    }

    func run() throws {
        let listener = try ListeningSocket(bindAddress: config.bindAddress, port: config.port)
        logger.info("mac-vnc-server \(AppVersion.current)")
        logger.info("mac-vnc-server listening on \(config.bindAddress):\(config.port)")
        let fpsDescription = config.adaptiveFrameRate ? "auto(60-45-30)" : "\(config.fps)"
        logger.info("fps=\(fpsDescription) scale=\(config.scale) encoding=\(config.encodingPreference.rawValue) display=\(config.displaySelection.description)")
        logger.info("password configured: \(config.password != nil)")
        logger.info("clipboard sync: \(config.clipboardSync ? "enabled" : "disabled")")
        logger.info("Connect with vnc://\(config.bindAddress == "0.0.0.0" ? "127.0.0.1" : config.bindAddress):\(config.port)")

        while true {
            let client = try listener.acceptClient()
            do {
                try RFBClientSession(
                    socket: client,
                    password: config.password,
                    fps: config.fps,
                    encodingPreference: config.encodingPreference,
                    capture: capture,
                    input: input,
                    clipboard: clipboard,
                    clipboardSync: config.clipboardSync,
                    adaptiveStreaming: config.adaptiveStreaming,
                    adaptiveFrameRate: config.adaptiveFrameRate,
                    logger: logger
                ).run()
            } catch {
                logger.warning("client disconnected: \(error.localizedDescription)")
            }
        }
    }
}

extension DisplaySelection {
    var description: String {
        switch self {
        case .automatic:
            return "auto"
        case .all:
            return "all"
        case .display(let index):
            return "\(index)"
        }
    }
}

struct AdaptiveFrameRateController {
    static let frameRates = [60, 45, 30]

    private(set) var index: Int
    private var slowFrameStreak = 0
    private var fastFrameStreak = 0

    init(startingFrameRate: Int = 60) {
        index = Self.frameRates.firstIndex(of: startingFrameRate) ?? 0
    }

    var frameRate: Int {
        Self.frameRates[index]
    }

    mutating func update(frameDuration: TimeInterval) -> Int? {
        let target = 1.0 / Double(frameRate)
        if frameDuration > target * 1.15 {
            slowFrameStreak += 1
            fastFrameStreak = 0
            guard slowFrameStreak >= 6 else {
                return nil
            }

            slowFrameStreak = 0
            guard index + 1 < Self.frameRates.count else {
                return nil
            }

            index += 1
            return frameRate
        }

        guard frameDuration < target * 0.70 else {
            slowFrameStreak = 0
            fastFrameStreak = 0
            return nil
        }

        fastFrameStreak += 1
        slowFrameStreak = 0
        guard fastFrameStreak >= 300 else {
            return nil
        }

        fastFrameStreak = 0
        guard index > 0 else {
            return nil
        }

        index -= 1
        return frameRate
    }

    mutating func reduceForBackpressure() -> Int? {
        slowFrameStreak = 0
        fastFrameStreak = 0
        guard index + 1 < Self.frameRates.count else {
            return nil
        }
        index += 1
        return frameRate
    }
}

struct AdaptiveScaleController {
    static let scales = [1.0, 0.75, 0.67]

    private(set) var index = 0
    private var overloadTime: TimeInterval = 0
    private var healthyTime: TimeInterval = 0

    var scale: Double {
        Self.scales[index]
    }

    mutating func update(
        frameDuration: TimeInterval,
        encodeDuration: TimeInterval,
        writeDuration: TimeInterval,
        frameInterval: TimeInterval,
        minimumFrameInterval: TimeInterval,
        staleRetries: Int,
        hadNetworkStall: Bool
    ) -> Double? {
        let encodeBudget = minimumFrameInterval * 1.10
        let overloaded = hadNetworkStall
            || frameDuration > frameInterval * 1.25
            || encodeDuration > encodeBudget
            || writeDuration > frameInterval * 1.10
            || staleRetries >= 2

        if overloaded {
            healthyTime = 0
            overloadTime += max(frameDuration, frameInterval)
            guard overloadTime >= 0.5 else {
                return nil
            }
            overloadTime = 0
            guard index + 1 < Self.scales.count else {
                return nil
            }
            index += 1
            return scale
        }

        overloadTime = 0
        guard index > 0,
              !hadNetworkStall,
              staleRetries == 0,
              frameDuration < frameInterval * 0.85,
              encodeDuration < encodeBudget * 0.8,
              writeDuration < frameInterval * 0.8 else {
            healthyTime = 0
            return nil
        }

        healthyTime += max(frameDuration, frameInterval)
        guard healthyTime >= 5 else {
            return nil
        }
        healthyTime = 0
        index -= 1
        return scale
    }
}

final class RFBClientSession: @unchecked Sendable {
    private struct FramebufferUpdateRequest {
        let incremental: Bool
        let rect: Rect
    }

    private enum EncodingTransaction {
        case zlib(ZlibEncoder.Transaction)
        case zrle(ZRLEEncoder.Transaction)
    }

    private struct PreparedFramebufferUpdate {
        let framebuffer: Framebuffer
        let encoding: RFBEncoding
        let rects: [Rect]
        let encodedRects: [[UInt8]]
        let desktopSizeChanged: Bool
        let changedPixels: Int
        let uncompressedBytes: Int
        let payloadBytes: Int
        let captureDuration: TimeInterval
        let diffDuration: TimeInterval
        let encodeDuration: TimeInterval
        let transaction: EncodingTransaction?
    }

    private let socket: ClientSocket
    private let password: String?
    private let minimumFrameInterval: TimeInterval
    private var frameInterval: TimeInterval
    private let encodingPreference: EncodingPreference
    private let capture: FramebufferSource
    private let input: InputController
    private let clipboard: ClipboardBridge
    private let clipboardSync: Bool
    private let adaptiveStreaming: Bool
    private let adaptiveFrameRate: Bool
    private let logger: ServerLogger
    private var pixelFormat = PixelFormat.serverDefault
    private var clientCapabilities = RFBClientCapabilities(encodings: [RFBEncoding.raw.rawValue])
    private var previousFramebuffer: Framebuffer?
    private var currentLayout = VirtualDisplayLayout.empty
    private var lastFramebufferUpdate = Date.distantPast
    private var hasSentFramebufferUpdate = false
    private let zrleEncoder: ZRLEEncoder
    private let zlibEncoder: ZlibEncoder
    private let state = NSCondition()
    private var stopped = false
    private var latestUpdateRequest: FramebufferUpdateRequest?
    private var activeUpdateRequest: FramebufferUpdateRequest?
    private var writerError: Error?
    private var captureRateConsumer: ObjectIdentifier?
    private var networkStallNotifications = 0
    private var networkStalls = 0
    private var staleFrameRetries = 0
    private var updatesSent = 0
    private var bytesSent = 0
    private var adaptiveFrameRateController: AdaptiveFrameRateController
    private var adaptiveScaleController = AdaptiveScaleController()
    private var adaptiveScale = 1.0
    private var frameHadNetworkStall = false
    private var forceFullFramebuffer = false

    init(
        socket: ClientSocket,
        password: String?,
        fps: Int,
        encodingPreference: EncodingPreference,
        capture: FramebufferSource,
        input: InputController,
        clipboard: ClipboardBridge,
        clipboardSync: Bool,
        adaptiveStreaming: Bool,
        adaptiveFrameRate: Bool,
        logger: ServerLogger
    ) throws {
        self.socket = socket
        self.password = password
        minimumFrameInterval = 1.0 / Double(fps)
        frameInterval = minimumFrameInterval
        self.encodingPreference = encodingPreference
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
        self.clipboardSync = clipboardSync
        self.adaptiveStreaming = adaptiveStreaming
        self.adaptiveFrameRate = adaptiveFrameRate
        self.logger = logger
        adaptiveFrameRateController = AdaptiveFrameRateController(startingFrameRate: fps)
        zrleEncoder = try ZRLEEncoder()
        zlibEncoder = try ZlibEncoder()
    }

    func run() throws {
        let initialFrame = try capture.capture()
        currentLayout = initialFrame.layout
        previousFramebuffer = initialFrame

        try handshake(initialFrame: initialFrame)
        let captureRateConsumer = ObjectIdentifier(self)
        self.captureRateConsumer = captureRateConsumer
        (capture as? CaptureFrameRateController)?.registerCaptureRateConsumer(
            captureRateConsumer,
            fps: Int((1.0 / minimumFrameInterval).rounded())
        )
        startFramebufferWriter()
        defer {
            stopFramebufferWriter()
            input.releaseKeys()
            if let captureRateConsumer = self.captureRateConsumer {
                (capture as? CaptureFrameRateController)?.unregisterCaptureRateConsumer(captureRateConsumer)
            }
        }

        while true {
            if let writerError = consumeWriterError() {
                throw writerError
            }
            let messageType = try socket.readExact(1)[0]
            switch messageType {
            case 0:
                try handleSetPixelFormat()
            case 2:
                try handleSetEncodings()
            case 3:
                try handleFramebufferUpdateRequestMessage()
            case 4:
                try handleKeyEvent()
            case 5:
                try handlePointerEvent()
            case 6:
                try handleClientCutText()
            default:
                throw RFBError.protocolError("unsupported client message \(messageType)")
            }
        }
    }

    private func handshake(initialFrame: Framebuffer) throws {
        let preferLegacyHandshake = password != nil
        try socket.writeString(preferLegacyHandshake ? "RFB 003.003\n" : "RFB 003.008\n")
        let clientVersion = try socket.readExact(12)
        let versionText = String(bytes: clientVersion, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let isRFB33 = preferLegacyHandshake || versionText == "RFB 003.003"

        if isRFB33 {
            if let password {
                try socket.writeAll(UInt32(2).beBytes)
                try authenticate(password: password)
            } else {
                try socket.writeAll(UInt32(1).beBytes)
            }
        } else {
            if password == nil {
                try socket.writeAll([1, 1])
            } else {
                try socket.writeAll([2, 2, 1])
            }

            let selectedSecurity = try socket.readExact(1)[0]
            switch selectedSecurity {
            case 1:
                try socket.writeAll(UInt32(0).beBytes)
            case 2:
                guard let password else {
                    try socket.writeAll(UInt32(1).beBytes)
                    throw RFBError.authenticationFailed
                }
                try authenticate(password: password)
            default:
                throw RFBError.protocolError("unsupported security type \(selectedSecurity)")
            }
        }

        _ = try socket.readExact(1)
        try sendServerInit(framebuffer: initialFrame)
        logger.info("client connected: \(versionText), framebuffer \(initialFrame.width)x\(initialFrame.height)")
    }

    private func authenticate(password: String) throws {
        var challenge = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, challenge.count, &challenge)
        if status != errSecSuccess {
            for index in challenge.indices {
                challenge[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }

        try socket.writeAll(challenge)
        let response = try socket.readExact(16)
        if try VNCAuth.response(challenge: challenge, password: password) == response {
            try socket.writeAll(UInt32(0).beBytes)
        } else {
            try socket.writeAll(UInt32(1).beBytes)
            throw RFBError.authenticationFailed
        }
    }

    private func sendServerInit(framebuffer: Framebuffer) throws {
        var bytes: [UInt8] = []
        bytes += UInt16(framebuffer.width).beBytes
        bytes += UInt16(framebuffer.height).beBytes
        bytes += PixelFormat.serverDefault.bytes
        let name = "mac-vnc-server".data(using: .utf8) ?? Data()
        bytes += UInt32(name.count).beBytes
        bytes += Array(name)
        try socket.writeAll(bytes)
    }

    private func handleSetPixelFormat() throws {
        _ = try socket.readExact(3)
        let bytes = try socket.readExact(16)
        let requested = try PixelFormat(bytes: bytes)
        guard requested.trueColor, [8, 16, 32].contains(requested.bitsPerPixel) else {
            throw RFBError.unsupportedPixelFormat(requested)
        }
        state.lock()
        pixelFormat = requested
        state.unlock()
    }

    private func handleSetEncodings() throws {
        _ = try socket.readExact(1)
        let countBytes = try socket.readExact(2)
        let count = Int(UInt16.be(countBytes[0], countBytes[1]))
        let bytes = try socket.readExact(count * 4)
        let encodings = stride(from: 0, to: bytes.count, by: 4).map { offset in
            Int32(bitPattern: UInt32.be(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]))
        }
        let capabilities = RFBClientCapabilities(encodings: encodings)
        state.lock()
        clientCapabilities = capabilities
        state.unlock()
        logger.verbose("client capabilities: \(capabilities.summary)")
    }

    private func handleFramebufferUpdateRequestMessage() throws {
        let header = try socket.readExact(9)
        let incremental = header[0] != 0
        let x = Int(UInt16.be(header[1], header[2]))
        let y = Int(UInt16.be(header[3], header[4]))
        let width = Int(UInt16.be(header[5], header[6]))
        let height = Int(UInt16.be(header[7], header[8]))

        state.lock()
        latestUpdateRequest = FramebufferUpdateRequest(
            incremental: incremental,
            rect: Rect(x: x, y: y, width: width, height: height)
        )
        state.signal()
        state.unlock()
    }

    private func startFramebufferWriter() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            do {
                try framebufferWriterLoop()
            } catch {
                socket.shutdown()
                state.lock()
                writerError = error
                stopped = true
                state.broadcast()
                state.unlock()
            }
        }
    }

    private func framebufferWriterLoop() throws {
        while true {
            let request = waitForUpdateRequest()
            guard let request else {
                return
            }
            try sendFramebufferUpdate(request)
        }
    }

    private func waitForUpdateRequest() -> FramebufferUpdateRequest? {
        state.lock()
        defer { state.unlock() }

        while latestUpdateRequest == nil && activeUpdateRequest == nil && !stopped {
            state.wait()
        }
        guard !stopped else {
            return nil
        }

        if let request = latestUpdateRequest {
            latestUpdateRequest = nil
            activeUpdateRequest = request
            return request
        }

        guard let activeUpdateRequest else {
            return nil
        }

        return FramebufferUpdateRequest(
            incremental: true,
            rect: activeUpdateRequest.rect
        )
    }

    private func stopFramebufferWriter() {
        state.lock()
        stopped = true
        state.broadcast()
        state.unlock()
        socket.shutdown()
    }

    private func sendFramebufferUpdate(_ request: FramebufferUpdateRequest) throws {
        frameHadNetworkStall = false
        throttleFrameRate()
        let frameStarted = Date()
        let measureTimings = logger.isVerbose
        state.lock()
        let allowStaleRetry = !clientCapabilities.isAppleScreenSharingClient
        state.unlock()

        var staleRetries = 0
        var captureDuration = 0.0
        var diffDuration = 0.0
        let prepared: PreparedFramebufferUpdate

        while true {
            let candidate = try prepareFramebufferUpdate(request, measureTimings: measureTimings)
            if measureTimings {
                captureDuration += candidate.captureDuration
                diffDuration += candidate.diffDuration
            }

            let canRetryStaleFrame = candidate.encodeDuration <= minimumFrameInterval * 1.5
            if allowStaleRetry,
               staleRetries < 1,
               canRetryStaleFrame,
               try isStale(candidate.framebuffer) {
                staleRetries += 1
                continue
            }

            prepared = candidate
            break
        }

        if let transaction = prepared.transaction {
            try commit(transaction)
        }

        if prepared.desktopSizeChanged {
            let header = [0, 0] + UInt16(1).beBytes
            let resizeResponse = desktopSizeResponse(for: prepared.framebuffer)
            try socket.writeAll([header, resizeResponse], onStall: { [self] in
                noteNetworkStall()
            })

            state.lock()
            updatesSent += 1
            bytesSent += header.count + resizeResponse.count
            currentLayout = prepared.framebuffer.layout
            forceFullFramebuffer = true
            networkStallNotifications = 0
            state.unlock()
            return
        }

        let rectCount = prepared.encodedRects.count
        guard rectCount <= Int(UInt16.max) else {
            throw RFBError.protocolError("too many rectangles in framebuffer update")
        }
        let header = [0, 0] + UInt16(rectCount).beBytes
        let writeStarted = DispatchTime.now().uptimeNanoseconds
        var updateChunks = [[UInt8]]()
        updateChunks.reserveCapacity(1 + prepared.encodedRects.count)
        updateChunks.append(header)
        updateChunks.append(contentsOf: prepared.encodedRects)
        try socket.writeAll(updateChunks, onStall: { [self] in
            noteNetworkStall()
        })
        let updateBytes = updateChunks.reduce(0) { $0 + $1.count }
        let writeDuration = elapsedSeconds(since: writeStarted)

        let frameDuration = Date().timeIntervalSince(frameStarted)
        state.lock()
        staleFrameRetries += staleRetries
        updatesSent += 1
        bytesSent += updateBytes
        if measureTimings && (updatesSent == 1 || updatesSent % 60 == 0) {
            let compressionRatio = prepared.payloadBytes > 0
                ? Double(prepared.uncompressedBytes) / Double(prepared.payloadBytes)
                : 0
            logger.verbose(
                "updates=\(updatesSent) encoding=\(prepared.encoding) last_rects=\(prepared.rects.count) " +
                "bytes=\(updateBytes) total_bytes=\(bytesSent) " +
                "changed_pixels=\(prepared.changedPixels) " +
                "raw_bytes=\(prepared.uncompressedBytes) payload_bytes=\(prepared.payloadBytes) " +
                "compression_ratio=\(String(format: "%.2f", compressionRatio)) " +
                "stale_retries=\(staleFrameRetries) network_stalls=\(networkStalls) " +
                "frame_ms=\(Int(frameDuration * 1_000)) " +
                "capture_ms=\(Int(captureDuration * 1_000)) " +
                "diff_ms=\(Int(diffDuration * 1_000)) " +
                "encode_ms=\(Int(prepared.encodeDuration * 1_000)) " +
                "write_ms=\(Int(writeDuration * 1_000))"
            )
        }
        previousFramebuffer = prepared.framebuffer
        currentLayout = prepared.framebuffer.layout
        hasSentFramebufferUpdate = true
        forceFullFramebuffer = false
        networkStallNotifications = 0
        state.unlock()

        let hadNetworkStall = frameHadNetworkStall
        try adaptStreaming(
            frameDuration: frameDuration,
            encodeDuration: prepared.encodeDuration,
            writeDuration: writeDuration,
            encoding: prepared.encoding
        )
        adaptScale(
            frameDuration: frameDuration,
            encodeDuration: prepared.encodeDuration,
            writeDuration: writeDuration,
            staleRetries: staleRetries,
            hadNetworkStall: hadNetworkStall
        )
        adaptFrameRate(frameDuration: frameDuration)

        if clipboardSync, let text = clipboard.localTextIfChanged() {
            try sendServerCutText(text)
        }
    }

    private func prepareFramebufferUpdate(
        _ request: FramebufferUpdateRequest,
        measureTimings: Bool
    ) throws -> PreparedFramebufferUpdate {
        let captureStarted = measureTimings ? Date() : .distantPast
        let capturedFramebuffer = try capture.capture()
        let scale: CGFloat
        let format: PixelFormat
        let encoding: RFBEncoding
        let previous: Framebuffer?
        let sentBefore: Bool
        let supportsResize: Bool
        let forceFull: Bool
        state.lock()
        scale = CGFloat(adaptiveScale)
        format = pixelFormat
        encoding = selectedEncodingLocked()
        previous = previousFramebuffer
        sentBefore = hasSentFramebufferUpdate
        supportsResize = clientCapabilities.supportsDynamicResize
        let useEncodingTransaction = !clientCapabilities.isAppleScreenSharingClient
        forceFull = forceFullFramebuffer
        state.unlock()

        let framebuffer = try FramebufferResampling.scale(capturedFramebuffer, factor: scale)
        let captureDuration = measureTimings ? Date().timeIntervalSince(captureStarted) : 0
        let framebufferSizeChanged = sentBefore
            && (previous?.width != framebuffer.width || previous?.height != framebuffer.height)
        let resizeUpdate = framebufferSizeChanged && supportsResize && !forceFull
        let requested = framebufferSizeChanged || forceFull
            ? Rect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
            : request.rect
        let shouldDiff = sentBefore && request.incremental && !framebufferSizeChanged && !forceFull
        let diffStarted = logger.isVerbose ? Date() : .distantPast
        let dirtyRects: [Rect]?
        if shouldDiff,
           let previous,
           let sequence = framebuffer.sequence,
           let previousSequence = previous.sequence,
           sequence == previousSequence &+ 1 {
            dirtyRects = framebuffer.dirtyRects
        } else {
            dirtyRects = nil
        }

        let rects: [Rect]
        if resizeUpdate {
            rects = []
        } else if shouldDiff,
           let previous,
           let sequence = framebuffer.sequence,
           previous.sequence == sequence {
            rects = []
        } else {
            let tileSize = RawEncoding.recommendedTileSize(
                requested: requested,
                dirtyRects: dirtyRects
            )
            rects = RawEncoding.rectangles(
                current: framebuffer,
                previous: previous,
                requested: requested,
                incremental: shouldDiff,
                dirtyRects: dirtyRects,
                tileSize: tileSize
            )
        }
        let diffDuration = logger.isVerbose ? Date().timeIntervalSince(diffStarted) : 0
        let transaction: EncodingTransaction?
        if resizeUpdate {
            transaction = nil
        } else if useEncodingTransaction {
            switch encoding {
            case .zlib:
                transaction = .zlib(try zlibEncoder.beginTransaction())
            case .zrle:
                transaction = .zrle(try zrleEncoder.beginTransaction())
            case .raw:
                transaction = nil
            }
        } else {
            transaction = nil
        }

        var encodedRects: [[UInt8]] = []
        encodedRects.reserveCapacity(rects.count)
        var encodeDuration = 0.0
        var changedPixels = 0
        var uncompressedBytes = 0
        var payloadBytes = 0

        for rect in rects {
            let encodeStarted = DispatchTime.now().uptimeNanoseconds
            let payload: [UInt8]
            let encodingBytes = UInt32(bitPattern: encoding.rawValue).beBytes
            switch encoding {
            case .zrle:
                if case .zrle(let transaction) = transaction {
                    payload = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                } else {
                    payload = try zrleEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                }
            case .zlib:
                if case .zlib(let transaction) = transaction {
                    payload = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                } else {
                    payload = try zlibEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                }
            case .raw:
                payload = try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            }
            encodeDuration += elapsedSeconds(since: encodeStarted)
            changedPixels += rect.width * rect.height
            uncompressedBytes += rect.width * rect.height * format.cPixelByteCount
            let encodedPayloadBytes: Int
            switch encoding {
            case .zlib, .zrle:
                encodedPayloadBytes = max(0, payload.count - 4)
            case .raw:
                encodedPayloadBytes = payload.count
            }
            payloadBytes += encodedPayloadBytes

            var rectResponse: [UInt8] = []
            rectResponse.reserveCapacity(12 + payload.count)
            rectResponse += UInt16(rect.x).beBytes
            rectResponse += UInt16(rect.y).beBytes
            rectResponse += UInt16(rect.width).beBytes
            rectResponse += UInt16(rect.height).beBytes
            rectResponse += encodingBytes
            rectResponse += payload
            encodedRects.append(rectResponse)
        }

        return PreparedFramebufferUpdate(
            framebuffer: framebuffer,
            encoding: encoding,
            rects: rects,
            encodedRects: encodedRects,
            desktopSizeChanged: resizeUpdate,
            changedPixels: changedPixels,
            uncompressedBytes: uncompressedBytes,
            payloadBytes: payloadBytes,
            captureDuration: captureDuration,
            diffDuration: diffDuration,
            encodeDuration: encodeDuration,
            transaction: transaction
        )
    }

    private func isStale(_ framebuffer: Framebuffer) throws -> Bool {
        guard let sequence = framebuffer.sequence else {
            return false
        }
        let latestSequence: UInt64?
        if let sequenceSource = capture as? FramebufferSequenceSource {
            latestSequence = try sequenceSource.currentSequence()
        } else {
            latestSequence = try capture.capture().sequence
        }
        guard let latestSequence else {
            return false
        }
        return latestSequence != sequence
    }

    private func commit(_ transaction: EncodingTransaction) throws {
        switch transaction {
        case .zlib(let transaction):
            try zlibEncoder.commit(transaction)
        case .zrle(let transaction):
            try zrleEncoder.commit(transaction)
        }
    }

    private func desktopSizeResponse(for framebuffer: Framebuffer) -> [UInt8] {
        [0, 0]
            + UInt16(framebuffer.width).beBytes
            + UInt16(framebuffer.height).beBytes
            + UInt32(bitPattern: RFBPseudoEncoding.desktopSize).beBytes
    }

    private func consumeWriterError() -> Error? {
        state.lock()
        defer { state.unlock() }
        let error = writerError
        writerError = nil
        return error
    }

    private func selectedEncoding() -> RFBEncoding {
        state.lock()
        defer { state.unlock() }
        return selectedEncodingLocked()
    }

    private func selectedEncodingLocked() -> RFBEncoding {
        switch encodingPreference {
        case .raw:
            return .raw
        case .zrle:
            return clientCapabilities.supportsZRLE ? .zrle : .raw
        case .zlib:
            return clientCapabilities.supportsZlib ? .zlib : .raw
        case .auto:
            if clientCapabilities.isAppleScreenSharingClient, clientCapabilities.supportsZlib {
                return .zlib
            }
            if clientCapabilities.supportsZRLE {
                return .zrle
            }
            return clientCapabilities.supportsZlib ? .zlib : .raw
        }
    }

    private func throttleFrameRate() {
        let elapsed = Date().timeIntervalSince(lastFramebufferUpdate)
        if elapsed < frameInterval {
            usleep(useconds_t((frameInterval - elapsed) * 1_000_000))
        }
        lastFramebufferUpdate = Date()
    }

    private func adaptStreaming(
        frameDuration: TimeInterval,
        encodeDuration: TimeInterval,
        writeDuration: TimeInterval,
        encoding: RFBEncoding
    ) throws {
        guard adaptiveStreaming else {
            return
        }

        let target = frameInterval
        guard encodeDuration > 0 else {
            return
        }
        guard frameDuration > target * 1.25 else {
            return
        }

        if encodeDuration >= writeDuration {
            try setCompressionLevel(1, for: encoding)
        } else {
            try setCompressionLevel(3, for: encoding)
        }
    }

    private func adaptScale(
        frameDuration: TimeInterval,
        encodeDuration: TimeInterval,
        writeDuration: TimeInterval,
        staleRetries: Int,
        hadNetworkStall: Bool
    ) {
        guard adaptiveStreaming,
              supportsDynamicResize(),
              updatesSent > 3 else {
            return
        }

        guard let scale = adaptiveScaleController.update(
            frameDuration: frameDuration,
            encodeDuration: encodeDuration,
            writeDuration: writeDuration,
            frameInterval: frameInterval,
            minimumFrameInterval: minimumFrameInterval,
            staleRetries: staleRetries,
            hadNetworkStall: hadNetworkStall
        ) else {
            return
        }

        adaptiveScale = scale
        logger.verbose("adaptive scale changed to \(String(format: "%.2f", scale))")
    }

    private func adaptFrameRate(frameDuration: TimeInterval) {
        guard adaptiveFrameRate else {
            return
        }

        guard let frameRate = adaptiveFrameRateController.update(frameDuration: frameDuration) else {
            return
        }

        frameInterval = 1.0 / Double(frameRate)
        updateCaptureRateIfSafe(frameRate)
        logger.verbose("adaptive fps changed to \(frameRate)")
    }

    private func noteNetworkStall() {
        frameHadNetworkStall = true
        networkStalls += 1
        guard adaptiveFrameRate else {
            return
        }

        networkStallNotifications += 1
        guard networkStallNotifications >= 2 else {
            return
        }
        networkStallNotifications = 0
        guard let frameRate = adaptiveFrameRateController.reduceForBackpressure() else {
            return
        }

        frameInterval = 1.0 / Double(frameRate)
        updateCaptureRateIfSafe(frameRate)
        logger.verbose("adaptive fps changed to \(frameRate) due to network backpressure")
    }

    private func updateCaptureRateIfSafe(_ frameRate: Int) {
        state.lock()
        let reconfigureCapture = !clientCapabilities.isAppleScreenSharingClient
        let captureRateConsumer = self.captureRateConsumer
        state.unlock()

        guard let captureRateConsumer else {
            return
        }
        (capture as? CaptureFrameRateController)?.updateCaptureRate(
            frameRate,
            consumer: captureRateConsumer,
            reconfigureCapture: reconfigureCapture
        )
    }

    private func elapsedSeconds(since start: UInt64) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func setCompressionLevel(_ level: Int32, for encoding: RFBEncoding) throws {
        switch encoding {
        case .zrle:
            try zrleEncoder.setCompressionLevel(level)
        case .zlib:
            try zlibEncoder.setCompressionLevel(level)
        case .raw:
            return
        }
    }

    private func supportsDynamicResize() -> Bool {
        state.lock()
        defer { state.unlock() }
        return clientCapabilities.supportsDynamicResize
    }

    private func handleKeyEvent() throws {
        let bytes = try socket.readExact(7)
        let down = bytes[0] != 0
        let keysym = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
        state.lock()
        let mapAltToCommand = clientCapabilities.isAppleScreenSharingClient
        state.unlock()
        requestCaptureRecoveryAfterInput()
        input.key(down: down, keysym: keysym, mapAltToCommand: mapAltToCommand)
    }

    private func handlePointerEvent() throws {
        let bytes = try socket.readExact(5)
        let mask = bytes[0]
        let x = UInt16.be(bytes[1], bytes[2])
        let y = UInt16.be(bytes[3], bytes[4])
        state.lock()
        let layout = currentLayout
        state.unlock()
        requestCaptureRecoveryAfterInput()
        input.pointer(buttonMask: mask, x: x, y: y, layout: layout)
    }

    private func requestCaptureRecoveryAfterInput() {
        (capture as? InputRecoverySource)?.requestRecoveryAfterInput()
    }

    private func handleClientCutText() throws {
        _ = try socket.readExact(3)
        let lengthBytes = try socket.readExact(4)
        let length = Int(UInt32.be(lengthBytes[0], lengthBytes[1], lengthBytes[2], lengthBytes[3]))
        let bytes = try socket.readExact(length)
        if clipboardSync {
            let text = String(decoding: bytes, as: UTF8.self)
            clipboard.setRemoteText(text)
        }
    }

    private func sendServerCutText(_ text: String) throws {
        let payload = Array(text.utf8)
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += UInt32(payload.count).beBytes
        bytes += payload
        try socket.writeAll(bytes)
    }
}
