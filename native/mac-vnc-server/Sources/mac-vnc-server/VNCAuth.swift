import CommonCrypto
import Foundation

enum VNCAuth {
    static func response(challenge: [UInt8], password: String) throws -> [UInt8] {
        guard challenge.count == 16 else {
            throw RFBError.protocolError("VNC challenge must be 16 bytes")
        }

        var key = Array(password.utf8.prefix(8))
        while key.count < kCCKeySizeDES {
            key.append(0)
        }
        key = key.map(reverseBits)

        var output: [UInt8] = []
        output.reserveCapacity(16)

        try encryptBlock(Array(challenge[0..<8]), key: key, into: &output)
        try encryptBlock(Array(challenge[8..<16]), key: key, into: &output)

        return output
    }

    private static func encryptBlock(_ block: [UInt8], key: [UInt8], into output: inout [UInt8]) throws {
        var encrypted = [UInt8](repeating: 0, count: kCCBlockSizeDES)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            key,
            kCCKeySizeDES,
            nil,
            block,
            kCCBlockSizeDES,
            &encrypted,
            kCCBlockSizeDES,
            &moved
        )

        guard status == kCCSuccess, moved == kCCBlockSizeDES else {
            throw RFBError.authenticationFailed
        }

        output.append(contentsOf: encrypted)
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }
}

