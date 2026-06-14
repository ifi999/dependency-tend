import XCTest
import Engine
import Security
@testable import AppCore

final class AppUpdateManifestVerifierTests: XCTestCase {
    func testVerifiesManifestChecksumAndArchiveDigest() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)
        let manifestData = manifest(version: "1.3.0", assetSHA256: digest)
        let checksumData = Data("\(digest)  DependencyTend.app.zip\n".utf8)

        let verified = try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: manifestData,
            checksumData: checksumData,
            archiveData: archive
        )

        XCTAssertEqual(verified.versionString, "1.3.0")
        XCTAssertEqual(verified.assetName, "DependencyTend.app.zip")
        XCTAssertEqual(verified.assetSHA256, digest)
        XCTAssertEqual(verified.signatureFormat, "openssl-rsa-sha256")
    }

    func testVerifiesManifestRSASignature() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)
        let manifestData = manifest(version: "1.3.0", assetSHA256: digest)
        let keys = try makeSigningKeys()
        let signature = try sign(manifestData, privateKey: keys.privateKey)

        let verified = try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: manifestData,
            checksumData: Data("\(digest)  DependencyTend.app.zip\n".utf8),
            archiveData: archive,
            signatureData: signature,
            publicKeyPEMData: keys.publicKeyPEM
        )

        XCTAssertEqual(verified.versionString, "1.3.0")
    }

    func testVerifiesManifestSubjectPublicKeyInfoSignature() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)
        let manifestData = manifest(version: "1.3.0", assetSHA256: digest)
        let keys = try makeSigningKeys()
        let signature = try sign(manifestData, privateKey: keys.privateKey)
        let publicKeyPEM = pem(label: "PUBLIC KEY", der: subjectPublicKeyInfoDER(keys.publicKeyDER))

        let verified = try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: manifestData,
            checksumData: Data("\(digest)  DependencyTend.app.zip\n".utf8),
            archiveData: archive,
            signatureData: signature,
            publicKeyPEMData: publicKeyPEM
        )

        XCTAssertEqual(verified.versionString, "1.3.0")
    }

    func testRejectsTamperedManifestSignature() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)
        let originalManifest = manifest(version: "1.3.0", assetSHA256: digest,
                                        createdAt: "2026-06-14T00:00:00Z")
        let tamperedManifest = manifest(version: "1.3.0", assetSHA256: digest,
                                        createdAt: "2026-06-14T00:00:01Z")
        let keys = try makeSigningKeys()
        let signature = try sign(originalManifest, privateKey: keys.privateKey)

        XCTAssertThrowsError(try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: tamperedManifest,
            checksumData: Data("\(digest)  DependencyTend.app.zip\n".utf8),
            archiveData: archive,
            signatureData: signature,
            publicKeyPEMData: keys.publicKeyPEM
        )) { error in
            XCTAssertEqual(error as? AppUpdateManifestError, .signatureVerificationFailed)
        }
    }

    func testRejectsInvalidPublicKeyPEM() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)

        XCTAssertThrowsError(try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: manifest(version: "1.3.0", assetSHA256: digest),
            checksumData: Data("\(digest)  DependencyTend.app.zip\n".utf8),
            archiveData: archive,
            signatureData: Data("signature".utf8),
            publicKeyPEMData: Data("not a public key".utf8)
        )) { error in
            XCTAssertEqual(error as? AppUpdateManifestError, .invalidPublicKey)
        }
    }

    func testRejectsReleaseVersionMismatch() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)

        XCTAssertThrowsError(try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: manifest(version: "1.4.0", assetSHA256: digest),
            checksumData: Data("\(digest)  DependencyTend.app.zip\n".utf8),
            archiveData: archive
        )) { error in
            XCTAssertEqual(error as? AppUpdateManifestError,
                           .releaseVersionMismatch(expected: "1.3.0", actual: "1.4.0"))
        }
    }

    func testRejectsChecksumMismatch() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)
        let wrong = String(repeating: "0", count: 64)

        XCTAssertThrowsError(try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: manifest(version: "1.3.0", assetSHA256: digest),
            checksumData: Data("\(wrong)  DependencyTend.app.zip\n".utf8),
            archiveData: archive
        )) { error in
            XCTAssertEqual(error as? AppUpdateManifestError,
                           .checksumMismatch(expected: digest, actual: wrong))
        }
    }

    func testRejectsUnexpectedChecksumAssetName() throws {
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)

        XCTAssertThrowsError(try AppUpdateManifestVerifier.verify(
            release: release("1.3.0"),
            manifestData: manifest(version: "1.3.0", assetSHA256: digest),
            checksumData: Data("\(digest)  Other.app.zip\n".utf8),
            archiveData: archive
        )) { error in
            XCTAssertEqual(error as? AppUpdateManifestError,
                           .checksumAssetNameMismatch(expected: "DependencyTend.app.zip",
                                                      actual: "Other.app.zip"))
        }
    }

    private func manifest(version: String, assetSHA256: String,
                          createdAt: String = "2026-06-14T00:00:00Z") -> Data {
        Data("""
        {
          "version": "\(version)",
          "tag": "v\(version)",
          "commitSHA": "\(String(repeating: "a", count: 40))",
          "buildNumber": "42",
          "minimumAppVersion": "1.0.0",
          "assetName": "DependencyTend.app.zip",
          "assetSHA256": "\(assetSHA256)",
          "createdAt": "\(createdAt)",
          "signatureFormat": "openssl-rsa-sha256"
        }
        """.utf8)
    }

    private func release(_ version: String) -> AppUpdateRelease {
        let semVer = SemVer.parse(version)!
        return AppUpdateRelease(
            version: semVer,
            versionString: version,
            tag: "v\(version)",
            releasePageURL: URL(string: "https://github.com/ifi999/dependency-tend/releases/tag/v\(version)")!,
            body: "",
            zipAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.app.zip")!,
            checksumAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.app.zip.sha256")!,
            manifestAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.update-manifest.json")!,
            signatureAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.update-manifest.json.sig")!
        )
    }

    private func makeSigningKeys() throws -> (privateKey: SecKey, publicKeyPEM: Data, publicKeyDER: Data) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "AppUpdateManifestVerifierTests", code: 1)
        }
        return (privateKey, pem(label: "RSA PUBLIC KEY", der: publicDER), publicDER)
    }

    private func sign(_ data: Data, privateKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "AppUpdateManifestVerifierTests", code: 2)
        }
        return signature
    }

    private func pem(label: String, der: Data) -> Data {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n".utf8)
    }

    private func subjectPublicKeyInfoDER(_ rsaPublicKeyDER: Data) -> Data {
        let rsaEncryptionIdentifier = Data([
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ])
        var publicKeyBits = Data([0x00])
        publicKeyBits.append(rsaPublicKeyDER)
        return derTagged(0x30, payload: rsaEncryptionIdentifier + derTagged(0x03, payload: publicKeyBits))
    }

    private func derTagged(_ tag: UInt8, payload: Data) -> Data {
        var data = Data([tag])
        data.append(derLength(payload.count))
        data.append(payload)
        return data
    }

    private func derLength(_ length: Int) -> Data {
        guard length >= 128 else { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
