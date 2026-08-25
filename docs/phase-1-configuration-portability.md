# Phase 1 — Configuration portability, macOS to Windows

**Date:** 2026-08-18 · **Sample:** one macOS machine, one Windows machine, one run

This is the first validation of the assumption stated in the project README: that the configuration of AI coding tools captured on macOS can be restored on a Windows machine. One restore run completed successfully and revealed a second problem: work that has no remote copy.

## What we tested

Claude Code was the subject. The capture included the configuration categories needed to reproduce the setup:

- global settings and shared instructions
- user-authored skills
- MCP server and plugin definitions

This public report intentionally omits local paths, filenames, commands, environment-variable names and values, project names, and machine-specific inventory counts.

Credentials were out of scope by construction. No keychain access, no tokens, no OAuth or session entries, no browser data. As it happened, no captured item required a secret to be meaningful, so nothing had to be dropped on those grounds.

The capture was written as a folder containing a human-readable manifest plus a PowerShell script that reproduces the setup on the destination machine. The folder was moved to the Windows machine by hand — dragged, not synced.

## Result

All planned restore operations and post-run checks passed in that single run: the restored skills were present, the settings file parsed, and the instruction file's absolute import path was rewritten to point at a file that existed on the destination.

Two defects surfaced during the run, both in the restore script rather than the capture:

1. **Encoding.** Windows PowerShell 5.1 reads a `.ps1` file as the system code page unless it carries a UTF-8 byte-order mark. Without the BOM, non-ASCII comments and strings were mangled badly enough to break the parser. Note the asymmetry: JSON config files must be written *without* a BOM, and PowerShell scripts *with* one. A tool that writes both needs to know the difference.
2. **Reporting.** The dry-run mode logged planned work separately from completed work but counted only the latter, so a successful preview displayed "0 completed" and read as total failure.

The restore needed no elevation and wrote only inside the user profile. We did not separately verify that the destination account lacked administrator rights, so strict non-administrator validation remains open.

## What did not transfer, by design

Some captured items were deliberately excluded from the restore because they were meaningful only on the source platform: platform-specific hooks and integrations, platform-specific permission rules, and project-derived environment descriptions that would be misleading elsewhere.

This single run showed that some working configuration was bound to its platform and should not travel. In this setup, copying everything faithfully would have produced a broken destination. A capture tool needs to report what it excludes rather than make those decisions silently.

## The finding

Restoring the configuration produced a workspace with nothing in it.

Configuration and work are two different layers, and only the first is a file-copying problem:

| Layer | Contents | How it moves |
|---|---|---|
| Harness | settings, rules, skills, plugin and MCP definitions | file conversion and copy — worked in this run |
| Work | repositories, source, dependencies | `git clone` and reinstall — does not include uncommitted or unpushed state |

Dependencies and build output can be regenerated on the destination and do not need to travel. Size was not the obstacle in this run.

The source audit also found work with no remote copy, including uncommitted changes. The exact machine inventory and project counts are intentionally omitted from this public report. A normal clone cannot restore that machine-local state.

So the boundary of portability is not file size, and not the distinction between configuration and code. It is this:

> **Anything with a copy on a remote is already portable. Work without one remains machine-local until a separate process snapshots it and sends it to a destination.**

## A second boundary: execution stays put

Viewing the same live session from both machines demonstrated another limit.

Judgment and conversation were account-scoped and followed the person between devices. Tools, files, and screen access remained on the machine hosting the session. Moving the capture folder between the machines still required a manual transfer.

Some capabilities are not portable in principle. iOS builds require a Mac; no amount of configuration sync changes that. Any design that assumes a single roaming environment has to account for capabilities that cannot roam.

## What this changes

Going in, the question was *how do we copy an environment to another machine.*

Coming out, it is *what actually needs to move between machines.*

In this run, configuration restoration was a manageable file-conversion and copying problem. Version control already handles committed code. The unresolved residue was work without a remote copy and capability bound to one machine.

This reframing narrows the product rather than widening it, which we consider the useful outcome of the experiment.

## Not yet validated

- **Cleanup.** The README commits to removing what Pado places and reporting item by item what could not be verified. Nothing was removed in this run. The uninstall path is entirely untested.
- **Non-administrator restore**, in the strict sense described above.
- **Repeatability.** One machine pair, one run. The encoding defect in particular suggests that locale and platform-version variation deserve their own pass.
- **Whether any of this matters day to day.** That the environment can be restored says nothing about whether restoring it is worth doing. Only sustained use answers that.
