# Mitts

Lets your local AI agents use the apps on your Mac: Finder, System Settings, Xcode, and
the bits of Chrome a browser extension can't reach (Chrome Web Store pages, `chrome://`
pages, other extensions' pages, file pickers and permission dialogs). Any agent that can
run a command can use it.

It's the desktop sibling of [Paws](https://github.com/mikecann/paws), which drives Chrome
pages from the inside. Paws for the browser, Mitts for everything else.

It's a spike: macOS 14 or later, tested on macOS 26.6 with three displays.

## Why

On 29 Oct 2026 the ChatGPT app's computer-use service added a signed "browser access"
check, which killed our codex-browser bridge, and Codex's own desktop control of Chrome
stopped working until the ChatGPT app was opened. Everything we had for driving the Mac
depended on someone else's private plumbing. Mitts is ours, signed with our certificate,
and runs entirely on the Mac.

## How it fits together

```
mitts CLI (any agent)
  → Mitts.app, a background app with no Dock icon, on a Unix socket in
    ~/Library/Application Support/Mitts
  → the macOS Accessibility API (reading and pressing things)
    and ScreenCaptureKit (window-only screenshots)
```

macOS gives Accessibility and Screen Recording to the "responsible" process. A command
an agent runs counts as part of whatever started the agent (Threadbear Runner, Terminal),
so those apps would end up holding the grants. Instead the CLI passes each command to
Mitts.app, which holds them under one code signature. The CLI starts the app the first
time you use it. This is the same trick as Peekaboo's bridge, and Paws' service.

What it's like to use:

- Windows are named by what they are: `Finder`, `"Chrome:Web Store"` (an app and part of
  a title), or a ref like `w3` that sticks to that window for as long as it's open.
  Chrome puts the profile name in its window titles, so `"Chrome:Michael"` finds the
  right profile.
- `mitts snap` lists what you can click or type in, with refs (`e12`) that stay on the
  same control. After the first look you get only what changed.
- Clicking, typing and keys all answer with that diff, and with any new window or sheet
  the app opened, so there's no separate look.
- Actions go through the Accessibility API first: no mouse, no stealing focus, and they
  work on windows behind other windows and on other displays. `--mouse` and `--front`
  are there for the few things that need a real click or the active app.
- Password fields are masked and `mitts type` refuses them. `mitts handoff` puts an "Over
  to you" panel on the window for sign-ins, passkeys and 2FA, and can wait for Done.
- Screenshots are of one window (or one element), never the whole screen, shrunk to
  1600 px, and deleted after an hour.

## Install

```sh
./scripts/install.sh    # builds Mitts.app into ~/Applications, links `mitts` into ~/.local/bin
                        # and the agent skill into ~/.claude/skills and ~/.codex/skills
mitts doctor            # starts it, and says which permissions it still needs
```

The first time it starts, macOS asks for Accessibility (needed) and Screen Recording
(only for `mitts shot`). Both are in System Settings › Privacy & Security.

The script signs with your Apple Development certificate, keeping the default designated
requirement (this bundle id, signed by that certificate). That's what lets the grants
survive a rebuild while nothing signed by anyone else can claim them. Without a
certificate it signs ad hoc, and macOS asks again after every build.

## Use

```sh
mitts windows                                # every app's windows, with refs and displays
mitts snap Finder                            # the front Finder window
mitts click e23
mitts press w2 cmd+shift+g                   # keys go to the app, even in the background
mitts type e57 "~/Downloads" --submit
mitts menu Finder "File > New Finder Window"
mitts read "System Settings"                 # the words, for reading values
mitts snap "Chrome:Michael"                  # Chrome's toolbar, tabs and the page
mitts shot w2                                # prints the PNG path
mitts handoff "Chrome:App Store Connect" "Sign in with your passkey, then click Done" --wait 300
```

`mitts help` lists everything.

## What works so far

Tested by hand on 29 Oct 2026:

- Finder: list and select files, Go to Folder by keys in the background, type a path,
  Back, close the window, and spot the new window when one opens.
- System Settings: read the About pane, move between panes. SwiftUI makes new elements
  on every look, so a control that reappears looking exactly the same keeps its ref.
- Chrome: toolbar, address bar, extensions, bookmarks bar and tabs, plus the page itself.
  It reads the Chrome Web Store developer dashboard (which Paws can't), including a
  modal's text and buttons. Snapshots take 0.1 to 0.6 s.
- Window-only screenshots of a window behind others, and element crops.
- The handoff panel and `--wait`.

## Not yet

- Chrome only gives its browser window keyboard focus while Chrome is the active app, so
  some shortcuts (cmd+w) need `press --front`, which brings the window forward for the
  keystroke and then gives you back whatever you had in front.
- Windows on other Spaces don't show up (macOS only lists the current Space's).
- Chrome stops updating a page's tree while its window is fully covered.
- No scrolling by mouse wheel, drag and drop, or right-click menus yet.
- No approvals for posting, sending or deleting; Threadbear will own those, as for Paws.
- No LaunchAgent (the CLI starts the app when it's needed).
