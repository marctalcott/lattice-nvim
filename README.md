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

Lattice uses org-mode style TODO keywords. An item is a task when its first word is a declared keyword, and it can sit anywhere in a note. See [`examples/sample-notes.md`](examples/sample-notes.md).

```markdown
---
todo: TODO NEXT | DONE CANCELED
---

# November 2 — Project Review

Freeform notes are fine; Lattice ignores them.

- TODO Prepare revised staffing plan
- NEXT Send project update [due:2026-11-05]
- DONE Review the completed migration

## NEXT Draft the Q1 plan

## Waiting On
- @Raju Provide deployment estimate [due:2026-11-06]
- [ ] @Asha Submit hiring feedback
- DONE @Lee Send the signed contract
```

### Keywords and sequences

A sequence lists states in order, as in org-mode's `#+TODO:`. Words before `|` are open states, and words after it are done states. Without a `|`, the last word is the only done state. Fast-access suffixes such as `TODO(t)` or `DONE(d!)` are accepted and ignored.

- **For the whole notes root,** set `todo` in [`.lattice.json`](#configuration-latticejson) to one sequence or a list of them. The default is `TODO | DONE`.
- **For one note,** put a `todo:` key in its YAML front matter. This replaces the root sequences for that note only, as `#+TODO:` does in an org file:

  ```yaml
  ---
  todo: TODO NEXT WAITING | DONE CANCELED
  ---
  ```

  For several sequences, use a list:

  ```yaml
  ---
  todo:
    - TODO NEXT | DONE
    - BUG | FIXED
  ---
  ```

  Lattice reads only the `todo` key and ignores the rest of the front matter. If the value is invalid, the note uses the root sequences, and the problem is listed under WARNINGS.

### Rules

| You write                                  | Lattice reads                                                    |
|--------------------------------------------|------------------------------------------------------------------|
| `- TODO Task`, `* NEXT Task`, `+ TODO Task` | Task in an open state, in MY TO DO                              |
| `## NEXT Task` (any heading level)         | Task in an open state                                            |
| `- DONE Task`, `- CANCELED Task`           | Task in a done state, in the DONE group                          |
| Bullets under a `Waiting On` heading       | Items you're waiting on. Plain bullets and `[ ]` are open; `[x]` is done and hidden. Keyword items there take their keyword's state. |
| `@Name` first, in `Waiting On`             | Who you're waiting on. Without it the item shows as *Unassigned*. |
| `[due:YYYY-MM-DD]`                         | Due date. On a `Waiting On` item, this is your follow-up date.   |
| `[promised:YYYY-MM-DD]`                    | Waiting On only: the date the other person committed to. Shown, but not used for sorting, Overdue, or Due Soon. |

- Keywords match exactly, as in org-mode. `TODO` is a keyword, but `todo`, `Todo`, `TODO:` and `TODOs` are not. A keyword with nothing after it (`- TODO` or `## TODO`) is not a task.
- Keyword items count at any nesting depth. In a `Waiting On` section, plain bullets count only at the top level.
- Ordered (`1.`) items, prose, and anything in a fenced or indented code block are never tasks. Front matter lines are never tasks either.
- `Waiting On` matches exactly, at any heading level from `#` to `######`. Its section ends at the next heading. Keyword items inside it are waiting items; a keyword heading always counts as yours.
- A checkbox before a keyword is allowed (`- [ ] TODO Task`), and the keyword decides the state.
- An `@Name` is one word, for example `@Raju` or `@Asha-Lee`. On your own items, an `@mention` is ordinary text.
- An invalid date such as `[due:2026-02-30]` is never corrected. The task is shown with no date, and both the dashboard's WARNINGS block and `:LatticeHealth` list the problem.
- Windows (CRLF) line endings and a UTF-8 BOM are handled.

## Dashboard

`:Lattice` (default `<leader>ll`) opens the dashboard in the current window. For [`examples/sample-notes.md`](examples/sample-notes.md) on November 2, 2026, it shows:

```
LATTICE                                                                      Mon Nov 02
My management workspace — local notes
~/Documents/WorkNotes  (1 note)
───────────────────────────────────────────────────────────────────────────────────────
MY TO DO (5)
  [ ] TODO Review budget                                        Oct 30
  [ ] NEXT Send project update                                  Nov 05
  [ ] TODO Prepare revised staffing plan
  [ ] TODO Nested items count when they start with a keyword
  [ ] NEXT Draft the Q1 plan

WAITING ON (3)
  [ ] Raju — Provide deployment estimate                        Nov 06
  [ ] Asha — Submit hiring feedback                             Nov 09  promised Nov 07
  [ ] Unassigned — Follow up with vendor

OVERDUE (1)
  !  TODO Review budget                                         Oct 30

DUE SOON (3)  [within next 7 days; excludes overdue]
  ·  NEXT Send project update                                   Nov 05
  ·  Raju — Provide deployment estimate                         Nov 06
  ·  Asha — Submit hiring feedback                              Nov 09  promised Nov 07

DONE (3)
  [x] DONE Review the completed migration
  [x] CANCELED Book the offsite
  [x] DONE Lee — Send the signed contract

───────────────────────────────────────────────────────────────────────────────────────
Enter  Open note    r  Refresh    q  Close    ?  Help
```

- **MY TO DO** and **WAITING ON** list open tasks, each row showing its keyword state. Tasks with a date come first, earliest first, so overdue items lead. Undated tasks follow. Ties are ordered by file path and line.
- **OVERDUE** lists open tasks due before today, oldest first.
- **DUE SOON** lists open tasks due from today through 7 days ahead, soonest first.
- **DONE** lists items in a done state (DONE, CANCELED, …), from the most recently modified note first. Checked `[x]` Waiting On items without a keyword stay hidden.
- A task can appear both in its owner group and in a date group. Each group's count covers only that group.
- **INBOX** appears only if the inbox folder exists. See [Capture inbox](#capture-inbox).
- **WARNINGS** appears when a file couldn't be read, a date is invalid, or a note's front matter `todo:` is invalid. `Enter` on a date or front matter line opens it at that line.
- With no open tasks, the dashboard shows the keywords it looks for, and the header shows the scanned root and note count.

| Key     | Action                                                                 |
|---------|------------------------------------------------------------------------|
| `Enter` | Open the task's note with the cursor on its line. An already-open note keeps its unsaved changes. |
| `r`     | Rescan notes and reread `.lattice.json`                                |
| `q`     | Close the dashboard and return to the previous buffer                  |
| `?`     | Toggle help                                                            |

## Adding tasks

Run these from a Markdown note. They edit only that buffer and never save it.

- `<leader>lt` or `:LatticeAddTodo` asks for the task and adds `- TODO <task>` on the line below the cursor. It uses the note's first open keyword: from its front matter if it has one, else from the root sequences. On a list item, the new item matches that item's indent. If the cursor is in the front matter, the item goes just below it.
- `<leader>ld` or `:LatticeAddWaiting` asks for a name (optional; press Enter to skip), then the task. It adds `- [ ] @Name <task>`, or `- [ ] <task>` if you skipped the name, under `Waiting On`:
  - The item goes after the last non-blank line of the section, below any existing items and their sub-bullets.
  - If the note has more than one `Waiting On` section, Lattice uses the one containing the cursor. If the cursor isn't inside one, it uses the nearest section above the cursor, or the first section if there are none above.
  - If the note has no `Waiting On` section, Lattice asks before adding `## Waiting On` at the end. Answer No, or cancel any prompt with `Esc`, and the buffer stays exactly as it was.
- If a new item lands inside a code block, for example one that is never closed, Lattice can't list it and warns you.

## Commands and keymaps

| Command              | Default key  | Action                                                  |
|----------------------|--------------|---------------------------------------------------------|
| `:Lattice`           | `<leader>ll` | Open or focus the dashboard                             |
| `:LatticeRefresh`    | `<leader>lr` | Rescan notes and reread `.lattice.json`                 |
| `:LatticeAddTodo`    | `<leader>lt` | Add a `TODO` item below the cursor                      |
| `:LatticeAddWaiting` | `<leader>ld` | Add an item under `Waiting On` in the current note      |
| `:LatticeHealth`     |              | Same as `:checkhealth lattice`; see [Troubleshooting](#troubleshooting) |

Lua API: `require("lattice")` provides `setup`, `open`, `refresh`, `add_todo`, `add_waiting` and `health`.

Lattice never replaces a mapping you already have. If one of its default keys is already mapped when `setup` runs, Lattice leaves your mapping alone, warns once, and lists the key in `:LatticeHealth`. The dashboard help shows only the keys Lattice actually mapped. Mappings local to one buffer don't count as conflicts. Running `setup` again, for example on a config reload, first removes the keys the previous run created. A value that is neither a key string nor `false` is reported and ignored. To change or turn off keys:

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
  "todo": ["TODO NEXT WAITING | DONE CANCELED"],
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
| `todo`           | `["TODO \| DONE"]`             | Keyword sequences for every note (a string or a list). A note's front matter `todo:` replaces them for that note. |
| `scan.include`   | `["**/*.md"]`                  | Files to scan. Only `.md` files are ever read.             |
| `scan.exclude`   | `["Archives/**", ".git/**"]`   | Files and folders to skip. A list you give **replaces** the default, so keep `Archives/**` in it if you want Archives skipped. |
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

Older configs may still contain `headings.todo`. It is ignored, and the dashboard shows a notice. Mark items with keywords instead.

Changes to `.lattice.json` take effect on the next refresh (`r`, `:LatticeRefresh`), with no restart needed. If the file is invalid, the dashboard shows the error and lists no tasks. It doesn't fall back to scanning some other way.

## Capture inbox

For notes captured away from your Mac, such as in Drafts on iPhone, copy the Markdown into `Inbox/` in your notes root by hand, from a Drafts action, by AirDrop, or however you like. Set a different folder with `inbox.path`. Lattice doesn't import or sync anything itself.

When the folder exists, the dashboard's INBOX group lists each `.md` file in it, including subfolders, oldest first. Each entry shows the file's first line as its title and the file's modified date. `Enter` opens the capture. Lattice never moves or edits captures. Once you file a note into its PARA location, it leaves the list at the next refresh.

`scan.exclude` doesn't affect this list. Keyword items and `Waiting On` sections in inbox notes count as tasks like any others, so add `Inbox/**` to `scan.exclude` if you'd rather keep them off the dashboard until the note is filed.

## Limitations

- **Saved files only.** Lattice reads files from disk. A task you add or check off appears on the dashboard after you save the note and refresh.
- **Manual refresh.** There is no file watching or background indexing. The dashboard and its line numbers reflect the last scan.
- **Whole-tree scan.** Every refresh rescans all included notes synchronously. This is fast for typical note collections but not optimized for very large trees.
- **No state-cycling command.** Change a task's state by editing its keyword (`TODO` → `DONE`), or check `[x]` on a Waiting On item.
- **Org subset.** Keywords, sequences and per-file `todo:` follow org-mode. Priorities, tags, `SCHEDULED`/`DEADLINE`, `#+TYP_TODO`, and state-change logging are not supported. Lattice doesn't infer tasks from prose, and only one-word `@Name` assignees are recognized.
- **DONE grows.** The DONE group lists every done item in the scanned notes. Archive old notes, or exclude them, to keep it short.
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
| A task is missing                         | Check that the item starts with a declared keyword in the right case (see the note's front matter `todo:` and `:LatticeHealth`), that it's outside code blocks, that the file is saved, and that it isn't excluded. Then refresh. |
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
