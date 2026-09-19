import Darwin
import Foundation

enum LaunchAgentServiceError: LocalizedError {
    case rootUser
    case executableUnavailable
    case invalidArguments
    case serviceNotInstalled
    case launchctlUnavailable(String)
    case launchctlFailed(arguments: [String], status: Int32, output: String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .rootUser:
            return "mac-vnc-server service commands must be run from the logged-in user session, not as root"
        case .executableUnavailable:
            return "could not determine the mac-vnc-server executable path"
        case .invalidArguments:
            return "--service cannot be passed to the registered service command"
        case .serviceNotInstalled:
            return "the mac-vnc-server service is not loaded; register it first with 'mac-vnc-server --service'"
        case .launchctlUnavailable(let message):
            return "could not run launchctl: \(message)"
        case .launchctlFailed(let arguments, let status, let output):
            let command = (["launchctl"] + arguments).joined(separator: " ")
            return "\(command) failed with exit status \(status)\(output.isEmpty ? "" : ": \(output)")"
        case .fileSystem(let message):
            return message
        }
    }
}

enum LaunchAgentService {
    static let label = "com.pablozaiden.mac-vnc-server"

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    static func install(arguments: [String]) throws {
        guard !arguments.contains("--service") else {
            throw LaunchAgentServiceError.invalidArguments
        }

        let userID = try currentUserID()
        let executableURL = try currentExecutableURL()
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try install(
            arguments: arguments,
            executableURL: executableURL,
            homeDirectory: homeDirectory,
            userID: userID
        )
    }

    static func restart() throws {
        let userID = try currentUserID()
        let target = serviceTarget(for: userID)
        guard try isLoaded(target) else {
            throw LaunchAgentServiceError.serviceNotInstalled
        }

        try runLaunchctl(["kickstart", "-k", target])
        print("Restarted \(label).")
    }

    static func plistData(
        executableURL: URL,
        arguments: [String],
        homeDirectory: URL
    ) throws -> Data {
        guard !arguments.contains("--service") else {
            throw LaunchAgentServiceError.invalidArguments
        }

        let logDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("mac-vnc-server", isDirectory: true)
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path] + arguments,
            "WorkingDirectory": homeDirectory.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "EnvironmentVariables": [
                "HOME": homeDirectory.path
            ],
            "StandardOutPath": logDirectory
                .appendingPathComponent("stdout.log")
                .path,
            "StandardErrorPath": logDirectory
                .appendingPathComponent("stderr.log")
                .path
        ]

        do {
            return try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
        } catch {
            throw LaunchAgentServiceError.fileSystem(
                "could not serialize the macOS service configuration: \(error.localizedDescription)"
            )
        }
    }

    private static func install(
        arguments: [String],
        executableURL: URL,
        homeDirectory: URL,
        userID: uid_t
    ) throws {
        let fileManager = FileManager.default
        let launchAgentsDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsDirectory
            .appendingPathComponent("\(label).plist")
        let logDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("mac-vnc-server", isDirectory: true)
        let serviceTarget = serviceTarget(for: userID)
        let serviceDomain = "gui/\(userID)"

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw LaunchAgentServiceError.executableUnavailable
        }

        let plistData = try plistData(
            executableURL: executableURL,
            arguments: arguments,
            homeDirectory: homeDirectory
        )

        try createDirectory(launchAgentsDirectory, fileManager: fileManager)
        try createDirectory(logDirectory, fileManager: fileManager)

        if try isLoaded(serviceTarget) {
            try runLaunchctl(["bootout", serviceTarget])
        }

        try writeAtomically(plistData, to: plistURL, fileManager: fileManager)
        try runLaunchctl(["bootstrap", serviceDomain, plistURL.path])
        try runLaunchctl(["kickstart", "-k", serviceTarget])

        print("Registered \(label) as a per-user macOS service.")
        print("LaunchAgent: \(plistURL.path)")
        print("Logs: \(logDirectory.path)")
    }

    private static func currentExecutableURL() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4096)
        var bufferSize = UInt32(buffer.count)
        guard _NSGetExecutablePath(&buffer, &bufferSize) == 0 else {
            throw LaunchAgentServiceError.executableUnavailable
        }

        let path = String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw LaunchAgentServiceError.executableUnavailable
        }
        return url
    }

    private static func currentUserID() throws -> uid_t {
        let userID = getuid()
        guard userID != 0 else {
            throw LaunchAgentServiceError.rootUser
        }
        return userID
    }

    private static func serviceTarget(for userID: uid_t) -> String {
        "gui/\(userID)/\(label)"
    }

    private static func createDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
        } catch {
            throw LaunchAgentServiceError.fileSystem(
                "could not create \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private static func writeAtomically(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        do {
            try data.write(to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            let result = temporaryURL.path.withCString { sourcePath in
                url.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard result == 0 else {
                throw LaunchAgentServiceError.fileSystem(
                    "could not install \(url.path): \(String(cString: strerror(errno)))"
                )
            }
        } catch let error as LaunchAgentServiceError {
            throw error
        } catch {
            throw LaunchAgentServiceError.fileSystem(
                "could not write \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private static func isLoaded(_ target: String) throws -> Bool {
        let result = try runLaunchctl(["print", target])
        if result.status == 0 {
            return true
        }

        let output = result.output.lowercased()
        if result.status == 113
            || output.contains("could not find")
            || output.contains("no such process")
            || output.contains("not found") {
            return false
        }
        throw LaunchAgentServiceError.launchctlFailed(
            arguments: ["print", target],
            status: result.status,
            output: result.output
        )
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw LaunchAgentServiceError.launchctlUnavailable(error.localizedDescription)
        }

        process.waitUntilExit()
        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(
            data: stdout + stderr,
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let result = CommandResult(status: process.terminationStatus, output: output)
        guard result.status == 0 || arguments.first == "print" else {
            throw LaunchAgentServiceError.launchctlFailed(
                arguments: arguments,
                status: result.status,
                output: result.output
            )
        }
        return result
    }
}
