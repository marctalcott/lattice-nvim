# Org-mode for Markdown — implementation plan and decisions

Companion to [`LATTICE_SYNTAX_SPEC.md`](LATTICE_SYNTAX_SPEC.md) (v0.2). The spec is the contract; this file records how its open points were decided and in what order the work lands. Decisions are dated and attributed to the product owner (PO) where they were asked.

## Delivery

One pull request per spec milestone (§17). The plugin keeps working after every PR.

| PR | Milestone | Contents | User-visible change |
|----|-----------|----------|---------------------|
| 1 | A — Parser foundation | Spec, this plan, Tree-sitter structure (`markdown.lua`), task identification and hierarchy (`tasks.lua`), PAR-001..006 | None yet: the dashboard still uses the v0.1 parser |
| 2 | B — Metadata and workflows | Planning lines, priorities, tags (local and inherited), property drawers, `STATE`, project and workflow resolution, `.lattice.json` `workflows`, legacy v0.1 reading; scanner and dashboard switch to the new parser; v0.1 `parser.lua` removed | States, priorities, tags on rows (checkbox tasks were later withdrawn, D14) |
| 3 | C — Scheduling engine | Timestamps, SCHEDULED, DEADLINE with warnings, repeaters (`+`, `++`, `.+`) with Org calendar arithmetic | Agenda dates come from SCHEDULED/DEADLINE |
| 4 | D — Mutation engine | Controlled mutation layer: `set_state`, checkbox sync, progress cookies, parent rollup, CLOSED, scheduling edits, recurrence on completion, `:LatticeMigrate` | Editing commands; migration of v0.1 notes |
| 5 | E — Integration | Unified index, agenda and project queries, filtering, incremental refresh, dashboard editing, refile and archive, PAR-029..030 end to end | Week agenda, TODO and project views |

## Decisions

### D1. Parser: Tree-sitter (PO, 2026-11-03) — spec §13.1, §18.8

Block structure comes from Neovim's Tree-sitter Markdown parser (`markdown.lua`). It is bundled with Neovim 0.10+, so no install is needed. Org metadata is parsed line by line inside the regions it reports. There is no line-based fallback for structure: if no parser loads, the scan reports an error and `:LatticeHealth` explains it.

Known risk, accepted: a broken parser binary (for example a `markdown.so` replaced in place on macOS) is killed by the OS and takes Neovim with it; Lattice cannot catch that. Measured cost: about 1.3 ms per 680-line note.

### D2. Projects are optional (PO question, 2026-11-03) — spec §4.2, §18.4

Not every note or task belongs to a project. A task's project is, in order:

1. an explicit `:PROJECT:` property, inherited from ancestors, or `project:` in the note's front matter;
2. the enclosing top-level `#` heading, **only** when its text names a configured project (a key of `workflows` other than `default`, compared case-insensitively). This satisfies the §15 fixtures (`# Etna` → Etna) without turning `# Meeting notes` into a project;
3. otherwise none.

Workflow resolution (§4.2): `:WORKFLOW:` property (inherited) → the project's workflow → front matter `todo:` (v0.1, per note) → `default`. A heading whose first word is a state of some other workflow is reported as `unknown-state` (PAR-014 for headings).

Confirmed by the PO on 2026-11-03; implemented in milestone B.

### D3. v0.1 syntax: read both, migrate on request (PO, 2026-11-03)

The parser keeps reading v0.1 forms, and `:LatticeHealth` lists them as legacy:

| v0.1 form | Org form it means |
|-----------|-------------------|
| bullet under `## Waiting On` | `:STATE: WAITING` |
| `@Name` at the start of a waiting item | `:ASSIGNED: Name` |
| `[due:YYYY-MM-DD]` | `DEADLINE: <YYYY-MM-DD Day>` |
| `[promised:YYYY-MM-DD]` | `:PROMISED:` property |
| front matter `todo:` | a per-note workflow |

`:LatticeMigrate` (milestone D) rewrites the current buffer to the Org forms, only when run, as one undo step, never saving. Waiting items work as in Org: `WAITING` is a state like any other.

### D4. Configuration in `.lattice.json` (PO, 2026-11-03)

Workflows (§4.1, §4.2), priorities (§5), tag and property inheritance (§6.3, §7) and deadline warning days (§9.2) live in `.lattice.json` in the notes root, using the spec's table shapes in JSON, so every computer reads the same settings. `setup()` keeps `root` and keymaps. The v0.1 `todo` key keeps working as the `default` workflow.

### D5. Every checkbox is a task (PO, 2026-11-03) — superseded by D14

Implemented in milestone B, then reversed the same day when the PO chose strict Org (D14).

### D6. Keyword bullets — now legacy (D14)

`- TODO Send update` and `- [ ] NEXT x` are read as Lattice v0.1 items (kind `item`), with v0.1 rules: a checked box or a done state means done. Org has no list-item tasks, so Lattice never writes them.

### D7. Checkbox and state conflicts — withdrawn (D14)

With no checkbox tasks there is nothing to conflict. Legacy items use v0.1 rules without diagnostics.

### D8. Multi-word states — spec §4.2

States may contain spaces (`IN PROGRESS`), matched exactly and longest first. Org itself does not allow this; it is an Extended feature needed by the spec's own example.

### D9. Smaller defaults (not asked; change on request)

- Reopening a task removes its `CLOSED:` line, as Org does (§4.4).
- Tasks without `:ID:` are identified by path plus heading/item text path, re-resolved before each edit (§18.5, §14.2 source validation).
- Setext headings are not tasks; the spec's grammar is ATX only (§3.1).
- List items inside block quotes are tasks like any other.

### D10. The default workflow is the spec's (§4.1)

`TODO NEXT WAITING | DONE CANCELED`, replacing v0.1's `TODO | DONE`. A note's v0.1 `Waiting On` items get `WAITING` when their workflow has it.

### D11. Dashboard during milestones B–D

The v0.1 dashboard groups stay until the agenda (milestone E). WAITING ON shows tasks in the `WAITING` state plus v0.1 `Waiting On` items; the date column is the `DEADLINE` (or v0.1 `[due:]`). Rows show state, priority, assignee and local tags.

### D12. Calendar arithmetic and repeaters follow Org's implementation — spec §10, §18.6

Org shifts timestamps with Emacs `encode-time`, and `lattice.schedule` matches it:

- Month and year steps keep the day number and overflow: Jan 31 `+1m` → Mar 3 (Mar 2 in a leap year), Feb 29 `+1y` → Mar 1. Clamping to the month end would be friendlier, but it is not what Org does.
- `+` adds one interval to the current occurrence, even when the result is still in the past (catch-up). `++` adds whole intervals, always at least one, until the occurrence is after the completion moment; a date without a time stands for its midnight. `++` steps are taken from the original date, so month-end days don't drift. `.+` adds one interval to the completion date, keeping the time of day; for `h` it adds to the completion time.
- Warning and delay periods convert to days as Org's `org-get-wdays` does (`w` = 7, `m` = 30.4, `y` = 365.25, rounded down).
- When both SCHEDULED and DEADLINE repeat, each advances by its own repeater from the same completion moment; a timestamp without a repeater is unchanged (§18.6).
- Weekday names are rewritten in English after a shift.
- Repeated completion commands must not double-advance (§10.3): the mutation layer (milestone D) re-checks the source text before applying a change.

### D13. Dashboard dates during milestones C–D

OVERDUE uses deadlines before today. TODAY follows Org's daily agenda: scheduled today, or scheduled earlier and still open, after any `-Nd` delay, plus deadlines today. DUE SOON uses each deadline's warning period, else `deadlines.warning_days` (14, Org's default; the v0.1 window was a fixed 7 days). A v0.1 `[due:]` date counts as a deadline.

### D14. Strict Org: only headings are tasks (PO, 2026-11-03) — spec Amendment 1

Asked whether Org counts `- [ ]` as a TODO (it does not), the PO chose to follow Org. Only headings are tasks. Checkboxes are steps that feed progress cookies (top-level boxes in the entry, else child TODO headings) and are not on the dashboard. Org metadata (planning, drawers, tags, priority) is read only for headings, and `:PRIORITY:` / `:STATE:` drawer entries set nothing. Org's `[-]` is recognized. v0.1 list forms stay readable until migrated, and Lattice writes only headings: `<leader>lt` inserts `## TODO x` at the enclosing heading's level after its subtree (Org's `C-S-RET`), `<leader>ld` inserts `## WAITING x` with `:ASSIGNED:`, and cycling never gives a plain list item a state.

### D15. Blank lines between a heading and its metadata — Adapted (2026-11-03)

Found while testing in LazyVim: saving a note runs a Markdown formatter that inserts a blank line after every heading (markdownlint MD022, Prettier), which would cut a drawer or planning line off from its heading under Org's rule that they follow the headline directly. Lattice therefore skips blank lines between a heading, its planning lines and its drawer, but only when the next non-blank line is metadata; prose still ends the metadata. Lattice itself writes metadata directly under the heading.

### D16. Mutation layer and editing behaviour (milestone D, 2026-11-03)

- **One path for edits.** Operations in `lattice.mutate` are pure (lines in, lines out). `apply()` refuses unless the buffer still equals the lines the edit was computed from (§14.2 source validation), then writes only the hunks `vim.diff` finds, bottom-up, as one undo step. This is also how a repeated completion is kept from double-advancing a repeater (§10.3). Edits go to the buffer; Lattice never writes files.
- **Org defaults for logging:** `logging.done` false (`org-log-done` nil), `logging.repeat` "time" (`org-log-repeat`): `:LAST_REPEAT:` plus a state note in Org's format, placed after the planning lines and drawer, newest first. Notes go in the entry, not a `:LOGBOOK:` drawer (`org-log-into-drawer` nil). Only "time" is supported, not "note".
- **Repeats:** a completed repeating heading (with or without a state) returns to its previous state when that was active, else the workflow's first active state, unless `repeat_to_state` says otherwise; no `CLOSED` is added.
- **Checkboxes:** Lattice writes lowercase `[x]` (Markdown's usual form; Org writes `[X]`, and both read the same). Toggling a parent sets its descendants to match, then parents are derived from children (`[x]`, `[-]`, `[ ]`). Cookies are recalculated only on ancestors of the change, so stale cookies elsewhere are left as written. Percentages round down.
- **Planning edits:** entries share the first planning line, in Org's order (CLOSED, DEADLINE, SCHEDULED); rescheduling keeps an existing repeater and warning.
- **Priority:** `org-priority-start-cycle-with-default` behaviour: none → default; past either end → removed.
- **Migration (D3):** each v0.1 item becomes a heading one level below its enclosing heading (nested items deeper), its sub-items dedented beneath it, with blank lines around it. On headings, `[due:]` becomes `DEADLINE` and a `WAITING` heading's `@Name` / `[promised:]` become `:ASSIGNED:` / `:PROMISED:`. Nothing is lost or reordered, so some forms are left as written and reported: a bullet nested in a plain list item (a heading would split the list), an item that would need headings past `######`, an item or heading whose title is only `@Name` or dates, one with more than one valid `[due:]` or `[promised:]`, and a `[due:]` or `[promised:]` that differs from the heading's `DEADLINE` (active or not) or `:PROMISED:`.
- **Inactive planning timestamps:** like Org, an inactive `[...]` timestamp on `SCHEDULED` or `DEADLINE` schedules nothing; Lattice also lists it under WARNINGS.
- **Deferred to milestone E:** `refile_task` and `archive_task` (§14.2), which move text between notes, and editing from the dashboard.

### D17. Integration (milestone E, 2026-11-03)

- **Index and refresh.** The scanner keeps each note's parse, stamped with its file's mtime and size (or its buffer's changedtick), and re-parses only notes whose stamp changed; a config change drops the cache. Loaded buffers with unsaved changes are read instead of their files (§14.1). Saving a note under the root refreshes an open dashboard (BufWritePost). No file watching outside Neovim and no background work.
- **Agenda.** Week view (Org's `C-c a a`): each day lists scheduled items, deadlines and repeat occurrences; today adds open items scheduled earlier (`Sched. Nx`), overdue deadlines (`N d. ago`) and deadlines inside their warning (`In N d.`). Done tasks are left out (§9.3 completed-task suppression). Sort: timed first, then priority (missing = default), then deadlines before scheduled, oldest first. TODO list (`C-c a t`): priority, then deadline. Projects: counts, `:PROJECT_STATUS:`, next action (first `NEXT`, else most urgent).
- **Filters.** On `F`, so `/` keeps its Vim meaning (search; Org's agenda uses `/` for its tag filter). One small language for every view (`+tag -tag #A project:X @person state:S words`) instead of Org's separate filter commands.
- **Dashboard edits** follow Org's agenda keys where they don't clash with the dashboard (`t`, `+`/`-`, `S`/`D`, `s` to save). They edit the note's buffer (loaded hidden and listed), never the file; `s` saves only buffers the dashboard edited. A row's task is on its recorded line while that line is unchanged; otherwise it is found again by its whole title, nearest the old line. If the title changed, or the number of tasks of that kind carrying it differs from when the dashboard was drawn, the edit is refused rather than guessed. Rescheduling refuses to overwrite a SCHEDULED or DEADLINE it can't read, or a heading with two of them, so nothing the user wrote is lost; an inactive one is rescheduled as active, keeping its repeater and warning.
- **Refile** (`C-c C-w`): targets are every heading in every note plus "end of note"; the subtree goes to the end of the target's subtree, one level deeper, re-levelled. No refile logging (`org-log-refile` nil).
- **Archive**: Org's default location adapted to Markdown, `%s_archive.md` beside the note, the subtree promoted to level 1 with Org's five ARCHIVE_* properties; `:ARCHIVE_OLPATH:` and refile targets use heading titles without state, priority or tags, as Org's do. Archive notes are excluded from scanning by default. Lattice never creates folders, so a location in a missing folder is an error, and a location that resolves to the note itself is refused. A note outside the notes root archives beside itself.
- **Two-note edits** (refile across notes, archive) check both buffers before changing either, then apply both.
- **Constraint change.** AGENTS.md previously limited edits to the current note. Refile, archive and dashboard edits change other notes' buffers, as Org's do; files are still written only when the user saves.

## Compatibility classification (§2.2)

| Feature | Category |
|---------|----------|
| TODO keywords on headings | Adapted (`#` for `*`) |
| Checkbox tasks with workflow states | Unsupported (as in Org; D14) |
| Keyword bullets without a box | Legacy v0.1, read only |
| Multi-word states | Extended |
| SCHEDULED, DEADLINE, CLOSED, repeaters | Direct |
| Planning and properties on checkboxes | Unsupported (as in Org) |
| `[#A]` priorities on headings | Direct |
| `:PRIORITY:` and `:TAGS:` on checkboxes | Unsupported (as in Org) |
| Trailing `:tag:` on headings, inheritance | Direct |
| Property drawers | Direct (headings only); blank lines before them allowed (Adapted, D15) |
| Progress cookies | Direct |
| Parent checkbox follows children (`[-]`, `[x]`) | Direct |
| Checkbox progress counted for headings | Direct |
| Org Babel, tables, links, export, clocking | Unsupported |
