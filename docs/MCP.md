# Local MCP control

Vorssaint can expose Keep Awake to a local MCP client. In General settings,
enable **MCP** and keep Vorssaint running. The switch is off by default and is
not transferred in settings backups. Enabling it permits processes running as
the same macOS user to access the local control socket; it does not authenticate
individual agents. Only enable it when you trust those processes.

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

The app rejects requests that exceed its processing deadline before execution.
If a connection breaks or the client times out before receiving a response,
the outcome can be unknown. Read the current state before retrying a change.

The MCP server uses the Swift SDK 0.10.0 and its dependencies. Building it
requires Swift 6.0 and access to those Swift packages, or a populated local
SwiftPM cache. Its protocol version is 2025-03-26; client compatibility should
be checked before use. No network listener is opened by this integration.
