Manual written known issue:

- Understand naming convention about actor usage (e.g. Merge FTPClient with FtpClientActor, remove the suffix, etc…
- Have a timeout when receiving data on data channels
- Still doesn't really work with folders, can wait.
- No transfer entry in the transfer pane
- To test once the download speed has been improved: Finder completion status icon
- Create tests for the Ferri app (trying to understand how to make that work with no access to docker CLI in tests [App Sandbox])
- Use VSplitView instead of VStack for the transfer/file browser division
- Clicking the refresh button move us back to the root folder
- Double click on a folder doesn't open it
- No "selection" of file (e.g. click on file doesn't change its background to blue/text to white)
- Make sure we have a test for download integrity (e.g. file on server has same hash as file downloaded)

- AGENTS.md file.
    - Add "use xcode MCP over any CLI tool whenever you have the chance"
        - Super useful to avoid issue with swift packages
    - Also add the scope of the project
        - not a full fledge FTP server, only one use for browsing/download.
        - No support for operations that modify remote objects)


=====

New TODO section managed by claude

## How to tackle this (session plan for Claude Pro)

Main budget levers on Pro: **model choice** (Opus drains the limit far faster than Sonnet) and **context
size** (every turn re-sends the whole conversation, so long sprawling sessions get expensive per-turn).

Working rules:
- **Default to Sonnet.** Almost all of this is mechanical SwiftUI wiring. Reserve Opus only for pause/resume
  (session 3) and switch back after.
- **One TODO section ≈ one session.** Sections are grouped by file locality, so each keeps context small.
- **`/clear` + commit between sections.** Don't accumulate A–I in one session — you'd pay to re-send the
  whole history every turn. Finish → commit → `/clear` → start next cold. Good `CLAUDE.md` makes cold starts
  cheap.
- **Point Claude at the section** ("Implement section B of TODO.md") so it reads only the relevant slice.
- **`/plan` first each session**, approve, then execute — a rejected plan is cheaper than unwinding wrong edits.
- **Sequential, not parallel** — skip background/parallel subagents; they multiply usage.

Suggested order (S/M/L = relative effort, not a promise about how many fit in one 5-hour window):

| # | Sections | Why grouped | Model | Size |
|---|----------|-------------|-------|------|
| 1 | **B + I** — remove Rename/Delete/New Folder, dead upload drop, `Item.swift`/SwiftData | Pure deletion; removes misleading paths before building on them. Low-risk warm-up. | Sonnet | S |
| 2 | **A core** — progress plumbing (protocol → facade → VM → `TransferItem`), speed field, status→completed/failed | One vertical slice through the download stack; everything else in the queue depends on it. | Sonnet | L |
| 3 | **A rest** — queue summary, toolbar Transfers button + badge, colored direction badges, then pause/resume | Builds on #2's context. Do pause/resume **last** — it's the hard part. | Sonnet, **Opus** for pause/resume only | M |
| 4 | **C + D + E** — breadcrumbs + item count, colored ext badges, selection highlight, Get Info / Copy Path | All inside `FileBrowserView` — one file's context. | Sonnet | M |
| 5 | **F + G** — Connecting overlay, error Retry, Permission Denied state, Disconnect, wire no-op Connect, double-click-to-connect | All connection-lifecycle; touches `MainView`/`SidebarView`. | Sonnet | M |
| 6 | **H** — wire ⌘N/⌘R, add ⌘[ / ⌘] / ⌘↑ | Small, isolated to `FerriApp` + observers. | Sonnet | S |

Notes:
- **Pause/resume is the one deep item.** Interrupting and resuming a live SFTP stream is real protocol work
  in the actor, not just a UI toggle — the one place to spend Opus, and worth `/plan`-ing before writing code.
- If budget is tight, sessions 1 and 6 are cheap quick wins; sessions 2–3 hold most of the value and cost.

### Session prompts (paste one per fresh `/clear`ed session)

Each prompt assumes you've set the model per the table and start in a clean session. They ask for a plan
first — review it, then let it execute. Verify with the Xcode MCP tooling (preferred) or
`xcodebuild -workspace Ferri.xcworkspace -scheme Ferri build`, and commit before `/clear`ing.

**Session 1 — cleanup (B + I):**
```
Read CLAUDE.md and sections B and I of TODO.md. This is the read/download-only scope cleanup:
remove the out-of-scope remote-mutation UI and the dead Xcode scaffolding — do NOT implement any
of it. Specifically: remove Rename/Delete from the file context menu and New Folder from the
toolbar menu (plus their alerts and the stubbed createFolder/deleteFile/renameFile methods on
FileBrowserViewModel), remove or neutralize the Finder-drop upload path in FileBrowserView, and
remove the unused Item.swift + SwiftData import in FerriApp. Plan the exact edits first, then
build to confirm it still compiles.
```

**Session 2 — transfer progress plumbing (A core):**
```
Read CLAUDE.md and section A of TODO.md (focus on "Live progress never updates" and
"Transfer speed"). Wire download progress end to end: thread the progress callback that already
exists on SFTPClient.downloadToFile(...:progress:) through FTPClient.downloadFile and
FTPClientProtocol, and have FileBrowserViewModel.downloadFile feed it into the TransferItem so the
queue's progress bar advances and status flips to .completed / .failed. Add a throughput/speed
field to TransferItem computed from the progress updates. Match the existing MVVM + async style.
Plan first, then implement and build. Leave pause/resume for a later session.
```

**Session 3 — transfer queue UI + pause/resume (A rest):**
```
Read section A of TODO.md. Building on the now-working progress plumbing: add the queue summary
("N active · N completed"), a toolbar "Transfers" button with an active-count badge that toggles
the queue, and colored direction badges — matching design/Ferri Window.dc.html. THEN add
pause/resume: a .paused TransferStatus case, a per-row play/pause control, and the actual
stream interruption/resume in the SFTP download path. Treat pause/resume as the hard part —
plan it carefully before writing code (this is the session to use Opus for).
```

**Session 4 — file browser presentation (C + D + E):**
```
Read sections C, D, E of TODO.md and open design/Ferri Window.dc.html for reference. Work inside
FileBrowserView: add a clickable breadcrumb path bar with an item count (replacing the plain
navigationTitle), add color-coded file-type badges (an ext→label/color map like the prototype's
extMeta), make the selected row highlight correctly, and add "Get Info" and "Copy Path" to the
file context menu. Read/download-only scope — no mutation. Plan first, then build.
```

**Session 5 — connection lifecycle (F + G):**
```
Read sections F and G of TODO.md. Touch MainView and SidebarView: add an in-window "Connecting to
{host}…" overlay, a Retry button on the connection error dialog (re-attempts connect), a styled
"Permission Denied" empty state, a working "Disconnect" context-menu item (call
FTPClient.disconnect()), wire the currently no-op "Connect" context item, and change connect to
fire on double-click / context-menu Connect (single-click = select only; autoConnect calls connect
directly). Plan first, then build.
```

**Session 6 — commands & shortcuts (H):**
```
Read section H of TODO.md. The menu commands in FerriApp post .newConnection and .refresh but
nothing observes them — add the observers so ⌘N and ⌘R work, and add ⌘[ (back), ⌘] (forward),
and ⌘↑ (parent) bound to the existing FileBrowserViewModel navigation. Plan first, then build.
```

## Gap analysis — `design/` prototype vs. current implementation (2026-07-15)

Diffed the interactive design prototype (`design/Ferri Window.dc.html`, `design/Ferri Storyboard.dc.html`)
against the SwiftUI app in `Ferri/Ferri/`. The prototype is the intended end-state; items below are where
the app diverges. Grouped by area, roughly ordered most→least impactful. Scope note: the design's masthead
advertises "SFTP over SSH · Read & download only · Drag to Finder · Pause & resume · Light & dark", which
matches the read-only scope in CLAUDE.md — so remote-mutation UI in the app is *out of scope AND not in the
design* and should be removed, not finished.

### A. Transfer queue (biggest gaps — "Pause & resume" is a headline feature)

- [ ] **Pause / Resume per transfer is entirely missing.** Design shows a play/pause button on each active
      row and a `Paused` (orange) state. App has no such control: `TransferStatus`
      (`Models/TransferItem.swift`) has no `.paused` case, and `TransferQueueView` renders no pause button.
      This is a masthead-advertised feature.
- [ ] **Live progress never updates.** `FileBrowserViewModel.downloadFile` starts the download task but never
      wires `SFTPClient.downloadToFile(..., progress:)` (which exists,
      `FTPClient/Sources/FTPClient/SFTPClient.swift:300`) into the `TransferItem`. The facade
      `FTPClient.downloadFile(named:to:)` (`FTPClient.swift:80`) doesn't even take a progress closure, and
      `FTPClientProtocol` has no progress-capable download. Result: the progress bar stays at 0 and status
      never flips to `.completed`/`.failed`. (Overlaps manual TODO "No transfer entry in the transfer pane"
      and "Finder completion status icon".)
- [ ] **Transfer speed is not shown.** Design shows e.g. "1.8 MB/s" per row. `TransferItem` has no speed
      field and `TransferRow` renders none. Needs a throughput field fed by the progress callback.
- [ ] **Queue summary text missing.** Design shows "N active · N completed" next to the "Transfers" title;
      app shows only the "Transfers" headline (with Clear Completed / Cancel All).
- [ ] **Toolbar "Transfers" toggle + active-count badge missing.** Design has a toolbar button that toggles
      the queue and shows a badge with the active transfer count. App only exposes the chevron in the queue
      divider; there is no toolbar entry point and no badge anywhere.
- [ ] Cosmetic: design uses colored rounded direction badges (blue = down, orange = paused, red = failed);
      app uses a plain SF Symbol arrow. Queue also defaults collapsed in the design vs. expanded in the app
      (`isTransferQueueExpanded = true` in `MainView`).

### B. Remote-mutation UI that is out of scope and not in the design (remove)

- [ ] **File context menu has Rename & Delete; design has neither.** `FileBrowserView` file context menu
      offers Download / Rename / Delete. Rename & Delete call `FileBrowserViewModel` methods that
      intentionally `throw "not supported"`. Design's file menu is Download / Get Info / Copy Path. Remove
      Rename & Delete (and their alerts + stubbed VM methods) — they mislead the user.
- [ ] **"New Folder" toolbar menu should be removed.** The `ellipsis.circle` toolbar menu exposes "New
      Folder" (also stubbed to throw). Not in design, out of scope.
- [ ] **Finder-drop upload path is dead/misleading.** `FileBrowserView.handleDrop` accepts a Finder drop and
      enqueues a `TransferItem` with `direction: .upload, status: .failed` — no upload is ever performed and
      upload is out of scope. Either remove the `.onDrop(of: [.fileURL])` target or make it a no-op; today it
      silently drops a "failed upload" row into the queue.

### C. Missing file-context-menu items (design)

- [ ] **Get Info** — present in design context menu, absent in app.
- [ ] **Copy Path** — present in design context menu, absent in app.

### D. Path bar / breadcrumbs

- [ ] **No breadcrumb path bar.** Design shows a clickable breadcrumb trail (`host › folder › folder`) with
      an item count ("N items") on the right, above the file list. App uses `.navigationTitle(currentPath)`
      (a plain string in the title bar) — no clickable segments, no item count.

### E. File list presentation

- [ ] **No colored file-type badges.** Design renders files as a document glyph with a color-coded extension
      label (SQL/PNG/JS/…). App uses a generic SF Symbol from `RemoteFile.icon`. Consider an ext→label/color
      map like the prototype's `extMeta`.
- [ ] **Row selection highlight.** Design highlights the selected row (accent background, white text) on
      single click. Verify SwiftUI `Table` selection actually renders this (manual TODO already flags "No
      selection of file"); if not, needs styling.
- [ ] Note: manual TODO items "Double click on a folder doesn't open it", "Refresh moves back to root", and
      "sort" are all part of the file-list behavior the prototype gets right (double-click opens, sortable
      column headers with ▲/▼ arrows, dirs always sorted before files).

### F. Connection flow, overlay & errors

- [ ] **No "Connecting…" overlay.** Design shows an in-window overlay ("Connecting to {host}…" + spinner)
      over the browse area during connect. App reflects connecting state only via the sidebar dot (orange);
      the browse pane shows nothing until listing starts.
- [ ] **Error dialog has no Retry.** Design's error alert is title + body + **Retry** / Cancel, and Retry
      re-attempts the connection (SPEC §3.4 also calls for retry). App uses a plain `.alert("Connection
      Error")` with only "OK". Add Retry.
- [ ] **Generic error text.** Design distinguishes timeout ("Couldn't connect to the server") vs. auth
      ("Authentication failed"); app surfaces raw `error.localizedDescription`. (Lower priority.)
- [ ] **No dedicated "Permission Denied" state.** Design shows a styled empty state when entering a
      restricted folder; app falls back to the generic red error view.

### G. Sidebar / connection management

- [ ] **Context-menu "Connect" is a no-op.** `SidebarView` connection context menu "Connect" button has an
      empty body (`// handled by parent` — but nothing handles it). Wire it to actually connect.
- [ ] **No "Disconnect".** Design's connection context menu is Connect / Disconnect / Edit… / Delete. App is
      missing Disconnect entirely (and the app never calls `FTPClient.disconnect()` anywhere).
- [ ] **Decision: connect on double-click, single-click = select only** (matches the design). Today the app
      connects on selection change (single-click, via `MainView.onChange(selectedConnection)`). Change so a
      double-click (or context-menu "Connect") triggers connect, single-click just selects; autoConnect must
      then call `connect` directly rather than relying on the selection-change side effect.

### H. App-level commands / keyboard shortcuts

- [ ] **Menu commands are wired to nothing.** `FerriApp` posts `.newConnection` and `.refresh`
      notifications, but no view observes them (no `onReceive`/`NotificationCenter` subscriber). So ⌘N and
      ⌘R menu items do nothing.
- [ ] **Missing navigation shortcuts.** SPEC §5 lists ⌘[ (back), ⌘] (forward), ⌘↑ (parent); none are bound.

### I. Cleanup (not design-driven, noticed while diffing)

- [ ] `Ferri/Ferri/Item.swift` is the leftover Xcode SwiftData template model and `FerriApp` still
      `import SwiftData` without using a `ModelContainer`. Appears to be unused scaffolding — remove.
- [ ] Connection sheet is a richer grouped `Form` (adds "Initial Directory" + "Connect on launch", not in
      design) — that's a fine superset; only cosmetic divergence is the title ("New Connection" vs "Add
      Server") and primary button label ("Save" vs "Connect"). Low priority, no action needed unless aligning
      copy.
