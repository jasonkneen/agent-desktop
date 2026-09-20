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
    .sheet(isPresented: $showingWizard) { WizardSheet(agent: row.agent) }
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
          let result = try await AccountCreator.signIn(account: account)
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

/// The setup wizard over an agent, as a sheet. Its own WizardModel, so it
/// polls that account's real state while it is open.
struct WizardSheet: View {
  let agent: Agent
  @StateObject private var wizard = WizardModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Set up \(agent.name)").font(.headline)
          Text("account \(agent.account)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { dismiss() } label: { Text("Close") }
          .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, Theme.gutter).padding(.vertical, 12)

      WizardView(model: wizard)
    }
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
