import SwiftUI

@MainActor
final class WizardModel: ObservableObject {
  @Published var state = SetupState()
  @Published var inAgentAccount: Bool
  /// The stream server's own answer, asked of the binary itself. Nil when it
  /// cannot be asked (not in the agent account, or the binary will not run) —
  /// then the checklist falls back to the receipt file.
  @Published var serverPermissions: ServerPermissions?

  /// In an agent's account every check is about THIS account — account,
  /// session, receipt — and its own port, from the registry. The pre-registry
  /// "agent" name is still honoured for machines that predate the list.
  let paths: Paths
  let streamPort: UInt16
  private let inspector: SetupInspector
  private var timer: Timer?
  /// One kickstart per app launch: the first time the server reports all
  /// three grants it gets restarted, and never again from this run. A fresh
  /// launch (next login) re-arms it naturally.
  private var restartedStreamServerAfterGrants = false

  init() {
    let me = NSUserName()
    let inAgent = Self.runningInAgentAccount(as: me)
    inAgentAccount = inAgent
    paths = Paths(account: inAgent ? me : Paths().account)
    streamPort = RegistryStore.read(prefix: Paths().prefix)?.agent(account: me)?.port
      ?? Registry.firstPort
    inspector = SetupInspector(probe: LiveProbe(), paths: paths, port: streamPort)
  }

  /// Am I, the app, running inside one of the managed agent accounts? Registry
  /// membership, read-only — the sweep in `load` must never run from inside an
  /// agent's session, where it would see other users' accounts as gone.
  nonisolated static func runningInAgentAccount(as user: String, prefix: URL = Paths().prefix) -> Bool {
    user == Paths().account
      || (RegistryStore.read(prefix: prefix)?.agents.contains { $0.account == user } ?? false)
  }

  func start() {
    Task { await refresh() }
    // Polling rather than a Done button: the check is the truth, so a step
    // ticks over when it is actually true, never because someone said so.
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
  }

  func stop() { timer?.invalidate(); timer = nil }

  func refresh() async {
    recordPermissions()
    // The server's own report, not a check run from here: macOS credits a
    // check to the app that spawned it, so running `mac-vnc-server diagnose`
    // from this app reported THIS app's grants (tccd's log confirmed it) —
    // the same self-vouch that once showed "all approved" on a read-only view.
    serverPermissions = inAgentAccount
      ? ServerPermissions.read(paths.serverStatus, probe: LiveProbe())
      : nil
    state = inspector.inspect(serverPermissions: serverPermissions)
    maybeRestartStreamServer()
  }

  /// macOS applies a new input-posting grant only to processes started AFTER
  /// the grant, so an already-running server stays watch-only until it comes
  /// back. The moment the server reports everything granted, the wizard
  /// restarts it itself, in this account's own domain — no admin password.
  private func maybeRestartStreamServer() {
    guard inAgentAccount, serverPermissions?.allGranted == true,
          !restartedStreamServerAfterGrants else { return }
    restartedStreamServerAfterGrants = true
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "-k", "gui/\(getuid())", "com.agentdesktop.mac-vnc-server"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()   // fire and forget: if the job is not loaded, the Start button still exists
  }

  /// Permissions are only readable inside this account, so the poller records
  /// them as it goes: the owner's list ticks over the moment the grants land,
  /// with nothing for a human to click. Only changes are written, so the file's
  /// date keeps meaning "when the truth last changed" — the owner side compares
  /// it with a rebuilt host binary to catch voided grants.
  private func recordPermissions() {
    guard inAgentAccount else { return }
    let s = Permissions.status()
    let body = "self-test user=\(NSUserName()) screenRecording=\(s.screenRecording) accessibility=\(s.accessibility)\n"
    if (try? String(contentsOf: paths.selfTest, encoding: .utf8)) != body {
      try? body.write(to: paths.selfTest, atomically: true, encoding: .utf8)
    }
  }
}

struct WizardView: View {
  @ObservedObject var model: WizardModel

  var body: some View {
    HStack(spacing: 0) {
      steps
        .frame(width: 260)
        .glassEffect(.regular, in: Rectangle())
      Divider()
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 820, minHeight: 540)
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  private var steps: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Agent Desktop").font(.title2.bold())
        Text(model.inAgentAccount ? "Agent account" : "Your account")
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding(Theme.gutter)

      ForEach(Step.allCases, id: \.self) { step in
        let s = model.state[step]
        HStack(spacing: 12) {
          StatusDot(state: s, isCurrent: model.state.current == step)
          VStack(alignment: .leading, spacing: 2) {
            Text(step.title)
              .font(.callout.weight(model.state.current == step ? .semibold : .regular))
            Text(s.detail)
              .font(.caption).foregroundStyle(.secondary)
              .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
        .background(model.state.current == step ? Theme.accent.opacity(0.09) : .clear)
      }

      Spacer()
      ProgressView(value: model.state.progress)
        .padding(Theme.gutter)
    }
  }

  @ViewBuilder
  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let step = model.state.current {
          StepDetail(step: step, model: model)
        } else {
          Complete()
        }
      }
      .padding(Theme.gutter + 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct Complete: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 40)).foregroundStyle(Theme.done)
      Text("The agent has its own desktop").font(.title.bold())
      Text("""
        One check left, and no status row can make it for you: ask the agent \
        for a screenshot and look at it. It should be the agent's desktop — \
        an empty default wallpaper — not your own screen with your windows on \
        it. If you see your own screen, something is pointed at the console \
        session, and everything will look fine until you notice.
        """)
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
