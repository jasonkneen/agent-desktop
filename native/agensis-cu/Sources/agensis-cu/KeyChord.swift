import Foundation

/// A parsed key combination like "cmd+shift+t", "Return", "Page_Down".
struct KeyChord: Sendable, Equatable {
  var keyCode: UInt16
  var flags: UInt64

  static let command: UInt64 = 0x0010_0000
  static let shift: UInt64 = 0x0002_0000
  static let control: UInt64 = 0x0004_0000
  static let option: UInt64 = 0x0008_0000
  static let function: UInt64 = 0x0080_0000

  static func parse(_ chord: String) -> KeyChord? {
    let parts = chord.split(separator: "+").map {
      $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "")
    }
    guard let last = parts.last, !last.isEmpty, let code = keyCodes[last] else { return nil }
    var flags: UInt64 = 0
    for modifier in parts.dropLast() {
      guard let bit = modifiers[modifier] else { return nil }
      flags |= bit
    }
    return KeyChord(keyCode: code, flags: flags)
  }

  static let modifiers: [String: UInt64] = [
    "cmd": command, "command": command, "super": command, "meta": command, "win": command,
    "shift": shift,
    "ctrl": control, "control": control,
    "alt": option, "opt": option, "option": option,
    "fn": function,
  ]

  static let keyCodes: [String: UInt16] = {
    var map: [String: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
      "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
      "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "equal": 24,
      "9": 25, "7": 26, "-": 27, "minus": 27, "8": 28, "0": 29,
      "]": 30, "rightbracket": 30, "o": 31, "u": 32, "[": 33, "leftbracket": 33,
      "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "quote": 39, "k": 40,
      ";": 41, "semicolon": 41, "\\": 42, "backslash": 42, ",": 43, "comma": 43,
      "/": 44, "slash": 44, "n": 45, "m": 46, ".": 47, "period": 47, "`": 50, "grave": 50,
      "return": 36, "enter": 36, "kpenter": 76, "tab": 48, "space": 49,
      "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
      "forwarddelete": 117, "home": 115, "end": 119,
      "pageup": 116, "pgup": 116, "pagedown": 121, "pgdn": 121,
      "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    let fKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
    return map
  }()
}
