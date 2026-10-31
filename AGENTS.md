# ComputerCub

Swift CLI plus background app that lets agents drive Mac apps through the Accessibility
API. README.md has the why and the shape; this is for working on it.

- `Sources/ComputerCub/`: `main.swift` picks CLI or service; `Service.swift` is the socket
  server and the thin client; `Commands.swift` has every command; `Snapshot.swift` turns
  an AX tree into ref lines and diffs; `Desktop.swift` holds refs, windows and app lookup;
  `Input.swift` keys and mouse; `Shot.swift` ScreenCaptureKit; `Handoff.swift` the panel.
- Build small: `swift build` (debug, about 15 s) while iterating. `./scripts/install.sh`
  makes the signed release app. The M5 is often under heavy load, so prefix with `nice`.
- To test without touching ComputerCub.app or the agents using it, give the debug build its
  own folder: `export COMPUTERCUB_HOME=/tmp/cub-dev`, start `.build/debug/computercub serve`
  in the background, and use `.build/debug/computercub` against it (same env). It borrows
  whatever grants your terminal or Threadbear Runner has. `.build/debug/computercub quit`
  with the env set stops it; without the env, `quit` stops everyone's ComputerCub.
- Clicks and keys go through Accessibility and post to the app's process. Real mouse events
  take Mike's pointer, so add another route before reaching for `Input.click`.
- Test on harmless things (Finder windows you open yourself, System Settings' About
  pane). Close what you open, put back any tab you changed, and run `computercub clean` after
  screenshots. Ask Mike before anything that posts, sends, buys, deletes or changes a
  setting.
- Live tests share Mike's screen. Before one, check he's away (`ioreg -c IOHIDSystem | awk '/HIDIdleTime/{print int($NF/1e9); exit}'`
  gives seconds since his last input; under a minute or two means he's typing) and if he is, wait or ask. Even a
  background press can cost him keystrokes, and anything that brings a window forward (`--front`, osascript
  `activate`) certainly does.
- Keep output small: every line in a snapshot costs every agent tokens on every look.
