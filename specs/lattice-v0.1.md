# Lattice v0.1 — Implementation Specification

Status: Superseded by LATTICE_SPEC.md (2026-11-02) where the two differ; kept for history
Date: 2026-11-01
Project: Lattice (independent of Portico)

## 1. Problem and goal

The user manages work in Markdown files edited with Neovim/LazyVim, organized using Tiago Forte's PARA method. An AI coding/notes agent can already create and update files. The missing capability is a unified, navigable view of (a) work the user owes and (b) work delegated to others that the user is waiting on.

Build a small Lua plugin for Neovim that reads existing notes, identifies tasks by strict Markdown section headings, and presents a dashboard that links to each source line. Do not build a new notes app.

## 2. Scope and non-goals

### v0.1 must provide

1. Configurable Markdown scan root and file include/exclude globs.
2. Strict recognition of task sections headed To Do and Waiting On.
3. Recognition of ordinary list bullets and checkbox list items under those headings.
4. Optional assignee and due-date metadata parsing.
5. A dashboard grouped into My To Do and Waiting On, hiding completed tasks by default.
6. Jump to the original note and line with Enter.
7. Manual refresh that reloads .lattice.json without restarting Neovim.
8. User-invoked shortcuts to insert tasks under the appropriate section in the current file.

### Explicitly out of scope

- Portico integration, Portico repository edits, Portico branding, project-management workflows.
- Electron, React, TypeScript, iOS, web servers, databases, accounts, cloud sync.
- Built-in LLM or AI provider integrations; AI agents may edit the plain Markdown externally.
- Automatic reorganization of PARA notes or scanning-time modifications.
- Automatic notifications or assignment to other people's systems.
- Recurring tasks, priorities, advanced status workflows, automatic refresh, full-text search, and dedicated person views.

## 3. Separate-project layout

The intended repository is lattice/, not a folder under portico/.

```
lattice/
├── README.md
├── AGENTS.md
├── specs/
│   └── lattice-v0.1.md
├── examples/
│   ├── .lattice.json
│   └── meeting-notes.md
└── lua/
    └── lattice/                # created during implementation
        ├── init.lua
        ├── config.lua
        ├── scanner.lua
        ├── parser.lua
        └── dashboard.lua
```

The .lattice.json used at runtime lives in the PARA notes root, separate from the plugin's own source repository.

## 4. Source-note format

Only a section headed exactly To Do or exactly Waiting On is scanned for tasks. Any ATX Markdown heading depth # through ###### is supported. Matching is case-sensitive; spaces around the heading text are ignored. ## TODO, ## Todos, and ## Waiting for are not recognized. Do not infer tasks from unrelated prose or headings.

```markdown
# November 1 — Engineering Notes

## To Do
- Prepare staffing plan
- [ ] Review quarterly budget
- [ ] Send update to CIO [due:2026-11-05]
- [x] Complete last week's report

## Waiting On
- @Raju Deployment estimate
- [ ] @Asha Hiring feedback
- [ ] @Taylor Architecture review [due:2026-11-07]
```

### Item interpretation

| Input                        | Interpretation                                  |
|------------------------------|-------------------------------------------------|
| `- Task`                     | Open task under the current recognized section  |
| `- [ ] Task`                 | Open task under the current recognized section  |
| `- [x] Task` or `- [X] Task` | Completed task, excluded from default dashboard |
| `- @Raju Task`               | Task associated with Raju under `Waiting On`    |
| `[due:2026-11-05]`           | Optional ISO-formatted due date                 |

Accept -, *, or + as list markers. In v0.1, collect only top-level list items within each task section; ignore nested bullet items to avoid accidentally turning substeps into separate responsibilities. A task section ends at the next Markdown heading of any depth. Blank lines do not end a section. Ignore bullets inside fenced code blocks. Include checkboxes and ordinary bullets for compatibility with the existing user's workflow; insertion shortcuts should prefer [ ] so tasks can be explicitly completed.

@person should be an optional single token (for example @Raju, @Asha, @Taylor-Smith), immediately after the bullet/checkbox. In Waiting On, an item without @person remains visible as Unassigned rather than being discarded. In To Do, task ownership is the user, regardless of incidental @mentions in text; do not infer ownership from random mentions.

[due:YYYY-MM-DD] is optional. Invalid dates should be treated as metadata errors and displayed as undated rather than causing a scan failure. Do not invent due dates. For waiting items, the due date means a desired follow-up date unless stated otherwise in prose.

## 5. Scan rules and configuration

A plain JSON file named .lattice.json is stored in the PARA notes root. Example:

```json
{
  "version": 1,
  "scan": {
    "include": ["**/*.md"],
    "exclude": ["Archives/**"]
  },
  "headings": {
    "todo": "To Do",
    "waiting": "Waiting On"
  }
}
```

Rules:

- The notes root is set explicitly in the plugin's Neovim configuration. Never assume the Portico workspace is the notes root. The JSON file is read from that root.
- All include/exclude globs are relative to the notes root. * matches within one path segment; ** matches across path segments.
- Scan all matching .md files except excluded paths; directories under exclusions are skipped.
- Archives/** is a default exclusion, and users may remove it in their own config.
- Never traverse outside the configured notes root through ../ paths or symlink resolution.
- If config is missing, use the above defaults with a nonfatal status message; if malformed, show an actionable error and avoid silently scanning an unintended directory.
- On manual refresh, reread both config and Markdown; no Neovim restart required.
- Scanning is strictly read-only, even when an AI agent has altered notes.
- Ignore I/O errors for individual unreadable files but report their count and paths in an inspectable message.

## 6. Dashboard

Command: :Lattice opens or focuses a Neovim dashboard buffer. Example:

```
LATTICE
──────────────────────────────────
MY TO DO                      (3)
  Prepare staffing plan
  Review quarterly budget
  Send update to CIO          Nov 5

WAITING ON                    (3)
  Raju     Deployment estimate
  Asha     Hiring feedback
  Taylor   Architecture review Nov 7

Enter: Open original note   r: Refresh   q: Close
```

The counts are illustrative. Entries should retain the exact source path and line in memory while the dashboard is open. Enter opens the original Markdown file at that line. Group by task section, hiding completed items. Within each group, sort dated tasks by ascending due date, followed by undated items in stable file-and-line order. Indicate an overdue date clearly when present. Tasks without dates remain visible.

A task may be identified by (relative_path, line_number) during a scan; no persistent ID or database is required. A refresh reconstructs the list, so line numbers remain accurate after note edits.

## 7. Keymaps and task-insertion behavior

Default LazyVim-friendly keymaps:

| Keymap       | Action                                               |
|--------------|------------------------------------------------------|
| `<leader>ll` | Open Lattice dashboard                               |
| `<leader>lt` | Add a new task to `To Do` in current file            |
| `<leader>ld` | Add a delegated task to `Waiting On` in current file |
| `<leader>lr` | Refresh Lattice                                      |

Also expose :Lattice and :LatticeRefresh commands. Allow keymaps to be overridden or disabled so they do not collide with the user's existing LazyVim configuration.

For insertion, prompt for a description; delegated insertion additionally prompts for a one-token assignee. Append `- [ ] <description>` to the matching section (or create the correct section at the end of the active note if missing). For delegated entries append `- [ ] @<person> <description>`. Only edit the current Markdown buffer after explicit user invocation; do not write to arbitrary notes and do not silently save to disk. Respect Neovim's usual buffer save behavior. Do not accidentally insert into the dashboard buffer.

## 8. Acceptance criteria / test scenarios

1. Separate project: cloning/building Lattice does not require any Portico code or data; no file writes go into Portico.
2. PARA scan: scan Projects/, Areas/, Resources/, and other included folders; skip Archives/ and user-specified patterns.
3. Strict matching: ## To Do and ### Waiting On match; ## TODO and ## Waiting for do not.
4. Open tasks: both - Task and - [ ] Task appear in the correct dashboard group.
5. Completed tasks: - [x] Task and - [X] Task do not appear in default open lists.
6. People: @Raju in Waiting On extracts Raju; missing assignee displays Unassigned.
7. Dates: valid [due:2026-11-05] is parsed; absent/invalid date never breaks a scan.
8. Boundaries: bullets in unrelated headings, nested bullets, and code fences are not counted.
9. Navigation: Enter opens the correct file and exact task line.
10. Refresh: a task checked off externally or excluded via a config change disappears after refresh.
11. Edit restraint: running a scan does not change any note; shortcut insertion only changes the current Markdown buffer.
12. Offline: all core functions operate without internet, cloud accounts, or AI services.

## 9. Implementation guidance

Use Lua and standard Neovim APIs. Split config loading, Markdown parsing, scanning, and dashboard rendering into testable modules. Start with functional correctness rather than complex indexing or caching. Avoid extra dependencies until there is a demonstrated need. A simple whole-tree scan on demand is acceptable for v0.1.

For AI-assisted development, implement against the acceptance criteria and propose any change to the strict heading convention or task format before proceeding.

## 10. Decisions retained from discussion

- Name: Lattice.
- Lattice is a separate management-work notes plugin, not Portico.
- Keep Neovim/LazyVim, Markdown, and PARA.
- Use a lightweight Lua plugin, not a new Electron app.
- Use distinct strict headings To Do and Waiting On with bullets beneath each.
- No required #lattice/owe or #lattice/waiting tags.
- Configurable exclusions in .lattice.json; Archives excluded by default.
- Notes remain source of truth; AI agent may help manage them but is not a dependency.
