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
    .background(.ultraThinMaterial)
  }
}

struct AgentRowView: View {
  let row: AgentRow
  @ObservedObject var model: AgentsModel

  var body: some View {
    HStack(spacing: 14) {
      Circle().fill(tint).frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.agent.name).font(.callout.weight(.semibold))
        Text("\(row.agent.account) · port \(String(row.agent.port)) · \(row.status.detail)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(row.status.label)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(tint)
      Button(row.status.action) { act() }
        .buttonStyle(row.status.watchable ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
    }
    .padding(14)
    .background(tint.opacity(row.status.watchable ? 0.07 : 0.03),
                in: RoundedRectangle(cornerRadius: Theme.radius))
    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(tint.opacity(0.25)))
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
    if row.status.watchable { model.watching = row.agent }
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
