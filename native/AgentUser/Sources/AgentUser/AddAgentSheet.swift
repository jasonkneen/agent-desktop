import SwiftUI

/// Adding an agent. The app creates the macOS account itself — a root helper
/// behind the standard administrator prompt — then shows the generated
/// password once so the human can sign the account in at the login screen.
/// The manual command stays as a fallback for people who would rather do it
/// by hand.
struct AddAgentSheet: View {
  @ObservedObject var model: AgentsModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var creating = false
  @State private var failure: String?
  @State private var outcome: AccountCreator.Outcome?

  private var account: String { model.registry.nextAccount() }
  private var port: UInt16 { model.registry.nextPort() }
  private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

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
            .disabled(creating || outcome != nil)
          Text("Account **\(outcome?.result.account ?? account)**, port **\(String(port))** — both picked for you.")
            .font(.caption).foregroundStyle(.secondary)
        }

        if let outcome {
          created(outcome)
        } else {
          HumanBadge(reason: "Creating the account asks for your administrator password — the standard macOS prompt, once. After that, only the real login window can start its desktop, so you sign it in yourself.")

          if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
              .font(.callout).foregroundStyle(Theme.waiting)
              .fixedSize(horizontal: false, vertical: true)
          }

          if creating {
            HStack(spacing: 9) {
              ProgressView().controlSize(.small)
              Text("Creating the account…")
            }
          } else {
            DisclosureGroup("Or create the account yourself") {
              VStack(alignment: .leading, spacing: 9) {
                numbered(1, "Create **\(account)** yourself, as a standard account")
                numbered(2, "Sign it in once via the user menu")
                numbered(3, "Open this app there and grant two permissions")
              }
              .padding(.top, 4)
              Button("Register \(account) manually") {
                model.add(name: trimmedName)
                dismiss()
              }
              .padding(.top, 4)
            }
          }
        }
      }
      .padding(22)

      Divider()

      HStack {
        Spacer()
        if outcome == nil {
          Button("Cancel") { dismiss() }
          Button {
            createAccount()
          } label: {
            if creating { ProgressView().controlSize(.small) } else {
              Text(failure == nil ? "Create \(account) account…" : "Try again")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(trimmedName.isEmpty || creating || !AccountCreator.available())
          if !AccountCreator.available() {
            Text("helper not installed")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Button("Done") { dismiss() }   // the row was registered the moment the account existed
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
      }
      .padding(16)
    }
    .frame(width: 520)
  }

  /// The success half. Registration already happened — the row is live below.
  /// The password matters only as recovery: the account was signed in in the
  /// background, so nobody should ever need to type this.
  @ViewBuilder
  private func created(_ outcome: AccountCreator.Outcome) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      if outcome.result.signedIn {
        Label("Account “\(outcome.result.account)” created and signed in", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium)).foregroundStyle(Theme.done)
        Text("Its desktop is starting in the background. If its row below does not go live within a few seconds, open it and grant the two permissions inside its desktop.")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Label("Account “\(outcome.result.account)” created", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium)).foregroundStyle(Theme.done)
        Text("macOS has not shown its background session yet. If it does not appear, use “Sign in” on its row, or sign in once via the user menu with the password below.")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      DisclosureGroup("Its password (recovery only)") {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 8) {
            Text(outcome.password)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(1).truncationMode(.middle)
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(outcome.password, forType: .string)
            }
          }
          Text("Saved at **\(Paths().prefix.appending(path: outcome.result.account + "-pass").path)** and nowhere else. You should never need to type this — the account was signed in automatically. If macOS ever logs it out, “Sign in” on its row redoes that.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
      }
    }
  }

  private func createAccount() {
    failure = nil
    creating = true
    let account = account, display = trimmedName, port = port
    Task { @MainActor in
      do {
        let outcome = try await AccountCreator.create(account: account, display: display, port: port)
        // Registered the moment it exists, so the row below is already live.
        model.add(name: display, account: outcome.result.account, port: port)
        self.outcome = outcome
      } catch let e as AccountCreator.CreationError {
        if let why = e.errorDescription { failure = why }
      } catch {
        failure = error.localizedDescription
      }
      creating = false
    }
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
