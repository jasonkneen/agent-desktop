import Darwin
import Foundation

enum PasswordStoreError: LocalizedError {
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        }
    }
}

enum PasswordStore {
    static let passwordLength = 8
    static let configFileName = "config.json"

    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    private enum PathKind {
        case missing
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    private struct Config: Codable {
        let password: String
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mac-vnc-server", isDirectory: true)
            .appendingPathComponent(configFileName)
    }

    static func loadOrCreate() throws -> String {
        try loadOrCreate(in: configURL.deletingLastPathComponent())
    }

    static func loadOrCreate(in directoryURL: URL) throws -> String {
        let fileManager = FileManager.default
        try ensureDirectory(directoryURL, fileManager: fileManager)

        let fileURL = directoryURL.appendingPathComponent(configFileName)
        switch try pathKind(at: fileURL) {
        case .regularFile:
            return try load(from: fileURL, fileManager: fileManager)
        case .missing:
            break
        case .symbolicLink:
            throw PasswordStoreError.invalidConfiguration(
                "\(fileURL.path) must be a regular file and not a symbolic link"
            )
        case .directory, .other:
            throw PasswordStoreError.invalidConfiguration(
                "\(fileURL.path) must be a regular file"
            )
        }

        let password = generatePassword()
        let data = try encodedConfig(password: password)
        let temporaryURL = directoryURL
            .appendingPathComponent(".\(configFileName).\(UUID().uuidString).tmp")

        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try data.write(to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        } catch {
            if case .regularFile = try pathKind(at: fileURL) {
                return try load(from: fileURL, fileManager: fileManager)
            }
            throw error
        }

        return password
    }

    private static func ensureDirectory(_ directoryURL: URL, fileManager: FileManager) throws {
        switch try pathKind(at: directoryURL) {
        case .missing:
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        case .directory:
            break
        case .symbolicLink:
            throw PasswordStoreError.invalidConfiguration(
                "\(directoryURL.path) must be a directory and not a symbolic link"
            )
        case .regularFile, .other:
            throw PasswordStoreError.invalidConfiguration(
                "\(directoryURL.path) must be a directory"
            )
        }

        guard case .directory = try pathKind(at: directoryURL) else {
            throw PasswordStoreError.invalidConfiguration(
                "\(directoryURL.path) must be a directory and not a symbolic link"
            )
        }

        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directoryURL.path
        )
    }

    private static func load(from fileURL: URL, fileManager: FileManager) throws -> String {
        guard case .regularFile = try pathKind(at: fileURL) else {
            throw PasswordStoreError.invalidConfiguration(
                "\(fileURL.path) must be a regular file and not a symbolic link"
            )
        }

        let data = try Data(contentsOf: fileURL)
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw PasswordStoreError.invalidConfiguration(
                "could not decode \(fileURL.path): \(error.localizedDescription)"
            )
        }

        guard isValid(password: config.password) else {
            throw PasswordStoreError.invalidConfiguration(
                "\(fileURL.path) must contain an ASCII password of exactly \(passwordLength) characters"
            )
        }

        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
        return config.password
    }

    private static func pathKind(at url: URL) throws -> PathKind {
        var fileInfo = stat()
        let result = url.path.withCString { path in
            lstat(path, &fileInfo)
        }
        guard result == 0 else {
            guard errno == ENOENT else {
                throw PasswordStoreError.invalidConfiguration(
                    "could not inspect \(url.path): \(String(cString: strerror(errno)))"
                )
            }
            return .missing
        }

        switch fileInfo.st_mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFREG:
            return .regularFile
        case S_IFLNK:
            return .symbolicLink
        default:
            return .other
        }
    }

    private static func encodedConfig(password: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Config(password: password))
    }

    private static func generatePassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<passwordLength).map { _ in
            alphabet[Int.random(in: alphabet.indices, using: &generator)]
        })
    }

    private static func isValid(password: String) -> Bool {
        password.utf8.count == passwordLength && password.allSatisfy { alphabet.contains($0) }
    }
}
