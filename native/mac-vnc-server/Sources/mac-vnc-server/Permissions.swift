import ApplicationServices
import Foundation
import ScreenCaptureKit

enum Permissions {
    static func printAndRequest() {
        let screenReady = CGPreflightScreenCaptureAccess()
        let eventReady = CGPreflightPostEventAccess()
        let accessibilityReady = AXIsProcessTrusted()

        printStatus(screenReady: screenReady, eventReady: eventReady, accessibilityReady: accessibilityReady)

        if !screenReady {
            _ = CGRequestScreenCaptureAccess()
        }
        if !eventReady {
            _ = CGRequestPostEventAccess()
        }
        if !accessibilityReady {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        if !screenReady || !eventReady || !accessibilityReady {
            print("""

            If a prompt appeared, grant access and restart mac-vnc-server.
            You can also grant permissions manually in:
            System Settings -> Privacy & Security -> Screen Recording
            System Settings -> Privacy & Security -> Accessibility
            """)
        }
    }

    static func printStatus() {
        printStatus(
            screenReady: CGPreflightScreenCaptureAccess(),
            eventReady: CGPreflightPostEventAccess(),
            accessibilityReady: AXIsProcessTrusted()
        )
    }

    /// True when this process will be credited for its own TCC requests.
    /// macOS attributes a request to the *responsible* process: a child of an
    /// app inherits the app, so an ask from there grants the app — which is
    /// how "approved" dialogs once left this server read-only. Under launchd
    /// (parent PID 1) the process stands alone and the grant lands on this
    /// exact binary, the one that posts the viewer's clicks.
    static var isOwnResponsibleProcess: Bool { getppid() == 1 }

    /// True when any of the three grants this server needs is missing.
    static var anythingMissing: Bool {
        !CGPreflightScreenCaptureAccess() || !CGPreflightPostEventAccess() || !AXIsProcessTrusted()
    }

    /// Asks for whatever is missing. Only meaningful when
    /// `isOwnResponsibleProcess`; callers gate on it.
    static func requestMissing() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// The request returns at once; the dialog belongs to tccd and dies with
    /// the process that asked. Exiting straight into a capture that cannot
    /// start yet made launchd respawn it every ten seconds, so the dialog
    /// flashed and vanished before anyone could click it. Stay alive until
    /// Screen Recording lands. After five minutes, exit anyway: a fresh process
    /// re-asks, in case this one's preflight answer went stale.
    static func waitForScreenRecording(logger: ServerLogger) async {
        let started = Date()
        // CGRequestScreenCaptureAccess alone never made tccd post a dialog for
        // this server; the one it posted came from a capture-side query
        // (ScreenCaptureKit, via replayd). So make that query once, then stay
        // alive: the dialog is held open for as long as this process lives.
        if !CGPreflightScreenCaptureAccess() {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        while !CGPreflightScreenCaptureAccess() {
            if Date().timeIntervalSince(started) > 300 {
                logger.info("still no Screen Recording after 5 minutes — restarting to ask again")
                Foundation.exit(0)
            }
            try? await Task.sleep(for: .seconds(2))
        }
        logger.info("Screen Recording granted — starting capture")
    }

    /// The server's own grants, written where the setup app can read them.
    /// Only this process can report them: a checker the app spawns is credited
    /// to the app, so it reports the app's grants (tccd's log showed exactly
    /// that — every such check had the app as its subject). Written every tick
    /// so the file's age says whether the server is alive.
    static func startStatusReporter() {
        guard let dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else {
            return
        }
        let file = dir.appending(path: "server-status-\(NSUserName()).txt")
        Task.detached(priority: .utility) {
            while true {
                let body = "server user=\(NSUserName()) screenRecording=\(CGPreflightScreenCaptureAccess()) "
                    + "postEvent=\(CGPreflightPostEventAccess()) accessibility=\(AXIsProcessTrusted())\n"
                try? body.write(to: file, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func printStatus(screenReady: Bool, eventReady: Bool, accessibilityReady: Bool) {
        print("Screen Recording: \(screenReady ? "granted" : "missing")")
        print("Post Event:       \(eventReady ? "granted" : "missing")")
        print("Accessibility:    \(accessibilityReady ? "granted" : "missing")")
    }
}
