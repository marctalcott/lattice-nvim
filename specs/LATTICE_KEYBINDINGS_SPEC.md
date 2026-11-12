# Lattice Default Keybinding Redesign — Specification

- Version: 1.0 with Amendment 1
- Status: PO specification agreed and Amendment 1 approved by the PO (2026-11-12); not yet implemented
- Parent project: Lattice (Neovim/LazyVim plugin)
- Components: `lua/lattice/config.lua` (defaults, merging), `lua/lattice/init.lua` (registration, conflict detection), `lua/lattice/health.lua`, `lua/lattice/dashboard.lua` (week view), docs
- Related documents: [`LATTICE_SPEC.md`](LATTICE_SPEC.md), [`LATTICE_SYNTAX_SPEC.md`](LATTICE_SYNTAX_SPEC.md), [`LATTICE_INBOX_SPEC.md`](LATTICE_INBOX_SPEC.md) A1.10

The product owner (PO) wrote the specification below (v1.0, 2026-11-12). Amendment 1 records what the current code already does and how the spec fits Lattice; the developer proposed it and the PO approved it, including the A1.4 decisions, on 2026-11-12. **Where the amendment and the sections below differ, the amendment wins.**

---

## Amendment 1 — Fitting the redesign to the current code (2026-11-12)

### A1.1 What already exists

- **Per-action configuration.** `config.lua` has `DEFAULT_KEYMAPS` (16 named actions). `setup({ keymaps = { name = "<key>" | false } })` overrides or disables single actions, and `keymaps = false` disables all of them. Unknown names and bad values are reported, not fatal. The redesign keeps this model (§6 "prefer the existing mechanism").
- **Exact-collision detection.** `init.lua` `set_keymaps()` checks for an existing global normal-mode mapping (`maparg` from a scratch buffer). If another plugin or the user already owns the key, Lattice skips it, warns once with the key and action name, and lists it in `:LatticeHealth` (`health.keymap_conflicts`). Remapping after `setup()` is called again clears only Lattice's own mappings. This covers §5 requirements 1–6 for exact collisions.
- **Week agenda.** The dashboard already has a week view (`state.view = "week"`, key `2`). `dashboard.open()` takes no arguments today. `<leader>oa` needs a way to open the dashboard in that view, or switch an open dashboard to it. This reuses the existing state and adds no second agenda.
- **`<leader>` is not hardcoded.** Keys are stored as `<leader>…` strings, so Neovim expands them with the user's actual `mapleader`.

### A1.2 Gaps the implementation must close

1. **Prefix interactions** (§5.8). Lattice does not detect these today:
   - Another plugin maps `<leader>o` itself. Every `<leader>o…` key then waits for `timeoutlen`, and the plain `<leader>o` mapping only fires after that delay.
   - A user sets a Lattice key that is a prefix of an existing mapping, or that extends one.

   Proposal: report both cases in `:LatticeHealth` as warnings, but still register the key, because neither overwrites anything. Exact collisions stay skipped.
2. **Load order.** Detection only sees mappings that exist when `setup()` runs. If a plugin maps the same key later, its `vim.keymap.set` silently replaces Lattice's mapping, and Lattice cannot prevent that. Proposal: `:LatticeHealth` re-checks each active keymap and reports any whose current owner is no longer Lattice. The docs should explain that, under lazy.nvim, `keys =` specs from other plugins are present at startup, but mappings set in their `config` functions may arrive later.
3. **Hardcoded hint.** `insert.lua` tells users "use `<leader>lt`". It should name the active `add_todo` key, or the `:LatticeAddTodo` command when no key is mapped.
4. **Which-key.** Lattice does not depend on which-key and should not start to. Each mapping already has a `desc`, and which-key shows that. The `desc` for `add_waiting` ("add Waiting On") should become "add WAITING task". Proposal: document an optional spec, `{ "<leader>o", group = "lattice" }`, rather than registering the group from the plugin. If the Overseer extra is installed, it already names the `<leader>o` group "overseer".

### A1.3 LazyVim and Overseer conflicts (checked against LazyVim v16.0.0, 459a4c3b)

- **Core LazyVim** maps `<leader>l` to `:Lazy`, so Lattice's old `<leader>l…` defaults made it wait for `timeoutlen`. That is the motivation for the change. Core LazyVim defines no mapping or which-key group under `<leader>o` (`lua/lazyvim/config/keymaps.lua`, `lua/lazyvim/plugins/*.lua`, `lua/lazyvim/plugins/lsp/*.lua`).
- **Overseer extra** (`lazyvim.plugins.extras.editor.overseer`) maps `<leader>ow`, `<leader>oo` and `<leader>ot`, and names the `<leader>o` which-key group "overseer". It is the only LazyVim extra under `<leader>o`. Two of its keys collide with the new defaults: **`ot`** (add TODO) and **`ow`** (refile). Lattice skips both, reports them, and the docs suggest `<leader>oT` and `<leader>oF`. (The draft of this amendment also listed `oq`, `oi`, `ob` and `oc`. Those came from an older version of the extra and are not in v16.)
- **Tests (§8 items 14–15)** cannot load LazyVim itself. Proposal: keep a fixture listing the LazyVim core `<leader>` mappings and the Overseer extra mappings (with the LazyVim version they came from), pre-map them in a test, then run `setup()` and assert which Lattice keys were registered, skipped and reported.

### A1.4 Decisions (approved by the PO, 2026-11-12)

1. **Configurable prefix** (§1 "the prefix must remain configurable"). Today each key is configured individually. Decision: add `keymaps_prefix` (default `"<leader>o"`). The defaults become suffixes such as `l`, `a` and `t`, and a full key string in `keymaps.<name>` still wins. `keymaps_prefix = "<leader>l"` would restore the old layout in one line, except that agenda would land on `<leader>la`, which was previously unbound. This adds a setup option, not a persistent file format.
2. **Dashboard reuse** (§3). If a dashboard window is open, `<leader>oa` switches it to the week view, and `<leader>ol` switches it back to the overview. Decision: yes. Each key focuses the existing window and sets the view, so there is still one dashboard state.
3. **Release and migration.** Changing the defaults breaks muscle memory for existing users, so this ships as 0.4.0. The changelog will contain a migration block that restores the old keys, using either `keymaps_prefix = "<leader>l"` or the explicit `keymaps = { … }` table. The new action name is `agenda`.

### A1.5 Delivery

One PR: config and registration changes, the agenda entry point, health reporting, `insert.lua` hint, tests, README / `doc/lattice.txt` / TUTORIAL / CHANGELOG. Historical specs (`lattice-v0.1.md`, `LATTICE_SPEC.md`, `ORG_MARKDOWN_PLAN.md`, `LATTICE_SYNTAX_SPEC.md`, `LATTICE_INBOX_SPEC.md`, `product-vision.md`) keep their `<leader>l` references as written at the time; this spec supersedes them on keybindings.

---

## PO specification v1.0 (2026-11-12)

Lattice: Default Keybinding Redesign

### Objective

Update the default keybindings in the Lattice Neovim plugin to improve compatibility with LazyVim while maintaining familiarity with Emacs Org-mode conventions.

Guiding principle: Org-mode semantics, Markdown syntax, Neovim interface.

Our priorities, in order, are:

1. LazyVim compatibility: Do not interfere with standard LazyVim functionality.
2. Org-mode familiarity: Preserve established Org-mode conventions where practical.
3. Intuitive shortcuts: Make commands easy to learn and remember.
4. Configurability: Allow users to override defaults without modifying plugin source code.

Implement these changes in the Lattice source code, not merely in the developer's personal Neovim configuration.

### 1. Change the default prefix

Change Lattice's default keybinding prefix from `<leader>l` to `<leader>o`.

Reasoning:

- LazyVim already uses `<leader>l` for its Lazy plugin manager.
- `<leader>o` provides a logical namespace for Lattice's Org-inspired functionality.
- We are not attempting to reproduce Emacs key combinations exactly.
- We want Lattice to coexist with standard LazyVim without disrupting existing shortcuts.

Use the actual configured Neovim leader key. Do not hardcode Space.

The prefix must remain configurable.

### 2. New default keybinding mappings

Update the existing default mappings as follows:

| Current | New | Action |
|---|---|---|
| `<leader>ll` | `<leader>ol` | Open Dashboard |
| New | `<leader>oa` | Open Agenda |
| `<leader>lr` | `<leader>or` | Refresh Notes |
| `<leader>lt` | `<leader>ot` | Create TODO |
| `<leader>ld` | `<leader>oW` | Create delegated/WAITING task |
| `<leader>ln` | `<leader>on` | Next Task State |
| `<leader>lp` | `<leader>op` | Previous Task State |
| `<leader>ls` | `<leader>os` | Select Task State |
| `<leader>lx` | `<leader>ox` | Toggle Checkbox |
| `<leader>lS` | `<leader>oS` | Schedule Task |
| `<leader>lD` | `<leader>oD` | Set Deadline |
| `<leader>l+` | `<leader>o+` | Increase Priority |
| `<leader>l-` | `<leader>o-` | Decrease Priority |
| `<leader>lw` | `<leader>ow` | Refile Task |
| `<leader>lA` | `<leader>oA` | Archive Task |
| `<leader>li` | `<leader>oi` | Open Capture Inbox |
| `<leader>lR` | `<leader>oR` | Refresh GitHub Inbox |

These are 17 proposed default mappings: 16 replacements and one new Agenda shortcut.

Uppercase and lowercase mappings are intentionally distinct. For example:

- `<leader>oa` opens Agenda.
- `<leader>oA` archives a task.
- `<leader>ow` refiles a task.
- `<leader>oW` creates a delegated/WAITING task.

### 3. Dashboard versus Agenda

We agreed to preserve both commands because they serve different purposes.

**Dashboard — `<leader>ol`.** Opens Lattice's main management dashboard. The dashboard focuses on responsibilities and overall work status:

- Tasks assigned to the user.
- Delegated tasks and items waiting on others.
- Overdue commitments.
- Upcoming responsibilities.
- Project status and progress.
- Outstanding work requiring attention.

This remains the primary entry point into Lattice.

**Agenda — `<leader>oa`.** Opens Lattice's existing Weekly Agenda view directly. The agenda focuses on time-based planning:

- Tasks scheduled for today.
- Upcoming deadlines.
- Overdue scheduled work.
- Recurring tasks.
- Activities scheduled for the coming week.

Implementation requirement:

Do not create a separate agenda engine or duplicate the existing agenda functionality.

The current Lattice dashboard already supports a Weekly Agenda view.

The new `<leader>oa` command should open that existing view directly, equivalent to opening Lattice and selecting its Weekly Agenda view.

The existing dashboard shortcut should continue opening the normal overview.

If the dashboard is already open, reuse the existing interface and switch to the requested view where practical.

### 4. Preserve Org-mode conventions

Continue following familiar Org-mode conventions wherever doing so does not create conflicts with LazyVim.

**Refile — `<leader>ow`.** Org-mode uses `C-c C-w` for refiling. Although R might initially seem more intuitive, we deliberately chose W to preserve the established Org-mode convention.

**Deadline — `<leader>oD`.** Org-mode uses `C-c C-d` to assign deadlines. Keep uppercase D as the Lattice shortcut. Deadlines must remain independent of task ownership.

**Schedule — `<leader>oS`.** Org-mode uses `C-c C-s` to schedule tasks. Keep uppercase S for scheduling.

**Delegated/WAITING tasks — `<leader>oW`.** Creating a delegated/WAITING task is a Lattice-specific convenience, not a standard dedicated Org-mode command. We chose uppercase W because it naturally represents WAITING. Lowercase W remains Refile.

**Agenda — `<leader>oa`.** The Org-mode agenda is commonly opened through `C-c a a`. We are not copying the complete Emacs command hierarchy because that would create unnecessary conflicts with LazyVim. Instead, lowercase A opens Agenda directly.

**Archive — `<leader>oA`.** Uppercase A archives the selected task. This provides a logical pairing with lowercase A for Agenda.

### 5. Compatibility with LazyVim

Lattice must prioritize compatibility with the standard LazyVim installation.

However, optional LazyVim extras and other installed plugins may occupy portions of the `<leader>o` namespace.

One known potential conflict is the optional Overseer integration, which uses shortcuts including:

- `<leader>oo`
- `<leader>ot`
- `<leader>ow`

Before implementing the new defaults, inspect LazyVim's current keybinding definitions and confirm the proposed mappings do not interfere with its standard configuration.

Also inspect existing Lattice conflict-detection behavior.

Requirements:

1. Detect an existing mapping before registering a Lattice default.
2. Never silently overwrite another plugin's mapping.
3. Report the conflicting key combination and intended Lattice action.
4. Continue registering other nonconflicting Lattice mappings.
5. Allow users to override conflicting mappings through configuration.
6. Report detected conflicts in `:LatticeHealth`.
7. Verify that mappings work with LazyVim's Which-Key integration.
8. Check for exact mapping collisions and problematic prefix interactions.

Do not assume that every user's LazyVim setup is identical.

### 6. Preserve configurability

Users must remain able to customize Lattice's mappings.

Requirements:

- Register the new mappings by default.
- Respect user-defined keybinding overrides.
- Allow users to disable or change individual mappings where the existing configuration model supports it.
- Avoid registering duplicate mappings under the previous `<leader>l` prefix.
- Preserve compatibility with existing user configurations wherever possible.
- Document how users can retain their previous bindings if desired.

Prefer the existing Lattice keybinding configuration mechanism rather than introducing a completely new system.

### 7. Update documentation

Update all documentation referencing Lattice's default keybindings. This includes:

- README.
- Installation instructions.
- Configuration examples.
- Keybinding reference.
- Which-Key descriptions.
- Health-check documentation.
- Dashboard help.
- Agenda help.
- Capture inbox documentation where applicable.
- Changelog and migration notes.

Clearly document the distinction between:

- Dashboard and Agenda.
- Agenda and Archive.
- Refile and WAITING.
- Schedule and Deadline.

Explain that the default prefix changed from `<leader>l` to `<leader>o` specifically to improve LazyVim compatibility.

### 8. Automated tests

Update or add automated tests covering:

1. All 17 default mappings.
2. Removal of the previous default bindings.
3. Correct uppercase/lowercase behavior.
4. Direct opening of the existing Weekly Agenda view.
5. Correct dashboard default view.
6. Refile behavior.
7. Delegated-task creation.
8. Deadline and scheduling commands.
9. Archive behavior.
10. Configurable keybinding overrides.
11. Detection of existing mappings.
12. Non-overwriting behavior during collisions.
13. Accurate `:LatticeHealth` conflict reporting.
14. Compatibility with standard LazyVim.
15. Optional Overseer mapping conflicts.

Ensure the new Agenda command does not create a second agenda implementation or introduce inconsistent view state.

### 9. Acceptance criteria

The change is complete when:

- Lattice uses `<leader>o` for its default global shortcuts.
- Standard LazyVim functionality remains intact.
- `<leader>ol` opens the main Dashboard.
- `<leader>oa` directly opens the existing Weekly Agenda.
- `<leader>oA` archives a task.
- `<leader>ow` refiles a task.
- `<leader>oW` creates a delegated/WAITING task.
- `<leader>oD` assigns a deadline.
- `<leader>oS` schedules a task.
- Every other existing Lattice command uses the new prefix.
- Users can customize keybindings.
- Conflicts are detected and reported without silently overriding existing mappings.
- Documentation and tests are updated.
- No unrelated application behavior changes.

### 10. Implementation boundaries

This should remain a focused keybinding and compatibility update.

Do not change:

- Markdown syntax.
- TODO workflow semantics.
- Task ownership or delegation behavior.
- Deadline and scheduling logic.
- Recurrence processing.
- Project organization.
- Existing agenda calculations.
- Existing dashboard functionality.

The only intended functional addition is a direct keyboard shortcut for opening the existing Weekly Agenda view.

Avoid unnecessary refactoring.

### Deliverables

1. Updated Lattice source code.
2. Updated keybinding configuration and registration logic.
3. Direct Agenda shortcut implementation.
4. Updated documentation.
5. Updated automated tests.
6. Confirmation of LazyVim compatibility.
7. A brief summary of any remaining keybinding conflicts or migration concerns.

Goal: Make Lattice feel natural to LazyVim users while preserving the most useful and recognizable Emacs Org-mode conventions.

This specification reflects our agreed design decisions. Implementation has not yet been performed.
