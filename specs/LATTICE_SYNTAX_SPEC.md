# Lattice — Markdown Syntax and Org-mode Compatibility Specification

- Version: 0.2
- Status: Implementation specification (decisions on open points: [`ORG_MARKDOWN_PLAN.md`](ORG_MARKDOWN_PLAN.md))
- Target: Neovim / LazyVim
- Implementation language: Lua
- Dependencies: Neovim APIs; optional Tree-sitter Markdown parser
- Related document: Lattice Technical Specification v0.1

---

## Amendment 1 — Strict Org checkbox semantics (2026-11-03, product owner)

Following §2.1 priority 1 ("follow documented Emacs Org-mode behavior"), the product owner chose Org's model for checkboxes over the Extended model in §3.2–§3.4. Where this amendment and the sections below differ, the amendment wins.

1. **Only headings are tasks** (§3.1, Adapted). A Markdown checkbox is not a task: it has no workflow state, does not appear on the dashboard or agenda, and carries no planning lines, priority, tags or properties. §3.2–§3.4, the checkbox parts of §3.5, §5, §6.2 and §12 (`kind = "checkbox"`), the §15.2 fixture (now a heading), and acceptance test PAR-015 do not apply.
2. **Checkboxes are steps** (§11.4, Direct). `[ ]`, `[x]`/`[X]` and Org's partly-done `[-]` feed a heading's progress cookie (`[1/3]`, `[33%]`): the top-level checkboxes of the lists directly in its entry (Org's `org-checkbox-hierarchical-statistics`), else its direct child TODO headings (`org-hierarchical-todo-statistics`). A cookie on a list item counts that item's direct child checkboxes.
3. **Parent checkboxes** (§11.5) follow Org: checking every child checks the parent box, a partly checked set gives `[-]`. Heading states never change because of their checkboxes; an optional Org-style rule (`org-enforce-todo-checkbox-dependencies`) may block completing a heading while its boxes are unchecked.
4. **Org's `:PRIORITY:` and `:STATE:`** are not set from drawers: priority is the heading's `[#A]` cookie, and the state is the heading's keyword.
5. **Lattice v0.1 forms** — keyword bullets (`- TODO x`) and bullets under a `Waiting On` heading — are read as legacy items until a note is migrated, so existing notes keep working. They follow v0.1 rules and take no Org metadata. Lattice never writes them: `<leader>lt` and `<leader>ld` insert headings (`## TODO x`, `## WAITING x` with `:ASSIGNED:`).
6. Compatibility table (§2.2): "Scheduling on Markdown checkboxes" is **Unsupported**, as in Org.

---

## 1. Purpose

This specification defines how Lattice recognizes, interprets, and modifies tasks stored in Markdown files.

The primary design principle is:

> Org-mode semantics, Markdown syntax, Neovim interface.

Lattice must preserve Org-mode's established task-management behavior wherever practical, while supporting ordinary Markdown headings and checkboxes as equally capable task objects.

This document defines:

- Markdown task grammar
- Heading and checkbox task identification
- Task states and configurable workflows
- Scheduling and deadline metadata
- Recurring task semantics
- Priorities and tags
- Properties and task metadata
- Task hierarchy and checkbox rollups
- Parser architecture
- File modification rules
- Compatibility requirements
- Automated acceptance tests

Lattice is not intended to parse every feature of `.org` files. It implements a defined subset of Org-mode semantics over Markdown.

## 2. Compatibility Rules

### 2.1 Compatibility priorities

When deciding how a feature should behave, use the following order:

1. Follow documented Emacs Org-mode behavior.
2. Preserve valid Markdown structure.
3. Extend Org-mode conventions where necessary for first-class Markdown checkbox tasks.
4. Keep the syntax human-readable without Lattice.
5. Avoid introducing alternative conventions when an Org-mode equivalent already exists.

### 2.2 Compatibility categories

Every supported feature must be classified as one of:

| Category    | Meaning                                          |
|-------------|--------------------------------------------------|
| Direct      | Same syntax and semantics as Org-mode            |
| Adapted     | Same semantics with Markdown structural changes  |
| Extended    | New behavior necessary for Lattice               |
| Unsupported | Not implemented in the current release           |

For example:

- `SCHEDULED:` timestamps: Direct
- `#` headings instead of `*`: Adapted
- Scheduling on Markdown checkboxes: Extended
- Org Babel: Unsupported

The implementation must not claim complete Org-mode compatibility.

## 3. Task Grammar

### 3.1 Heading tasks

A heading task begins with an ATX Markdown heading containing a configured TODO keyword.

```markdown
# Etna
## TODO Review system architecture
### NEXT Prepare technical proposal
### DONE Document requirements
```

Grammar:

```
heading-task :=
    heading-marker
    whitespace
    todo-keyword
    whitespace
    [priority]
    title
    [tags]
```

Where:

- `heading-marker` is one to six `#` characters.
- `todo-keyword` must match a configured workflow state.
- `priority` uses Org-mode priority syntax.
- `title` is arbitrary Markdown-compatible text.
- `tags` use Org-style trailing tag syntax.

Example:

```markdown
## TODO [#A] Review architecture :etna:design:
```

A heading without a TODO keyword is an organizational heading, not automatically a task.

### 3.2 Checkbox tasks

Checkbox tasks use standard Markdown task-list syntax.

```markdown
- [ ] Review configuration
- [x] Complete documentation
```

Accepted list markers:

```markdown
- [ ] Task
* [ ] Task
+ [ ] Task
1. [ ] Task
```

Checkbox matching must be case-sensitive for the task marker:

- `[ ]` — unfinished
- `[x]` — completed
- `[X]` — completed

Checkbox tasks must support the same metadata and agenda capabilities as heading tasks.

### 3.3 Checkbox workflow states

Org-mode does not normally treat individual list checkboxes as full TODO headings. Lattice extends the task model to support this.

Example:

```markdown
- [ ] Review security findings
  :PROPERTIES:
  :STATE: WAITING
  :END:
```

Rules:

1. The checkbox marker represents basic completion.
2. The `STATE` property represents the configured workflow state.
3. An unfinished workflow state requires `[ ]`.
4. A completed workflow state requires `[x]`.
5. When a task changes state through Lattice, both representations must remain synchronized.
6. Conflicting values must produce a diagnostic.
7. Lattice must not silently discard an explicit custom state.

If no explicit state exists, `[ ]` maps to the configured default unfinished state and `[x]` maps to the default completed state.

### 3.4 Checkbox metadata

Metadata for checkbox tasks belongs inside the Markdown list item.

```markdown
- [ ] Review system configuration
  SCHEDULED: <2026-11-05 Thu>
  DEADLINE: <2026-11-09 Mon>
  :PROPERTIES:
  :PRIORITY: A
  :ASSIGNED: Tavren Solis
  :END:
```

The parser must use Markdown list boundaries and indentation to determine ownership.

Metadata must not accidentally attach to a neighboring checkbox.

### 3.5 Metadata placement

For heading tasks, planning metadata is associated with the heading's planning area.

For checkbox tasks, planning metadata is associated with the checkbox's list-item body.

The parser must recognize:

- Planning lines
- Property drawers
- Child tasks
- Ordinary prose
- Nested lists

Metadata inside fenced code blocks must be ignored.

## 4. TODO Workflow Engine

### 4.1 Default workflow

The default workflow is configurable.

Example:

```lua
workflows = {
  default = {
    active = {
      "TODO",
      "NEXT",
      "WAITING",
    },
    done = {
      "DONE",
      "CANCELED",
    },
  },
}
```

States before the completion boundary are unfinished. States after it are terminal.

### 4.2 Project-specific workflows

Different projects may use different workflows.

```lua
workflows = {
  default = {
    active = { "TODO", "NEXT", "WAITING" },
    done = { "DONE", "CANCELED" },
  },
  etna = {
    active = {
      "BACKLOG",
      "READY",
      "IN PROGRESS",
      "BLOCKED",
    },
    done = {
      "COMPLETE",
      "CANCELED",
    },
  },
  krakatoa = {
    active = {
      "TODO",
      "REVIEW",
      "APPROVED",
    },
    done = {
      "DONE",
    },
  },
}
```

Workflow resolution order:

1. Explicit task workflow, if supported and configured.
2. Project workflow.
3. Global default workflow.

An unknown state must not automatically be interpreted as completed.

### 4.3 State transitions

Lattice must support:

- Forward state cycling
- Backward state cycling
- Direct state selection
- Completion
- Reopening
- Canceled states
- State-change logging when configured

Transitions must preserve task metadata and surrounding Markdown.

### 4.4 Completion timestamps

When configured, completing a task inserts an Org-compatible closed timestamp.

```
CLOSED: [2026-11-09 Mon 14:30]
```

Reopening must follow a documented policy for retaining or removing the closed timestamp.

## 5. Priorities

Org-mode priority syntax is required.

```markdown
## TODO [#A] Resolve critical issue
## TODO [#B] Review documentation
## TODO [#C] Organize notes
```

For checkbox tasks, Lattice supports an explicit property:

```markdown
- [ ] Review configuration
  :PROPERTIES:
  :PRIORITY: A
  :END:
```

Requirements:

- Configurable priority values
- Configurable default priority
- Priority filtering
- Priority sorting
- Keyboard shortcuts to increase or decrease priority
- Agenda priority display

A missing priority must not be interpreted as the highest priority.

## 6. Tags

### 6.1 Heading tags

Use Org-mode's trailing colon-delimited tags.

```markdown
## TODO Review deployment :etna:infrastructure:
```

### 6.2 Checkbox tags

Checkbox tasks use the same tag convention through a property.

```markdown
- [ ] Review deployment
  :PROPERTIES:
  :TAGS: etna infrastructure
  :END:
```

This is a Lattice adaptation of Org-mode's tag conventions.

### 6.3 Tag inheritance

Lattice must support configurable inheritance from parent headings.

Example:

```markdown
# Etna :engineering:
## TODO Review architecture :design:
```

The task's effective tags are:

```
engineering
design
```

Inherited tags must be distinguished from locally defined tags so edits do not duplicate inherited values.

Tag inheritance must be configurable.

## 7. Properties

Lattice supports Org-style property drawers.

```markdown
## TODO Review architecture
:PROPERTIES:
:ID: etna-review-001
:ASSIGNED: Elira Voss
:EFFORT: 2:00
:END:
```

The parser must:

- Preserve unknown properties.
- Recognize property names without requiring a fixed schema.
- Support inherited properties where configured.
- Preserve property values during unrelated edits.
- Detect malformed drawers.
- Avoid modifying unknown metadata.

Lattice-specific properties may include:

```
STATE
ASSIGNED
FOLLOWUP
PROJECT
PROJECT_STATUS
WORKFLOW
```

Property names are case-insensitive for lookup but should retain their original spelling when unrelated lines are preserved.

## 8. Scheduled Dates

### 8.1 Syntax

Use Org-mode active timestamp syntax.

```
SCHEDULED: <2026-11-05 Thu>
```

Supported forms include:

```
<YYYY-MM-DD Day>
<YYYY-MM-DD Day HH:MM>
```

The weekday text is display metadata. The numeric date is authoritative.

A mismatched weekday should generate a diagnostic or be corrected through an explicit editing operation.

### 8.2 Agenda behavior

Scheduled unfinished tasks appear on their scheduled date.

If the scheduled date passes without completion, the task remains eligible for agenda display according to Org-mode's overdue scheduling rules.

Completed nonrecurring tasks do not appear as unfinished scheduled work.

## 9. Deadlines

### 9.1 Syntax

```
DEADLINE: <2026-11-09 Mon>
```

### 9.2 Deadline warnings

Lattice must support Org-mode-style advance warnings.

Example:

```
DEADLINE: <2026-11-09 Mon -3d>
```

This represents a three-day warning interval.

The global warning period must be configurable.

### 9.3 Agenda behavior

Deadlines must support:

- Upcoming warning periods
- Due-today display
- Overdue display
- Completed-task suppression
- Sorting by deadline
- Project and priority filtering

The scheduling engine must distinguish a scheduled date from a deadline.

## 10. Recurring Tasks

### 10.1 Org-mode repeaters

Lattice must support the three Org-mode repeater forms.

| Repeater | Semantics                                                      |
|----------|----------------------------------------------------------------|
| `+`      | Advance from the prior occurrence by one interval              |
| `++`     | Advance by enough whole intervals to reach a future occurrence |
| `.+`     | Advance relative to the completion date                        |

Examples:

```
SCHEDULED: <2026-11-09 Mon +1w>
SCHEDULED: <2026-11-12 Thu ++1m>
SCHEDULED: <2026-11-15 Sun .+1w>
```

The exact Org-mode distinction between catch-up and future-only recurrence must be preserved.

### 10.2 Supported units

- `h` — hours
- `d` — days
- `w` — weeks
- `m` — months
- `y` — years

Calendar month and year arithmetic must follow Org-mode's documented behavior, not approximate fixed-day conversions.

### 10.3 Recurrence processing

When a repeating task is marked complete:

1. Identify its repeater.
2. Determine the completion date.
3. Calculate the next occurrence using the repeater semantics.
4. Update the relevant planning timestamp.
5. Keep the repeating task active.
6. Record completion history when configured.
7. Refresh agenda indexes.

Repeated completion commands must not create duplicate advancement.

### 10.4 Multiple recurring weekdays

A requirement such as every Monday and Tuesday must be supported.

The implementation must not redefine the meaning of `+1w` to mean multiple weekdays.

Until a precise representation is finalized, the compatible default is to use separate recurring tasks or occurrences.

A future Lattice-specific multi-weekday property may be introduced as an explicitly documented extension.

### 10.5 Recurrence edge cases

Tests must cover:

- Completing early
- Completing late
- Missing several occurrences
- Month-end dates
- February in leap years
- Year rollover
- Scheduled and deadline repeaters together
- Reopening a recurring task
- Multiple completion commands
- Timestamp time-of-day preservation

## 11. Task Hierarchy

### 11.1 Heading hierarchy

Heading nesting follows Markdown heading levels.

```markdown
# Fuji
## TODO Prepare release
### TODO Complete tests
### TODO Review documentation
```

A heading's subtree continues until the next heading of equal or higher level.

### 11.2 Checkbox hierarchy

Checkbox nesting follows Markdown list indentation.

```markdown
- [ ] Prepare release
  - [x] Complete tests
  - [ ] Review documentation
```

The parser must use actual list structure, not a fixed assumption that every child is indented by two spaces.

### 11.3 Mixed hierarchies

```markdown
# Vesuvius
## TODO Prepare release
- [ ] Complete testing
  - [x] Unit tests
  - [ ] Integration tests
- [ ] Prepare documentation
```

Both heading and checkbox tasks must appear in the unified task tree.

### 11.4 Checkbox progress

Org-mode-style checkbox progress must be supported.

```markdown
- [ ] Prepare release [1/3]
  - [x] Complete tests
  - [ ] Review documentation
  - [ ] Publish notes
```

Progress cookies may use:

```
[1/3]
[33%]
```

Lattice must recalculate these values after child checkbox changes.

### 11.5 Parent completion

Checkbox parent completion behavior must be configurable to support automatic rollup.

Default Lattice behavior:

- All child checkboxes complete: parent checkbox becomes completed.
- Any child checkbox incomplete: parent checkbox remains incomplete.
- Progress cookies update automatically.

This automatic parent-marker behavior is a Lattice policy; Org-mode's progress-cookie updates and checkbox-state propagation must be distinguished during compatibility testing.

Heading TODO states do not automatically become DONE solely because their children are complete.

Optional Org-style dependency rules may prevent a heading from being completed while children remain unfinished.

## 12. Unified Task Model

Both task types must use the same task representation.

```lua
Task = {
  id = nil,
  kind = "heading",
  title = "",
  state = "TODO",
  priority = nil,
  scheduled = nil,
  deadline = nil,
  closed = nil,
  recurrence = nil,
  tags = {},
  properties = {},
  parent_id = nil,
  children = {},
  project_id = nil,
  workflow_id = nil,
  source = {
    path = "",
    start_line = 0,
    end_line = 0,
  },
}
```

`kind` is either `heading` or `checkbox`.

Additional fields may include:

- Effective inherited tags
- Effective inherited properties
- Local versus inherited workflow
- Task diagnostics
- Completion progress
- Derived overdue status
- Source content version

The parser must distinguish stored metadata from derived values.

## 13. Parser Architecture

### 13.1 Parsing strategy

Prefer a structural Markdown parser, such as Neovim's Tree-sitter Markdown integration, for identifying:

- Headings
- Lists
- Task markers
- Code fences
- Paragraph boundaries
- Nested structures

Org-mode metadata should be parsed within the structural regions identified by the Markdown parser.

A line-oriented parser may be used for individual metadata fields but must not be the sole mechanism for determining Markdown task boundaries.

### 13.2 Parsing pipeline

```
Markdown Files
      |
      v
File Discovery
      |
      v
Markdown Structure Parser
      |
      v
Task Identification
      |
      v
Metadata Extraction
      |
      v
Hierarchy Resolution
      |
      v
Workflow and Inheritance Resolution
      |
      v
Normalized Task Index
      |
      v
Agenda / Dashboard / Queries
```

### 13.3 Parser requirements

The parser must:

1. Ignore code fences.
2. Ignore ordinary prose resembling task metadata.
3. Preserve source locations.
4. Support nested Markdown lists.
5. Support mixed heading and checkbox tasks.
6. Preserve unknown properties.
7. Detect invalid metadata.
8. Avoid modifying files during scans.
9. Support incremental reparsing.
10. Produce deterministic task structures.

### 13.4 Diagnostics

Diagnostics must identify:

- File
- Line
- Severity
- Error category
- Human-readable explanation

Examples:

- Unknown workflow state
- Invalid timestamp
- Conflicting checkbox and TODO state
- Malformed property drawer
- Duplicate task ID
- Invalid recurrence expression
- Ambiguous task metadata ownership

Diagnostics must not automatically rewrite files.

## 14. Source Editing

### 14.1 Editing principles

All task modifications must be performed through a controlled mutation layer.

The mutation layer must:

- Modify the smallest practical source region.
- Preserve unrelated text.
- Preserve unknown metadata.
- Respect unsaved Neovim buffers.
- Support undo for buffer edits.
- Detect external file changes.
- Avoid silent data loss.

### 14.2 Required operations

```
set_state(task, state)
set_priority(task, priority)
set_scheduled(task, timestamp)
set_deadline(task, timestamp)
set_property(task, key, value)
toggle_checkbox(task)
complete_task(task)
refile_task(task, destination)
archive_task(task)
```

Operations must validate source identity and expected source content before applying changes.

### 14.3 Recurring task mutations

Completing a recurring task must be transactional at the task level.

The completion record and next-occurrence update must not leave the task in an inconsistent state.

## 15. Test Fixtures

All test fixtures must use fictional information.

Project names must be volcano names.

People must have invented names unrelated to actual coworkers.

### 15.1 Heading fixture

```markdown
# Etna
## TODO [#A] Review architecture :engineering:
SCHEDULED: <2026-11-05 Thu>
DEADLINE: <2026-11-09 Mon>
:PROPERTIES:
:ASSIGNED: Tavren Solis
:END:
```

Expected:

- Project: Etna
- Task type: heading
- State: TODO
- Priority: A
- Scheduled: November 5, 2026
- Deadline: November 9, 2026
- Assigned: Tavren Solis

### 15.2 Checkbox fixture

```markdown
# Krakatoa
- [ ] Review release checklist
  SCHEDULED: <2026-11-06 Fri>
  :PROPERTIES:
  :STATE: NEXT
  :ASSIGNED: Elira Voss
  :END:
```

Expected:

- Project: Krakatoa
- Task type: checkbox
- State: NEXT
- Scheduled: November 6, 2026
- Assigned: Elira Voss

### 15.3 Recurrence fixture

```markdown
# Fuji
## TODO Review monthly report
SCHEDULED: <2026-11-12 Thu ++1m>
```

Expected:

- Task is recurring.
- Recurrence interval is one calendar month.
- Repeater type is `++`.
- Next occurrence follows Org-mode future-occurrence semantics.

### 15.4 Hierarchy fixture

```markdown
# Vesuvius
## TODO Prepare release
- [ ] Complete validation [1/2]
  - [x] Review unit tests
  - [ ] Review integration tests
```

Expected:

- Heading task contains a checkbox task.
- Checkbox task contains two children.
- Parent progress is 1/2.
- Parent remains incomplete.

## 16. Automated Acceptance Tests

The following tests are required before declaring the parser and task engine complete.

| ID      | Test                       | Expected result               |
|---------|----------------------------|-------------------------------|
| PAR-001 | Parse heading TODO         | Correct task                  |
| PAR-002 | Parse checkbox TODO        | Correct task                  |
| PAR-003 | Parse nested headings      | Correct hierarchy             |
| PAR-004 | Parse nested checkboxes    | Correct hierarchy             |
| PAR-005 | Parse mixed hierarchy      | Correct parent relationships  |
| PAR-006 | Ignore fenced code         | No false tasks                |
| PAR-007 | Parse scheduled date       | Correct timestamp             |
| PAR-008 | Parse deadline             | Correct timestamp             |
| PAR-009 | Parse priority             | Correct priority              |
| PAR-010 | Parse tags                 | Correct local tags            |
| PAR-011 | Inherit tags               | Correct effective tags        |
| PAR-012 | Parse property drawer      | Correct properties            |
| PAR-013 | Unknown property           | Preserved                     |
| PAR-014 | Unknown workflow state     | Diagnostic                    |
| PAR-015 | Checkbox-state conflict    | Diagnostic                    |
| PAR-016 | Weekly repeater            | Correct next occurrence       |
| PAR-017 | Monthly repeater           | Correct calendar arithmetic   |
| PAR-018 | `++` repeater              | Skip missed occurrences       |
| PAR-019 | `.+` repeater              | Completion-relative occurrence|
| PAR-020 | Deadline warning           | Correct warning period        |
| PAR-021 | Overdue scheduled task     | Agenda inclusion              |
| PAR-022 | Checkbox rollup            | Correct progress              |
| PAR-023 | Parent completion          | Configured behavior           |
| PAR-024 | State cycling              | Correct next state            |
| PAR-025 | Project workflow override  | Correct workflow              |
| PAR-026 | Source mutation            | Unrelated text preserved      |
| PAR-027 | Unsaved buffer edit        | No data loss                  |
| PAR-028 | Duplicate task IDs         | Diagnostic                    |
| PAR-029 | Incremental reparse        | Updated task index            |
| PAR-030 | Agenda source jump         | Correct file and task         |

## 17. Implementation Milestones

### Milestone A — Parser foundation

- Markdown structure recognition
- Heading task identification
- Checkbox task identification
- Source ranges
- Hierarchy
- Basic parser tests

### Milestone B — Metadata and workflows

- Planning lines
- Priorities
- Tags
- Properties
- State resolution
- Project workflow overrides

### Milestone C — Scheduling engine

- Timestamp parser
- Scheduled tasks
- Deadlines
- Warning periods
- Repeaters
- Recurrence tests

### Milestone D — Task mutation engine

- State transitions
- Checkbox synchronization
- Progress rollups
- Completion timestamps
- Scheduling edits
- Safe source modifications

### Milestone E — Integration

- Unified task index
- Agenda queries
- Project queries
- Neovim source navigation
- Incremental refresh
- End-to-end tests

All milestones are part of Lattice v1.

## 18. Open Technical Decisions

The following decisions must be resolved through prototypes or compatibility tests before the corresponding implementation is finalized:

1. Exact checkbox metadata placement in Markdown dialects and renderers.
2. How Org-style property drawers interact with Markdown paragraph and list parsing.
3. Handling checkbox tasks with multiple terminal workflow states.
4. Whether project workflows are resolved by folder, property, or explicit mapping when multiple definitions apply.
5. Persistent identity strategy for tasks without IDs.
6. Exact handling of recurring tasks with both SCHEDULED and DEADLINE timestamps.
7. The compatibility boundary between Org-mode checkbox progress behavior and Lattice's automatic parent completion.
8. Performance characteristics of Tree-sitter parsing across large PARA repositories.

These are engineering validation items. They do not remove features from the v1 scope.

## 19. Definition of Done

This specification is implemented when:

- Both heading and checkbox tasks parse correctly.
- Org-compatible metadata is recognized.
- Configurable TODO workflows work for both task types.
- Scheduling and recurrence pass compatibility tests.
- Parent-child relationships and progress are correct.
- File mutations preserve unrelated Markdown.
- Diagnostics identify malformed or conflicting metadata.
- The normalized task index supports agenda and project queries.
- Automated tests pass.
- The implementation works locally in Neovim without requiring external services.

---

End of Lattice Markdown Syntax and Org-mode Compatibility Specification v0.2
