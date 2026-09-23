# slyTerm notes

- 2026-08-26 (v2.6.0): THE crash (3 identical reports Aug 23/24/26, `objc_release` inside
  `-[_NSWindowTransformAnimation dealloc]` during a CA transaction flush) was a double
  release: `AppWindow` is created in code, so `isReleasedWhenClosed` defaulted to true —
  AppKit released it on close while ARC still owned it via `windows`. The dangling close
  animation blew up minutes later. Fix: `win.isReleasedWhenClosed = false`. Any NSWindow
  built without a nib needs that line.
- White screen at login: slyTerm (login item) raced launchd's ttyd; one `load()` with no
  navigation delegate meant a refused connection stayed blank forever. ttyd 1.7.7's
  frontend has NO reconnect either (no "reconnect" string in the binary), so a dead
  websocket after sleep also stayed blank. TermPane now retries with backoff, reloads
  when WebKit kills the content process, and the tmux supervisor reloads a pane whose
  window has no client.
- tmux is the source of truth: one tab == one window in the `slywatch` group, named by
  the tab and passed through `ttyd -a` as `?arg=NAME` so reloads/relaunches re-attach
  to the same chat. Orphan windows become tabs (adoption), a window that dies takes
  its tab with it, Cmd+W / red button kill the window. The base session's `home`
  window is a sleeper, never a chat.
- zsh trap: an unquoted `=slywatch` argument is expanded by zsh to the path of the
  `slywatch` command on PATH. Quote tmux `=name` targets in interactive shells.
- `launchctl kickstart -k` does NOT re-read an edited plist — bootout + bootstrap.
- 2026-09-02: RC 'Session creation failed' at login = boot DNS race (claude doesn't retry RC creation); slyterm-shell now waits for api.anthropic.com before exec. tmux 3.5a sanitizes TAB in -F output to '_' — slyterm MCP separators must be printable (SEP='|;|'). Fix a dead tab in place: tmux respawn-window -k -t '=slywatch:N' ~/.local/bin/slyterm-shell
- 2026-09-09: slyterm MCP open_tab used osascript Cmd+T via System Events and hung/timed out (AppleEvent -1712, Accessibility). Rewritten in ~/.claude/mcp-servers/slyterm/server.mjs to the no-permission path (~100ms): `tmux new-window -d -t '=slywatch' -n NAME ~/.local/bin/slyterm-shell NAME` — the 3s supervisor adopts the orphan window as a new tab (verified in ~/Library/Logs/slyterm.log 'adopting orphan chat').
- 2026-09-09 v2.7.0: command channel via Darwin notify (bridge.h + -import-objc-header): `notifyutil -p com.sly.slyterm.newWindow` opens a new window, `.newSplit` a new split — instant, zero permissions. AppleEvents/System Events HANG from claude chats (both 'tell app' and Accessibility paths), so never script slyTerm with osascript. notify.h is not visible to Swift without a bridging header.
- 2026-09-15 mic: Claude Code voice ('No audio detected') works only when the tmux SERVER was forked by an app holding the Microphone TCC grant (Terminal.app); a server created by ttyd's slyterm-shell (launchd agent) hears silence even though the ttyd binary has a grant. The 23:47 restart raced: slyTerm's panes reconnected through ttyd and recreated the server (pid 1206, -x 40 -y 12) before the script did, and 7 of 11 chats were dropped. slyterm-restart-server now quits slyTerm BEFORE kill-server and reopens sessions whose pane pid is dead (~/.claude/sessions/<pid>.json, deduped by session id). Run it with: open -a Terminal ~/.local/bin/slyterm-restart-server
- 2026-09-17: a tab whose tmux window name contains a dot (auto-renamed to the claude version "2.1.274") can never reattach: tmux parses `-t =2.1.274` as window 2 / pane 1.274, so the client lands on the 'home' sleeper and all typing/mic goes there; the app's kill-window on it fails the same way and the next close-tab killed a different window (sly-235424-c4). slyterm-shell + slyterm-restart-server now strip dots from window names; existing window renamed sly-clock. Never name windows with dots.
- 2026-09-22 mic/focus jumping tabs: a chat window tmux auto-renamed to claude's version ("2.1.276") is untargetable (tmux reads dots as window.pane), so slyterm-shell's sanitized ?arg= attached the tab to a DIFFERENT window; the supervisor saw no client on the pane's name and reloaded it every 12s (19k reloads in the log) — and each ttyd load focuses the xterm textarea, which takes first responder and drags the tab (and dictation) off whatever you were typing in. v2.8.0: repairNames() renames untargetable windows BY INDEX + pins automatic-rename/allow-rename off, panes rebind to the new name, reattach is capped at 3 tries (reset on a live client or wake), and a background reload blurs the page and hands the key window back unless the user clicked since. Diagnose with: grep -c "load (detached)" ~/Library/Logs/slyterm.log
