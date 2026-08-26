# slyTerm 2.6 launch posts (paste-ready; you post, nothing here auto-posts)

## Show HN
**Title:** Show HN: slyTerm – a macOS terminal where every tab is a Claude Code chat that survives sleep and restarts
**Text:**
I run 5-6 Claude Code sessions all day and kept losing them: Terminal.app on a restart, browser tabs on sleep, and my watch had no idea any of them existed.

slyTerm is a ~900-line Swift + WebKit app that treats a tab as a *chat*, not a shell. Each tab is a window in a shared tmux group named by the tab; reload, wake, quit, crash — relaunch and every tab re-attaches to the same conversation. A 3-second supervisor reconciles tabs with `tmux list-windows`, so a chat started from my Apple Watch shows up as a tab, and Cmd+W kills the window so the watch and desktop always agree. Remote Control is on for every tab, so the phone app sees them too.

Source (MIT): https://github.com/AssiamahS/slyTerm — prebuilt DMG + the watch daemon kit: https://sylvassiamah.gumroad.com/l/slyterm

Happy to answer questions about the tmux session-group trick (grouped sessions share windows but keep an independent current window per client, which is what makes "one tab = one window" work).

## Reddit r/ClaudeAI
**Title:** I built a Mac terminal where each tab is a Claude Code chat with Remote Control on, and the chats survive sleep/restart (open source)
**Body:** Same as HN, plus: "The watch part is a separate daemon (ccwatch) that reads Claude Code's own session registry, so the list on the wrist is literally the tabs on the Mac in the same order, and a dictated reply is typed into that tab."

## Reddit r/macapps
**Title:** slyTerm 2.6 — native Swift terminal for Claude Code sessions, ~230KB, no Electron, tabs persist through restarts
**Body:** Two-paragraph version. Lead with "no Electron, 230 KB, Apple Silicon", then the tmux persistence.

## X / Threads (one post)
Every tab in this terminal is a Claude Code chat. Close the lid, restart the Mac, relaunch — same chats, same tabs. And they're on my watch.
~900 lines of Swift, MIT.
github.com/AssiamahS/slyTerm
DMG + watch kit: sylvassiamah.gumroad.com/l/slyterm

## Where it fits in the store
Product page permalink: /l/slyterm ($12). Cross-link from the MCP Server Cookbook page ("the terminal I run these from").
