// Ed25519 signing for update disk images. Run with `xcrun swift Scripts/update-key.swift <command>`.
//
//   generate <private-key-file>      Write a new private key (base64 seed, mode 0600); print the public key.
//   sign <file>                      Print the base64 signature of <file>. The private key comes from
//                                    $AMANUENSIS_UPDATE_PRIVATE_KEY (base64) or the file at
//                                    $AMANUENSIS_UPDATE_PRIVATE_KEY_FILE.
//   verify <file> <sig-file> <key>   Check a signature file against a base64 public key.
//
// The app verifies the same signatures with CryptoKit before it installs an update.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func decodeBase64(_ text: String, _ what: String) -> Data {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("\(what) is not valid base64")
    }
    return data
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    let environment = ProcessInfo.processInfo.environment
    let encoded: String
    if let inline = environment["AMANUENSIS_UPDATE_PRIVATE_KEY"], !inline.isEmpty {
        encoded = inline
    } else if let path = environment["AMANUENSIS_UPDATE_PRIVATE_KEY_FILE"], !path.isEmpty {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("Could not read the private key file at \(path)")
        }
        encoded = contents
    } else {
        fail("Set AMANUENSIS_UPDATE_PRIVATE_KEY or AMANUENSIS_UPDATE_PRIVATE_KEY_FILE")
    }
    let seed = decodeBase64(encoded, "Private key")
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("The private key must be a base64 Ed25519 seed")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate" where arguments.count == 2:
    let destination = URL(fileURLWithPath: arguments[1])
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        fail("\(destination.path) already exists; move it away before generating a new key")
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 2:
    let contents = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    print(try privateKey().signature(for: contents).base64EncodedString())
case "verify" where arguments.count == 4:
    let contents = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let signature = decodeBase64(try String(contentsOfFile: arguments[2], encoding: .utf8), "Signature")
    let raw = decodeBase64(arguments[3], "Public key")
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("The public key must be a base64 Ed25519 key")
    }
    guard key.isValidSignature(signature, for: contents) else {
        fail("Signature does not match \(arguments[1])")
    }
    print("Signature verified for \(arguments[1])")
default:
    fail(
        """
        Usage: update-key.swift generate <private-key-file>
               update-key.swift sign <file>
               update-key.swift verify <file> <signature-file> <public-key-base64>
        """)
}
