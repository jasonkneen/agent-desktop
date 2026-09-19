import Foundation
import Testing
@testable import agensis_cu

@Test func keyChordParsesModifiersAndKeys() {
  #expect(KeyChord.parse("return") == KeyChord(keyCode: 36, flags: 0))
  let c = KeyChord.parse("cmd+shift+t")
  #expect(c?.keyCode == 17)
  #expect(c?.flags == KeyChord.command | KeyChord.shift)
  #expect(KeyChord.parse("cmd+space")?.keyCode == 49)
  #expect(KeyChord.parse("page_down")?.keyCode == 121)
  #expect(KeyChord.parse("nonsense-key") == nil)
  #expect(KeyChord.parse("f5")?.keyCode == 96)
}

@Test func clickCoordinatesScaleFromLastScreenshot() {
  let fake = FakeDesktop()
  fake.captureScale = 2.0
  let tools = Tools(desktop: fake)
  _ = tools.call("screenshot", [:])           // fixes scale at 2.0
  _ = tools.call("click", ["x": 100.0, "y": 50.0])
  let click = fake.events.first { $0.kind == "click" }
  #expect(click?.a == 200.0)                    // 100 px * 2.0
  #expect(click?.b == 100.0)
  #expect(click?.s == "left")
}

@Test func defaultScaleBeforeScreenshotUsesDisplayWidth() {
  let fake = FakeDesktop()
  fake.widthPoints = 2560                        // 2560 / min(2560,1280) = 2.0
  let tools = Tools(desktop: fake)
  _ = tools.call("move", ["x": 10.0, "y": 10.0])
  #expect(fake.events.first?.a == 20.0)
}

@Test func screenshotReturnsImageContent() {
  let server = MCPServer(tools: Tools(desktop: FakeDesktop()))
  let resp = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                            "params": ["name": "screenshot", "arguments": [:]]])
  let content = ((resp?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
  #expect(content.contains { $0["type"] as? String == "image" })
}

@Test func permissionDenialSurfacesAsToolError() {
  let fake = FakeDesktop()
  fake.perms = PermissionState(screenRecording: false, accessibility: false)
  let server = MCPServer(tools: Tools(desktop: fake))
  let resp = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                            "params": ["name": "screenshot", "arguments": [:]]])
  #expect((resp?["result"] as? [String: Any])?["isError"] as? Bool == true)
}

@Test func initializeAndToolsListShape() {
  let server = MCPServer(tools: Tools(desktop: FakeDesktop()))
  let initResp = server.handle(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": [:]])
  #expect(((initResp?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "agensis-cu")
  #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
  let list = server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
  let names = (((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
  #expect(names.contains("screenshot"))
  #expect(names.contains("click"))
  #expect(names.contains("permissions"))
  #expect(names.contains("launch_app"))
}

@Test func typeAndKeyAndOpenRoute() {
  let fake = FakeDesktop()
  let tools = Tools(desktop: fake)
  _ = tools.call("type", ["text": "Hello VNC"])
  _ = tools.call("key", ["keys": "cmd+space"])
  _ = tools.call("launch_app", ["name": "TextEdit"])
  #expect(fake.events.contains { $0.kind == "type" && $0.s == "Hello VNC" })
  #expect(fake.events.contains { $0.kind == "key" && $0.a == 49 })
  #expect(fake.events.contains { $0.kind == "launch" && $0.s == "TextEdit" })
}

@Test func unknownMethodWithIdErrorsButNotificationDrops() {
  let server = MCPServer(tools: Tools(desktop: FakeDesktop()))
  #expect(server.handle(["jsonrpc": "2.0", "id": 9, "method": "bogus"]) != nil)
  #expect(server.handle(["jsonrpc": "2.0", "method": "bogus"]) == nil)
}
