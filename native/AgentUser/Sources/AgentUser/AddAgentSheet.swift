import SwiftUI

/// Adding an agent. The app picks the account name and port, then hands over
/// the two things it cannot do. Saying so up front matters: a wizard that
/// silently stops at an admin prompt reads as broken.
struct AddAgentSheet: View {
  @ObservedObject var model: AgentsModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  private var account: String { model.registry.nextAccount() }
  private var port: UInt16 { model.registry.nextPort() }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Add an agent").font(.headline)
        Text("Each agent gets its own account and desktop, so two never share a screen.")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(22)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 7) {
          Text("What should it be called?").font(.callout.weight(.medium))
          TextField("Scout", text: $name)
            .textFieldStyle(.roundedBorder)
          Text("Account **\(account)**, port **\(String(port))** — both picked for you.")
            .font(.caption).foregroundStyle(.secondary)
        }

        HumanBadge(reason: "Creating the account needs admin rights, and only the real login window can start a desktop. The app hands you each one and waits.")

        VStack(alignment: .leading, spacing: 9) {
          numbered(1, "Copy the command that creates **\(account)**")
          numbered(2, "Sign it in once via the user menu")
          numbered(3, "Open this app there and grant two permissions")
        }
      }
      .padding(22)

      Divider()

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Start setup") {
          model.add(name: name.trimmingCharacters(in: .whitespaces))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(16)
    }
    .frame(width: 520)
  }

  private func numbered(_ n: Int, _ text: String) -> some View {
    HStack(spacing: 11) {
      Text(String(n))
        .font(.caption2.bold())
        .frame(width: 19, height: 19)
        .background(Color.secondary.opacity(0.18), in: Circle())
      Text(.init(text)).font(.callout)
    }
  }
}

/// Shown when an agent's desktop is up but its stream is not. Without this the
/// viewer would load a dead page and look broken.
struct WaitingView: View {
  let agent: Agent
  var onStart: () -> Void
  var onSetup: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      ZStack {
        Circle()
          .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
          .foregroundStyle(.quaternary)
          .frame(width: 76, height: 76)
        Image(systemName: "display")
          .font(.system(size: 28, weight: .light))
          .foregroundStyle(.tertiary)
      }

      VStack(spacing: 9) {
        Text("Waiting for a connection").font(.title2.weight(.semibold))
        Text("**\(agent.account)** is signed in, but its screen stream has not started yet. This usually clears itself within a few seconds of login.")
          .font(.callout).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 430)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 9) {
        Circle().fill(Theme.waiting).frame(width: 7, height: 7)
        Text("Checking port \(String(agent.port)) every two seconds")
          .font(.caption).foregroundStyle(Theme.waiting)
      }
      .padding(.horizontal, 15).padding(.vertical, 8)
      .background(Theme.waiting.opacity(0.13), in: Capsule())

      HStack(spacing: 10) {
        Button("Start the stream", action: onStart).buttonStyle(.borderedProminent)
        Button("Open setup", action: onSetup)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}

/// Shown when the viewer's own bridge could not start. A blank window would be
/// indistinguishable from an empty desktop, so this says what failed and why.
struct BridgeFailed: View {
  let message: String
  var onRetry: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 32)).foregroundStyle(Theme.waiting)
      Text("The viewer could not start").font(.title3.weight(.semibold))
      Text(message)
        .font(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: 420)
        .fixedSize(horizontal: false, vertical: true)
      Button("Try again", action: onRetry).buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}
