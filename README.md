# Lattice

Lattice is a local-first Neovim/LazyVim plugin that gathers what you owe other people, and what they owe you, from your existing Markdown notes into one keyboard-driven dashboard.

- Your notes stay the only source of truth. Lattice has no database, server, account, network access, or AI dependency.
- Your PARA folders stay as they are. Lattice scans the notes root you configure.
- Scanning is read-only. Lattice changes a note only when you run an insert command in it, and it never saves for you.

Lattice is independent of Portico and works without it.

## Requirements

- Neovim 0.12. Tested on 0.12.4 on macOS. The code uses APIs that exist from Neovim 0.10 onward, but 0.10 and 0.11 are untested.
- No other plugins. LazyVim is optional.

## Install (lazy.nvim / LazyVim)

Create `~/.config/nvim/lua/plugins/lattice.lua`:

```lua
return {
  {
    "marctalcott/lattice-nvim",
    lazy = false,
    opts = {
      root = "~/Documents/WorkNotes", -- required: your notes root; Lattice never guesses it
    },
  },
}
```

lazy.nvim calls `require("lattice").setup(opts)` for you. If your employer requires a security review of code before it runs on a work machine, pin a reviewed commit (for example `commit = "<sha>"`), or clone the reviewed source and point lazy.nvim at it with `dir = "~/path/to/lattice-nvim"` in place of the repository name.

Without lazy.nvim, put the repository on your `runtimepath` and call:

```lua
require("lattice").setup({ root = "~/Documents/WorkNotes" })
```

Optionally copy [`examples/.lattice.json`](examples/.lattice.json) into the notes root to customize scanning. Without it, Lattice uses the defaults below and says so on the dashboard.

## Note format

Lattice follows Org-mode's task model in ordinary Markdown: *Org-mode semantics, Markdown syntax, Neovim interface.* The full contract is [`specs/LATTICE_SYNTAX_SPEC.md`](specs/LATTICE_SYNTAX_SPEC.md); decisions on its open points are in [`specs/ORG_MARKDOWN_PLAN.md`](specs/ORG_MARKDOWN_PLAN.md). See [`examples/sample-notes.md`](examples/sample-notes.md).

```markdown
# Etna :engineering:

## IN PROGRESS [#A] Review system architecture :design:
DEADLINE: <2026-11-05 Thu>
:PROPERTIES:
:ID: etna-review-001
:END:
- [x] Collect requirements
- [ ] Draft the proposal
  SCHEDULED: <2026-11-03 Tue>

# Team

- [ ] Reply about the offsite venue
  :PROPERTIES:
  :STATE: WAITING
  :ASSIGNED: Elira Voss
  :END:
```

### Tasks

| You write | Lattice reads | Org compatibility |
|-----------|---------------|-------------------|
| `## TODO Title` (any `#` level) | Heading task. A heading without a state is just a heading. | Adapted (`#` for `*`) |
| `- [ ] Title`, `* [ ]`, `+ [ ]`, `1. [ ]` | Checkbox task: `[ ]` open, `[x]` / `[X]` done. **Every checkbox is a task.** | Extended |
| `- TODO Title` (no box) | Task in that state | Extended (Lattice v0.1 syntax) |
| `- [ ] WAITING Title` | Checkbox task in that state | Extended |

- A heading's subtree runs to the next heading of the same or a higher level. Checkbox children follow list nesting, whatever the indent width. Headings and checkboxes form one tree: a checkbox under `## TODO Plan` is that task's child.
- States match exactly, as in Org: `TODO` is a state; `todo`, `TODO:` and `TODOs` are not. A state with no title after it is not a task, and neither is an empty checkbox.
- Prose, and anything in a fenced or indented code block, is never a task. Front matter is never a task.
- Tasks are found with Neovim's built-in Tree-sitter Markdown parser. Windows line endings and a UTF-8 BOM are handled.

### States and workflows

A workflow lists active states, then done states (Org's `TODO | DONE`). The default is `TODO NEXT WAITING` / `DONE CANCELED`. Set workflows in [`.lattice.json`](#configuration-latticejson):

```json
"workflows": {
  "default": { "active": ["TODO", "NEXT", "WAITING"], "done": ["DONE", "CANCELED"] },
  "etna":    { "active": ["BACKLOG", "READY", "IN PROGRESS", "BLOCKED"], "done": ["COMPLETE", "CANCELED"] }
}
```

- **Which workflow applies:** a `:WORKFLOW:` property (inherited), else the task's project's workflow, else the note's front matter `todo:` (v0.1), else `default`. States may contain spaces (`IN PROGRESS`).
- **Projects are optional.** A task's project is an inherited `:PROJECT:` property, or `project:` in front matter, or the top-level `#` heading when its text names a configured workflow: `# Etna` is the Etna project above, but `# Meeting notes` is not a project.
- **Checkbox states:** `:STATE:` in the item's drawer sets the state. Without one, `[ ]` is the workflow's first active state and `[x]` its first done state. The box always decides whether the item is finished; a box that disagrees with its state (`- [x] TODO …`) is listed as a warning, and Lattice never changes either.
- A state Lattice doesn't know (`:STATE: PONDERING`, or `## BACKLOG …` outside the etna workflow) is a warning and never counts as done.

### Metadata

Metadata goes directly below the title: below a heading, or inside a list item, indented with it. Reading stops at the first other line, so look-alike text further down is ignored.

| Metadata | Example | Org compatibility |
|----------|---------|-------------------|
| Planning | `SCHEDULED: <2026-11-05 Thu>`, `DEADLINE: <2026-11-09 Mon -3d>`, `CLOSED: [2026-11-09 Mon 14:30]` | Direct (Extended on checkboxes) |
| Priority | `## TODO [#A] Title`; on a checkbox, `:PRIORITY: A` | Direct / Extended |
| Tags | `## TODO Title :etna:design:`; on a checkbox, `:TAGS: etna design` | Direct / Extended |
| Properties | `:PROPERTIES:` … `:NAME: value` … `:END:` (any names; `:NAME+:` appends) | Direct (Extended on checkboxes) |

- Tags inherit from enclosing headings and tasks (`inherit.tags`). `:PROJECT:` and `:WORKFLOW:` always inherit; other properties inherit when listed in `inherit.properties`.
- `:ASSIGNED:` names the person shown on a row. `:STATE: WAITING` puts a task in WAITING ON.
- The dashboard's date is the `DEADLINE`. `SCHEDULED`, repeaters (`+1w`, `++1m`, `.+1d`) and warning periods are parsed now and drive the agenda in the next milestone.
- Problems are warnings, never silent fixes: invalid timestamps, a weekday that doesn't match its date, malformed drawers, unknown priorities, states or workflows, and duplicate `:ID:`s (within a note or across notes).

### Lattice v0.1 syntax

Notes written for Lattice 0.1 keep working, and `:LatticeHealth` counts what still uses the old forms. [`examples/legacy-v0.1-notes.md`](examples/legacy-v0.1-notes.md) shows them all.

| v0.1 form | Read as |
|-----------|---------|
| Bullets under a `## Waiting On` heading | Waiting items (state `WAITING` when they have none) |
| `@Name` at the start of a waiting item | `:ASSIGNED: Name` |
| `[due:YYYY-MM-DD]` | The task's date, like `DEADLINE` (a real `DEADLINE` wins) |
| `[promised:YYYY-MM-DD]` | `:PROMISED:` |
| Front matter `todo: TODO NEXT \| DONE` | That note's workflow |

A command to convert a note to the Org forms is planned.

## Dashboard

`:Lattice` (default `<leader>ll`) opens the dashboard in the current window. For the two notes in [`examples/`](examples) with [`examples/.lattice.json`](examples/.lattice.json), on November 2, 2026, it shows:

```

```

- **MY TO DO** and **WAITING ON** list open tasks. Each row shows the state, priority, assignee and the task's own tags. WAITING ON holds tasks in the `WAITING` state and v0.1 `Waiting On` items. Tasks with a date come first, earliest first, so overdue items lead. Undated tasks follow. Ties are ordered by file path and line.
- **OVERDUE** lists open tasks due before today, oldest first.
- **DUE SOON** lists open tasks due from today through 7 days ahead, soonest first.
- **DONE** lists finished tasks (a done state, or a checked box), from the most recently modified note first. It shows the 20 most recent and a count of the rest.
- A task can appear both in its owner group and in a date group. Each group's count covers only that group.
- **INBOX** appears only if the inbox folder exists. See [Capture inbox](#capture-inbox).
- **WARNINGS** appears when a file couldn't be read or a note has a problem Lattice found (see [Metadata](#metadata)). `Enter` on a warning opens the note at that line.
- With no open tasks, the dashboard shows the keywords it looks for, and the header shows the scanned root and note count.

| Key     | Action                                                                 |
|---------|------------------------------------------------------------------------|
| `Enter` | Open the task's note with the cursor on its line. An already-open note keeps its unsaved changes. |
| `r`     | Rescan notes and reread `.lattice.json`                                |
| `q`     | Close the dashboard and return to the previous buffer                  |
| `?`     | Toggle help                                                            |

## Adding tasks

Run these from a Markdown note. They edit only that buffer and never save it.

- `<leader>lt` or `:LatticeAddTodo` asks for the task and adds `- TODO <task>` on the line below the cursor. It uses the first active state of the note's workflow: its front matter `todo:` if set, else the default workflow. On a list item, the new item matches that item's indent and goes after its sub-bullets, so they stay with their own item. If the cursor is in the front matter, the item goes just below it. Inside a `Waiting On` section the new item counts as a waiting item, like any keyword item there, so move the cursor out of the section first to add one of your own.
- `<leader>ld` or `:LatticeAddWaiting` asks for a name (optional; press Enter to skip), then the task. It adds `- [ ] @Name <task>`, or `- [ ] <task>` if you skipped the name, under `Waiting On`:
  - The item goes after the last non-blank line of the section, below any existing items and their sub-bullets.
  - If the note has more than one `Waiting On` section, Lattice uses the one containing the cursor. If the cursor isn't inside one, it uses the nearest section above the cursor, or the first section if there are none above.
  - If the note has no `Waiting On` section, Lattice asks before adding `## Waiting On` at the end. Answer No, or cancel any prompt with `Esc`, and the buffer stays exactly as it was.
- If a new item lands inside a code block, for example one that is never closed, Lattice can't list it and warns you.

## Changing an item's state

Like org-mode's `S-Right` / `S-Left`, `<leader>ln` (`:LatticeNextState`) and `<leader>lp` (`:LatticePrevState`) step the item under the cursor through its keyword sequence. With `TODO NEXT | DONE CANCELED`:

```
- Write docs  →  - TODO Write docs  →  - NEXT Write docs  →  - DONE Write docs  →  - CANCELED Write docs  →  - Write docs
```

`<leader>lp` goes the other way. The details:

- It works on bullets (`-`, `*`, `+`, with or without a checkbox) and `#` headings. The keyword goes after the marker and any checkbox: `- [ ] TODO Write docs`. The checkbox itself is left alone.
- It uses the workflow in effect on that line: a `:WORKFLOW:` property, the project's workflow, the note's front matter `todo:`, or the default. An item stays within the sequence that holds its keyword, so `BUG` steps to `FIXED` and then back to no keyword. An item with no keyword starts on the first sequence.
- On a plain line, a numbered item, an empty bullet, the front matter, or a line inside a code block, it changes nothing and says why.
- It edits only the buffer, as one undo step. Save the note and refresh the dashboard to see the change there.

## Commands and keymaps

| Command              | Default key  | Action                                                  |
|----------------------|--------------|---------------------------------------------------------|
| `:Lattice`           | `<leader>ll` | Open or focus the dashboard                             |
| `:LatticeRefresh`    | `<leader>lr` | Rescan notes and reread `.lattice.json`                 |
| `:LatticeAddTodo`    | `<leader>lt` | Add a `TODO` item below the cursor                      |
| `:LatticeAddWaiting` | `<leader>ld` | Add an item under `Waiting On` in the current note      |
| `:LatticeNextState`  | `<leader>ln` | Move the item under the cursor to its next state        |
| `:LatticePrevState`  | `<leader>lp` | Move the item under the cursor to its previous state    |
| `:LatticeHealth`     |              | Same as `:checkhealth lattice`; see [Troubleshooting](#troubleshooting) |

Lua API: `require("lattice")` provides `setup`, `open`, `refresh`, `add_todo`, `add_waiting`, `next_state`, `prev_state` and `health`.

Lattice never replaces a mapping you already have. If one of its default keys is already mapped when `setup` runs, Lattice leaves your mapping alone, warns once, and lists the key in `:LatticeHealth`. The dashboard help shows only the keys Lattice actually mapped. Mappings local to one buffer don't count as conflicts. Running `setup` again, for example on a config reload, first removes the keys the previous run created. A value that is neither a key string nor `false` is reported and ignored. To change or turn off keys:

```lua
opts = {
  root = "~/Documents/WorkNotes",
  keymaps = {
    open = "<leader>nl",
    add_todo = "<leader>nt",
    add_waiting = "<leader>nw",
    next_state = "<leader>nn",
    prev_state = "<leader>np",
    refresh = false, -- no mapping
  },
  -- or keymaps = false to set none
}
```

LazyVim maps `<leader>l` alone to `:Lazy`. The `<leader>l…` defaults still work, but pressing `<leader>l` by itself then waits `timeoutlen` before opening Lazy. Pick a different prefix if that bothers you.

## Configuration: `.lattice.json`

This file lives in the **notes root**, not in this plugin's repository. Every field is optional:

```json
{
  "version": 1,
  "workflows": {
    "default": { "active": ["TODO", "NEXT", "WAITING"], "done": ["DONE", "CANCELED"] },
    "etna": { "active": ["BACKLOG", "READY", "IN PROGRESS", "BLOCKED"], "done": ["COMPLETE", "CANCELED"] }
  },
  "priorities": { "values": ["A", "B", "C"], "default": "B" },
  "inherit": { "tags": true, "properties": [] },
  "deadlines": { "warning_days": 14 },
  "scan": {
    "include": ["**/*.md"],
    "exclude": ["Archives/**", ".git/**", "Projects/Completed/**"]
  },
  "headings": {
    "waiting": "Waiting On"
  },
  "inbox": {
    "path": "Inbox"
  }
}
```

| Field            | Default                        | Meaning                                                    |
|------------------|--------------------------------|------------------------------------------------------------|
| `version`        | `1`                            | Format version. Any other value is an error.               |
| `workflows`      | `default`: `TODO NEXT WAITING` / `DONE CANCELED` | Named workflows: `{ "active": [...], "done": [...] }`. `default` applies unless a task's `:WORKFLOW:` or project picks another. Names are one word, matched case-insensitively. |
| `todo`           | —                              | Lattice v0.1 way to set the default workflow as Org sequences (`"TODO NEXT \| DONE"`). Use it or `workflows.default`, not both. |
| `priorities`     | `A`, `B`, `C`; default `B`     | Allowed priority values (single letters or digits, highest first) and the default used for sorting. |
| `inherit.tags`   | `true`                         | Whether tasks inherit tags from enclosing headings and tasks |
| `inherit.properties` | `[]`                       | Extra properties to inherit (or `true` for all). `PROJECT` and `WORKFLOW` always inherit. |
| `deadlines.warning_days` | `14`                   | Default deadline warning period, as Org's `org-deadline-warning-days` (used by the agenda in the next milestone) |
| `scan.include`   | `["**/*.md"]`                  | Files to scan. Only `.md` files are ever read.             |
| `scan.exclude`   | `["Archives/**", ".git/**"]`   | Files and folders to skip. A list you give **replaces** the default, so keep `Archives/**` in it if you want Archives skipped. |
| `headings.waiting` | `"Waiting On"`               | v0.1: heading whose bullets are waiting items              |
| `inbox.path`     | `"Inbox"`                      | Folder inside the root listed as the capture inbox         |

### Glob matching

Globs are matched against each path relative to the notes root, using `/` separators and no leading `./`. For example, `Projects/Alpha/notes.md`.

- `*` matches any characters within one path segment. `Areas/*.md` matches `Areas/x.md` but not `Areas/team/x.md`.
- `**` matches any number of segments, including none. `**/drafts/**` matches `drafts/a.md` and `Areas/x/drafts/a.md`.
- `?` matches one character, `[abc]` a character class, and `{a,b}` alternatives.
- A pattern must match the whole path. `Archives` alone matches only a file named `Archives`, so use `Archives/**` to skip the folder.
- When an exclude pattern matches a folder, Lattice doesn't enter it at all.
- Matching is case-sensitive, even though the default macOS file system is not.
- Patterns may not be absolute or contain `..`. Invalid patterns are reported as errors.

### Always applied

- Any directory named `.git`, at any depth, is skipped, whatever `scan.exclude` says.
- Symbolic links are never followed, even links that point inside the root. Symlink cycles therefore can't cause endless scanning, and the scan can't leave the root. To include a linked folder, move it into the root.

Older configs may still contain `headings.todo`. It is ignored, and the dashboard shows a notice.

Changes to `.lattice.json` take effect on the next refresh (`r`, `:LatticeRefresh`), with no restart needed. If the file is invalid, the dashboard shows the error and lists no tasks. It doesn't fall back to scanning some other way.

## Capture inbox

For notes captured away from your Mac, such as in Drafts on iPhone, copy the Markdown into `Inbox/` in your notes root by hand, from a Drafts action, by AirDrop, or however you like. Set a different folder with `inbox.path`. Lattice doesn't import or sync anything itself.

When the folder exists, the dashboard's INBOX group lists each `.md` file in it, including subfolders, oldest first. Each entry shows the file's first line as its title and the file's modified date. `Enter` opens the capture. Lattice never moves or edits captures. Once you file a note into its PARA location, it leaves the list at the next refresh.

`scan.exclude` doesn't affect this list. Tasks in inbox notes count like any others, so add `Inbox/**` to `scan.exclude` if you'd rather keep them off the dashboard until the note is filed.

## Limitations

- **Saved files only.** Lattice reads files from disk. A task you add or check off appears on the dashboard after you save the note and refresh.
- **Manual refresh.** There is no file watching or background indexing. The dashboard and its line numbers reflect the last scan.
- **Whole-tree scan.** Every refresh rescans all included notes synchronously. This is fast for typical note collections but not optimized for very large trees.
- **Org subset, in progress.** Tasks, workflows, priorities, tags, properties and planning lines are read (milestones A and B of the spec). Scheduling and repeaters in the agenda, editing commands that keep checkboxes, `:STATE:` and progress cookies in sync, and `CLOSED` timestamps come in later milestones. Until then `<leader>ln` / `<leader>lp` change the state word on the line only.
- **Tree-sitter.** Lattice needs Neovim's Markdown parser, which ships with Neovim. A broken parser binary can crash Neovim when it loads; see [Troubleshooting](#troubleshooting).
- **Symlinks** are skipped entirely (see above).
- **Not yet built:** WBR preparation, AI-assisted commitment discovery, Portico publishing, and automated Drafts import are planned for later milestones (see [`specs/LATTICE_SPEC.md`](specs/LATTICE_SPEC.md) §11). The dashboard doesn't show or pretend to support them.

## Troubleshooting

Run `:LatticeHealth` (or `:checkhealth lattice`). It runs a fresh read-only scan and reports:

- the notes root and how many notes were scanned
- whether `.lattice.json` was found and is valid
- open and completed task counts
- each file or folder that couldn't be read
- each invalid date, with its file (relative to the root) and line number
- every warning about a note (timestamps, drawers, states, priorities, duplicate IDs), with file and line
- whether the Markdown Tree-sitter parser loaded, the workflows, and how many items still use v0.1 syntax
- any default keymaps skipped because the key was already mapped

Common problems:

| Symptom                                   | Fix                                                                                        |
|-------------------------------------------|--------------------------------------------------------------------------------------------|
| "Notes root is not set"                   | Add `root` to `opts`, or pass it to `setup()`.                                              |
| "Notes root … is not a directory"         | Check the path. `~` is expanded, and relative paths are resolved from Neovim's current directory. |
| "Invalid JSON" / "Invalid config"         | Fix `.lattice.json` as the message describes, then press `r`.                                |
| A task is missing                         | Check that a heading or bullet starts with a state of its workflow, in the right case (`:LatticeHealth` lists the workflows), or that it's a checkbox with text; that it's outside code blocks, that the file is saved, and that it isn't excluded. Then refresh. |
| A whole folder is missing                 | It may be excluded, a symlink, or unreadable. `:LatticeHealth` lists unreadable paths.       |
| `Enter` warns that a file "no longer exists" | The note was moved or deleted since the last scan. Press `r`.                            |
| Neovim quits ("KILL") when opening or scanning Markdown | A Tree-sitter parser binary is broken (on macOS, often `markdown.so` replaced in place). Delete it, for example `rm -rf ~/.local/share/nvim/lazy/nvim-treesitter/parser ~/.local/share/nvim/site/parser`, then run `:TSUpdate` from a fresh Neovim. |
| `<leader>l…` keys do nothing              | Another mapping may own the key. See `:LatticeHealth`, then choose different keys.          |

## Development

```sh
nvim -l tests/run.lua
```

The runner executes `tests/parser_spec.lua`, `scanner_spec.lua`, `dashboard_spec.lua`, `insert_spec.lua`, `tasks_spec.lua` and `metadata_spec.lua` headlessly in temporary directories, using only synthetic fixtures. Never add real work notes to this repository.

Layout:

```
lua/lattice/init.lua       setup, commands, keymaps
lua/lattice/config.lua     defaults, plugin options, .lattice.json validation
lua/lattice/markdown.lua   Markdown block structure from Tree-sitter
lua/lattice/tasks.lua      tasks, workflows, inheritance, hierarchy
lua/lattice/metadata.lua   planning lines and property drawers
lua/lattice/timestamp.lua  Org timestamps
lua/lattice/keywords.lua   workflows, sequences, front matter
lua/lattice/scanner.lua    read-only traversal of the notes root
lua/lattice/dashboard.lua  dashboard rendering, navigation
lua/lattice/insert.lua     user-triggered edits to the current note
lua/lattice/health.lua     :checkhealth lattice / :LatticeHealth
doc/lattice.txt            :help lattice
specs/                     product vision and implementation specs
```

See [`CHANGELOG.md`](CHANGELOG.md) for changes and deferred items.

## License

No license has been chosen yet. Until the owner adds one, all rights are reserved.
