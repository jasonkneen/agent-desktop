import SwiftUI

@MainActor
final class AgentsModel: ObservableObject {
  @Published var rows: [AgentRow] = []
  @Published var registry = Registry()
  @Published var watching: Agent?
  @Published var addingAgent = false

  let paths = Paths()
  private lazy var inspector = AgentInspector(probe: probe, paths: paths)
  private let probe = LiveProbe()
  private var timer: Timer?

  func start() {
    reload()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func stop() { timer?.invalidate(); timer = nil }

  func reload() {
    registry = RegistryStore.load(prefix: paths.prefix, probe: probe)
    refresh()
  }

  func refresh() { rows = inspector.rows(registry) }

  @discardableResult
  func add(name: String) -> Agent {
    var r = registry
    let a = r.add(name: name)
    registry = r
    RegistryStore.save(r, prefix: paths.prefix)
    refresh()
    return a
  }

  /// Register an agent whose account already exists (the setup helper created
  /// it): keep the account and port that are actually true on this machine.
  @discardableResult
  func add(name: String, account: String, port: UInt16) -> Agent {
    var r = registry
    let a = r.add(name: name, account: account, port: port)
    registry = r
    RegistryStore.save(r, prefix: paths.prefix)
    refresh()
    return a
  }

  /// Soft delete: drop the list entry only. The macOS account, its files and
  /// its pass file stay — deleting the account is the human's job, in System
  /// Settings. Once it is gone, load()'s sweep drops any row left behind.
  @discardableResult
  func remove(account: String) -> Bool {
    var r = registry
    guard r.remove(account: account) else { return false }
    registry = r
    RegistryStore.save(r, prefix: paths.prefix)
    if watching?.account == account { watching = nil }
    refresh()
    return true
  }
}

struct AgentListView: View {
  @ObservedObject var model: AgentsModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.rows.isEmpty { empty } else { list }
      Divider()
      footer
    }
    .frame(minWidth: 820, minHeight: 560)
    .onAppear { model.start() }
    .onDisappear { model.stop() }
    .sheet(isPresented: $model.addingAgent) { AddAgentSheet(model: model) }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Agents on this Mac").font(.title3.bold())
        Text("Each has its own account, desktop and port.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button { model.addingAgent = true } label: {
        Label("Add agent", systemImage: "plus")
      }
    }
    .padding(Theme.gutter)
  }

  private var list: some View {
    ScrollView {
      VStack(spacing: 9) {
        ForEach(model.rows) { row in
          AgentRowView(row: row, model: model)
        }
      }
      .padding(Theme.gutter)
    }
  }

  private var empty: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: "desktopcomputer")
        .font(.system(size: 34)).foregroundStyle(.tertiary)
      Text("No agents yet").font(.title3.weight(.semibold))
      Text("Add one and it gets its own account and desktop, kept apart from yours.")
        .font(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: 360)
      Button("Add an agent") { model.addingAgent = true }
        .buttonStyle(.borderedProminent)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    let live = model.rows.filter { if case .live = $0.status { return true }; return false }.count
    let waiting = model.rows.filter { $0.status == .waiting }.count
    return HStack(spacing: 9) {
      Circle()
        .fill(live > 0 ? Theme.done : Theme.blocked)
        .frame(width: 7, height: 7)
      Text("\(model.rows.count) agent\(model.rows.count == 1 ? "" : "s") · \(live) live"
           + (waiting > 0 ? " · \(waiting) waiting" : ""))
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 16).padding(.vertical, 9)
    .glassEffect(.regular, in: Rectangle())
  }
}

struct AgentRowView: View {
  let row: AgentRow
  @ObservedObject var model: AgentsModel
  @State private var confirmingDelete = false
  @State private var showingWizard = false
  @State private var signingIn = false
  /// True from a successful sign-in until the poller actually sees the
  /// session. Without it there is a two-second window where the button is
  /// clickable again but a second click only fires a duplicate admin prompt.
  @State private var awaitingSession = false
  @State private var note: String?

  private var busy: Bool { signingIn || awaitingSession }

  var body: some View {
    HStack(spacing: 14) {
      Circle().fill(tint).frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.agent.name).font(.callout.weight(.semibold))
        Text("\(row.agent.account) · port \(String(row.agent.port)) · \(row.status.detail)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let note {
        Text(note).font(.caption).foregroundStyle(Theme.waiting)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
      }
      Text(row.status.label)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(tint)
      Button {
        act()
      } label: {
        if busy {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(awaitingSession ? "Starting…" : row.status.action)
          }
        } else {
          Text(row.status.action)
        }
      }
      .buttonStyle(row.status.watchable ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
      .disabled(busy)

      Button {
        confirmingDelete = true
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove \(row.agent.name) from this list")
    }
    .padding(14)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.radius))
    .onChange(of: row.status) { _, new in
      if case .signedOut = new { return }
      awaitingSession = false
      note = nil
    }
    .confirmationDialog(
      "Remove \(row.agent.name)?",
      isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Remove from list", role: .destructive) { model.remove(account: row.agent.account) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Only the list entry goes. The macOS account “\(row.agent.account)”, its files and its stored password stay — delete the account in System Settings when you are done with it, and this list drops any row whose account is gone the next time it starts.")
    }
    .sheet(isPresented: $showingWizard) { AgentSetupSheet(agent: row.agent, model: model) }
  }

  private var tint: Color {
    switch row.status {
    case .live: return Theme.done
    case .idle: return Theme.done
    case .waiting: return Theme.waiting
    case .signedOut, .notSetUp: return Theme.blocked
    }
  }

  private func act() {
    switch row.status {
    case .idle, .live:
      model.watching = row.agent
    case .signedOut:
      // The helper signs the account back in, in the background — the thing
      // that used to be a manual trudge to the login screen.
      note = nil
      signingIn = true
      let account = row.agent.account
      Task { @MainActor in
        do {
          let result = try await AccountCreator.signIn(account: account, port: row.agent.port)
          if result.signedIn {
            // Held until the poller confirms the session, so the button
            // cannot be clicked into a duplicate admin prompt.
            awaitingSession = true
            note = "signed in — its desktop is starting"
          } else {
            note = "sign-in started; if it does not appear, try again"
          }
        } catch let e as AccountCreator.CreationError {
          if let why = e.errorDescription { note = why }
        } catch {
          note = error.localizedDescription
        }
        signingIn = false
      }
    case .notSetUp, .waiting:
      showingWizard = true
    }
  }
}

/// One agent's setup, as the live facts behind a checklist. Gathered with the
/// same probe as its row, so the sheet can never disagree with the list — and
/// polled while open, so a sign-in started anywhere ticks it over within two
/// seconds. Nobody should have to close and reopen a window to see progress.
@MainActor
final class AgentSetupModel: ObservableObject {
  /// The four facts a setup is made of, worst first. The sheet turns them into
  /// a checklist; the first false one is the next action.
  struct Facts: Equatable {
    var accountExists = false
    var signedIn = false
    var streaming = false
    var hands: Hands = .unproven("permissions not granted yet")
  }

  @Published var facts = Facts()
  /// Set while the helper is running; the button shows it rather than letting
  /// a second click fire a second administrator prompt.
  @Published var working = false
  @Published var note: String?

  let agent: Agent
  private let inspector: AgentInspector
  private var timer: Timer?

  init(agent: Agent, probe: SystemProbe = LiveProbe(), paths: Paths = Paths()) {
    self.agent = agent
    self.inspector = AgentInspector(probe: probe, paths: paths)
  }

  func start() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func stop() { timer?.invalidate(); timer = nil }

  func refresh() {
    facts = Facts(
      accountExists: inspector.probe.userExists(agent.account),
      signedIn: inspector.probe.hasGUISession(agent.account),
      streaming: inspector.probe.portOpen(agent.port),
      hands: inspector.hands(for: agent)
    )
  }

  /// The helper's login path is also "make sure it is in and streaming": it
  /// reuses a live session rather than stacking one, installs the account's
  /// LaunchAgents and loads them straight away. One call covers both a
  /// signed-out agent and a signed-in one whose stream never came up.
  func signIn() {
    working = true
    note = nil
    let account = agent.account, port = agent.port
    Task { @MainActor in
      do {
        _ = try await AccountCreator.signIn(account: account, port: port)
        // No success note: the checklist ticking over IS the feedback.
      } catch let e as AccountCreator.CreationError {
        if let why = e.errorDescription { note = why }   // cancelled stays quiet
      } catch {
        note = error.localizedDescription
      }
      working = false
    }
  }
}

/// The per-agent "Set up" sheet: that agent's real state as a live checklist,
/// with exactly one next action. Never a generic wizard over some other
/// account — the sheet that used to be here probed the pre-registry "agent"
/// account and so called agents "not signed in" that plainly were.
struct AgentSetupSheet: View {
  let agent: Agent
  @ObservedObject var model: AgentsModel
  @StateObject private var setup: AgentSetupModel
  @Environment(\.dismiss) private var dismiss

  init(agent: Agent, model: AgentsModel) {
    self.agent = agent
    self.model = model
    _setup = StateObject(wrappedValue: AgentSetupModel(agent: agent))
  }

  private var facts: AgentSetupModel.Facts { setup.facts }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Set up \(agent.name)").font(.headline)
          Text("account \(agent.account) · port \(String(agent.port))")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { dismiss() } label: { Text("Close") }
          .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, Theme.gutter).padding(.vertical, 12)

      Divider()

      VStack(alignment: .leading, spacing: 16) {
        checklist
        Divider()
        action
      }
      .padding(Theme.gutter)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520)
    .onAppear { setup.start() }
    .onDisappear { setup.stop() }
  }

  private var checklist: some View {
    VStack(alignment: .leading, spacing: 14) {
      CheckRow(done: facts.accountExists, title: "macOS account",
               detail: facts.accountExists
                 ? "\(agent.account) exists"
                 : "\(agent.account) is missing")
      CheckRow(done: facts.signedIn, title: "Signed in",
               detail: facts.signedIn
                 ? "its desktop is running in the background"
                 : "not signed in")
      CheckRow(done: facts.streaming, title: "Screen stream",
               detail: facts.streaming
                 ? "serving on port \(String(agent.port))"
                 : "nothing serving on port \(String(agent.port)) yet")
      CheckRow(done: facts.hands == .granted, title: "Permissions",
               detail: handsDetail)
    }
  }

  private var handsDetail: String {
    if case .unproven(let why) = facts.hands { return why }
    return "screen recording and accessibility granted"
  }

  /// The first thing that is not done, as one button and one sentence. When
  /// everything is done it is Watch — setup's whole point.
  @ViewBuilder
  private var action: some View {
    if !facts.accountExists {
      Label("The macOS account is gone. Remove this row and add the agent again — its account is created fresh, with its stream already wired up.",
            systemImage: "exclamationmark.triangle.fill")
        .font(.callout).foregroundStyle(Theme.waiting)
        .fixedSize(horizontal: false, vertical: true)
    } else if !facts.signedIn || !facts.streaming {
      VStack(alignment: .leading, spacing: 9) {
        Button { setup.signIn() } label: {
          if setup.working {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…") }
          } else {
            Text(facts.signedIn ? "Start the stream" : "Sign in in the background")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(setup.working)
        Text(facts.signedIn
          ? "Signs nobody out: the helper installs the stream and this app into \(agent.name)'s session and starts them now."
          : "Asks for your administrator password once. \(agent.name) then stays signed in in the background — no login screen.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else if facts.hands == .granted {
      Button { watch() } label: { Text("Watch \(agent.name)") }
        .buttonStyle(.borderedProminent)
    } else {
      VStack(alignment: .leading, spacing: 9) {
        Button { watch() } label: { Text("Watch \(agent.name)") }
          .buttonStyle(.borderedProminent)
        Text("Its desktop is streaming. Screen Recording and Accessibility can only be granted inside \(agent.name)'s account — macOS shows those dialogs only there. Switch over via the user menu and follow this app, which is running in that session asking for them.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    if let note = setup.note {
      Label(note, systemImage: "exclamationmark.triangle.fill")
        .font(.callout).foregroundStyle(Theme.waiting)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func watch() {
    model.watching = agent
    dismiss()
  }
}

/// One line of the setup checklist: state in the icon, what was checked in the
/// caption. No step numbers — there is exactly one thing to do at a time and
/// the button below says which.
private struct CheckRow: View {
  let done: Bool
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
        .font(.system(size: 17))
        .foregroundStyle(done ? Theme.done : Color.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(done ? .regular : .semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.radius))
  }
}

/// Lets a row pick its button style without the two branches having different
/// static types.
struct AnyButtonStyle: PrimitiveButtonStyle {
  private let make: (Configuration) -> AnyView
  init<S: PrimitiveButtonStyle>(_ style: S) {
    make = { AnyView(Button($0).buttonStyle(style)) }
  }
  func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
