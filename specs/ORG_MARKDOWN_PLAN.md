# Org-mode for Markdown — implementation plan and decisions

Companion to [`LATTICE_SYNTAX_SPEC.md`](LATTICE_SYNTAX_SPEC.md) (v0.2). The spec is the contract; this file records how its open points were decided and in what order the work lands. Decisions are dated and attributed to the product owner (PO) where they were asked.

## Delivery

One pull request per spec milestone (§17). The plugin keeps working after every PR.

| PR | Milestone | Contents | User-visible change |
|----|-----------|----------|---------------------|
| 1 | A — Parser foundation | Spec, this plan, Tree-sitter structure (`markdown.lua`), task identification and hierarchy (`tasks.lua`), PAR-001..006 | None yet: the dashboard still uses the v0.1 parser |
| 2 | B — Metadata and workflows | Planning lines, priorities, tags (local and inherited), property drawers, `STATE`, project and workflow resolution, `.lattice.json` `workflows`, legacy v0.1 reading; scanner and dashboard switch to the new parser; v0.1 `parser.lua` removed | All checkboxes become tasks; states, priorities, tags on rows |
| 3 | C — Scheduling engine | Timestamps, SCHEDULED, DEADLINE with warnings, repeaters (`+`, `++`, `.+`) with Org calendar arithmetic | Agenda dates come from SCHEDULED/DEADLINE |
| 4 | D — Mutation engine | Controlled mutation layer: `set_state`, checkbox sync, progress cookies, parent rollup, CLOSED, scheduling edits, recurrence on completion, `:LatticeMigrate` | Editing commands; migration of v0.1 notes |
| 5 | E — Integration | Unified index, agenda and project queries, filtering, incremental refresh, PAR-026..030 end to end | Agenda dashboard |

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

### D5. Every checkbox is a task (PO, 2026-11-03) — spec §3.2

As the spec says. A box without a state gets the default unfinished state (`[ ]`) or default done state (`[x]`/`[X]`), from the first sequence of the applicable workflow.

### D6. Keyword bullets stay tasks — Extended (PO, 2026-11-03)

`- TODO Send update` (no box) remains a task, with kind `checkbox` and `checkbox = nil`. A box may also carry an inline state, `- [ ] WAITING Reply` (Extended), equivalent to `:STATE: WAITING`.

### D7. Checkbox and state conflicts — spec §3.3

The box is basic completion (rule 1): `- [x] TODO x` counts as done, `- [ ] DONE x` as open, and both produce a `state-conflict` diagnostic (rule 6). Lattice never rewrites either value during a scan.

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

## Compatibility classification (§2.2)

| Feature | Category |
|---------|----------|
| TODO keywords on headings | Adapted (`#` for `*`) |
| Checkbox tasks with workflow states | Extended |
| Keyword bullets without a box | Extended |
| Multi-word states | Extended |
| SCHEDULED, DEADLINE, CLOSED, repeaters | Direct |
| Planning and properties on checkboxes | Extended |
| `[#A]` priorities on headings | Direct |
| `:PRIORITY:` and `:TAGS:` on checkboxes | Extended |
| Trailing `:tag:` on headings, inheritance | Direct |
| Property drawers | Direct (heading), Extended (checkbox) |
| Progress cookies | Direct |
| Automatic parent checkbox completion | Extended (Lattice policy) |
| Org Babel, tables, links, export, clocking | Unsupported |
