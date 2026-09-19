import Foundation

final class ServerLogger: @unchecked Sendable {
    private let verbose: Bool
    private let lock = NSLock()

    init(verbose: Bool) {
        self.verbose = verbose
    }

    var isVerbose: Bool {
        verbose
    }

    func info(_ message: String) {
        write(message, to: stdout)
    }

    func verbose(_ message: String) {
        guard verbose else {
            return
        }
        write(message, to: stdout)
    }

    func warning(_ message: String) {
        write("warning: \(message)", to: stderr)
    }

    func error(_ message: String) {
        write("error: \(message)", to: stderr)
    }

    private func write(_ message: String, to stream: UnsafeMutablePointer<FILE>) {
        lock.lock()
        defer { lock.unlock() }
        fputs("\(message)\n", stream)
    }
}
