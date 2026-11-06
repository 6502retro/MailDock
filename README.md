# MailDock

A native macOS app for Gmail, with all your accounts open in one sidebar. It is built with SwiftUI and talks to Gmail through Google's Gmail API. There is no web view and no server.

- Combined **All Inboxes** plus each account's folders, labels and unread counts
- Threaded conversations, inbox tabs, Gmail search syntax, attachments
- Compose, reply, reply all, forward, with drafts saved to Gmail
- Archive, trash, spam, star and labels, with undo and Gmail's keyboard shortcuts
- New-mail notifications and a Dock badge
- Remote images are blocked until you choose to show them

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

## Install

```
bash install.command
```

This compiles the app on your Mac and installs it in `~/Applications`. See [README.txt](README.txt) for the one-time Google Cloud setup.

## Privacy

See [PRIVACY.md](PRIVACY.md).

## Layout

| Path | Contents |
|---|---|
| `Sources/Core` | Gmail API client, Google sign-in, email rendering, app state |
| `Sources/App` | SwiftUI interface |
| `Tests/CoreTests` | Unit tests (`swift test`) |
| `Resources` | Info.plist and app icon |
| `install.command` | Builds a universal app and installs it |
