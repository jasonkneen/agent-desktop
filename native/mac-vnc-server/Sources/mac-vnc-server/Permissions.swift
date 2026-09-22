import ApplicationServices
import Foundation

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

    private static func printStatus(screenReady: Bool, eventReady: Bool, accessibilityReady: Bool) {
        print("Screen Recording: \(screenReady ? "granted" : "missing")")
        print("Post Event:       \(eventReady ? "granted" : "missing")")
        print("Accessibility:    \(accessibilityReady ? "granted" : "missing")")
    }
}
