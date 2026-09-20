import Foundation
import OpenDirectory
import Security
import SetupCore

// agentdesktop-setup — a root helper that creates the agent's macOS account.
//
// Ported from noodle's LocalMacService (OpenDirectory createRecord with a
// scanned free UID, verifyPassword after changePassword, mkdir-0700 home
// dirs, refusal guardrails), but far smaller: instead of a launchd daemon
// and an XPC channel, the app shells out through osascript's standard
// administrator prompt. The password is generated here, as root, and
// written straight to a 0600 pass file owned by the console user — it is
// never on a command line, never in argv, and never in a keychain the
// agent's own account could reach. The human reads that file once, to type
// the password at the login screen during Fast User Switching.

func fail(_ reason: String) -> Never {
  FileHandle.standardError.write(("agentdesktop-setup: " + reason + "\n").data(using: .utf8)!)
  exit(1)
}

let usage = """
  usage: agentdesktop-setup create --account NAME --display NAME --owner-uid N --pass-file PATH

  Creates a standard macOS account for an agent via OpenDirectory.
  Prints JSON on success: {"account":...,"uid":...,"home":...}
  """

// ---- argument parsing ------------------------------------------------------

guard CommandLine.arguments.count == 10, CommandLine.arguments[1] == "create" else {
  fputs(usage + "\n", stderr); exit(2)
}
var account = "", display = "", passFile = ""
var ownerUID: UInt32 = 0
var i = 2
while i < CommandLine.arguments.count {
  let flag = CommandLine.arguments[i], value = CommandLine.arguments[i + 1]
  switch flag {
  case "--account": account = value
  case "--display": display = value
  case "--pass-file": passFile = value
  case "--owner-uid":
    guard let u = UInt32(value) else { fail("--owner-uid must be a number") }
    ownerUID = u
  default: fail("unknown flag \(flag)\n" + usage)
  }
  i += 2
}

// ---- request validation (same rules as the app, via SetupCore) -------------

guard geteuid() == 0 else {
  fail("must run as root — the app does this through the administrator prompt")
}
if let why = AccountName.reason(account) { fail(why) }
guard !display.isEmpty, display.count < 64 else { fail("the display name is empty or too long") }
guard !passFile.isEmpty else { fail("--pass-file is required") }
guard ownerUID > 0 else { fail("--owner-uid must be a real user id") }

// ---- guardrails (noodle's: refuse, never adopt, never modify) ---------------

guard getpwnam(account) == nil else {
  fail("an account named \(account) already exists — nothing was created or changed")
}
let home = "/Users/" + account
var homeStat = stat()
guard lstat(home, &homeStat) != 0 else {
  fail("\(home) already exists — an account or home with this name exists. It was not adopted or changed.")
}

// Next free UID from 501, same scan noodle does: getpwuid until it misses,
// then step past. If an existing agent account was renamed or deleted since
// the registry was written, the scan is the truth, not the registry.
var uid: UInt32 = 501
while getpwuid(uid_t(uid)) != nil { uid += 1 }
guard uid < 60_000 else { fail("no free UID between 501 and 60000") }

// ---- generate the password here, as root ------------------------------------

var bytes = [UInt8](repeating: 0, count: 32)
guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
  fail("could not generate a random password (SecRandomCopyBytes failed)")
}
let password = Data(bytes).base64EncodedString()

// ---- create the OD record ----------------------------------------------------

do {
  let node = try ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes))
  let attributes: [String: [String]] = [
    kODAttributeTypeUniqueID: [String(uid)],
    kODAttributeTypePrimaryGroupID: ["20"],            // staff, same as noodle
    kODAttributeTypeNFSHomeDirectory: [home],
    kODAttributeTypeUserShell: ["/bin/zsh"],
    kODAttributeTypeFullName: [display],
    kODAttributeTypeComment: ["Managed by Agent Desktop"],
  ]
  let user = try node.createRecord(withRecordType: kODRecordTypeUsers,
                                   name: account, attributes: attributes)
  try user.changePassword(nil, toPassword: password)
  try user.verifyPassword(password)   // prove the record actually authenticates
} catch {
  fail("OpenDirectory account creation failed: \(error)")
}

// ---- home directories (noodle's layout, 0700, owned by the agent) ------------

do {
  let fm = FileManager.default
  var dirs = [home]
  for sub in ["Desktop", "Documents", "Downloads", "Library", "Library/Preferences", "Movies", "Music", "Pictures", "Public"] {
    dirs.append(home + "/" + sub)
  }
  for dir in dirs {
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
  }
  // chown -R via fts would be nicer; a flat walk of what we made is enough,
  // because the home was just created and is empty.
  let en = fm.enumerator(atPath: home)
  while let path = en?.nextObject() as? String {
    en?.skipDescendants()   // the walk yields directories too; skip their children
    let full = home + "/" + path
    var st = stat()
    guard stat(full, &st) == 0 else { continue }
    guard chown(full, uid_t(uid), 20) == 0 else {
      fail("could not set ownership on \(full): \(String(cString: strerror(errno)))")
    }
  }
} catch {
  fail("home directory creation failed: \(error)")
}

// ---- pass file: 0600, owned by the console user -------------------------------
// Written only after the account exists, so a failure never leaves a password
// file for an account that was never created. O_EXCL so another local user
// cannot pre-plant a file for us to truncate as root.

passFile.withCString { cpath -> Void in
  let fd = open(cpath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  guard fd >= 0 else {
    fail("could not create \(passFile) exclusively (does it already exist, or is it a symlink?)")
  }
  defer { close(fd) }
  let data = (password + "\n").data(using: .utf8)!
  data.withUnsafeBytes { raw in
    var written = 0
    while written < raw.count {
      let n = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
      guard n > 0 else { fail("could not write the pass file") }
      written += n
    }
  }
  guard fchown(fd, uid_t(ownerUID), 20) == 0 else {
    fail("could not chown the pass file to uid \(ownerUID)")
  }
  guard fchmod(fd, 0o600) == 0 else { fail("could not chmod the pass file") }
}

// ---- report -------------------------------------------------------------------

let result = CreationResult(account: account, uid: uid, home: home)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let json = try! encoder.encode(result)
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))
