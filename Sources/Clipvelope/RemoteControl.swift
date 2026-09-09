import Foundation
import AppKit

/// `Clipvelope --open` and `--preferences`: a script's way to talk to the running
/// instance.
///
/// The transport is a distributed notification, which any process in the login
/// session can post, a sandboxed one included. Acting on the bare name would let
/// any such process put the decrypted history on screen for the cost of one
/// line of code. So each launch mints a random token, keeps it in the app's
/// Keychain item, and ignores any request that does not carry it. The
/// command-line side is the same binary: it reads the token back and sends it
/// along.
///
/// What this is and is not. It raises the cost of the trivial attack, and that
/// is all it does. It is **not** a security boundary, because the credential is
/// held by a *code identity* rather than by a person: anything running as this
/// user can execute Clipvelope's own binary with `--open`, and that child reads
/// the same token legitimately. No peer check fixes that, XPC code-signing
/// requirements included, because the caller genuinely is Clipvelope. In an
/// unsigned build it is weaker still: the token sits in the file keychain,
/// which any program the user runs can read. SECURITY.md says so plainly under
/// "Known limits"; do not write a claim here that the design cannot keep.
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
        // Keychain calls can block on a system dialog, and this runs while the
        // app is starting. On the main thread that freezes a menu-bar app before
        // it owns a window the dialog could sit over. Requests are refused until
        // this lands, which is the safe direction.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try keyStore.saveRemoteControlToken(fresh)
                DispatchQueue.main.async { token = fresh }
            } catch {
                DispatchQueue.main.async { token = nil }
                NSLog("%@", "Clipvelope: --open and --preferences are disabled, the Keychain would not hold their token: \(error)")
            }
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
