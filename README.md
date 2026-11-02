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

Lattice reads top-level list items under headings named exactly `To Do` or `Waiting On`, at any heading level from `#` to `######`. See [`examples/sample-notes.md`](examples/sample-notes.md).

```markdown
# November 2 — Project Review

Freeform notes are fine; Lattice ignores them.

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

Rules:

| You write                         | Lattice reads                                                     |
|-----------------------------------|-------------------------------------------------------------------|
| `- Task`, `* Task`, `+ Task`      | Open task                                                         |
| `- [ ] Task`                      | Open task                                                         |
| `- [x] Task`, `- [X] Task`        | Completed; hidden from the dashboard                              |
| `@Name` first, in `Waiting On`    | Who you're waiting on. Without it the item shows as *Unassigned*. |
| `[due:YYYY-MM-DD]`                | Due date. On a `Waiting On` item, this is your follow-up date.    |
| `[promised:YYYY-MM-DD]`           | Waiting On only: the date the other person committed to. Shown but not used for sorting, Overdue, or Due Soon. |

- Heading matching is exact and case-sensitive, ignoring spaces around the heading text. `TODO`, `To do`, `To-Do` and `Waiting For` are not recognized.
- A section ends at the next heading of any level. Blank lines don't end it.
- Only top-level items count. Nested bullets, continuation lines, and ordered (`1.`) items are not tasks.
- Anything inside a fenced code block is ignored, including headings.
- An `@Name` is one word, for example `@Raju` or `@Asha-Lee`. In `To Do`, an `@mention` is ordinary text.
- An invalid date such as `[due:2026-02-30]` is never corrected. The task is shown with no date, and `:LatticeHealth` lists the problem.
- Windows (CRLF) line endings and a UTF-8 BOM are handled.

## Dashboard

`:Lattice` (default `<leader>ll`) opens the dashboard in the current window:

```
LATTICE                                           Mon Nov 02
My management workspace — local notes
~/Documents/WorkNotes  (128 notes)
────────────────────────────────────────────────────────────
MY TO DO (3)
  [ ] Review budget                         Oct 30
  [ ] Send project update                   Nov 05
  [ ] Prepare revised staffing plan

WAITING ON (3)
  [ ] Raju — Provide deployment estimate    Nov 06
  [ ] Asha — Submit hiring feedback
  [ ] Unassigned — Follow up with vendor

OVERDUE (1)
  !  Review budget                          Oct 30

DUE SOON (2)  [within next 7 days; excludes overdue]
  ·  Send project update                    Nov 05
  ·  Raju — Provide deployment estimate     Nov 06

────────────────────────────────────────────────────────────
Enter  Open note    r  Refresh    q  Close    ?  Help
```

- **MY TO DO** and **WAITING ON** list open tasks. Tasks with a date come first, earliest first, so overdue items lead. Undated tasks follow. Ties are ordered by file path and line.
- **OVERDUE** lists open tasks due before today, oldest first.
- **DUE SOON** lists open tasks due from today through 7 days ahead, soonest first.
- A task can appear both in its owner group and in a date group. Each group's count covers only that group.
- **INBOX** appears only if the inbox folder exists. See [Capture inbox](#capture-inbox).
- With no open tasks, the dashboard says which headings it looks for, and the header shows the scanned root and note count.

| Key     | Action                                                                 |
|---------|------------------------------------------------------------------------|
| `Enter` | Open the task's note with the cursor on its line. An already-open note keeps its unsaved changes. |
| `r`     | Rescan notes and reread `.lattice.json`                                |
| `q`     | Close the dashboard and return to the previous buffer                  |
| `?`     | Toggle help                                                            |

## Adding tasks

Run these from a Markdown note. They edit only that buffer and never save it.

- `<leader>lt` or `:LatticeAddTodo` asks for the task and adds `- [ ] <task>` under `To Do`.
- `<leader>ld` or `:LatticeAddWaiting` asks for a name (optional; press Enter to skip), then the task. It adds `- [ ] @Name <task>`, or `- [ ] <task>` if you skipped the name, under `Waiting On`.

How Lattice chooses where to add:

- The new item goes after the last non-blank line of the section, below any existing items and their sub-bullets.
- If the note has more than one matching section, Lattice uses the one containing the cursor. If the cursor isn't inside one, it uses the nearest section above the cursor, or the first section if there are none above.
- If the note has no matching section, Lattice asks before adding `## To Do` or `## Waiting On` at the end. Answer No, or cancel any prompt with `Esc`, and the buffer stays exactly as it was.

## Commands and keymaps

| Command              | Default key  | Action                                                  |
|----------------------|--------------|---------------------------------------------------------|
| `:Lattice`           | `<leader>ll` | Open or focus the dashboard                             |
| `:LatticeRefresh`    | `<leader>lr` | Rescan notes and reread `.lattice.json`                 |
| `:LatticeAddTodo`    | `<leader>lt` | Add a task under `To Do` in the current note            |
| `:LatticeAddWaiting` | `<leader>ld` | Add an item under `Waiting On` in the current note      |
| `:LatticeHealth`     |              | Same as `:checkhealth lattice`; see [Troubleshooting](#troubleshooting) |

Lua API: `require("lattice")` provides `setup`, `open`, `refresh`, `add_todo`, `add_waiting` and `health`.

Lattice never replaces a mapping you already have. If one of its default keys is already mapped when `setup` runs, Lattice leaves your mapping alone, warns once, and lists the key in `:LatticeHealth`. To change or turn off keys:

```lua
opts = {
  root = "~/Documents/WorkNotes",
  keymaps = {
    open = "<leader>nl",
    add_todo = "<leader>nt",
    add_waiting = "<leader>nw",
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
  "scan": {
    "include": ["**/*.md"],
    "exclude": ["Archives/**", ".git/**", "Projects/Completed/**"]
  },
  "headings": {
    "todo": "To Do",
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
| `scan.include`   | `["**/*.md"]`                  | Files to scan. Only `.md` files are ever read.             |
| `scan.exclude`   | `["Archives/**", ".git/**"]`   | Files and folders to skip. A list you give **replaces** the default, so keep `Archives/**` in it if you want Archives skipped. |
| `headings.todo`  | `"To Do"`                      | Exact heading text for your commitments                    |
| `headings.waiting` | `"Waiting On"`               | Exact heading text for items you're waiting on             |
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

Changes to `.lattice.json` take effect on the next refresh (`r`, `:LatticeRefresh`), with no restart needed. If the file is invalid, the dashboard shows the error and lists no tasks. It doesn't fall back to scanning some other way.

## Capture inbox

For notes captured away from your Mac, such as in Drafts on iPhone, copy the Markdown into `Inbox/` in your notes root by hand, from a Drafts action, by AirDrop, or however you like. Set a different folder with `inbox.path`. Lattice doesn't import or sync anything itself.

When the folder exists, the dashboard's INBOX group lists each `.md` file in it, including subfolders, oldest first. Each entry shows the file's first line as its title and the file's modified date. `Enter` opens the capture. Lattice never moves or edits captures. Once you file a note into its PARA location, it leaves the list at the next refresh.

`scan.exclude` doesn't affect this list. `To Do` and `Waiting On` sections in inbox notes count as tasks like any others, so add `Inbox/**` to `scan.exclude` if you'd rather keep them off the dashboard until the note is filed.

## Limitations

- **Saved files only.** Lattice reads files from disk. A task you add or check off appears on the dashboard after you save the note and refresh.
- **Manual refresh.** There is no file watching or background indexing. The dashboard and its line numbers reflect the last scan.
- **Whole-tree scan.** Every refresh rescans all included notes synchronously. This is fast for typical note collections but not optimized for very large trees.
- **No completion command.** Mark tasks done by editing the note (`- [x]`).
- **Strict format.** Lattice doesn't infer tasks from prose, and only one-word `@Name` assignees are recognized.
- **Symlinks** are skipped entirely (see above).
- **Not yet built:** WBR preparation, AI-assisted commitment discovery, Portico publishing, and automated Drafts import are planned for later milestones (see [`specs/LATTICE_SPEC.md`](specs/LATTICE_SPEC.md) §11). The dashboard doesn't show or pretend to support them.

## Troubleshooting

Run `:LatticeHealth` (or `:checkhealth lattice`). It runs a fresh read-only scan and reports:

- the notes root and how many notes were scanned
- whether `.lattice.json` was found and is valid
- open and completed task counts
- each file or folder that couldn't be read
- each invalid date, with its file (relative to the root) and line number
- any default keymaps skipped because the key was already mapped

Common problems:

| Symptom                                   | Fix                                                                                        |
|-------------------------------------------|--------------------------------------------------------------------------------------------|
| "Notes root is not set"                   | Add `root` to `opts`, or pass it to `setup()`.                                              |
| "Notes root … is not a directory"         | Check the path. `~` is expanded, and relative paths are resolved from Neovim's current directory. |
| "Invalid JSON" / "Invalid config"         | Fix `.lattice.json` as the message describes, then press `r`.                                |
| A task is missing                         | Check that the heading is spelled exactly, the item is top-level and outside a code fence, the file is saved, and it isn't excluded. Then refresh. |
| A whole folder is missing                 | It may be excluded, a symlink, or unreadable. `:LatticeHealth` lists unreadable paths.       |
| `Enter` warns that a file "no longer exists" | The note was moved or deleted since the last scan. Press `r`.                            |
| `<leader>l…` keys do nothing              | Another mapping may own the key. See `:LatticeHealth`, then choose different keys.          |

## Development

```sh
nvim -l tests/run.lua
```

The runner executes `tests/parser_spec.lua`, `scanner_spec.lua`, `dashboard_spec.lua` and `insert_spec.lua` headlessly in temporary directories, using only synthetic fixtures. Never add real work notes to this repository.

Layout:

```
lua/lattice/init.lua       setup, commands, keymaps
lua/lattice/config.lua     defaults, plugin options, .lattice.json validation
lua/lattice/parser.lua     pure Markdown parsing
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
