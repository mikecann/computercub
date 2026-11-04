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
   Links show their real address when the name is a shortened one (Slack's
   `link "dropbox.com/…" → https://…`); `--find` gives every matching link's full address
   (`--find dropbox`), and `computercub read <ref>` lists the links inside that element.
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

## Mike's iPhone

Before asking Mike to check something on his iPhone 15 Pro Max (a setting, what's on screen),
look yourself. He's had to remind agents that this exists. There are two ways in, and which
one works depends on whether the phone is locked.

**Unlocked: `phone`.** A helper on the phone itself takes taps over Wi-Fi, so nothing on the Mac
is touched. `computercub shot phone`, then `click phone x y [--double|--long]`,
`swipe phone x y x2 y2`, `scroll phone down|up`, `type phone "text" [--submit]` after tapping the
field, `press phone home|return|delete|tab`, all in the last shot's pixels. The first command
starts the helper (about 10 seconds); after that each takes under a second. Try it first. If it
says the phone is locked, use iPhone Mirroring below. If it says the phone asked for Face ID,
ask Mike to look at his phone, then run it again.

**Locked: iPhone Mirroring.**

- `open -a "iPhone Mirroring"`, wait a few seconds, then `computercub shot "iPhone Mirroring"`.
  The window exposes nothing to Accessibility, so `snap` gives no refs and shots are how you read it.
- Drive it with positions from its last shot, in that picture's pixels: `computercub click "iPhone Mirroring" x y`,
  `computercub swipe "iPhone Mirroring" x y x2 y2`, and `computercub type "iPhone Mirroring" "text" [--submit]` after
  tapping the field. `computercub press "iPhone Mirroring" cmd+1` goes Home, `cmd+2` opens the app switcher, `cmd+3` Search.
  All of it runs from the background, so Mike keeps his pointer, keyboard and front app. `--pointer` and `--front` take them
  from him, so on the mirror they're refused while he's used the Mac in the last two minutes; don't get round that with
  osascript or your own events. When a tap misses, send it again the same way: the first one after it connects often gets eaten.
- `type` sends short text as real keys, as a keyboard plugged into the phone would. Long text (over 60 characters),
  anything with a line break, and characters that aren't on a US keyboard go in as a paste instead, in one call, with
  Mike's clipboard put back after. So send a whole multi-line message in one `type`, not a call per line. `press`
  works on the phone too: `cmd+a` then `delete` clears a field.
- Only one agent at a time on the phone. If an answer says "Heads up: another … session used this window", another
  thread is driving it (or relaunching apps on it), and taps will land on its screens, not yours. Stop and tell Mike.
- `swipe` is a finger drag: it pages the home screen and works sideways swipes and sliders, but a drag doesn't scroll
  a list on the phone (iOS treats a pointer drag as a drag, as on an iPad). For lists use
  `computercub scroll "iPhone Mirroring" down` (or `up`), about 40% of a screen each, from the background in about
  8 seconds. If that doesn't move the phone it borrows Mike's pointer for about a second, but only while he's away;
  otherwise it says so, and you take a shot and try again.
  Start swipes on an empty spot: if the drag doesn't take, the phone sees a tap where it started.
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
