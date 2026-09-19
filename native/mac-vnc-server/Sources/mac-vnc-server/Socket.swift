import Darwin
import Foundation

final class ClientSocket {
    let fd: Int32
    private static let writeIdleTimeout: TimeInterval = 5
    private let stateLock = NSLock()
    private var didShutdown = false

    init(fd: Int32) throws {
        self.fd = fd

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw RFBError.socketError("failed to configure client socket")
        }
    }

    deinit {
        close(fd)
    }

    func readExact(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0

        while offset < count {
            let readCount = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount == 0 {
                throw RFBError.socketError("client disconnected")
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    _ = try waitForEvent(Int16(POLLIN), timeout: nil)
                    continue
                }
                throw RFBError.socketError(String(cString: strerror(errno)))
            }
            offset += readCount
        }

        return buffer
    }

    func writeAll(
        _ bytes: [UInt8],
        idleTimeout: TimeInterval = ClientSocket.writeIdleTimeout,
        onStall: (() -> Void)? = nil
    ) throws {
        var offset = 0
        var lastProgress = DispatchTime.now().uptimeNanoseconds
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { pointer in
                Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                lastProgress = DispatchTime.now().uptimeNanoseconds
                continue
            }
            if written == 0 {
                try waitForWritable(
                    since: lastProgress,
                    idleTimeout: idleTimeout,
                    onStall: onStall
                )
                continue
            }
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForWritable(
                        since: lastProgress,
                        idleTimeout: idleTimeout,
                        onStall: onStall
                    )
                    continue
                }
                throw RFBError.socketError(String(cString: strerror(errno)))
            }
        }
    }

    func writeAll(
        _ chunks: [[UInt8]],
        idleTimeout: TimeInterval = ClientSocket.writeIdleTimeout,
        onStall: (() -> Void)? = nil
    ) throws {
        guard chunks.count <= 1_024 else {
            for chunk in chunks {
                try writeAll(chunk, idleTimeout: idleTimeout, onStall: onStall)
            }
            return
        }

        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        guard totalBytes > 0 else {
            return
        }

        var offsets = [Int](repeating: 0, count: chunks.count)
        var writtenTotal = 0
        var lastProgress = DispatchTime.now().uptimeNanoseconds

        while writtenTotal < totalBytes {
            let written = withIOVectors(chunks: chunks, offsets: offsets) { vectors in
                vectors.withUnsafeBufferPointer { pointer in
                    Darwin.writev(fd, pointer.baseAddress, Int32(pointer.count))
                }
            }
            if written > 0 {
                writtenTotal += written
                var remaining = written
                for index in offsets.indices {
                    let available = chunks[index].count - offsets[index]
                    let consumed = min(remaining, available)
                    offsets[index] += consumed
                    remaining -= consumed
                    if remaining == 0 {
                        break
                    }
                }
                lastProgress = DispatchTime.now().uptimeNanoseconds
                continue
            }
            if written == 0 {
                try waitForWritable(
                    since: lastProgress,
                    idleTimeout: idleTimeout,
                    onStall: onStall
                )
                continue
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try waitForWritable(
                    since: lastProgress,
                    idleTimeout: idleTimeout,
                    onStall: onStall
                )
                continue
            }
            throw RFBError.socketError(String(cString: strerror(errno)))
        }
    }

    func writeString(_ string: String) throws {
        try writeAll(Array(string.utf8))
    }

    func shutdown() {
        stateLock.lock()
        guard !didShutdown else {
            stateLock.unlock()
            return
        }
        didShutdown = true
        stateLock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    private func withIOVectors<T>(
        chunks: [[UInt8]],
        offsets: [Int],
        _ body: ([iovec]) -> T
    ) -> T {
        func appendVectors(_ index: Int, _ vectors: [iovec]) -> T {
            guard index < chunks.count else {
                return body(vectors)
            }

            let offset = offsets[index]
            guard offset < chunks[index].count else {
                return appendVectors(index + 1, vectors)
            }

            return chunks[index].withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return appendVectors(index + 1, vectors)
                }
                var nextVectors = vectors
                nextVectors.append(
                    iovec(
                        iov_base: UnsafeMutableRawPointer(mutating: baseAddress).advanced(by: offset),
                        iov_len: chunks[index].count - offset
                    )
                )
                return appendVectors(index + 1, nextVectors)
            }
        }

        return appendVectors(0, [])
    }

    private func waitForWritable(
        since start: UInt64,
        idleTimeout: TimeInterval,
        onStall: (() -> Void)?
    ) throws {
        let remaining = remainingTimeout(since: start, idleTimeout: idleTimeout)
        guard let remaining, remaining > 0 else {
            throw RFBError.socketError("socket write stalled for \(idleTimeout) seconds")
        }

        let pollInterval = min(remaining, 0.25)
        if try !waitForEvent(Int16(POLLOUT), timeout: pollInterval) {
            onStall?()
            if (remainingTimeout(since: start, idleTimeout: idleTimeout) ?? 0) <= 0 {
                throw RFBError.socketError("socket write stalled for \(idleTimeout) seconds")
            }
        }
    }

    private func waitForEvent(_ events: Int16, timeout: TimeInterval?) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let timeoutMilliseconds: Int32
            if let timeout {
                guard timeout > 0 else {
                    return false
                }
                timeoutMilliseconds = Int32(min(Double(Int32.max), max(1, ceil(timeout * 1_000))))
            } else {
                timeoutMilliseconds = -1
            }

            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw RFBError.socketError("client socket closed while waiting for I/O")
                }
                if descriptor.revents & events != 0 {
                    return true
                }
                continue
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            throw RFBError.socketError(String(cString: strerror(errno)))
        }
    }

    private func remainingTimeout(since start: UInt64, idleTimeout: TimeInterval) -> TimeInterval? {
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return idleTimeout - elapsed
    }
}

final class ListeningSocket {
    let fd: Int32

    init(bindAddress: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RFBError.socketError(String(cString: strerror(errno)))
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
            close(fd)
            throw RFBError.socketError("invalid IPv4 bind address: \(bindAddress)")
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RFBError.socketError("bind \(bindAddress):\(port) failed: \(message)")
        }

        guard listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RFBError.socketError("listen failed: \(message)")
        }
    }

    deinit {
        close(fd)
    }

    func acceptClient() throws -> ClientSocket {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD >= 0 {
                var flag: Int32 = 1
                setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
                return try ClientSocket(fd: clientFD)
            }
            if errno == EINTR {
                continue
            }
            throw RFBError.socketError(String(cString: strerror(errno)))
        }
    }
}
