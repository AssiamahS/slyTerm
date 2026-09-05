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
