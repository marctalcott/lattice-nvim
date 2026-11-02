# Lattice for Neovim — Developer Implementation Specification

- Project: marctalcott/lattice-nvim
- Document version: 1.0 — November 2, 2026
- Status: Ready for implementation; this is a specification, not an assertion that the GitHub repository contains source code.
- Target: macOS + Neovim/LazyVim. Written primarily in Lua.
- Product owner: The repository owner.

> This document is the Milestone 1 contract. Where it differs from `lattice-v0.1.md`, this document wins. The capture inbox and `[promised:...]` decisions recorded in `product-vision.md` (2026-11-01) remain in effect. **Amendment A (below) replaces the `To Do` heading convention with org-mode style TODO keywords.**

## Amendment A — Org-style TODO keywords (2026-11-02, requested by the product owner)

Replaces every rule about the `To Do` heading in §4, §5 (`headings.todo`) and §7 (`<leader>lt`). `Waiting On` sections are unchanged.

1. A bullet (`-`, `*`, `+`) at any nesting depth, or an ATX heading, whose first word is a declared keyword followed by a title is a task: `- TODO Send update`, `## NEXT Draft plan`. Tasks are no longer tied to a section. A keyword with no title, ordered items, prose, code blocks and front matter are never tasks.
2. Keywords come from org-mode style sequences, such as `TODO NEXT | DONE CANCELED`. Words before `|` are open states and words after it are done states; without `|`, the last word is the done state. Fast-access suffixes such as `TODO(t)` are ignored. Keywords match exactly (case-sensitive), as in org: `todo`, `To Do` and `to-do` are not keywords.
3. Root sequences come from `todo` in `.lattice.json` (a string or a list; default `["TODO | DONE"]`). A note's YAML front matter `todo:` key (a string, a block list or a flow list) replaces them for that note, like org's per-file `#+TODO:`. Front matter must start the note with a `key:` line and contain only YAML-shaped lines, so a note opening with a horizontal rule is unaffected. An invalid per-note value falls back to the root sequences with a warning. An invalid root value is a config error.
4. Open-state keyword items appear in MY TO DO, or in WAITING ON when inside a `Waiting On` section, with the state shown on each row. Done-state items, and keyword items checked `[x]`, appear in a DONE group: the 20 most recent, newest note first, with a count of the rest. `Waiting On` bullets without a keyword keep the `[ ]` / `[x]` rules, and checked ones stay hidden.
5. `<leader>lt` inserts `- <first open keyword> <text>` below the cursor (after the front matter if the cursor is in it; on a list item, at its indent and after its sub-bullets). Inside a `Waiting On` section the inserted item is a waiting item, by rule 4. No heading is created or confirmed.
6. `headings.todo` in an older `.lattice.json` is ignored with a notice.

## 1. Executive summary

Build Lattice, a local-first personal management workspace implemented as a Neovim/LazyVim plugin, not a standalone Electron application. It enhances an existing Markdown notes repository organized with the PARA method. Its first job is to aggregate what I owe other people and what other people owe me into one actionable dashboard without disrupting the author's existing note-taking or AI-assisted editing workflow.

The product vision also includes (later) preparing weekly business reports (WBRs) from team updates and publishing approved project summaries into Portico, a different product. Lattice and Portico must be different repositories and independently usable applications. The first deliverable is a working local task dashboard with navigation, lightweight note entry, and a test suite.

### Nonnegotiable principles

- **One working surface:** Meetings and personal work notes are captured in Neovim Markdown files. Don't require switching to Portico during a meeting.
- **Markdown is the source of truth:** No database, web server, SaaS account, sync engine, or network requirement for the MVP.
- **Existing PARA folders remain intact:** The plugin scans a user-configured notes root, not a new Lattice-only storage scheme.
- **Explicit, predictable conventions:** Recognize tasks only under exact Markdown headings. Do not infer promises from arbitrary prose in v0.1.
- **Safe by default:** Scanning is strictly read-only; notes change only after a deliberate user edit/action.
- **Private by default:** Do not send notes to external services, or require an AI provider.
- **Portico independence:** The plugin installs and functions without Portico, its API, credentials, or repository.
- **Work-machine security:** User's employer requires security review of any executable code on corporate machines. Do not circumvent that process.

## 2. Primary user workflow

1. Open existing PARA Markdown files in Neovim/LazyVim; continue capturing freeform meeting notes as usual (often via an external AI agent that edits Markdown).
2. Under a literal `To Do` heading, enter personal commitments as bullet items. Under `Waiting On`, enter work the manager expects from others.
3. Open Lattice (`:Lattice` or `<leader>ll`) to see outstanding items from all included notes.
4. View due soon/overdue items and commitments by person. Press Enter to jump to the exact source file and line.
5. Mark an item done in its source note (`- [x]`); refresh Lattice to remove it from open tasks.
6. When away from the Mac, capture notes in Drafts on iPhone. Manually copy/import Markdown into the notes directory when back at the Mac. Automated Drafts import is not in the MVP.

The current workflow must remain usable even when an AI agent or the Portico application is unavailable.

## 3. Scope and staged delivery

| Area             | Milestone 1: Required, functioning                                                    | Later: documented, not presented as working                      |
|------------------|---------------------------------------------------------------------------------------|------------------------------------------------------------------|
| Markdown parsing | Exact `To Do` / `Waiting On` sections, open/completed bullets, person/date metadata   | AI inference from unstructured notes                             |
| File scanning    | Entire configured notes tree minus exclusions                                         | Background indexing / watchers                                   |
| Dashboard        | My To Do, Waiting On, Overdue, Due Soon, counts, source navigation                    | Rich project details, trends, notifications                      |
| Note capture     | Insert task into current Markdown buffer; create missing heading with confirmation    | Structured meeting templates, Drafts automation                  |
| WBR              | No active WBR feature; explain future state in docs                                   | Gather updates, review worksheet, generate approved report prose |
| Portico          | No API connection; explain future state in docs                                       | Human-reviewed project summary publishing                        |
| Cloud/AI         | None                                                                                  | Optional, independently authorized external AI workflows         |

Definition of done for Milestone 1: An installable, documented Lua plugin that passes automated tests and a real Neovim/LazyVim smoke test on macOS. A mockup or README without working plugin code is not complete.

## 4. Markdown conventions (strict)

*(For `To Do`, superseded by Amendment A.)* Recognize ATX headings of any depth (`#` through `######`) with exactly the case-sensitive text `To Do` or `Waiting On` after trimming heading-edge whitespace. Multiple sections of either type may appear in the same file. Do not match `TODO`, `To do`, `To-Do`, `Waiting For`, or any similar phrase. Text inside fenced code blocks is not parsed. A recognized task section ends at the next Markdown heading of any level (intentionally simple and deterministic).

Example:

```markdown
# November 2 — Project Review

Notes and decisions can be completely freeform.

## To Do
- Prepare revised staffing plan
- [ ] Send project update [due:2026-11-05]
- [x] Review the completed migration

## Waiting On
- @Raju Provide deployment estimate [due:2026-11-06]
- [ ] @Asha Submit hiring feedback
- [ ] Follow up with vendor

## Decisions
We agreed to revisit the release date next week.
```

Required parsing rules:

1. Only top-level list items directly beneath a recognized section count. Supported bullet markers: `-`, `*`, `+`. Nested bullets/continuation lines may be displayed as part of their parent in future, but are not independent tasks in v0.1.
2. A plain list item (`- Task`) or an unchecked checkbox (`- [ ] Task`) is an open task. `- [x] Task` and `- [X] Task` are complete; completed tasks are excluded from the default view. Do not treat a bare prose paragraph as a task.
3. The heading determines the category: `To Do` = my commitment; `Waiting On` = someone else's deliverable / my follow-up. No `#lattice/owe` or `#lattice/waiting` tags are required.
4. An optional `@Name` near the beginning of a `Waiting On` item identifies its assignee. Missing name is allowed and rendered Unassigned. Do not invent names.
5. Optional `[due:YYYY-MM-DD]` is a calendar date in local time. For `Waiting On`, it represents the manager's follow-up date unless more structured semantics are added later. Missing due date is allowed; invalid dates must not be silently normalized.
6. Preserve the complete source absolute path, relative path, and 1-based line number of each task. Identical text in separate files represents distinct tasks.
7. No natural-language inference or automatic rewrite of meeting notes is permitted in Milestone 1.
8. When a plain bullet is completed, the user can turn it into `[x]` manually. The plugin may offer a deliberate completion command later; do not auto-rewrite plain bullets during scans.

### Parsing edge cases to test

- Repeated `To Do` sections in one note and across several notes.
- Heading strings inside fenced code, and checkbox examples inside code fences.
- Nested lists; blank lines; indented continuation text; tasks immediately before the next heading.
- Tasks with no `@person`, no `[due:...]`, or both; invalid dates.
- Files without task sections and Markdown files containing ordinary prose.
- Different heading depths, exact-case enforcement, and Windows-style line endings where encountered.

## 5. Notes root and configuration

The user specifies one notes root in plugin setup. The plugin reads a `.lattice.json` in that root. It does not require moving or copying notes into the source-code repository.

Example `.lattice.json`:

```json
{
  "version": 1,
  "scan": {
    "include": ["**/*.md"],
    "exclude": ["Archives/**", ".git/**", "Projects/Completed/**"]
  },
  "headings": {
    "todo": "To Do",
    "waiting": "Waiting On"
  }
}
```

Config requirements:

- Paths and globs are relative to the configured notes root. `*` matches within a path segment and `**` can match across directories. Document exact matching semantics; tests must cover them.
- All Markdown files in that root are included by default, except Archives and the Git metadata directory. Additional exclusions are user-controlled. Do not implicitly restrict scanning to Daily Notes.
- Configuration changes take effect on `:LatticeRefresh`, without editing the plugin's source or restarting Neovim.
- Provide sensible defaults if `.lattice.json` is missing. Invalid JSON, invalid glob patterns, an inaccessible notes root, or unsupported config version should produce clear diagnostic messages, not silently scan elsewhere.
- Don't follow symbolic links outside the configured notes root (or recurse forever through symlink cycles). Be careful with private files and permission failures.
- Scan the filesystem read-only. Editing a note using an explicit task-insertion action is separate from scanning.
- For Milestone 1, scan files on disk. Explain that unsaved Neovim edits will appear after save and refresh.

Sample LazyVim plugin setup:

```lua
return {
  {
    "marctalcott/lattice-nvim",
    lazy = false,
    opts = {
      root = vim.fn.expand("~/Documents/WorkNotes"),
    },
  },
}
```

The developer may adjust the install snippet to the actual exported API, but must provide a working lazy.nvim/LazyVim installation example in the final README. The notes-root path above is illustrative and must be replaced by the user's real path.

## 6. Dashboard UI (Neovim native)

Implement as a readable Neovim buffer/window, not a browser, embedded server, Electron app, or pixel-for-pixel imitation of the supplied conceptual image. It must work with standard terminal Neovim themes, screen resizing, and keyboard navigation. Display accurate task counts sourced from the scan.

Required first-screen information:

```
LATTICE                                    Mon Nov 02
My management workspace — local notes
──────────────────────────────────────────────────
MY TO DO (3)
  [ ] Prepare revised staffing plan
  [ ] Send project update                    Nov 05
  [ ] Review budget

WAITING ON (2)
  [ ] Raju — Provide deployment estimate     Nov 06
  [ ] Asha — Submit hiring feedback

OVERDUE (1)
  !  Review budget                           Oct 30

DUE SOON (2)  [within next 7 days; excludes overdue]
  ·  Send project update                     Nov 05
  ·  Raju — Provide deployment estimate      Nov 06
──────────────────────────────────────────────────
Enter  Open note    r  Refresh    q  Close    ?  Help
```

All data above is illustrative. A single task may appear both in its owner category and in Overdue/Due Soon. Counts reflect unique tasks within each section. If there are no tasks, show a useful empty-state message and the currently scanned root.

Required behaviors:

- `:Lattice` opens the dashboard; `<leader>ll` should be offered as a configurable default mapping.
- `:LatticeRefresh` and `r` rescan notes and reread `.lattice.json`; `<leader>lr` is the suggested mapping.
- Enter on any task opens its actual source note at the correct line, placing the cursor there. Don't destroy the source buffer or its unsaved contents.
- `q` closes the dashboard; `?` shows keyboard help.
- Sort overdue items oldest-first; due-soon by soonest date; order owner sections with overdue/due-dated items before undated items. Stable tie ordering by file and line is acceptable.
- Show warnings in an optional health/diagnostics command (`:LatticeHealth`) for unreadable files and ignored invalid dates, without failing the whole scan.
- No invented project health, milestone dates, AI summaries, or Portico publish status.

Mockup boundary: The previously shown image includes Projects, WBR, and Portico panels. They represent the product vision. Do not display live counts, a Publish button, or "Ready to publish" unless they are backed by actual implemented functionality. A labeled Planned placeholder is optional; an MVP dashboard focused on tasks is preferable.

## 7. Note-entry commands and keymaps

Implement commands or Lua functions which insert Markdown into the current real Markdown buffer, never the dashboard buffer:

| Suggested key | Action            | Exact requirement                                                                                                              |
|---------------|-------------------|--------------------------------------------------------------------------------------------------------------------------------|
| `<leader>lt`  | Add personal task | Prompt for task text and insert `- [ ] <task>` under `To Do` in the current note. *(Superseded by Amendment A: inserts `- TODO <task>` below the cursor.)* |
| `<leader>ld`  | Add waiting item  | Prompt for assignee (optional) and task text, then insert `- [ ] @Person <task>` under `Waiting On` (or no name if omitted).   |
| `<leader>ll`  | Open dashboard    | Equivalent to `:Lattice`.                                                                                                      |
| `<leader>lr`  | Refresh           | Equivalent to `:LatticeRefresh`.                                                                                               |

- If the relevant heading is absent, ask before creating it. If the operation is canceled, leave the buffer untouched.
- When a heading occurs more than once, use a documented deterministic strategy (e.g., nearest matching heading to cursor or prompt to choose); do not silently insert into an unrelated section.
- Only the current note is edited; do not overwrite other files or silently save the buffer.
- Keymaps are configurable or can be disabled, and must not overwrite an existing mapping without notice.
- Short, natural entry is the goal. Users should never need to type long Lattice tags.

## 8. Proposed implementation layout

The implementation language is Lua, targeting a supported stable Neovim version (document minimum tested version). Recommended repository layout:

```
lattice-nvim/
├── README.md
├── LICENSE                  # owner selects license; do not invent it
├── AGENTS.md                # instructions for AI coding agents, optional
├── doc/lattice.txt          # :help lattice, desirable
├── lua/lattice/
│   ├── init.lua             # setup, commands, keymaps
│   ├── config.lua           # validation/defaults/.lattice.json
│   ├── parser.lua           # pure Markdown parsing
│   ├── scanner.lua          # read-only recursive traversal
│   ├── dashboard.lua        # Neovim buffers, navigation, actions
│   └── insert.lua           # explicit user-triggered note edits
├── examples/
│   ├── .lattice.json
│   └── sample-notes.md
└── tests/
    ├── parser_spec.lua
    ├── scanner_spec.lua
    ├── dashboard_spec.lua
    └── insert_spec.lua
```

Use `vim.uv` / supported Neovim APIs where appropriate. Do not require a background daemon. Keep scanning/parsing as independent of Neovim as practical for straightforward unit testing. All API and keybinding names in the README must match the shipped code.

## 9. Tests and acceptance checklist

The developer must deliver runnable tests and instructions for invoking them. Automated tests alone are not enough: demonstrate at least one real interactive smoke test inside Neovim/LazyVim on macOS.

- [ ] Install plugin from a fresh checkout using documented LazyVim configuration.
- [ ] Open `:Lattice` without Portico, AI, internet, or web server.
- [ ] A fixture with 2 personal open items, 2 waiting items, 1 completed item returns 2 and 2 open, not 5.
- [ ] Plain bullets and unchecked checkboxes count as open; checked boxes do not.
- [ ] `To Do` and `Waiting On` are case-sensitive/exact and work repeatedly in multiple notes.
- [ ] Nested bullets and fenced-code examples do not add false tasks.
- [ ] Dates are sorted correctly; invalid dates are surfaced as warnings rather than invented.
- [ ] `.lattice.json` includes Markdown throughout PARA and excludes `Archives/**` by default.
- [ ] Editing excludes then refreshing changes results without restarting.
- [ ] A dashboard selection opens the correct existing note at its exact line.
- [ ] A scan does not change content, timestamps intentionally, or git working-tree diff.
- [ ] Explicit task insertion works; creating a missing heading requires confirmation.
- [ ] Canceling insertion leaves notes unchanged; existing keymaps are respected.
- [ ] Symlink cycles, unreadable files, empty notes, and invalid configuration fail safely.
- [ ] No confidential work notes are committed to the plugin repository.
- [ ] README.md includes setup, sample notes, config, command reference, limitations, and troubleshooting.

## 10. Developer deliverables

1. Actual plugin source code in marctalcott/lattice-nvim, not Portico.
2. A usable, keyboard-driven dashboard that satisfies all Milestone 1 requirements.
3. A complete README.md, sample `.lattice.json`, synthetic sample notes, and installation/configuration instructions.
4. Unit and integration tests with repeatable commands, plus results of a real Neovim smoke test.
5. A short change log / outstanding limitations list with any intentionally deferred items.
6. A pull request against the Lattice repository for review, or a separate branch if asked. Do not claim the code is merged or released until it actually is.

Explicitly out of scope: Changing Portico code, changing the user's PARA directory structure, exposing private notes to third parties, creating an account, deploying a backend, or building an iPhone app.

---

## 11. Product vision after Milestone 1 (retain in roadmap, do not implement yet)

### Milestone 2 — Real-note trial and ergonomics

Use Lattice for a week of management meetings. Improve handling of many Markdown files, navigation, editing convenience, and review of missed follow-ups based on actual usage. Keep the user's existing agent-driven note capture intact.

### Milestone 3 — AI-assisted commitment discovery

Today, Lattice sees only explicit `To Do` and `Waiting On` bullets. A later optional agent-assisted review can inspect freeform meeting notes and propose personal promises, delegated work, and follow-ups. All changes to notes require user review/approval; no invented due dates, no silent task creation. Lattice itself should remain usable without AI.

### Milestone 4 — Weekly Business Reports (WBRs)

The user must report last week's team accomplishments, warnings/off-track items, and mitigation plans to their manager. Present workflow:

1. Receive Markdown updates from leaders for two teams. For a third, export completed items from a Kanban board and prepare its updates directly.
2. Collect three team-specific files, currently in a platform-engineering notes/Git repository.
3. Generate a candidate worksheet grouped by team and project.
4. Let the manager select/check which accomplishments, risks, and mitigations matter at their manager's level; don't force every low-level ticket into the report.
5. Draft concise, professional prose from the selected items, distinguishing accomplishments, warnings, and mitigation plans.
6. Review and copy the final text into the manager's Google Sheet. Direct Sheets integration is not required initially.

The collection workflow sometimes suffers Git conflicts because team leaders reuse old branches and miss changes to main. That is primarily a Git training/process issue; Git merge conflict resolution is not a Lattice requirement. Reading team-submitted PR content directly may be a future optional ingestion convenience, not a prerequisite for reporting.

### Milestone 5 — Review and publish summaries to Portico

Capture once in Lattice; publish only approved project facts to Portico. The user wants to take project meeting notes exclusively in Neovim, then inspect candidate project updates (status, decisions, blockers, ownership, next steps), edit them, and send approved summaries to Portico. Lattice must never automatically publish the original private meeting notes.

This integration requires Portico to expose an authenticated, permissioned project-update API. Define the API contract in the Portico repository, not by modifying Portico from Lattice without authorization. Make the integration optional, gated behind explicit configuration, with a preview/edit/confirm flow and clear failure handling. The Lattice core must still work with Portico offline or absent.

### Milestone 6 — Drafts note import (optional)

When away from the Mac, the user captures notes in Drafts on iPhone. At first, manually paste/export them into PARA Markdown. A later import tool can ingest these files on the Mac, preferably without a hosted web service or always-on background process.

## 12. Product boundaries and operational security

- **Lattice:** Personal management workspace, raw work notes, promises, waiting items, WBR candidate worksheets, approved outbound summaries.
- **Portico:** Shared organizational projects, intake, stages, team ownership, cross-team project reporting and governance.
- Only Lattice captures raw meeting notes. Portico receives carefully selected and approved project summaries in the future.
- Project source code and documentation live in marctalcott/lattice-nvim; employer meeting notes remain in the user's existing notes directory and must not be bundled with plugin tests or commits.
- No invisible network access. If networked features are eventually developed, they need explicit opt-in and required security clearance.

## 13. Suggested first instruction to the developer

> Implement Milestone 1 of `LATTICE_SPEC.md` as a Lua plugin for Neovim/LazyVim in the `marctalcott/lattice-nvim` repository. Start with a Markdown parser and filesystem scanner, then implement the dashboard, source navigation, safe task insertion, configuration, and tests. Use only synthetic fixtures, do not modify any Portico repo or any work notes, and do not implement WBR, AI, or Portico publishing yet. Before claiming completion, run automated tests and a macOS Neovim smoke test. Open a PR with installation instructions and remaining limitations.
