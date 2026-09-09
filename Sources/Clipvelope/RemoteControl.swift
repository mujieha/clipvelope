import Foundation
import AppKit

/// `Clipvelope --open` and `--preferences`: a script's way to talk to the running
/// instance.
///
/// The transport is a distributed notification, which any process in the login
/// session can post, a sandboxed one included. Acting on the bare name would let
/// any such process put the decrypted history on screen whenever it chose. So
/// each launch mints a random token, keeps it in the app's Keychain item (which
/// in a signed build only this app can read) and ignores any request that does
/// not carry it. The command-line side is the same binary: it reads the token
/// back and sends it along.
enum RemoteControl {
    static let openNotification = Notification.Name("com.mujieha.Clipvelope.open")
    static let preferencesNotification = Notification.Name("com.mujieha.Clipvelope.preferences")
    static let tokenKey = "token"

    /// This launch's token. Nil until `arm()` succeeds, and every request is
    /// refused while it is nil: a Keychain that cannot hold the token is not a
    /// reason to start accepting unauthenticated requests.
    private(set) static var token: Data?

    static func arm(keyStore: KeychainKeyStore = KeychainKeyStore()) {
        let fresh = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        do {
            try keyStore.saveRemoteControlToken(fresh)
            token = fresh
        } catch {
            token = nil
            NSLog("%@", "Clipvelope: --open and --preferences are disabled, the Keychain would not hold their token: \(error)")
        }
    }

    static func isAuthentic(_ notification: Notification) -> Bool {
        isAuthentic(userInfo: notification.userInfo, expected: token)
    }

    /// Pure, so the rule can be tested without a Keychain or a notification center.
    static func isAuthentic(userInfo: [AnyHashable: Any]?, expected: Data?) -> Bool {
        guard let expected,
              let presented = userInfo?[tokenKey] as? String,
              let bytes = Data(hexString: presented),
              bytes.count == expected.count
        else { return false }
        // Constant time. The token is random, so a timing leak would be slow to
        // exploit, but a comparison that cannot leak costs nothing here.
        var difference: UInt8 = 0
        for (a, b) in zip(bytes, expected) { difference |= a ^ b }
        return difference == 0
    }

    /// The command-line side. False when there is no token to present, which
    /// means no instance has armed itself since the Keychain was last cleared.
    static func send(_ name: Notification.Name, keyStore: KeychainKeyStore = KeychainKeyStore()) -> Bool {
        guard let token = keyStore.loadRemoteControlToken() else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: [tokenKey: token.hexString], deliverImmediately: true)
        return true
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
