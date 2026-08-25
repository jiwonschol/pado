# Pado

**Git only has what you committed.**

Pado is being built to keep a copy of the work your coding agents haven't committed yet. The mirror is designed to leave your branch, working tree, and index unchanged.

Your coding agent writes for hours. Until that work is committed or copied elsewhere, it may live only on that machine — and can disappear with it. The current prototype handles one repository at a time and targets an explicitly approved private GitHub remote.

Pado is also testing whether an AI coding setup — settings, MCP servers, skills — can be captured and restored on another machine. One macOS-to-Windows restore completed successfully; cleanup and repeatability remain untested.

## Status

Early development — nothing to install yet.

We are currently validating the core assumption: that the configuration of AI coding tools (settings, MCP servers, skills) captured on macOS can be restored on Windows and cleanly removed afterwards. A strict non-administrator-account test remains open.

One restore run now has a result. [Phase 1 — Configuration portability, macOS to Windows](docs/phase-1-configuration-portability.md) reports what transferred, what was deliberately left behind, and why the experiment turned toward uncommitted work. Cleanup remains untested.

A separate local proof harness passed mirroring and restoration against a disposable repository. Its GitHub privacy and write checks were simulated; it did not push to a real GitHub remote. The prototype is under review in [PR #1](https://github.com/jiwonschol/pado/pull/1).

## What Pado does (planned MVP)

- **Mirror** — copy the work you have not committed yet, one repository at a time, to an explicitly approved private GitHub remote without creating a commit on your current branch, switching branches, or changing your working tree.
- **Capture** — read the configuration of your AI coding tools on one machine and turn it into a small, portable specification.
- **Restore** — recreate that setup on another machine, after you sign in to your tools there yourself.
- **Cleanup** — remove what Pado placed, and report item by item: what was removed, what could not be verified, and what needs your manual review.

## What Pado does not do

- Pado does not store your work. The planned mirror sends it to an explicitly approved private GitHub remote; Pado runs no storage of its own, and there is no account to create.
- The design requires explicit approval and a positive GitHub privacy and write-permission check before a work snapshot is pushed. The current prototype has only exercised that policy through a disposable local repository and simulated GitHub responses.
- The planned MVP excludes credentials, tokens, and secrets. You sign in to each tool on the destination machine.
- Pado does not host your repositories or large files, and does not run your code remotely. They remain with the providers you already use.
- Pado is not a remote desktop or an OS migration tool.

## License

[Apache-2.0](LICENSE)
