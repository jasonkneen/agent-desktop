import Foundation

enum CLIError: LocalizedError {
    case helpRequested(String)
    case invalidArgument(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .invalidArgument(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}

enum CLICommand {
    case run(ServerConfig)
    case service(ServerConfig, [String])
    case serviceRestart
    case permissions
    case diagnose
    case wakeup
    case update
    case version

    func run() async throws {
        switch self {
        case .run(let config):
            let resolvedConfig = try resolvePassword(in: config)
            try await runServers(config: resolvedConfig)
        case .service(let config, let arguments):
            _ = try resolvePassword(in: config)
            try LaunchAgentService.install(arguments: arguments)
        case .serviceRestart:
            try LaunchAgentService.restart()
        case .permissions:
            Permissions.printAndRequest()
        case .diagnose:
            Permissions.printStatus()
            MacScreenCapture.printDisplayDiagnostics()
        case .wakeup:
            try DisplayWakeup.run()
        case .update:
            try await BinaryUpdater.run()
        case .version:
            print("mac-vnc-server \(AppVersion.current)")
        }
    }

    private func resolvePassword(in config: ServerConfig) throws -> ServerConfig {
        guard config.passwordFromConfig else {
            return config
        }

        let password = try PasswordStore.loadOrCreate()
        print("VNC password: \(password)")
        return config.withResolvedPassword(password)
    }

    private func runServers(config: ServerConfig) async throws {
        let configs = try await expandedConfigs(from: config)
        if configs.count == 1, let config = configs.first {
            try await Self.runServer(config: config)
            return
        }

        let sharedLogger = ServerLogger(verbose: config.verbose)
        let sharedCapture = try await StreamingScreenCapture(
            scale: config.scale,
            fps: config.fps,
            displaySelection: .all,
            logger: sharedLogger
        )

        for config in configs {
            let capture: SelectedDisplayFramebufferSource
            switch config.displaySelection {
            case .all:
                capture = SelectedDisplayFramebufferSource(source: sharedCapture, displayIndex: nil)
            case .display(let displayIndex):
                capture = SelectedDisplayFramebufferSource(source: sharedCapture, displayIndex: displayIndex)
            case .automatic:
                throw CLIError.invalidArgument("automatic display selection could not be expanded")
            }

            Task.detached {
                do {
                    try await Self.runServer(config: config, capture: capture)
                } catch {
                    fputs("mac-vnc-server \(config.bindAddress):\(config.port): \(CLI.errorMessage(for: error))\n", stderr)
                    Foundation.exit(1)
                }
            }
        }

        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private func expandedConfigs(from config: ServerConfig) async throws -> [ServerConfig] {
        guard config.displaySelection == .automatic else {
            return [config]
        }

        let displayCount = try await StreamingScreenCapture.displayCount()
        guard displayCount > 0 else {
            throw RFBError.captureFailed("ScreenCaptureKit found no displays")
        }
        guard Int(config.port) + displayCount <= Int(UInt16.max) else {
            throw CLIError.invalidArgument("not enough consecutive ports starting at \(config.port) for \(displayCount) display(s)")
        }

        var configs = [config.with(displaySelection: .all)]
        for displayIndex in 1...displayCount {
            configs.append(config.with(port: config.port + UInt16(displayIndex), displaySelection: .display(displayIndex)))
        }
        return configs
    }

    private static func runServer(config: ServerConfig, capture: FramebufferSource? = nil) async throws {
        let logger = ServerLogger(verbose: config.verbose)
        let captureSource: FramebufferSource
        if let capture {
            captureSource = capture
        } else {
            captureSource = try await StreamingScreenCapture(
                scale: config.scale,
                fps: config.fps,
                displaySelection: config.displaySelection,
                logger: logger
            )
        }
        let input = MacInputController(logger: logger)
        let clipboard = MacClipboard()
        let server = RFBServer(
            config: config,
            capture: captureSource,
            input: input,
            clipboard: clipboard,
            logger: logger
        )
        try server.run()
    }
}

enum CLI {
    private struct ParsedRun {
        let config: ServerConfig
        let registerService: Bool
        let serviceArguments: [String]
    }

    static func parse(arguments: [String]) throws -> CLICommand {
        guard let subcommand = arguments.first else {
            return command(for: try parseRun(arguments))
        }

        if subcommand == "--service-restart" {
            guard arguments.count == 1 else {
                throw CLIError.invalidArgument("--service-restart does not accept server options")
            }
            return .serviceRestart
        }

        if subcommand.hasPrefix("-") {
            return command(for: try parseRun(arguments))
        }

        switch subcommand {
        case "run":
            return command(for: try parseRun(Array(arguments.dropFirst())))
        case "permissions":
            return .permissions
        case "diagnose":
            return .diagnose
        case "wakeup":
            return .wakeup
        case "update":
            return .update
        case "version", "--version", "-V":
            return .version
        case "-h", "--help", "help":
            throw CLIError.helpRequested(helpText)
        default:
            throw CLIError.invalidArgument("unknown command '\(subcommand)'\n\n\(helpText)")
        }
    }

    private static func command(for parsedRun: ParsedRun) -> CLICommand {
        if parsedRun.registerService {
            return .service(parsedRun.config, parsedRun.serviceArguments)
        }
        return .run(parsedRun.config)
    }

    private static func parseRun(_ arguments: [String]) throws -> ParsedRun {
        var port: UInt16 = 5900
        var bindAddress = "127.0.0.1"
        var password: String?
        var passwordFromConfig = true
        var insecureAllowNoAuth = false
        var fps = 60
        var scale: Double = 1
        var encodingPreference = EncodingPreference.auto
        var displaySelection = DisplaySelection.automatic
        var verbose = false
        var clipboardSync = false
        var adaptiveStreaming = true
        var adaptiveFrameRate = true
        var registerService = false
        var serviceFlagIndices = Set<Int>()
        var index = 0

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--port", "-p":
                index += 1
                guard index < arguments.count, let parsed = UInt16(arguments[index]) else {
                    throw CLIError.invalidArgument("--port requires a valid TCP port")
                }
                port = parsed
            case "--bind":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--bind requires an IPv4 address")
                }
                bindAddress = arguments[index]
            case "--password":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--password requires a value")
                }
                password = arguments[index]
                passwordFromConfig = false
            case "--no-password":
                password = nil
                passwordFromConfig = false
            case "--insecure-allow-no-auth":
                insecureAllowNoAuth = true
            case "--fps":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--fps requires auto or a value between 1 and 120")
                }
                if arguments[index] == "auto" {
                    fps = 60
                    adaptiveFrameRate = true
                } else if let parsed = Int(arguments[index]), (1...120).contains(parsed) {
                    fps = parsed
                    adaptiveFrameRate = false
                } else {
                    throw CLIError.invalidArgument("--fps requires auto or a value between 1 and 120")
                }
            case "--scale":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0, parsed <= 4 else {
                    throw CLIError.invalidArgument("--scale requires a value greater than 0 and at most 4")
                }
                scale = parsed
            case "--encoding":
                index += 1
                guard index < arguments.count, let parsed = EncodingPreference(rawValue: arguments[index]) else {
                    throw CLIError.invalidArgument("--encoding must be auto, zrle, zlib, or raw")
                }
                encodingPreference = parsed
            case "--display":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--display requires all or a 1-based display number")
                }
                if arguments[index] == "all" {
                    displaySelection = .all
                } else if let parsed = Int(arguments[index]), parsed > 0 {
                    displaySelection = .display(parsed)
                } else {
                    throw CLIError.invalidArgument("--display requires all or a 1-based display number")
                }
            case "--verbose":
                verbose = true
            case "--service":
                registerService = true
                serviceFlagIndices.insert(index)
            case "--clipboard-sync":
                clipboardSync = true
            case "--no-adaptive":
                adaptiveStreaming = false
                adaptiveFrameRate = false
            case "--help", "-h":
                throw CLIError.helpRequested(helpText)
            default:
                throw CLIError.invalidArgument("unknown run argument '\(arg)'")
            }
            index += 1
        }

        if !isLoopback(bindAddress), !passwordFromConfig, password == nil, !insecureAllowNoAuth {
            throw CLIError.invalidArgument("""
            refusing to expose unauthenticated VNC on \(bindAddress)
            Use --password for LAN, or pass --insecure-allow-no-auth if you explicitly want no auth.
            """)
        }

        let config = ServerConfig(
            bindAddress: bindAddress,
            port: port,
            password: password,
            passwordFromConfig: passwordFromConfig,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference,
            displaySelection: displaySelection,
            verbose: verbose,
            clipboardSync: clipboardSync,
            adaptiveStreaming: adaptiveStreaming,
            adaptiveFrameRate: adaptiveFrameRate
        )
        return ParsedRun(
            config: config,
            registerService: registerService,
            serviceArguments: arguments.enumerated()
                .filter { !serviceFlagIndices.contains($0.offset) }
                .map(\.element)
        )
    }

    private static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address.hasPrefix("127.")
    }

    static func errorMessage(for error: Error) -> String {
        var message = error.localizedDescription
        if case RFBError.captureFailed(let captureMessage) = error,
           captureMessage == "ScreenCaptureKit found no displays" {
            message += "\nHint: run 'mac-vnc-server wakeup' to wake the display, then start the server again."
        }
        return message
    }

    static let helpText = """
    mac-vnc-server \(AppVersion.current)

    Usage:
      mac-vnc-server run [--service] [--bind 127.0.0.1] [--port 5900] [--password value]
                          [--fps auto|1...120] [--scale 1.0] [--encoding auto|zrle|zlib|raw]
                          [--display all|number] [--verbose] [--clipboard-sync] [--no-adaptive]
      mac-vnc-server --service-restart
      mac-vnc-server permissions
      mac-vnc-server diagnose
      mac-vnc-server wakeup
      mac-vnc-server update
      mac-vnc-server version

    Default bind address is 127.0.0.1 and default port is 5900. The first run generates an 8-character password in ~/.mac-vnc-server/config.json and prints it to stdout.
    Without --display, port 5900 serves all displays and 5901, 5902, ... serve each display.
    Use --display all to keep only the single combined-display server, or --display 1 for one display.
    Use --verbose to enable periodic framebuffer update logs.
    Use --clipboard-sync to enable basic text clipboard synchronization.
    Use --no-adaptive to disable adaptive FPS, compression, and scale changes.
    Use --service to install and start a per-user LaunchAgent that runs in the UI session.
    Use --service-restart to restart the registered LaunchAgent.
    Use --no-password only for clients that accept unauthenticated VNC.
    """
}

enum DisplayWakeup {
    static func run() throws {
        try signal()
        print("Sent display wake signal with caffeinate.")
    }

    static func signal() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "5"]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed("caffeinate failed with exit status \(process.terminationStatus)")
        }
    }
}

private extension ServerConfig {
    func with(port: UInt16? = nil, displaySelection: DisplaySelection) -> ServerConfig {
        ServerConfig(
            bindAddress: bindAddress,
            port: port ?? self.port,
            password: password,
            passwordFromConfig: passwordFromConfig,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference,
            displaySelection: displaySelection,
            verbose: verbose,
            clipboardSync: clipboardSync,
            adaptiveStreaming: adaptiveStreaming,
            adaptiveFrameRate: adaptiveFrameRate
        )
    }

    func withResolvedPassword(_ password: String) -> ServerConfig {
        ServerConfig(
            bindAddress: bindAddress,
            port: port,
            password: password,
            passwordFromConfig: false,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference,
            displaySelection: displaySelection,
            verbose: verbose,
            clipboardSync: clipboardSync,
            adaptiveStreaming: adaptiveStreaming,
            adaptiveFrameRate: adaptiveFrameRate
        )
    }
}
