import SwiftUI

/// What to do about the step the wizard is pointing at. Each case says what
/// the step achieves, then exactly one action — a command to paste, a button,
/// or a drag. Never a wall of options.
struct StepDetail: View {
  let step: Step
  @ObservedObject var model: WizardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(step.title).font(.title.bold())
      if let reason = step.humanReason { HumanBadge(reason: reason) }
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case .account: account
    case .session: session
    case .hosts: hosts
    case .permissions: permissions
    case .stream, .view: stream
    }
  }

  private var account: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Give the agent a standard account of its own, so it cannot administer this Mac and never touches your session.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      CommandBlock(command: "sudo sysadminctl -addUser \(model.paths.account) -fullName \"Agent\" -password -")
      Text("The trailing dash makes it prompt for the password instead of taking it on the command line, so it never lands in your shell history. Write it down — you need it at the next step and it cannot be recovered.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var session: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sign the account in once. Normally “Sign in” on its row does this in the background — the steps below are the fallback for when you would rather type its password yourself at the login window.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 8) {
        Label("Open the user menu at the right of the menu bar", systemImage: "1.circle.fill")
        Label("Choose \(model.paths.account.capitalized) and sign in", systemImage: "2.circle.fill")
        Label("Switch straight back to yourself", systemImage: "3.circle.fill")
      }
      .font(.callout)
      Button("Open Users & Groups") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")!)
      }
      Text("It keeps running in the background with its apps alive, and still renders while backgrounded — which is what makes screen capture work at all. After a restart, “Sign in” on its row brings it back.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var hosts: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Builds the two hosts and installs them where both accounts can reach them: the eyes that stream the screen, and the hands the agent drives it with.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      CommandBlock(command: "\(model.paths.prefix.path)/install.sh")
    }
  }

  /// The step people lose the most time on. The binaries are plain executables
  /// rather than app bundles, so macOS will often not list them until one is
  /// dragged in — and nothing on screen tells you that.
  private var permissions: some View {
    VStack(alignment: .leading, spacing: 14) {
      if model.inAgentAccount {
        Text("Grant Screen Recording and Accessibility. Asking here makes macOS show the dialogs directly.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          Button("Request permissions") { Permissions.request() }
            .buttonStyle(.borderedProminent)
          Button("Write the receipt") { writeReceipt() }
        }
        Divider().padding(.vertical, 2)
        Text("If either one will not stick, add the binary by hand — macOS hides plain executables from these lists until one is dragged in:")
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          Button("Screen Recording + reveal binary") {
            Permissions.stageDrag(model.paths.vncServer, into: .screenRecording)
          }
          Button("Accessibility + reveal binary") {
            Permissions.stageDrag(model.paths.computerUseHost, into: .accessibility)
          }
        }
        Text("Both open the right pane and put the binary in a Finder window beside it. Drag it into the list, then switch the toggle on.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("These are per-account, and macOS only shows the dialogs inside the account they apply to. Switch to \(model.paths.account.capitalized) and run this same app there — it will be waiting on this step.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("A rebuild of the hosts voids the grants, because macOS ties them to the binary's signature. If capture breaks right after one, this is why.")
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var stream: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Starts the screen stream inside the agent's session and registers it, so it comes back on its own at every login.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if model.inAgentAccount {
        Button("Start and register the stream") { startStream() }
          .buttonStyle(.borderedProminent)
      } else {
        Text("Run this app in the agent's account to start it. One account cannot launch a process in another's session.")
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func writeReceipt() {
    let s = Permissions.status()
    let body = "self-test user=\(NSUserName()) screenRecording=\(s.screenRecording) accessibility=\(s.accessibility)\n"
    try? body.write(to: model.paths.selfTest, atomically: true, encoding: .utf8)
    model.refresh()
  }

  private func startStream() {
    let pass = (try? String(contentsOf: model.paths.vncPassword, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let p = Process()
    p.executableURL = model.paths.vncServer
    // zlib is not optional: noVNC's ZRLE decoder rejects this server's output
    // with "Too big index in palette" and drops the connection on frame one.
    p.arguments = ["run", "--service", "--bind", "127.0.0.1", "--port", String(model.streamPort),
                   "--display", "1", "--encoding", "zlib", "--password", pass]
    try? p.run()
    model.refresh()
  }
}
