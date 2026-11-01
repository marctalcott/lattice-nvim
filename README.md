# Lattice

Lattice is a standalone, local-first task dashboard plugin for Neovim / LazyVim.

Lattice is not Portico. Portico remains a separate project-management product. Do not move Lattice work into a Portico repository or reuse Portico infrastructure, dependencies, branding, configuration, credentials, or data.

## Purpose

Surface a manager's commitments and delegated follow-ups across an existing collection of Markdown notes arranged with the PARA method, without replacing the note-taking workflow.

## Source of truth

Existing Markdown files. No separate task database, account, server, cloud sync, or AI dependency. Any AI agent can edit Markdown using the documented conventions, but the plugin itself works entirely offline.

## Install

Developed and tested on Neovim 0.12. Add a plugin spec to your LazyVim config, for example `lua/plugins/lattice.lua`:

```lua
return {
  {
    dir = "~/Documents/Projects/lattice",
    name = "lattice",
    event = "VeryLazy",
    opts = {
      root = "~/path/to/your/PARA/notes", -- required; Lattice never guesses this
    },
  },
}
```

Then copy `examples/.lattice.json` to the root of your notes folder and adjust the exclusions there. Without it, Lattice uses the same defaults and says so on the dashboard.

## Use

| Keymap       | Command           | Action                                        |
|--------------|-------------------|-----------------------------------------------|
| `<leader>ll` | `:Lattice`        | Open or focus the dashboard                   |
| `<leader>lt` |                   | Add a task to `To Do` in the current note     |
| `<leader>ld` |                   | Add a delegated task to `Waiting On` in the current note |
| `<leader>lr` | `:LatticeRefresh` | Reread `.lattice.json` and all notes          |

In the dashboard: `Enter` opens the original note at the task's line, `r` refreshes, and `q` closes.

Notes to expect:

- Lattice reads saved files. A task added with a shortcut appears after you save the note and refresh.
- The dashboard refreshes only on request, so its contents and line numbers reflect the last scan.
- Symlinks are skipped entirely, including links that point inside the notes root.

### Keymaps

LazyVim maps `<leader>l` to `:Lazy`. The defaults above still work, but pressing `<leader>l` alone now waits for `timeoutlen` before opening Lazy. To avoid that, choose other keys or turn any of them off:

```lua
opts = {
  root = "~/notes",
  keymaps = {
    open = "<leader>nl",
    add_todo = "<leader>nt",
    add_waiting = "<leader>nd",
    refresh = false,
  },
  -- or: keymaps = false,
}
```

## Note format

Lattice reads top-level list items under headings named exactly `To Do` or `Waiting On`, at any heading depth. See `examples/meeting-notes.md`.

```markdown
## To Do
- Ordinary bullets are open tasks
- [ ] Checkboxes work too [due:2026-11-05]
- [x] Completed items are hidden

## Waiting On
- [ ] @Raju Deployment estimate [due:2026-11-07]
- No assignee shows as Unassigned
```

On a `Waiting On` item, `[due:...]` means the date you want to follow up. Add `[promised:YYYY-MM-DD]` to record the date the other person committed to. It appears on the dashboard but doesn't affect sorting or the overdue mark, which follow `[due:...]`.

## Capture inbox

Put Markdown captures in `Inbox/` in your notes root, or set another folder inside the root with `inbox.path` in `.lattice.json`. Lattice doesn't care how they arrive, whether from a Drafts action, the share sheet, AirDrop, or a copy by hand.

The dashboard's INBOX group appears when the folder exists. It lists each `.md` file, including those in subfolders, oldest first, using the file's first line as the title and its modified date. `Enter` opens the capture.

Lattice never moves or changes captures. You or your AI agent file each note in its PARA location and add any tasks, and it leaves the group after the next refresh.

`scan.exclude` doesn't affect this list. `To Do` and `Waiting On` sections in inbox notes count as tasks like any others, so add `Inbox/**` to `scan.exclude` if you don't want them on the dashboard until the note is filed.

## Development

```sh
nvim -l tests/run.lua
```

## Contents

- `specs/product-vision.md` — complete management-accountability vision, deferred requirements, and traceability
- `specs/lattice-v0.1.md` — implementation-ready MVP specification
- `AGENTS.md` — guardrails for AI coding agents
- `examples/meeting-notes.md` — recognized task formats
- `examples/.lattice.json` — sample configuration for a notes root (not this plugin repo)
