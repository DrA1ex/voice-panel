import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#elseif canImport(VoicePanelCryptoCompat)
    import VoicePanelCryptoCompat
#endif

enum AESGCMCompat {
    private static let overhead = 28

    static func seal(_ plaintext: Data, key: Data) throws -> Data {
        #if canImport(CryptoKit)
            let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
            guard let combined = sealed.combined else {
                throw AESGCMCompatError.operationFailed
            }
            return combined
        #elseif canImport(VoicePanelCryptoCompat)
            guard [16, 24, 32].contains(key.count) else {
                throw AESGCMCompatError.invalidKeyLength
            }

            let plaintextLength = plaintext.count
            let outputCapacity = plaintextLength + overhead
            var output = Data(count: outputCapacity)
            var outputLength = 0
            let status = output.withUnsafeMutableBytes { outputBytes in
                plaintext.withUnsafeBytes { plaintextBytes in
                    key.withUnsafeBytes { keyBytes in
                        vp_aes_gcm_seal(
                            plaintextBytes.bindMemory(to: UInt8.self).baseAddress,
                            plaintextLength,
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
            guard status == 1 else {
                throw AESGCMCompatError.operationFailed
            }
            return Data(output.prefix(outputLength))
        #else
            throw AESGCMCompatError.unavailable
        #endif
    }

    static func open(_ combined: Data, key: Data) throws -> Data {
        #if canImport(CryptoKit)
            let sealed = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealed, using: SymmetricKey(data: key))
        #elseif canImport(VoicePanelCryptoCompat)
            guard [16, 24, 32].contains(key.count) else {
                throw AESGCMCompatError.invalidKeyLength
            }
            guard combined.count >= overhead else {
                throw AESGCMCompatError.operationFailed
            }

            let combinedLength = combined.count
            let plaintextCapacity = combinedLength - overhead
            var plaintext = Data(count: plaintextCapacity)
            var plaintextLength = 0
            let status = plaintext.withUnsafeMutableBytes { plaintextBytes in
                combined.withUnsafeBytes { combinedBytes in
                    key.withUnsafeBytes { keyBytes in
                        vp_aes_gcm_open(
                            combinedBytes.bindMemory(to: UInt8.self).baseAddress,
                            combinedLength,
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            plaintextBytes.bindMemory(to: UInt8.self).baseAddress,
                            plaintextCapacity,
                            &plaintextLength
                        )
                    }
                }
            }
            guard status == 1 else {
                throw AESGCMCompatError.operationFailed
            }
            return Data(plaintext.prefix(plaintextLength))
        #else
            throw AESGCMCompatError.unavailable
        #endif
    }
}

enum AESGCMCompatError: Error {
    case invalidKeyLength
    case operationFailed
    case unavailable
}
