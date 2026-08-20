# Pado

**Leave the machine. Keep your setup.**

Restore it on another computer, for as long as you choose.

Pado captures your AI coding setup on one computer, restores it on another, and lets you take it with you when you leave.

## Status

Early development — nothing to install yet.

We are currently validating the core assumption: that the configuration of AI coding tools (settings, MCP servers, skills) captured on macOS can be restored on a Windows machine under a standard (non-administrator) account, and cleanly removed afterwards.

## What Pado does (planned MVP)

- **Capture** — read the configuration of your AI coding tools on one machine and turn it into a small, portable specification.
- **Restore** — recreate that setup on another machine, after you sign in to your tools there yourself.
- **Cleanup** — remove what Pado placed, and report item by item: what was removed, what could not be verified, and what needs your manual review.

## What Pado does not do

- The planned MVP excludes credentials, tokens, and secrets. You sign in to each tool on the destination machine.
- Pado does not host your repositories or large files, and does not run your code remotely. They remain with the providers you already use.
- Pado is not a backup tool, a remote desktop, or an OS migration tool.

## License

[Apache-2.0](LICENSE)
