# Local MCP control

Vorssaint can expose Keep Awake and, optionally, sound, displays and window
layout to a local MCP client. In General settings, enable **MCP** and keep
Vorssaint running. Sound, displays and windows each have a separate opt-in,
also off by default. These choices are not transferred in settings backups.
Enabling them permits processes running as the same macOS user to access the
allowed controls; the socket does not authenticate individual agents. Only
enable them when you trust those processes.

Configure the MCP client to launch the executable inside the installed app:

```json
{
  "mcpServers": {
    "vorssaint": {
      "command": "/Applications/Vorssaint.app/Contents/MacOS/VorssaintMCP"
    }
  }
}
```

Adjust the path if the app is installed elsewhere. The Developer build has a
separate socket and its executable is inside `Vorssaint (Developer).app`. The
server does not start the app; requests fail when the app is not running or MCP
is disabled. Turning the switch off closes the listener.

The tools read the Keep Awake session, start it with one of the supported
durations (0, 15, 30, 60, 120, 240 or 480 minutes; 0 means indefinite), and
stop it. Starting again replaces the current session and saves the duration,
just like the app's controls. Existing preferences still apply: for example,
closed-lid mode or mouse movement can also be activated, and a locked screen
can pause the session. A reported active session is not a measurement that
macOS has actually prevented sleep.

With the respective categories enabled, the other tools are:

- `audio_status`, `audio_set_system_volume`, `audio_set_system_mute`,
  `audio_set_app_volume`, `audio_set_output` and `audio_set_app_output`.
  Use IDs returned by `audio_status`; omit `output_id` when setting an app
  back to the system default. Values are fractions: system volume 0–1, app
  volume 0–2 (above 1 boosts it). App volume and output choices are saved.
  A system volume of zero may also mute the output. System output changes
  preserve explicit app routes. Use `next_app_offset` and
  `next_output_offset` with `app_offset` and `output_offset` to page through
  large lists. When one list is exhausted before the other, pass its `total_apps`
  or `total_outputs` as its offset to avoid reading the first page again.
  Entries can change between requests. Volume and mute values can be optimistic
  while a write is pending.
- `display_list` and `display_set_brightness`, with the display ID and a
  brightness fraction from 0 to 1. A listed brightness can be cached or an
  optimistic UI value; `pending` refers to a display power transition, not a
  brightness read-back. Use `next_offset` to page through a truncated list;
  connecting or disconnecting a display can change the list between pages.
  Display control must also be enabled in Vorssaint.
- `window_active` and `window_layout`: read the frontmost application's PID,
  then provide it and a listed action to target its currently focused window.
  Accessibility permission and the Window Layout feature are required. Focus
  can change between windows of the same app. Moving to another display or
  restoring a previous position changes state on each invocation. Window
  exclusions and the active-session requirement are respected.

Audio and brightness actions report a queued/requested change, not a hardware
confirmation. A window layout result reports the initial application; a later
settling attempt can still fail. Use the app UI or a subsequent status read to
inspect the result, noting that some reported values are optimistic.

The app rejects requests that exceed its processing deadline before execution.
If a connection breaks or the client times out before receiving a response,
the outcome can be unknown. Read the current state before retrying a change.

The MCP server uses the Swift SDK 0.10.0 and its dependencies. Building it
requires Swift 6.0 and access to those Swift packages, or a populated local
SwiftPM cache. Its protocol version is 2025-03-26; client compatibility should
be checked before use. No network listener is opened by this integration.
