# CLAUDE.md

## Project: ProductivityTracker (macOS Client)

### What this is
A macOS menu bar app (SwiftUI MenuBarExtra) that tracks app/website usage,
blocks distracting sites via /etc/hosts, and syncs to a Node.js backend.

### Build & Run
- Open ProductivityTracker.xcodeproj in Xcode 17+
- Signing: Personal Team (free Apple ID), no paid Developer Program
- No App Sandbox (deleted), Hardened Runtime with Apple Events only
- Build & Run → chart icon in menu bar

### Key architecture decisions
- Non-sandboxed, Hardened Runtime, LSUIElement = true
- GRDB.swift for local SQLite (WAL mode, DatabasePool)
- KeychainAccess for token storage
- /etc/hosts modification for website blocking (NOT Network Extension)
- XPC LaunchDaemon does NOT work without paid Developer Program ($99/year)
  → Use sudoers-based helper approach instead
- AppleScript for browser URL extraction (requires Automation permission)

### Important patterns
- All database reads: dbPool.read { db in ... }
- All database writes: dbPool.write { db in ... }
- Never use both on the same thread (SQLite locked errors)
- Activity tracking is event-driven via NSWorkspace notifications
- Sync runs every 10 seconds, batch of 100 max

### Things to NOT do
- Don't add App Sandbox back
- Don't use ES modules (backend is CommonJS, but this is Swift)
- Don't try SMAppService.daemon() — needs paid Developer Program
- Don't use NEFilterDataProvider — unstable on macOS Tahoe 26