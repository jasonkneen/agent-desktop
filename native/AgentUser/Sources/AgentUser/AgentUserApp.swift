import SwiftUI
import AppKit

/// One app, decided by where it runs and what is set up:
///
///   agent account        → the permissions wizard, because only there can
///                          macOS be asked for the grants
///   your account, agents → the list, and the viewer for any that are live
///   your account, none   → the setup wizard
@main
struct AgentUserApp: App {
  @StateObject private var wizard = WizardModel()
  @StateObject private var agents = AgentsModel()

  var body: some Scene {
    WindowGroup {
      Group {
        if wizard.inAgentAccount {
          WizardView(model: wizard)
        } else if let watching = agents.watching {
          ViewerHost(agent: watching, agents: agents)
        } else {
          AgentListView(model: agents)
        }
      }
      .onAppear { wizard.start() }
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Agent Desktop") {
          NSApp.orderFrontStandardAboutPanel(options: [.credits: About.credits])
        }
      }
    }
  }
}

/// The About panel's credit text: copyright, licence, links.
enum About {
  static var credits: NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.paragraphSpacing = 4

    func text(_ s: String) -> NSAttributedString {
      NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .paragraphStyle: para,
      ])
    }
    func link(_ s: String, _ url: String) -> NSAttributedString {
      NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .link: URL(string: url)!,
        .paragraphStyle: para,
      ])
    }

    let out = NSMutableAttributedString()
    out.append(text("Copyright © 2026 Jason Kneen\n"))
    out.append(text("Released under the MIT License\n"))
    out.append(link("x.com/jasonkneen", "https://x.com/jasonkneen"))
    out.append(text("  ·  "))
    out.append(link("github.com/jasonkneen", "https://github.com/jasonkneen"))
    return out
  }
}

/// Decides, per agent, whether to show its desktop or explain why it cannot.
struct ViewerHost: View {
  let agent: Agent
  @ObservedObject var agents: AgentsModel
  @State private var bridge: Bridge?
  @State private var bridgeError: String?
  @State private var starting = false

  private var status: AgentStatus {
    agents.rows.first { $0.agent.id == agent.id }?.status ?? .waiting
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if let bridgeError {
        BridgeFailed(message: bridgeError, onRetry: connect)
      } else if status.watchable, let bridge {
        ViewerView(url: bridge.url, password: password)
      } else {
        WaitingView(agent: agent, starting: starting, onStart: start,
                    onSetup: { agents.watching = nil })
      }
    }
    .frame(minWidth: 900, minHeight: 620)
    .onAppear(perform: connect)
    .onDisappear { bridge?.stop() }
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Button {
        bridge?.stop()
        agents.watching = nil
      } label: {
        Label("Agents", systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)
      Text(agent.name).font(.callout.weight(.semibold))
      Text(agent.account).font(.caption).foregroundStyle(.secondary)
      Spacer()
      Text(status.label)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.done.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(status.watchable ? Theme.done : Theme.waiting)
    }
    .padding(.horizontal, 14).padding(.vertical, 9)
    .glassEffect(.regular, in: Rectangle())
  }

  private var password: String {
    (try? String(contentsOf: agents.paths.vncPassword, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// One bridge per agent, on its own web port, so watching two at once does
  /// not have them fighting over 6080.
  ///
  /// A failure here is reported, never swallowed. Silently carrying on leaves a
  /// blank window and no way to tell a dead bridge from a desktop that has
  /// nothing on it.
  private func connect() {
    bridgeError = nil
    let web = 6080 + UInt16(agent.port - Registry.firstPort)
    let b = Bridge(webRoot: agents.paths.prefix.appending(path: "noVNC"),
                   webPort: web, vncPort: agent.port)
    do {
      try b.start()
      bridge = b
    } catch {
      bridgeError = "Could not serve the viewer on port \(web). "
        + "Usually something else is already on it — an older websockify from a "
        + "previous setup is the common one."
    }
  }

  private func start() {
    // The helper's login path reuses the account's live session and (re)loads
    // its LaunchAgents — the one way this account can start a process inside
    // another's session. Asks for the administrator password once.
    starting = true
    let account = agent.account, port = agent.port
    Task { @MainActor in
      _ = try? await AccountCreator.signIn(account: account, port: port)
      starting = false   // the poller turns the view the moment the port opens
    }
  }
}
