import CryptoKit
import Darwin
import Foundation

struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    private enum Identifier: Equatable {
        case numeric(Int)
        case text(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    private let prerelease: [Identifier]

    var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            value += "-" + prerelease.map { identifier in
                switch identifier {
                case .numeric(let number):
                    return String(number)
                case .text(let text):
                    return text
                }
            }.joined(separator: ".")
        }
        return value
    }

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let withoutBuildMetadata = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let coreAndPrerelease = withoutBuildMetadata.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = coreAndPrerelease.first else {
            return nil
        }

        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch

        if coreAndPrerelease.count == 1 {
            prerelease = []
        } else {
            let identifiers = coreAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, !identifiers.contains(where: \.isEmpty) else {
                return nil
            }
            prerelease = identifiers.map { identifier in
                if let number = Int(identifier), String(number) == identifier {
                    return .numeric(number)
                }
                return .text(String(identifier))
            }
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let coreComparison = compareCore(lhs, rhs)
        if coreComparison != 0 {
            return coreComparison < 0
        }

        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            return compareIdentifiers(lhs.prerelease, rhs.prerelease) < 0
        }
    }

    private static func compareCore(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> Int {
        for (left, right) in zip(
            [lhs.major, lhs.minor, lhs.patch],
            [rhs.major, rhs.minor, rhs.patch]
        ) where left != right {
            return left < right ? -1 : 1
        }
        return 0
    }

    private static func compareIdentifiers(_ lhs: [Identifier], _ rhs: [Identifier]) -> Int {
        for (left, right) in zip(lhs, rhs) {
            switch (left, right) {
            case (.numeric(let left), .numeric(let right)):
                if left != right {
                    return left < right ? -1 : 1
                }
            case (.numeric, .text):
                return -1
            case (.text, .numeric):
                return 1
            case (.text(let left), .text(let right)):
                if left != right {
                    return left < right ? -1 : 1
                }
            }
        }
        if lhs.count == rhs.count {
            return 0
        }
        return lhs.count < rhs.count ? -1 : 1
    }
}

enum BinaryUpdater {
    private static let repository = "PabloZaiden/mac-vnc-server"
    private static let binaryAssetName = "mac-vnc-server"
    private static let checksumAssetName = "mac-vnc-server.sha256"

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    static func run() async throws {
        let executableURL = try currentExecutableURL()
        guard executableURL.lastPathComponent == binaryAssetName else {
            throw CLIError.commandFailed(
                "update is only available for the installed release binary '\(binaryAssetName)'"
            )
        }

        let release = try await fetchLatestRelease()
        guard let latestVersion = SemanticVersion(release.tagName) else {
            throw CLIError.commandFailed("latest release has an invalid version tag '\(release.tagName)'")
        }
        guard let currentVersion = SemanticVersion(AppVersion.current) else {
            throw CLIError.commandFailed("current version '\(AppVersion.current)' is invalid")
        }

        guard latestVersion > currentVersion else {
            print("mac-vnc-server \(AppVersion.current) is up to date.")
            return
        }

        let binaryAsset = try asset(named: binaryAssetName, in: release)
        let checksumAsset = try asset(named: checksumAssetName, in: release)
        let binaryData = try await download(binaryAsset.browserDownloadURL)
        let checksumData = try await download(checksumAsset.browserDownloadURL)
        try verify(binaryData: binaryData, checksumData: checksumData)

        try replaceExecutable(at: executableURL, with: binaryData)

        print("Updated mac-vnc-server from \(AppVersion.current) to \(latestVersion). Restart the server to use the new version.")
    }

    private static func fetchLatestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw CLIError.commandFailed("could not construct the GitHub releases URL")
        }
        var request = URLRequest(url: url)
        request.setValue("mac-vnc-server/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, context: "fetching the latest GitHub release")
        do {
            return try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw CLIError.commandFailed("could not decode the latest GitHub release: \(error.localizedDescription)")
        }
    }

    private static func asset(named name: String, in release: Release) throws -> Asset {
        guard let asset = release.assets.first(where: { $0.name == name }) else {
            throw CLIError.commandFailed("latest release \(release.tagName) is missing asset '\(name)'")
        }
        return asset
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("mac-vnc-server/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, context: "downloading \(url.lastPathComponent)")
        return data
    }

    private static func validateHTTPResponse(_ response: URLResponse, context: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CLIError.commandFailed("\(context) returned an invalid HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CLIError.commandFailed("\(context) failed with HTTP status \(httpResponse.statusCode)")
        }
    }

    private static func verify(binaryData: Data, checksumData: Data) throws {
        let checksumText = String(decoding: checksumData, as: UTF8.self)
        guard let expectedChecksum = checksumText
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init),
            expectedChecksum.count == 64,
            expectedChecksum.allSatisfy(\.isHexDigit) else {
            throw CLIError.commandFailed("latest release has an invalid SHA-256 checksum file")
        }

        let actualChecksum = SHA256.hash(data: binaryData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
            throw CLIError.commandFailed("downloaded binary failed SHA-256 verification")
        }
    }

    private static func currentExecutableURL() throws -> URL {
        var bufferSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &bufferSize)
        guard bufferSize > 0 else {
            throw CLIError.commandFailed("could not determine the current executable path")
        }

        var buffer = [CChar](repeating: 0, count: Int(bufferSize))
        let result = buffer.withUnsafeMutableBufferPointer { buffer in
            _NSGetExecutablePath(buffer.baseAddress, &bufferSize)
        }
        guard result == 0 else {
            throw CLIError.commandFailed("could not determine the current executable path")
        }

        let path = buffer.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        let url = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CLIError.commandFailed("current executable does not exist at \(url.path)")
        }
        return url
    }

    private static func replaceExecutable(at url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o755
        let temporaryURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".mac-vnc-server-update-\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            let renameResult = temporaryURL.path.withCString { temporaryPath in
                url.path.withCString { destinationPath in
                    Darwin.rename(temporaryPath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw CLIError.commandFailed("could not atomically replace \(url.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
