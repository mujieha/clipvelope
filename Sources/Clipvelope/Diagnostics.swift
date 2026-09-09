import Foundation
import AppKit
import ServiceManagement

/// `Clipvelope --status` prints what the app can see about its own installation,
/// then exits without starting the UI.
///
/// Worth having because several behaviours depend on how the app was signed and
/// where it lives -- Launch at Login registration and Keychain access both do --
/// and none of that is visible from the outside.
enum Diagnostics {
    /// Posted by `Clipvelope --open` and observed by the running instance, so a
    /// launcher or a script can bring up the history without Accessibility access.
    static let openNotification = Notification.Name("com.mujieha.Clipvelope.open")
    /// Posted by `Clipvelope --preferences`.
    static let preferencesNotification = Notification.Name("com.mujieha.Clipvelope.preferences")

    static func runIfRequested() {
        if CommandLine.arguments.contains("--open") { signalRunningInstance(openNotification) }
        if CommandLine.arguments.contains("--preferences") {
            signalRunningInstance(preferencesNotification)
        }
        guard CommandLine.arguments.contains("--status") else { return }

        let bundle = Bundle.main
        print("bundle path:      \(bundle.bundlePath)")
        print("bundle id:        \(bundle.bundleIdentifier ?? "none")")
        print("login item:       \(describe(SMAppService.mainApp.status))")

        if KeychainKeyStore.usesDataProtectionKeychain {
            print("key storage:      data protection keychain (private to this app)")
        } else {
            print("key storage:      file keychain (READABLE BY ANY APP YOU RUN)")
            print("                  sign the app to fix this - see docs/SIGNING.md")
        }

        reportUpdates()

        let vault = EncryptedStorage.defaultDirectory
        print("vault directory:  \(vault.path)")
        print("vault exists:     \(FileManager.default.fileExists(atPath: vault.path))")

        exit(0)
    }

    private static func signalRunningInstance(_ name: Notification.Name) -> Never {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mujieha.Clipvelope"
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !running.isEmpty else {
            print("Clipvelope is not running.")
            exit(1)
        }
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }

    /// Reports the updater, because a misconfigured feed fails *silently*: the
    /// app looks like it is checking for updates and simply never finds any,
    /// which is worse than having no updater at all.
    private static func reportUpdates() {
        #if SPARKLE
        print("updates:          built in")
        #else
        print("updates:          not in this build (CLIPVELOPE_SPARKLE=1 includes them)")
        #endif

        let info = Bundle.main.infoDictionary

        if info?["SUPublicEDKey"] as? String == nil {
            print("                  WARNING: no SUPublicEDKey, so no update could be verified")
        }

        // Only meaningful with the updater compiled in. Without it, a value left
        // behind by an earlier release build would contradict the line above.
        #if SPARKLE
        if let last = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            print("last check:       \(formatter.string(from: last))")
        } else {
            print("last check:       never")
        }
        #endif

        guard let feed = info?["SUFeedURL"] as? String, let url = URL(string: feed) else {
            print("feed:             not configured")
            return
        }
        print("feed:             \(feed)")
        // Only a build that would ever contact the feed probes it. A build without
        // the updater promises to make no network calls at all, and --status is
        // not an exception to that promise.
        #if SPARKLE
        print("feed reachable:   \(probe(url))")
        #else
        print("feed reachable:   not checked (this build has no updater and makes no network calls)")
        #endif
    }

    /// Fetches the feed once. This is the only network request Clipvelope makes
    /// outside an update check, and it happens only because someone asked for a
    /// diagnostic.
    private static func probe(_ url: URL) -> String {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"

        var answer = "no answer within 5s"
        let finished = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { finished.signal() }

            if let error {
                answer = "NO - \(error.localizedDescription)"
                return
            }
            guard let http = response as? HTTPURLResponse else {
                answer = "NO - no HTTP response"
                return
            }
            guard http.statusCode == 200 else {
                answer = "NO - HTTP \(http.statusCode)"
                if http.statusCode == 404 {
                    answer += " (nothing published there yet?)"
                }
                return
            }
            // A private repository answers a redirect to a login page with 200,
            // so a status code alone does not mean the feed is really there.
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            answer = body.contains("<rss")
                ? "yes (\(data?.count ?? 0) bytes)"
                : "reachable, but the response is not an appcast"
        }.resume()

        _ = finished.wait(timeout: .now() + 6)
        return answer
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "notRegistered (known to the system, not launching at login)"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval (user must allow it in System Settings)"
        // Distinct from .notRegistered: this is what a bundle reports before it
        // has ever registered. It is not a failure, and not a signing problem.
        case .notFound:         return "notFound (the system has no record of this app yet)"
        @unknown default:       return "unknown (\(status.rawValue))"
        }
    }
}
