---
name: computercub
description: ComputerCub, computer use for your Mac. Drive Mac apps (Finder, System Settings, Xcode, Helium, native dialogs and file pickers) and the parts of Chrome extensions can't reach (Chrome Web Store pages, chrome:// pages, Chrome's own toolbar and tabs) with the `computercub` command, and see and drive Mike's iPhone through iPhone Mirroring. Use when a job needs a native app, a page BrowserBear can't open, or something done or checked on his phone before asking him.
---

# ComputerCub

`computercub` reads windows through the macOS Accessibility API and acts on them by ref. Use
BrowserBear for ordinary Chrome pages; ComputerCub is for everything else.

1. `computercub windows [app]` to find the window. Name it as `w3`, `Finder`, or an app plus
   part of its title: `"Chrome:Michael"` (Chrome titles end with the profile name).
2. `computercub snap <window>` lists controls as `e12 button "Save"`. Later snaps show only
   what changed. On a long pane, `computercub snap <window> --find Privacy` lists just the
   matching controls. `computercub read <window>` gives the words, for reading values.
3. `computercub click e12`, `computercub type e7 "text" [--submit]`, `computercub press <window> cmd+shift+g`,
   `computercub menu <app> "File > New Window"`, `computercub drag e19 e18` (a file onto a folder),
   `computercub move <window> x y [w h]`, `computercub scroll <window> down` (says how far down it
   got). Each answers with what changed, so don't snap again after it. In a file picker,
   cmd+shift+g opens Go to Folder for hidden places like ~/Library.
4. Windows stay in the background, so Mike keeps his focus. `press` runs a cmd shortcut by
   pressing its menu item, Return and Escape as the control's Confirm and Cancel (Escape on a
   Save or Open sheet presses its Cancel button), and other keys go to the app directly.
   When none of that can reach it (a greyed-out item, a file picker's own shortcuts), it
   says "Not sent" rather than taking his focus. Then click a button for it if there is
   one; add `--front` (on `press`, `type` or `scroll`) only when it's worth interrupting him.
   Prefer a `click` on a button over a shortcut when there's one.
   When a plain `click` does nothing, `--mouse` sends a mouse click to the window itself:
   Mike's pointer doesn't move and the window stays in the background. `--pointer` uses
   his real pointer and brings the window forward, so it's the last resort, for when
   `--mouse` changed nothing (hover-only controls in Mac apps need it). A plain `click`
   flips System Settings switches, and `click --double` opens things (a Finder sidebar
   item, a file). For a web page's "Choose files", use `browserbear upload`. Don't write
   your own mouse-event tool: it takes his pointer.
5. `computercub type` without flags only sets the field's value, which apps may not notice: a
   rename in Finder shows the new text and stays the old name. Use `--submit` to have it
   typed with real keys and Return, or `--keys` for keys alone. If they don't reach the
   field from the background, it says so; `--front` brings the window up and clicks it.
6. Passwords, passkeys and 2FA are Mike's: `computercub handoff <window> "what to do" --wait 300`
   shows him a panel and waits for Done, then gives you the diff.
7. `computercub shot <window|ref>` only when you need to see it. For a window with no refs, `click`,
   `swipe` and `type` take a window and positions from its last shot, as under iPhone Mirroring. It's that window only, plus
   any menu or popover it has open; run `computercub clean` when you're done with personal
   screenshots. `snap` lists open menus and popovers too, and says when a menu is on screen
   but can't be read yet, so no `[menu]` means no menu.
8. While the screen is locked macOS hides all windows from Accessibility, so window commands
   fail and say so; `computercub doctor` shows it too. Wait for Mike, or for a read-only
   check use AppleScript from your own shell if the app is scriptable.

## iPhone Mirroring

Before asking Mike to check something on his iPhone 15 Pro Max (a setting, what's on screen),
look yourself. He's had to remind agents that this exists.

- `open -a "iPhone Mirroring"`, wait a few seconds, then `computercub shot "iPhone Mirroring"`.
  The window exposes nothing to Accessibility, so `snap` gives no refs and shots are how you read it.
- Drive it with positions from its last shot, in that picture's pixels: `computercub click "iPhone Mirroring" x y`,
  `computercub swipe "iPhone Mirroring" x y x2 y2`, and `computercub type "iPhone Mirroring" "text" [--submit]` after
  tapping the field. `computercub press "iPhone Mirroring" cmd+1` goes Home, `cmd+2` opens the app switcher, `cmd+3` Search.
  All of it runs from the background, so Mike keeps his pointer, keyboard and front app. Don't use `--pointer`, `--front`
  or your own click tool here: they take them from him, and he finds that really annoying.
- Each one answers without saying what changed, so take a new shot after it. Look before tapping again, since a tap that
  worked can take a moment to show, and repeating it lands on whatever's there now. The first gesture after it
  connects can get eaten, and small buttons sometimes miss. Passwords and passcodes stay Mike's.
- It only connects while the phone is locked. "iPhone in Use" means he has it in his hand, so
  don't wait on it. If it's stuck setting up, run `killall rapportd sharingd` (they relaunch) and reopen it.
- It draws the Dynamic Island plain black, so the blue location arrow doesn't show.
- Quit it when you're done: `osascript -e 'quit app "iPhone Mirroring"'`.

The window you're in shows Mike a blue outline with a bear peering over it. If a command says he
clicked stop, stop and ask him. Run `computercub resume` only once he says carry on.

Ask Mike before posting, sending, buying, deleting or changing settings or accounts.
