import SwiftUI

/// A small, deliberate set of tokens. Everything visual comes from here so the
/// app reads as one thing and adapts to light and dark without a second theme.
public enum Theme {
  public static let accent = Color.accentColor
  public static let done = Color(nsColor: .systemGreen)
  public static let waiting = Color(nsColor: .systemOrange)
  public static let blocked = Color(nsColor: .tertiaryLabelColor)

  public static let gutter: CGFloat = 28
  public static let radius: CGFloat = 10
}

/// The status dot beside each step. Shape as well as colour carries the
/// meaning, so it still reads without colour vision.
struct StatusDot: View {
  let state: StepState
  let isCurrent: Bool

  var body: some View {
    ZStack {
      Circle()
        .fill(fill.opacity(state.isDone ? 1 : 0.18))
        .frame(width: 20, height: 20)
      if state.isDone {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white)
      } else if isCurrent {
        Circle().fill(Theme.waiting).frame(width: 7, height: 7)
      } else if case .blocked = state {
        Image(systemName: "lock.fill")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Theme.blocked)
      }
    }
    .animation(.snappy(duration: 0.25), value: state)
  }

  private var fill: Color {
    if state.isDone { return Theme.done }
    if isCurrent { return Theme.waiting }
    return Theme.blocked
  }
}

/// Marks a step as something only a person can do, with the reason attached.
/// Without the reason these read as the app failing to automate something.
struct HumanBadge: View {
  let reason: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "hand.raised.fill")
        .font(.caption)
        .foregroundStyle(Theme.waiting)
      VStack(alignment: .leading, spacing: 2) {
        Text("Your step").font(.caption.weight(.semibold))
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.waiting.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radius))
  }
}

/// A command the person pastes, with a copy button — retyping a long path is
/// how typos get introduced.
struct CommandBlock: View {
  let command: String
  @State private var copied = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(command)
        .font(.system(.footnote, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .help("Copy")
    }
    .padding(12)
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.radius))
    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color(nsColor: .separatorColor)))
  }
}
