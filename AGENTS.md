# ComputerCub

Swift CLI plus background app that lets agents drive Mac apps through the Accessibility
API. README.md has the why and the shape; this is for working on it.

- `Sources/ComputerCub/`: `main.swift` picks CLI or service; `Service.swift` is the socket
  server and the thin client; `Commands.swift` has every command; `Snapshot.swift` turns
  an AX tree into ref lines and diffs; `Desktop.swift` holds refs, windows and app lookup;
  `Input.swift` keys and mouse; `Shot.swift` ScreenCaptureKit; `Handoff.swift` the panel.
- Build small: `swift build` (debug, about 15 s) while iterating. `./scripts/install.sh`
  makes the signed release app. The M5 is often under heavy load, so prefix with `nice`.
- To test without touching ComputerCub.app's own permissions, run the debug build as the
  service from your shell (`.build/debug/computercub serve`, in the background) and use the
  installed `computercub` CLI against it. It borrows whatever grants your terminal or Threadbear
  Runner has. `computercub quit` stops it.
- Test on harmless things (Finder windows you open yourself, System Settings' About
  pane). Close what you open, put back any tab you changed, and run `computercub clean` after
  screenshots. Ask Mike before anything that posts, sends, buys, deletes or changes a
  setting.
- Keep output small: every line in a snapshot costs every agent tokens on every look.
