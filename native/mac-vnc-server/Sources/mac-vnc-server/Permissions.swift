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

    private static func printStatus(screenReady: Bool, eventReady: Bool, accessibilityReady: Bool) {
        print("Screen Recording: \(screenReady ? "granted" : "missing")")
        print("Post Event:       \(eventReady ? "granted" : "missing")")
        print("Accessibility:    \(accessibilityReady ? "granted" : "missing")")
    }
}
