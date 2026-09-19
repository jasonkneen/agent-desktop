import Foundation
import Darwin

@main
struct MacVNCServerApp {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let command = try CLI.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            try await command.run()
        } catch CLIError.helpRequested(let text) {
            print(text)
        } catch {
            fputs("mac-vnc-server: \(CLI.errorMessage(for: error))\n", stderr)
            Foundation.exit(1)
        }
    }
}
