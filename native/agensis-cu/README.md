# agensis-cu (native computer-use host)

Swift source for the host that gives an agent a real macOS desktop. It runs
inside a macOS user account and serves MCP over stdio; the relay loads it with
`--mcp-allow computer=<path>`.

```sh
swift build -c release      # binary at .build/release/agensis-cu
swift test                  # protocol + coordinate maths, no TCC grant needed
```

`../../scripts/build-computer-host.sh` builds it and stages the binary into the
published npm package. See `packages/agensis-agent/skills/agent-desktop-setup`
for the end-to-end setup this host is part of, and the root README for the
permission model.
