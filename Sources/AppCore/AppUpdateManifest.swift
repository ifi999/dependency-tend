import CryptoKit
import Engine
import Foundation
import Security

public struct AppUpdateManifest: Equatable, Sendable {
    public let version: SemVer
    public let versionString: String
    public let tag: String
    public let commitSHA: String
    public let buildNumber: String
    public let minimumAppVersion: SemVer
    public let minimumAppVersionString: String
    public let assetName: String
    public let assetSHA256: String
    public let createdAt: String
    public let signatureFormat: String
}

public enum AppUpdateManifestError: Error, Equatable, LocalizedError, Sendable {
    case invalidVersion(String)
    case invalidMinimumAppVersion(String)
    case invalidCommitSHA(String)
    case invalidSHA256(String)
    case unsupportedSignatureFormat(String)
    case releaseVersionMismatch(expected: String, actual: String)
    case releaseTagMismatch(expected: String, actual: String)
    case manifestAssetNameMismatch(expected: String, actual: String)
    case checksumAssetNameMismatch(expected: String, actual: String)
    case checksumMismatch(expected: String, actual: String)
    case archiveChecksumMismatch(expected: String, actual: String)
    case malformedChecksumFile
    case invalidPublicKey
    case signatureVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let value):
            return "manifest version 형식이 올바르지 않습니다: \(value)"
        case .invalidMinimumAppVersion(let value):
            return "manifest minimumAppVersion 형식이 올바르지 않습니다: \(value)"
        case .invalidCommitSHA(let value):
            return "manifest commitSHA 형식이 올바르지 않습니다: \(value)"
        case .invalidSHA256(let value):
            return "SHA-256 형식이 올바르지 않습니다: \(value)"
        case .unsupportedSignatureFormat(let value):
            return "지원하지 않는 manifest 서명 형식입니다: \(value)"
        case .releaseVersionMismatch(let expected, let actual):
            return "릴리스 버전과 manifest 버전이 다릅니다: \(expected) != \(actual)"
        case .releaseTagMismatch(let expected, let actual):
            return "릴리스 태그와 manifest 태그가 다릅니다: \(expected) != \(actual)"
        case .manifestAssetNameMismatch(let expected, let actual),
             .checksumAssetNameMismatch(let expected, let actual):
            return "업데이트 파일 이름이 다릅니다: \(expected) != \(actual)"
        case .checksumMismatch(let expected, let actual),
             .archiveChecksumMismatch(let expected, let actual):
            return "업데이트 파일 checksum이 다릅니다: \(expected) != \(actual)"
        case .malformedChecksumFile:
            return "checksum 파일 형식이 올바르지 않습니다"
        case .invalidPublicKey:
            return "업데이트 manifest 공개 키를 읽지 못했습니다"
        case .signatureVerificationFailed:
            return "업데이트 manifest 서명 검증에 실패했습니다"
        }
    }
}

public enum AppUpdateManifestVerifier {
    public static let supportedSignatureFormat = "openssl-rsa-sha256"

    public static func verify(release: AppUpdateRelease,
                              manifestData: Data,
                              checksumData: Data,
                              archiveData: Data) throws -> AppUpdateManifest {
        let manifest = try decodeManifest(manifestData)
        guard manifest.versionString == release.versionString else {
            throw AppUpdateManifestError.releaseVersionMismatch(expected: release.versionString,
                                                               actual: manifest.versionString)
        }
        guard manifest.tag == release.tag else {
            throw AppUpdateManifestError.releaseTagMismatch(expected: release.tag, actual: manifest.tag)
        }
        guard manifest.assetName == GitHubReleaseParser.zipAssetName else {
            throw AppUpdateManifestError.manifestAssetNameMismatch(expected: GitHubReleaseParser.zipAssetName,
                                                                  actual: manifest.assetName)
        }
        let checksum = try parseChecksum(checksumData)
        guard checksum.assetName == manifest.assetName else {
            throw AppUpdateManifestError.checksumAssetNameMismatch(expected: manifest.assetName,
                                                                  actual: checksum.assetName)
        }
        guard checksum.sha256 == manifest.assetSHA256 else {
            throw AppUpdateManifestError.checksumMismatch(expected: manifest.assetSHA256,
                                                         actual: checksum.sha256)
        }
        let archiveSHA256 = sha256Hex(for: archiveData)
        guard archiveSHA256 == manifest.assetSHA256 else {
            throw AppUpdateManifestError.archiveChecksumMismatch(expected: manifest.assetSHA256,
                                                                actual: archiveSHA256)
        }
        return manifest
    }

    public static func verify(release: AppUpdateRelease,
                              manifestData: Data,
                              checksumData: Data,
                              archiveData: Data,
                              signatureData: Data,
                              publicKeyPEMData: Data) throws -> AppUpdateManifest {
        try verifySignature(messageData: manifestData,
                            signatureData: signatureData,
                            publicKeyPEMData: publicKeyPEMData)
        return try verify(release: release,
                          manifestData: manifestData,
                          checksumData: checksumData,
                          archiveData: archiveData)
    }

    public static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifySignature(messageData: Data,
                                        signatureData: Data,
                                        publicKeyPEMData: Data) throws {
        let publicKey = try publicKey(fromPEMData: publicKeyPEMData)
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm) else {
            throw AppUpdateManifestError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        let isValid = SecKeyVerifySignature(publicKey,
                                            algorithm,
                                            messageData as CFData,
                                            signatureData as CFData,
                                            &error)
        guard isValid else {
            throw AppUpdateManifestError.signatureVerificationFailed
        }
    }

    private static func publicKey(fromPEMData data: Data) throws -> SecKey {
        guard let pem = String(data: data, encoding: .utf8) else {
            throw AppUpdateManifestError.invalidPublicKey
        }
        let labels = ["RSA PUBLIC KEY", "PUBLIC KEY"]
        for label in labels {
            guard let der = derData(inPEM: pem, label: label) else { continue }
            let candidates = [der, strippedSubjectPublicKeyInfo(der)].compactMap { $0 }
            for candidate in candidates {
                if let key = secKey(fromPublicKeyDER: candidate) {
                    return key
                }
            }
        }
        throw AppUpdateManifestError.invalidPublicKey
    }

    private static func derData(inPEM pem: String, label: String) -> Data? {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex) else {
            return nil
        }
        let base64 = pem[beginRange.upperBound..<endRange.lowerBound]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: String(base64))
    }

    private static func secKey(fromPublicKeyDER data: Data) -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error)
    }

    private static func strippedSubjectPublicKeyInfo(_ data: Data) -> Data? {
        var index = data.startIndex
        guard let sequenceLength = readASN1Length(tag: 0x30, data: data, index: &index) else {
            return nil
        }
        let sequenceEnd = index + sequenceLength
        guard sequenceEnd <= data.endIndex else { return nil }
        guard let algorithmLength = readASN1Length(tag: 0x30, data: data, index: &index) else {
            return nil
        }
        index += algorithmLength
        guard index < sequenceEnd,
              let bitStringLength = readASN1Length(tag: 0x03, data: data, index: &index),
              bitStringLength > 1,
              index + bitStringLength <= sequenceEnd,
              data[index] == 0 else {
            return nil
        }
        index += 1
        return data[index..<(index + bitStringLength - 1)]
    }

    private static func readASN1Length(tag: UInt8, data: Data, index: inout Data.Index) -> Int? {
        guard index < data.endIndex, data[index] == tag else { return nil }
        index += 1
        guard index < data.endIndex else { return nil }
        let first = data[index]
        index += 1
        if first & 0x80 == 0 {
            return Int(first)
        }
        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= 4, index + byteCount <= data.endIndex else {
            return nil
        }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) + Int(data[index])
            index += 1
        }
        return length
    }

    private static func decodeManifest(_ data: Data) throws -> AppUpdateManifest {
        let payload = try JSONDecoder().decode(ManifestPayload.self, from: data)
        guard let version = SemVer.parse(payload.version),
              payload.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw AppUpdateManifestError.invalidVersion(payload.version)
        }
        guard let minimum = SemVer.parse(payload.minimumAppVersion),
              payload.minimumAppVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw AppUpdateManifestError.invalidMinimumAppVersion(payload.minimumAppVersion)
        }
        guard payload.commitSHA.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil else {
            throw AppUpdateManifestError.invalidCommitSHA(payload.commitSHA)
        }
        let assetSHA256 = payload.assetSHA256.lowercased()
        guard isSHA256(assetSHA256) else {
            throw AppUpdateManifestError.invalidSHA256(payload.assetSHA256)
        }
        guard payload.signatureFormat == supportedSignatureFormat else {
            throw AppUpdateManifestError.unsupportedSignatureFormat(payload.signatureFormat)
        }
        return AppUpdateManifest(version: version,
                                 versionString: payload.version,
                                 tag: payload.tag,
                                 commitSHA: payload.commitSHA.lowercased(),
                                 buildNumber: payload.buildNumber,
                                 minimumAppVersion: minimum,
                                 minimumAppVersionString: payload.minimumAppVersion,
                                 assetName: payload.assetName,
                                 assetSHA256: assetSHA256,
                                 createdAt: payload.createdAt,
                                 signatureFormat: payload.signatureFormat)
    }

    private static func parseChecksum(_ data: Data) throws -> (sha256: String, assetName: String) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppUpdateManifestError.malformedChecksumFile
        }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 2 else {
            throw AppUpdateManifestError.malformedChecksumFile
        }
        let sha256 = parts[0].lowercased()
        guard isSHA256(sha256) else {
            throw AppUpdateManifestError.invalidSHA256(parts[0])
        }
        return (sha256, parts[1])
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }

    private struct ManifestPayload: Decodable {
        let version: String
        let tag: String
        let commitSHA: String
        let buildNumber: String
        let minimumAppVersion: String
        let assetName: String
        let assetSHA256: String
        let createdAt: String
        let signatureFormat: String
    }
}
