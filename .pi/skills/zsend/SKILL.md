---
name: zsend
description: Send a message to a registered zcrew pane. User-typed only; human shortcut for zcrew send.
disable-model-invocation: true
---

Run the following via your Bash tool and report the output to the user:

  zcrew send $ARGUMENTS

Workers reporting back to main should prefer `zcrew reply "<message>"`.

If the command fails, report the error verbatim. Do not retry unless the user asks.
