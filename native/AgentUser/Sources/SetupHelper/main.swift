import Foundation
import OpenDirectory
import Security
import SetupCore
import Darwin

// agentdesktop-setup — a root helper that creates the agent's macOS account
// and signs it in, in the background.
//
// Ported from noodle's LocalMacService: OpenDirectory createRecord with a
// scanned free UID, verifyPassword after changePassword, mkdir-0700 home
// dirs, refusal guardrails — and the part that makes it feel automatic,
// SLSCreateLoginSessionWithDataAndVisibility (SkyLight private framework,
// dlopen'd): an off-console background login, so nobody ever types the
// password at a login screen. The password is generated here, as root, and
// written straight to a 0600 pass file owned by the console user — never on
// a command line, never in a keychain the agent's own account could reach.

func fail(_ reason: String) -> Never {
  log("FAILED: " + reason)
  FileHandle.standardError.write(("agentdesktop-setup: " + reason + "\n").data(using: .utf8)!)
  exit(1)
}

let usage = """
  usage: agentdesktop-setup create --account NAME --display NAME --owner-uid N --pass-file PATH
                                   [--vnc-port P --vnc-pass-file PATH]
         agentdesktop-setup login  --account NAME --pass-file PATH
                                   [--vnc-port P --vnc-pass-file PATH]

  create: makes a standard macOS account via OpenDirectory, then starts its
          desktop session in the background (SkyLight, root-only).
  login:  signs an existing account in the same way, reading the password
          from its pass file. If the account already has a session, it is
          reused rather than stacked.

  With --vnc-port and --vnc-pass-file, both actions also install the
  account's LaunchAgents (the VNC stream and the app) and load them into a
  live session, so logging in is all it takes.

  Prints JSON on success: {"account":...,"uid":...,"home":...,"session":...}
  """

// ---- SkyLight private session APIs (noodle's LocalMacPrivate, inlined) ------

// nonisolated(unsafe): a dlopen handle is immutable once loaded and this is a
// short-lived command-line process — there is no other actor to race with.
private nonisolated(unsafe) let skyLight: UnsafeMutableRawPointer? =
  dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_NOW)

/// Returns (status, sessionID). Zero visibility = an off-console login; this
/// does not enable Screen Sharing. Root only, like the real API requires.
private func slsCreateSession(payload: Data) -> (status: Int32, id: UInt32) {
  guard geteuid() == 0, let handle = skyLight,
        let sym = dlsym(handle, "SLSCreateLoginSessionWithDataAndVisibility") else { return (-1, 0) }
  typealias Create = @convention(c) (UnsafeRawPointer, Int, UInt32,
                                     UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer?) -> Int32
  let create = unsafeBitCast(sym, to: Create.self)
  var id: UInt32 = 0
  let status = payload.withUnsafeBytes { raw in
    create(raw.baseAddress!, payload.count, 0, &id, nil)
  }
  return (status, id)
}

private func slsSessions() -> [[String: Any]] {
  typealias Copy = @convention(c) () -> Unmanaged<CFArray>?
  guard let handle = skyLight, let sym = dlsym(handle, "SLSCopySessionList") else { return [] }
  guard let cf = unsafeBitCast(sym, to: Copy.self)() else { return [] }
  return (cf.takeRetainedValue() as NSArray) as! [[String: Any]]
}
private func sessionID(_ record: [String: Any]) -> UInt32? {
  (record["kCGSSessionIDKey"] as? NSNumber)?.uint32Value
}
private func sessionUser(_ record: [String: Any]) -> UInt32? {
  (record["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value
}
/// The account's existing GUI session, if it has one. Signing in twice would
/// stack sessions; this is also what lets `login` double as "make sure it's
/// in and streaming".
private func existingSession(uid: UInt32) -> UInt32? {
  slsSessions().first(where: { sessionUser($0) == uid }).flatMap(sessionID)
}

/// A stderr warning that does not fail the run: the account and session are
/// fine even if, say, bootstrap hit an already-loaded agent.
func warn(_ reason: String) {
  log("warning: " + reason)
  FileHandle.standardError.write(("agentdesktop-setup: warning: " + reason + "\n").data(using: .utf8)!)
}

/// Every run lands in <prefix>/log/helper.log: root writes it, everyone can
/// read it, and the app points people there when something does not come up —
/// so "nothing happened" is never the whole story. Best effort only: a logging
/// failure must never fail a run that would otherwise work. Passwords and
/// their files' contents never appear here.
///
/// nonisolated(unsafe): written once before anything logs, then read-only —
/// same single-threaded-CLI reasoning as skyLight below.
nonisolated(unsafe) var logPath: String?

func log(_ line: String) {
  guard let path = logPath else { return }
  let stamp = ISO8601DateFormatter().string(from: Date())
  let text = "\(stamp) \(line)\n"
  let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
  guard fd >= 0 else { return }
  defer { close(fd) }
  text.withCString { raw in
    _ = raw.withMemoryRebound(to: UInt8.self, capacity: text.utf8.count) {
      write(fd, $0, text.utf8.count)
    }
  }
}

/// Writes a LaunchAgent plist into the agent's home, owned by the agent.
private func writeAgentPlist(_ plist: [String: Any], path: String, uid: UInt32) throws {
  let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  guard chown(path, uid_t(uid), 20) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}

private func runLaunchctl(_ arguments: [String]) -> Int32 {
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
  proc.arguments = arguments
  proc.standardOutput = FileHandle.nullDevice
  proc.standardError = FileHandle.nullDevice
  do { try proc.run() } catch { return -1 }
  proc.waitUntilExit()
  return proc.terminationStatus
}

/// Installs the per-user LaunchAgents that make logging in enough: the VNC
/// stream (kept alive — it IS the desktop's eyes) and the app itself, which
/// in the agent's account is the permissions wizard. Without these, a fresh
/// account logs in to an empty desktop and nothing ever starts.
private func provisionStream(home: String, uid: UInt32, port: UInt16, vncPassFile: String) {
  let fm = FileManager.default
  let pass = ((try? String(contentsOfFile: vncPassFile, encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !pass.isEmpty else {
    warn("the VNC password file is empty or unreadable — stream not provisioned")
    return
  }

  let launchAgents = home + "/Library/LaunchAgents"
  let logDir = home + "/Library/Logs"
  let logs = logDir + "/mac-vnc-server"
  do {
    try fm.createDirectory(atPath: launchAgents, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o755])
    try fm.createDirectory(atPath: logs, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o755])
    // Everything just made was made by root — and so was anything left behind
    // by an earlier run, which never handed these over. The agents run as the
    // account: a root-owned log directory makes launchd kill the server before
    // it even starts ("could not open stdout path"), so ownership is set every
    // time, not only when the directory was just created.
    for dir in [home + "/Library", logDir, logs, launchAgents] {
      guard chown(dir, uid_t(uid), 20) == 0 else {
        warn("could not set ownership on \(dir); the account may not be able to run its agents")
        return
      }
    }
    log("LaunchAgents and log directories now owned by uid \(uid)")
  } catch {
    warn("could not create \(launchAgents): \(error.localizedDescription) — stream not provisioned")
    return
  }

  let serverPlist: [String: Any] = [
    "Label": "com.agentdesktop.mac-vnc-server",
    "ProgramArguments": [
      "/Users/Shared/agensis/mac-vnc-server", "run",
      "--bind", "127.0.0.1", "--port", String(port),
      "--display", "1", "--encoding", "zlib",
      "--password", pass,
    ],
    "WorkingDirectory": home,
    "RunAtLoad": true,
    "KeepAlive": true,
    "LimitLoadToSessionType": "Aqua",
    "ProcessType": "Interactive",
    "EnvironmentVariables": ["HOME": home],
    "StandardOutPath": logs + "/stdout.log",
    "StandardErrorPath": logs + "/stderr.log",
  ]
  let appPlist: [String: Any] = [
    "Label": "com.agentdesktop.agentuser",
    "ProgramArguments": ["/Users/Shared/agensis/AgentUser.app/Contents/MacOS/AgentUser"],
    "RunAtLoad": true,
    "LimitLoadToSessionType": "Aqua",
    "EnvironmentVariables": ["HOME": home],
  ]

  do {
    try writeAgentPlist(serverPlist, path: launchAgents + "/com.agentdesktop.mac-vnc-server.plist", uid: uid)
    try writeAgentPlist(appPlist, path: launchAgents + "/com.agentdesktop.agentuser.plist", uid: uid)
    log("wrote both LaunchAgents (stream on port \(port), app)")
  } catch {
    warn("could not write the LaunchAgents: \(error.localizedDescription)")
    return
  }

  // The account is signed in right now — load the agents into its live
  // session rather than making the human log out and back in. Already-loaded
  // is fine: kickstart just restarts them with the new plist.
  guard existingSession(uid: uid) != nil else {
    log("no live session for uid \(uid); the agents start at its next login")
    return
  }
  for label in ["com.agentdesktop.mac-vnc-server", "com.agentdesktop.agentuser"] {
    let domain = "gui/\(uid)"
    let target = domain + "/" + label
    let boot = runLaunchctl(["bootstrap", domain, launchAgents + "/" + label + ".plist"])
    if boot == 0 {
      log("\(label): loaded into \(domain)")
    } else if runLaunchctl(["kickstart", "-k", target]) == 0 {
      log("\(label): bootstrap=\(boot), kickstart restarted it")
    } else {
      warn("could not load \(label) into the live session; it starts at the next login")
    }
  }
}

/// The noodle login: OD record details + the password as `UserPasswordKey`,
/// marked as started by screen sharing, binary-plist'd, handed to SkyLight.
/// Polls the session list afterwards so "started" means the session exists.
private func startBackgroundSession(user: ODRecord, account: String, password: String) throws
  -> (session: UInt32, confirmed: Bool) {
  var payload = (try user.recordDetails(forAttributes: [kODAttributeTypeAllAttributes])
                   as? [String: Any]) ?? [:]
  payload["username"] = account
  payload["UserPasswordKey"] = password
  payload["SessionStartedBy"] = "ScreenSharing"
  let data: Data
  do {
    data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
  } catch {
    fail("could not build the login payload: \(error)")
  }
  let (status, sid) = slsCreateSession(payload: data)
  guard status == 0, sid != 0 else {
    fail("macOS background login failed (\(status)). The account was kept; sign it in via the user menu.")
  }
  for _ in 0..<75 {                       // 15 s: loginwindow usually beats this
    if slsSessions().contains(where: { sessionID($0) == sid }) { return (sid, true) }
    usleep(200_000)
  }
  return (sid, false)
}

// ---- argument parsing -------------------------------------------------------

guard CommandLine.arguments.count >= 2 else { fputs(usage + "\n", stderr); exit(2) }
let action = CommandLine.arguments[1]

var account = "", display = "", passFile = "", vncPassFile = ""
var ownerUID: UInt32 = 0
var vncPort: UInt16?
switch action {
case "create", "login":
  var i = 2
  let args = CommandLine.arguments
  while i < args.count {
    guard i + 1 < args.count else { fputs(usage + "\n", stderr); exit(2) }
    let flag = args[i], value = args[i + 1]
    switch flag {
    case "--account": account = value
    case "--display": display = value
    case "--pass-file": passFile = value
    case "--vnc-pass-file": vncPassFile = value
    case "--vnc-port":
      guard let p = UInt16(value), p > 0 else { fail("--vnc-port must be a port number") }
      vncPort = p
    case "--owner-uid":
      guard let u = UInt32(value) else { fail("--owner-uid must be a number") }
      ownerUID = u
    default: fail("unknown flag \(flag)\n" + usage)
    }
    i += 2
  }
default:
  fputs(usage + "\n", stderr); exit(2)
}

// ---- request validation (same rules as the app, via SetupCore) -------------

// The log lives beside the pass file, so every machine layout logs the same
// way. Set before validation: a refused request is exactly the run most worth
// seeing in the log.
logPath = (passFile as NSString).deletingLastPathComponent + "/log/helper.log"
// O_CREAT below makes the file, not its directory — without this, the first
// run on a machine logs nothing at all, silently, and the note in the app
// points at a log that does not exist.
mkdir((logPath! as NSString).deletingLastPathComponent, 0o755)
log("run: \(action) account=\(account) vncPort=\(vncPort.map(String.init) ?? "-")")

guard geteuid() == 0 else {
  fail("must run as root — the app does this through the administrator prompt")
}
if let why = AccountName.reason(account) { fail(why) }
if action == "create" {
  guard !display.isEmpty, display.count < 64 else { fail("the display name is empty or too long") }
  guard ownerUID > 0 else { fail("--owner-uid must be a real user id") }
}
guard !passFile.isEmpty else { fail("--pass-file is required") }

let node: ODNode
let user: ODRecord
var uid: UInt32 = 0
let password: String
var home = "/Users/" + account

if action == "create" {
  // ---- guardrails (noodle's: refuse, never adopt, never modify) ------------

  guard getpwnam(account) == nil else {
    fail("an account named \(account) already exists — nothing was created or changed")
  }
  var homeStat = stat()
  guard lstat(home, &homeStat) != 0 else {
    fail("\(home) already exists — an account or home with this name exists. It was not adopted or changed.")
  }

  // Next free UID from 501, same scan noodle does: getpwuid until it misses,
  // then step past. If an existing agent account was renamed or deleted since
  // the registry was written, the scan is the truth, not the registry.
  uid = 501
  while getpwuid(uid_t(uid)) != nil { uid += 1 }
  guard uid < 60_000 else { fail("no free UID between 501 and 60000") }

  // ---- generate the password here, as root ----------------------------------

  var bytes = [UInt8](repeating: 0, count: 32)
  guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
    fail("could not generate a random password (SecRandomCopyBytes failed)")
  }
  password = Data(bytes).base64EncodedString()

  // ---- create the OD record ---------------------------------------------------

  do {
    node = try ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes))
    let attributes: [String: [String]] = [
      kODAttributeTypeUniqueID: [String(uid)],
      kODAttributeTypePrimaryGroupID: ["20"],            // staff, same as noodle
      kODAttributeTypeNFSHomeDirectory: [home],
      kODAttributeTypeUserShell: ["/bin/zsh"],
      kODAttributeTypeFullName: [display],
      kODAttributeTypeComment: ["Managed by Agent Desktop"],
    ]
    user = try node.createRecord(withRecordType: kODRecordTypeUsers,
                                 name: account, attributes: attributes)
    try user.changePassword(nil, toPassword: password)
    try user.verifyPassword(password)   // prove the record actually authenticates
  } catch {
    fail("OpenDirectory account creation failed: \(error)")
  }

  // ---- home directories (noodle's layout, 0700, owned by the agent) ----------

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
    // The home was just created and is empty; a flat walk of it is enough.
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

  // ---- pass file: 0600, owned by the console user -----------------------------
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
} else {
  // ---- login: an existing account, from its pass file ------------------------
  // Recovery path: the account exists but has no session (e.g. created before
  // background login existed, or macOS logged it out at a restart).

  guard let pw = getpwnam(account) else {
    fail("no account named \(account) exists — nothing to sign in")
  }
  uid = UInt32(pw.pointee.pw_uid)
  home = String(cString: pw.pointee.pw_dir)

  guard FileManager.default.isReadableFile(atPath: passFile) else {
    fail("cannot read \(passFile) — the password file is missing or unreadable")
  }
  let stored = (try? String(contentsOfFile: passFile, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !stored.isEmpty else { fail("\(passFile) is empty") }
  password = stored

  do {
    node = try ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes))
    user = try node.record(withRecordType: kODRecordTypeUsers, name: account, attributes: nil)
    try user.verifyPassword(password)   // never start a session for a wrong password
  } catch {
    fail("could not verify the stored password for \(account): \(error)")
  }
}

// ---- the noodle part: background login, no human at a login screen ----------
// If the account already has a session (the human just logged in at the
// login screen, or signed in before), reuse it — creating a second one
// would stack sessions on the account.

let (session, confirmed): (UInt32, Bool)
if let existing = existingSession(uid: uid) {
  log("reusing session \(existing) for uid \(uid)")
  (session, confirmed) = (existing, true)
} else {
  let started = try startBackgroundSession(user: user, account: account, password: password)
  log("started session \(started.session), confirmed=\(started.confirmed)")
  (session, confirmed) = (started.session, started.confirmed)
}

// ---- make logging in enough: the stream and the app start themselves --------

if let port = vncPort, !vncPassFile.isEmpty {
  provisionStream(home: home, uid: uid, port: port, vncPassFile: vncPassFile)
} else {
  log("no vnc port given; LaunchAgents not provisioned")
}

// ---- report -------------------------------------------------------------------

var result = CreationResult(account: account, uid: uid, home: home)
result.session = session
result.sessionConfirmed = confirmed
log("done: account=\(account) uid=\(uid) session=\(session) confirmed=\(confirmed)")
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let json = try! encoder.encode(result)
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))
