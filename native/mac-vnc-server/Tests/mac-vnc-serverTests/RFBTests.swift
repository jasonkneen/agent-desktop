import CoreGraphics
import Foundation
import Testing
import zlib
@testable import mac_vnc_server

@Test func cliParsesWakeupCommand() throws {
    let isWakeupCommand = if case .wakeup = try CLI.parse(arguments: ["wakeup"]) {
        true
    } else {
        false
    }

    #expect(isWakeupCommand)
}

@Test func cliParsesVerboseRunFlag() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--verbose"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.verbose)
}

@Test func cliParsesServiceFlagAndRemovesItFromServiceArguments() throws {
    guard case .service(let config, let arguments) = try CLI.parse(
        arguments: ["--service", "--port", "5901", "--verbose"]
    ) else {
        Issue.record("expected service command")
        return
    }

    #expect(config.port == 5901)
    #expect(config.verbose)
    #expect(arguments == ["--port", "5901", "--verbose"])
}

@Test func cliParsesServiceRestartCommand() throws {
    guard case .serviceRestart = try CLI.parse(arguments: ["--service-restart"]) else {
        Issue.record("expected service restart command")
        return
    }
}

@Test func launchAgentPlistRunsInTheUserUIAsAKeepAliveService() throws {
    let homeDirectory = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let data = try LaunchAgentService.plistData(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/mac-vnc-server"),
        arguments: ["--port", "5901"],
        homeDirectory: homeDirectory
    )
    let propertyList = try #require(
        PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    )

    #expect(propertyList["Label"] as? String == LaunchAgentService.label)
    #expect(propertyList["RunAtLoad"] as? Bool == true)
    #expect(propertyList["KeepAlive"] as? Bool == true)
    #expect(propertyList["LimitLoadToSessionType"] as? String == "Aqua")
    #expect(propertyList["ProcessType"] as? String == "Interactive")
    #expect(propertyList["WorkingDirectory"] as? String == homeDirectory.path)
    #expect(
        propertyList["ProgramArguments"] as? [String]
            == ["/usr/local/bin/mac-vnc-server", "--port", "5901"]
    )
    #expect(
        (propertyList["EnvironmentVariables"] as? [String: String])?["HOME"]
            == homeDirectory.path
    )
    #expect(
        propertyList["StandardOutPath"] as? String
            == "/Users/tester/Library/Logs/mac-vnc-server/stdout.log"
    )
    #expect(
        propertyList["StandardErrorPath"] as? String
            == "/Users/tester/Library/Logs/mac-vnc-server/stderr.log"
    )
}

@Test func clientCapabilitiesIdentifyStandardAndAppleFeatures() {
    let capabilities = RFBClientCapabilities(encodings: [
        RFBEncoding.raw.rawValue,
        RFBStandardEncoding.copyRect,
        RFBStandardEncoding.tight,
        RFBEncoding.zlib.rawValue,
        RFBEncoding.zrle.rawValue,
        RFBPseudoEncoding.richCursor,
        RFBPseudoEncoding.desktopSize,
        RFBPseudoEncoding.extendedDesktopSize,
        1011
    ])

    #expect(capabilities.supportsRaw)
    #expect(capabilities.supportsCopyRect)
    #expect(capabilities.supportsTight)
    #expect(capabilities.supportsZlib)
    #expect(capabilities.supportsZRLE)
    #expect(capabilities.supportsRichCursor)
    #expect(capabilities.supportsExtendedDesktopSize)
    #expect(capabilities.isAppleScreenSharingClient)
    #expect(!capabilities.supportsDynamicResize)
    #expect(capabilities.summary.contains("copyrect"))
    #expect(capabilities.summary.contains("apple=true"))

    let genericResizeCapabilities = RFBClientCapabilities(encodings: [
        RFBEncoding.raw.rawValue,
        RFBPseudoEncoding.desktopSize
    ])
    #expect(genericResizeCapabilities.supportsDynamicResize)
}

@Test func keySymMapperMapsNavigationAndModifierKeys() {
    #expect(KeySymMapper.keyStroke(for: 0xff51)?.keyCode == 123)
    #expect(KeySymMapper.keyStroke(for: 0xff52)?.keyCode == 126)
    #expect(KeySymMapper.keyStroke(for: 0xff54)?.keyCode == 125)
    #expect(KeySymMapper.keyStroke(for: 0x09)?.keyCode == 48)
    #expect(KeySymMapper.keyStroke(for: 0x09)?.keyCode == KeySymMapper.keyStroke(for: 0xff09)?.keyCode)
    #expect(KeySymMapper.keyStroke(for: 0x01000009)?.keyCode == 48)
    #expect(KeySymMapper.keyCode(for: 0x01000060) == 50)
    #expect(KeySymMapper.keyStroke(for: 0xfe20)?.keyCode == 48)
    #expect(KeySymMapper.keyStroke(for: 0xfe20)?.needsShift == true)
    #expect(KeySymMapper.deadKey(for: 0xfe50, flags: [], recentShift: false) == .grave)
    #expect(KeySymMapper.deadKey(for: 0xfe51, flags: [], recentShift: false) == .acute)
    #expect(KeySymMapper.deadKey(for: 0xfe52, flags: [], recentShift: false) == .circumflex)
    #expect(KeySymMapper.deadKey(for: 0xfe53, flags: [], recentShift: false) == .tilde)
    #expect(KeySymMapper.deadKey(for: 0xfe57, flags: [], recentShift: false) == .diaeresis)
    #expect(KeySymMapper.deadKey(for: 0x01000300, flags: [], recentShift: false) == .grave)
    #expect(KeySymMapper.modifier(for: 0xffe1)?.keyCode == 56)
    #expect(KeySymMapper.modifier(for: 0xffe5)?.keyCode == 57)
    #expect(KeySymMapper.modifier(for: 0xffeb)?.flag == .maskCommand)
    #expect(KeySymMapper.modifier(for: 0xffe2)?.eventFlags.rawValue == 0x00020004)
    #expect(KeySymMapper.modifier(for: 0xffe7)?.eventFlags.rawValue == 0x00100008)
    #expect(KeySymMapper.modifier(for: 0xffe9, mapAltToCommand: true)?.keyCode == 55)
    #expect(KeySymMapper.modifier(for: 0xffea, mapAltToCommand: true)?.keyCode == 54)
}

@Test func modifierCandidatesCoverAppleAndStandardMappings() {
    let metaLeftCandidates = KeySymMapper.modifierCandidates(for: 0xffe7).map(\.keyCode)
    #expect(metaLeftCandidates.contains(55))
    #expect(metaLeftCandidates.contains(58))

    let altLeftCandidates = KeySymMapper.modifierCandidates(for: 0xffe9).map(\.keyCode)
    #expect(altLeftCandidates.contains(58))
    #expect(altLeftCandidates.contains(55))
}

@Test func printableDeadKeysymsPreserveCompositionIntent() {
    #expect(KeySymMapper.deadKey(for: 0x7e, flags: [], recentShift: false) == .tilde)
    #expect(KeySymMapper.deadKey(for: 0x22, flags: [], recentShift: false) == .diaeresis)
    #expect(KeySymMapper.deadKey(for: 0x27, flags: [], recentShift: false) == .acute)
    #expect(KeySymMapper.deadKey(for: 0x27, flags: [], recentShift: true) == .diaeresis)
    #expect(KeySymMapper.deadKey(for: 0x60, flags: [], recentShift: true) == .tilde)
    #expect(KeySymMapper.keyCode(for: 0x10002dc) == 50)
    #expect(KeySymMapper.keyCode(for: 0x1000308) == 39)
    #expect(KeySymMapper.printableKeyStroke(for: 0xff08) == nil)
}

@Test func shiftRequiredKeysPreserveAnActiveRightShift() {
    guard let shiftedKey = KeySymMapper.keyStroke(for: 0xfe20) else {
        Issue.record("expected a shift-required key mapping")
        return
    }

    let rightShift = CGEventFlags(rawValue: 0x00020004)
    #expect(KeySymMapper.eventFlags(for: shiftedKey, base: rightShift).rawValue == rightShift.rawValue)
    #expect(KeySymMapper.eventFlags(for: shiftedKey, base: []).rawValue == 0x00020002)
}

@Test func pointerMotionUsesTheActiveButton() {
    let right = MacInputController.pointerMotion(for: 0b00000100)
    #expect(right.type == .rightMouseDragged)
    #expect(right.button == .right)

    let center = MacInputController.pointerMotion(for: 0b00000010)
    #expect(center.type == .otherMouseDragged)
    #expect(center.button == .center)

    let idle = MacInputController.pointerMotion(for: 0)
    #expect(idle.type == .mouseMoved)
    #expect(idle.button == .left)
}

@Test func scrollDeltaAcceleratesOnlyForFastEvents() {
    #expect(ScrollDeltaPolicy.targetMultiplier(interval: nil) == 1)
    #expect(ScrollDeltaPolicy.targetMultiplier(interval: 0.020) == 1)
    #expect(ScrollDeltaPolicy.targetMultiplier(interval: 0.010) > 2)
    #expect(ScrollDeltaPolicy.targetMultiplier(interval: 0.008) == 4)
    #expect(ScrollDeltaPolicy.smoothMultiplier(current: 1, target: 4) < 4)
}

@Test func cliDisablesClipboardSyncByDefault() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(!config.clipboardSync)
}

@Test func cliDefaultsToAdaptiveFrameRate() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.fps == 60)
    #expect(config.adaptiveFrameRate)
}

@Test func cliUsesGeneratedPasswordConfigByDefault() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.password == nil)
    #expect(config.passwordFromConfig)
}

@Test func cliAcceptsExplicitPasswordOverride() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--password", "override"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.password == "override")
    #expect(!config.passwordFromConfig)
}

@Test func cliKeepsNoPasswordAsExplicitOverride() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--no-password"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.password == nil)
    #expect(!config.passwordFromConfig)
}

@Test func passwordStoreCreatesAndReusesEightBytePassword() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-vnc-server-password-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstPassword = try PasswordStore.loadOrCreate(in: directory)
    let secondPassword = try PasswordStore.loadOrCreate(in: directory)
    let fileURL = directory.appendingPathComponent(PasswordStore.configFileName)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)

    #expect(firstPassword == secondPassword)
    #expect(firstPassword.utf8.count == PasswordStore.passwordLength)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func passwordStoreRejectsSymlinkedPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-vnc-server-password-links-\(UUID().uuidString)", isDirectory: true)
    let fileManager = FileManager.default
    defer { try? fileManager.removeItem(at: root) }

    let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
    let linkedDirectory = root.appendingPathComponent("config-directory", isDirectory: true)
    try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: targetDirectory)

    var rejectedDirectoryLink = false
    do {
        _ = try PasswordStore.loadOrCreate(in: linkedDirectory)
    } catch {
        rejectedDirectoryLink = true
    }
    #expect(rejectedDirectoryLink)

    try fileManager.removeItem(at: linkedDirectory)
    let configURL = targetDirectory.appendingPathComponent(PasswordStore.configFileName)
    let targetURL = targetDirectory.appendingPathComponent("target.json")
    try Data(#"{"password":"ABCDEFGH"}"#.utf8).write(to: targetURL)
    try fileManager.createSymbolicLink(at: configURL, withDestinationURL: targetURL)

    var rejectedFileLink = false
    do {
        _ = try PasswordStore.loadOrCreate(in: targetDirectory)
    } catch {
        rejectedFileLink = true
    }
    #expect(rejectedFileLink)
}

@Test func cliParsesFixedFrameRate() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--fps", "30"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.fps == 30)
    #expect(!config.adaptiveFrameRate)
}

@Test func cliParsesAutoFrameRate() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--fps", "auto"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.fps == 60)
    #expect(config.adaptiveFrameRate)
}

@Test func adaptiveFrameRateUses60To45To30WithHysteresis() {
    var controller = AdaptiveFrameRateController(startingFrameRate: 60)
    #expect(controller.frameRate == 60)

    for _ in 0..<5 {
        #expect(controller.update(frameDuration: 0.020) == nil)
    }
    #expect(controller.update(frameDuration: 0.020) == 45)
    #expect(controller.frameRate == 45)

    for index in 0..<6 {
        #expect(controller.update(frameDuration: 0.030) == (index == 5 ? 30 : nil))
    }
    #expect(controller.frameRate == 30)

    for _ in 0..<299 {
        #expect(controller.update(frameDuration: 0.010) == nil)
    }
    #expect(controller.update(frameDuration: 0.010) == 45)
    #expect(controller.update(frameDuration: 0.010) == nil)
    #expect(controller.frameRate == 45)

    for _ in 0..<298 {
        #expect(controller.update(frameDuration: 0.010) == nil)
    }
    #expect(controller.update(frameDuration: 0.010) == 60)
    #expect(controller.frameRate == 60)
}

@Test func adaptiveScaleDropsOnlyAfterSustainedOverloadAndRecovers() {
    var controller = AdaptiveScaleController()
    let frameInterval = 1.0 / 60.0
    var firstScaleChange: Double?

    for _ in 0..<40 {
        if let scale = controller.update(
            frameDuration: 0.020,
            encodeDuration: 0.020,
            writeDuration: 0,
            frameInterval: frameInterval,
            minimumFrameInterval: frameInterval,
            staleRetries: 0,
            hadNetworkStall: false
        ) {
            firstScaleChange = scale
            break
        }
    }

    #expect(firstScaleChange == 0.75)
    #expect(controller.scale == 0.75)

    var recovered = false
    for _ in 0..<400 {
        if let scale = controller.update(
            frameDuration: 0.010,
            encodeDuration: 0.004,
            writeDuration: 0.002,
            frameInterval: frameInterval,
            minimumFrameInterval: frameInterval,
            staleRetries: 0,
            hadNetworkStall: false
        ) {
            recovered = scale == 1.0
            if recovered {
                break
            }
        }
    }

    #expect(recovered)
    #expect(controller.scale == 1.0)
}

@Test func framebufferResamplingPreservesLayoutAndScalesDirtyRects() throws {
    let layout = VirtualDisplayLayout(
        displays: [],
        origin: .zero,
        scale: 1,
        width: 4,
        height: 4
    )
    let framebuffer = Framebuffer(
        width: 4,
        height: 4,
        bgra: [UInt8](repeating: 0x80, count: 4 * 4 * 4),
        layout: layout,
        sequence: 7,
        dirtyRects: [Rect(x: 1, y: 1, width: 2, height: 2)]
    )

    let scaled = try FramebufferResampling.scale(framebuffer, factor: 0.5)

    #expect(scaled.width == 2)
    #expect(scaled.height == 2)
    #expect(scaled.bgra.count == 2 * 2 * 4)
    #expect(scaled.sequence == 7)
    #expect(scaled.layout.scale == 0.5)
    #expect(scaled.dirtyRects == [Rect(x: 0, y: 0, width: 2, height: 2)])
}

@Test func cliParsesClipboardSyncFlag() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--clipboard-sync"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.clipboardSync)
}

@Test func cliDisablesAdaptiveStreamingWhenRequested() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--no-adaptive"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(!config.adaptiveStreaming)
    #expect(!config.adaptiveFrameRate)
}

@Test func cliParsesUpdateCommand() throws {
    guard case .update = try CLI.parse(arguments: ["update"]) else {
        Issue.record("expected update command")
        return
    }
}

@Test func semanticVersionsTreatDevelopmentBuildAsOlderThanRelease() {
    guard let development = SemanticVersion("0.0.0-development"),
          let release = SemanticVersion("v0.2.5"),
          let olderRelease = SemanticVersion("0.2.4"),
          let sameRelease = SemanticVersion("0.2.5") else {
        Issue.record("expected valid semantic versions")
        return
    }

    #expect(development < release)
    #expect(olderRelease < release)
    #expect(release == sameRelease)
}

@Test func noDisplaysErrorSuggestsWakeupCommand() {
    let message = CLI.errorMessage(for: RFBError.captureFailed("ScreenCaptureKit found no displays"))

    #expect(message.contains("mac-vnc-server wakeup"))
}

@Test func pixelFormatRoundTrip() throws {
    let format = PixelFormat.serverDefault
    #expect(try PixelFormat(bytes: format.bytes) == format)
}

@Test func rawEncodingUsesLittleEndianBGRForDefaultFormat() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x33, 0x22, 0x11, 0xff], layout: layout)
    let bytes = try RawEncoding.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )

    #expect(bytes == [0x33, 0x22, 0x11, 0x00])
}

@Test func rawEncodingHonorsClientRequestedColorShifts() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x33, 0x22, 0x11, 0xff], layout: layout)
    let noVNCFormat = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 0,
        greenShift: 8,
        blueShift: 16
    )
    let bytes = try RawEncoding.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: noVNCFormat
    )

    #expect(bytes == [0x11, 0x22, 0x33, 0x00])
}

@Test func incrementalRawEncodingReturnsChangedTilesOnly() {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let previous = Framebuffer(width: 2, height: 1, bgra: [
        0, 0, 0, 0,
        0, 0, 0, 0
    ], layout: layout)
    let current = Framebuffer(width: 2, height: 1, bgra: [
        0, 0, 0, 0,
        1, 0, 0, 0
    ], layout: layout)

    let rects = RawEncoding.rectangles(
        current: current,
        previous: previous,
        requested: Rect(x: 0, y: 0, width: 2, height: 1),
        incremental: true,
        tileSize: 1
    )

    #expect(rects == [Rect(x: 1, y: 0, width: 1, height: 1)])
}

@Test func incrementalRawEncodingCoalescesAdjacentChangedTiles() {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 2)
    let previous = Framebuffer(
        width: 2,
        height: 2,
        bgra: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        layout: layout
    )
    let current = Framebuffer(
        width: 2,
        height: 2,
        bgra: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
        layout: layout
    )

    let rects = RawEncoding.rectangles(
        current: current,
        previous: previous,
        requested: Rect(x: 0, y: 0, width: 2, height: 2),
        incremental: true,
        tileSize: 1
    )

    #expect(rects == [Rect(x: 0, y: 0, width: 2, height: 2)])
}

@Test func incrementalRawEncodingUsesDirtyRectsToSkipCleanTiles() {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 4, height: 1)
    let previous = Framebuffer(
        width: 4,
        height: 1,
        bgra: [UInt8](repeating: 0, count: 16),
        layout: layout
    )
    var currentBytes = [UInt8](repeating: 0, count: 16)
    currentBytes[0] = 1
    currentBytes[12] = 1
    let current = Framebuffer(width: 4, height: 1, bgra: currentBytes, layout: layout)

    let rects = RawEncoding.rectangles(
        current: current,
        previous: previous,
        requested: Rect(x: 0, y: 0, width: 4, height: 1),
        incremental: true,
        dirtyRects: [Rect(x: 3, y: 0, width: 1, height: 1)],
        tileSize: 1
    )

    #expect(rects == [Rect(x: 3, y: 0, width: 1, height: 1)])
}

@Test func rawEncodingUsesSmallerTilesForSmallDirtyRegions() {
    #expect(
        RawEncoding.recommendedTileSize(
            requested: Rect(x: 0, y: 0, width: 1920, height: 1080),
            dirtyRects: [Rect(x: 10, y: 10, width: 8, height: 8)]
        ) == 16
    )
    #expect(
        RawEncoding.recommendedTileSize(
            requested: Rect(x: 0, y: 0, width: 1920, height: 1080),
            dirtyRects: [Rect(x: 0, y: 0, width: 640, height: 480)]
        ) == 64
    )
}

@Test func zlibEncodingRoundTripsRawPayload() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let encoder = try ZlibEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    #expect(compressedLength == payload.count - 4)

    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 8)
    let decompressedCount = decompressed.count
    let status = compressed.withUnsafeMutableBytes { inputPointer in
        decompressed.withUnsafeMutableBytes { outputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressedLength)
            stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(decompressedCount)
            return inflate(&stream, Z_SYNC_FLUSH)
        }
    }

    #expect(status == Z_OK)
    #expect(decompressed == [0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00])
}

@Test func zlibCompressionLevelCanChangeBetweenUpdates() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let encoder = try ZlibEncoder()
    let first = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    try encoder.setCompressionLevel(6)
    let second = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )

    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var decompressed = [UInt8]()
    for payload in [first, second] {
        let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
        var compressed = Array(payload.dropFirst(4))
        var output = [UInt8](repeating: 0, count: 8)
        let outputCount = output.count
        let status = compressed.withUnsafeMutableBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(compressedLength)
                stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }

        #expect(status == Z_OK)
        decompressed += output.prefix(8 - Int(stream.avail_out))
    }

    #expect(decompressed == [
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00,
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00
    ])
}

@Test func discardedZlibTransactionDoesNotAdvanceStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZlibEncoder()

    do {
        let transaction = try encoder.beginTransaction()
        _ = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    }

    let payload = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    #expect(try inflatePayloads([payload], outputCounts: [8]) == [
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00
    ])
}

@Test func committedZlibTransactionContinuesStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZlibEncoder()
    let transaction = try encoder.beginTransaction()
    let first = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    try encoder.commit(transaction)
    let second = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)

    #expect(try inflatePayloads([first, second], outputCounts: [8, 8]) == [
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00,
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00
    ])
}

@Test func discardedZRLETransactionDoesNotAdvanceStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZRLEEncoder()

    do {
        let transaction = try encoder.beginTransaction()
        _ = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    }

    let payload = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    #expect(try inflatePayloads([payload], outputCounts: [7]) == [
        0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04
    ])
}

@Test func committedZRLETransactionContinuesStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZRLEEncoder()
    let transaction = try encoder.beginTransaction()
    let first = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    try encoder.commit(transaction)
    let second = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)

    #expect(try inflatePayloads([first, second], outputCounts: [7, 7]) == [
        0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04,
        0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04
    ])
}

@Test func clientSocketWriteTimesOutWithoutPeerProgress() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        Issue.record("socketpair failed: \(String(cString: strerror(errno)))")
        return
    }
    defer { close(descriptors[1]) }

    var sendBufferSize: Int32 = 4 * 1024
    setsockopt(
        descriptors[0],
        SOL_SOCKET,
        SO_SNDBUF,
        &sendBufferSize,
        socklen_t(MemoryLayout<Int32>.size)
    )

    let socket = try ClientSocket(fd: descriptors[0])
    let payload = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
    var didTimeout = false
    do {
        try socket.writeAll(payload, idleTimeout: 0.05)
    } catch {
        didTimeout = true
    }

    #expect(didTimeout)
}

@Test func zrleEncodingUsesRawTilesWithCPixels() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let encoder = try ZRLEEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 7)
    let decompressedCount = decompressed.count
    let status = compressed.withUnsafeMutableBytes { inputPointer in
        decompressed.withUnsafeMutableBytes { outputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressedLength)
            stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(decompressedCount)
            return inflate(&stream, Z_SYNC_FLUSH)
        }
    }

    #expect(status == Z_OK)
    #expect(decompressed == [0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04])
}

@Test func zrleUsesSolidAndPackedPaletteTiles() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 8, height: 2)
    let framebuffer = Framebuffer(
        width: 8,
        height: 2,
        bgra: Array(repeating: [0x03, 0x02, 0x01, 0xff], count: 16).flatMap { $0 },
        layout: layout
    )
    let encoder = try ZRLEEncoder()
    let solidPayload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 8, height: 2),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    let alternatingPixels: [UInt8] = (0..<8).flatMap { index in
        index.isMultiple(of: 2)
            ? [0x03, 0x02, 0x01, 0xff]
            : [0x06, 0x05, 0x04, 0xff]
    }
    let alternating = Framebuffer(
        width: 8,
        height: 1,
        bgra: alternatingPixels,
        layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 8, height: 1)
    )
    let packedPayload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 8, height: 1),
        framebuffer: alternating,
        pixelFormat: .serverDefault
    )
    #expect(try inflatePayloads([solidPayload, packedPayload], outputCounts: [16, 16]) == [
        1, 0x03, 0x02, 0x01,
        2, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04, 0x55
    ])
}

@Test func zrleUsesRunLengthTilesWhenTheyWin() throws {
    let runLengths = [10, 10, 10, 10, 8, 8, 8]
    let runColors = [0, 1, 2, 3, 0, 1, 2]
    var pixels: [UInt8] = []
    for (length, color) in zip(runLengths, runColors) {
        pixels += Array(
            repeating: [UInt8(color * 3), UInt8(color * 5), UInt8(color * 7), 0xff],
            count: length
        ).flatMap { $0 }
    }
    let framebuffer = Framebuffer(
        width: 64,
        height: 1,
        bgra: pixels,
        layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 64, height: 1)
    )
    let encoder = try ZRLEEncoder()
    let paletteRLEPayload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 64, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    let paletteRLEBytes = try inflatePayloads([paletteRLEPayload], outputCounts: [64])
    #expect(paletteRLEBytes.first == 132)

    let distinctColors = (0..<17).flatMap { index -> [UInt8] in
        let color = UInt8(index)
        return [color, color &* 3, color &* 5, 0xff]
    }
    let manyColors = distinctColors + Array(repeating: [0, 0, 0, 0xff], count: 47).flatMap { $0 }
    let manyColorFramebuffer = Framebuffer(
        width: 64,
        height: 1,
        bgra: manyColors,
        layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 64, height: 1)
    )
    let plainEncoder = try ZRLEEncoder()
    let plainRLEPayload = try plainEncoder.encode(
        rect: Rect(x: 0, y: 0, width: 64, height: 1),
        framebuffer: manyColorFramebuffer,
        pixelFormat: .serverDefault
    )
    let plainRLEBytes = try inflatePayloads([plainRLEPayload], outputCounts: [512])
    #expect(plainRLEBytes.first == 128)
}

@Test func zrleEncodingHonorsClientRequestedColorShifts() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x30, 0x20, 0x10, 0xff], layout: layout)
    let noVNCFormat = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 0,
        greenShift: 8,
        blueShift: 16
    )
    let encoder = try ZRLEEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: noVNCFormat
    )

    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 4)
    let decompressedCount = decompressed.count
    let status = compressed.withUnsafeMutableBytes { inputPointer in
        decompressed.withUnsafeMutableBytes { outputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressedLength)
            stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(decompressedCount)
            return inflate(&stream, Z_SYNC_FLUSH)
        }
    }

    #expect(status == Z_OK)
    #expect(decompressed == [0, 0x10, 0x20, 0x30])
}

@Test func zrleUsesFourByteCPixelsForDepth32Format() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x30, 0x20, 0x10, 0xff], layout: layout)
    let appleFormat = PixelFormat(
        bitsPerPixel: 32,
        depth: 32,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )
    let encoder = try ZRLEEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: appleFormat
    )

    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 5)
    let decompressedCount = decompressed.count
    let status = compressed.withUnsafeMutableBytes { inputPointer in
        decompressed.withUnsafeMutableBytes { outputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressedLength)
            stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(decompressedCount)
            return inflate(&stream, Z_SYNC_FLUSH)
        }
    }

    #expect(status == Z_OK)
    #expect(decompressed == [0, 0x30, 0x20, 0x10, 0])
}

@Test func vncAuthKnownVector() throws {
    let challenge: [UInt8] = Array(0..<16)
    let response = try VNCAuth.response(challenge: challenge, password: "password")
    #expect(response == [0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb, 0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2])
}

@Test func virtualLayoutMapsNegativeCoordinates() {
    let display = VirtualDisplay(
        id: 1,
        bounds: CGRect(x: -100, y: 50, width: 200, height: 100),
        pixelWidth: 400,
        pixelHeight: 200
    )
    let layout = VirtualDisplayLayout(displays: [display])

    #expect(layout.width == 400)
    #expect(layout.height == 200)
    #expect(layout.globalPoint(framebufferX: 200, framebufferY: 100) == CGPoint(x: 0, y: 100))
}

private func inflatePayloads(_ payloads: [[UInt8]], outputCounts: [Int]) throws -> [UInt8] {
    guard payloads.count == outputCounts.count else {
        throw RFBError.protocolError("test payload count mismatch")
    }

    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw RFBError.protocolError("test inflateInit failed")
    }
    defer { inflateEnd(&stream) }

    var result: [UInt8] = []
    for (payload, outputCount) in zip(payloads, outputCounts) {
        guard payload.count >= 4 else {
            throw RFBError.protocolError("test payload is missing its length")
        }
        let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
        var compressed = Array(payload.dropFirst(4))
        var output = [UInt8](repeating: 0, count: outputCount)
        let status = compressed.withUnsafeMutableBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(compressedLength)
                stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard status == Z_OK else {
            throw RFBError.protocolError("test inflate failed with status \(status)")
        }
        result += output.prefix(outputCount - Int(stream.avail_out))
    }
    return result
}
