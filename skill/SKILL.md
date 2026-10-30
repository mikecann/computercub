---
name: computercub
description: ComputerCub, computer use for your Mac. Drive Mac apps (Finder, System Settings, Xcode, Helium, native dialogs and file pickers) and the parts of Chrome extensions can't reach (Chrome Web Store pages, chrome:// pages, Chrome's own toolbar and tabs) with the `computercub` command. Use when a job needs a native app or a page BrowserBear can't open.
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
4. Cmd shortcuts bring the window forward by themselves. If another key does nothing in a
   background app, retry with `--front`. If a click needs a real mouse, `--mouse`. Both
   briefly bring the window forward. `--mouse` scrolls the control into view first and
   won't click if something else would catch it.
5. Passwords, passkeys and 2FA are Mike's: `computercub handoff <window> "what to do" --wait 300`
   shows him a panel and waits for Done, then gives you the diff.
6. `computercub shot <window|ref>` only when you need to see it. It's window-only; run
   `computercub clean` when you're done with personal screenshots.
7. While the screen is locked macOS hides all windows from Accessibility, so window commands
   fail and say so; `computercub doctor` shows it too. Wait for Mike, or for a read-only
   check use AppleScript from your own shell if the app is scriptable.

Ask Mike before posting, sending, buying, deleting or changing settings or accounts.
