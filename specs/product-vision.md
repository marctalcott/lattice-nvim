# Lattice — Product Vision and Requirements

Status: Vision and requirements inventory, not an implementation commitment
Updated: 2026-11-01
Project boundary: Lattice is an independent personal management tool, unrelated to Portico.

## 1. Why Lattice exists

Lattice is a personal management accountability system, not simply a to-do list or a new notes application.

The central question is:

> Across everything I've recorded at work, what have I promised to do, what have others promised or been asked to do, and what needs my attention next?

A useful Lattice view should reveal obligations that otherwise disappear into daily notes, meetings, and project discussions. This includes both commitments the user owes and things the user is waiting for from other people. Over time, it should support the management habit of reviewing, following up, and closing the loop.

## 2. Existing workflow to preserve

- Editor: Neovim configured with LazyVim on a Mac.
- Notes: Plain Markdown files, already organized using Tiago Forte's PARA approach (Projects, Areas, Resources, Archives), with existing daily/work notes.
- AI-assisted editing: Claude or another local coding/notes agent can operate on the notes folder, create files, reorganize content, and propose edits. Lattice should consume the resulting Markdown without depending on a particular AI provider.
- Mobile capture: Drafts on the iPhone has been discussed as a capture inbox; any Lattice ingestion workflow is not yet specified. Drafts and Lattice must not require a cloud backend to use the core dashboard.
- Storage: The existing notes remain the source of truth; local files first, no Lattice-specific database for basic task display.
- Project separation: Use a separate lattice repository, never a subfolder of or dependency on Portico. Portico remains a distinct project-management product.

Lattice must fit the notes workflow, not require the user to migrate notes into an application.

## 3. User outcomes

The design should eventually let the user:

1. See my obligations: Review all my still-open tasks and commitments, regardless of which Markdown file contains them.
2. See delegated obligations: Review things other people own or owe me, ideally grouped by person, with enough context to follow up.
3. Know what needs attention: Recognize overdue commitments, upcoming dates, and items to follow up on even when the actual deliverable has a different deadline.
4. Return to the evidence: Open the original note at the exact task line, with surrounding meeting/project context.
5. Capture without friction: Record work notes using normal Markdown and existing mobile/desktop habits, with no long special tags required.
6. Recover commitments hidden in prose: Use an AI agent to identify potential promises or follow-ups in ordinary meeting notes, review proposed changes, then deliberately promote approved items into the tracked structure.
7. Close the loop: Mark actions complete or resolve a waiting item without maintaining a second system of record.

## 4. Agreed core conventions — version 0.1

These are agreed and already specified in lattice-v0.1.md:

- Use a small Lua plugin for Neovim/LazyVim, rather than Electron or a standalone Mac app.
- Scan Markdown within a configured PARA notes root, with .lattice.json include/exclude patterns; Archives excluded by default, and user can add any other exclusions.
- Parse only list items under strictly named To Do and Waiting On headings, at any heading depth. Avoid guesses based on arbitrary text.
- Accept ordinary bullets as outstanding items and Markdown checkboxes for outstanding/completed items. Prefer checkboxes when inserting new tasks.
- Allow optional @person at the start of a waiting item and optional [due:YYYY-MM-DD]; unassigned and undated items remain visible.
- Show two dashboard groupings: My To Do and Waiting On. Hide completed tasks by default; indicate overdue dates.
- Selecting an item jumps to its original file and line. Manual refresh rescans notes and configuration. Scanning is read-only.
- Provide keyboard shortcuts to open the dashboard, add a personal task, add a delegated item, and refresh.
- No external accounts, server, cloud sync, built-in AI calls, or separate database are required for v0.1.

Important boundary: The v0.1 parser cannot find a promise buried in ordinary prose. It only tracks items explicitly entered under those two headings. This is intentional for predictable first-release behavior, not a claim that the broader problem is fully solved.

## 5. Requirements beyond version 0.1

These capture the earlier discussion, but are not yet designed or scheduled. They should not silently expand the v0.1 implementation.

### 5.1 Distinguish commitments from ordinary tasks

A task may be a personal intention, an explicit promise to someone, or a delegated obligation. The user originally asked to track management promises, not just checkboxes. Future design should consider recording who the commitment is to, a useful description of the promise, its status, and where the promise came from. Do not require the user to duplicate it in two systems.

Open design question: Should a promise be another attribute of a To Do item, or is a separate commitment model needed? Favor the simplest Markdown representation that preserves meaning.

### 5.2 Follow-up review and attention dashboard

Beyond grouping by ownership, the product should help answer What requires follow-up today? Desired concepts discussed include:

- Overdue, upcoming, and undated views.
- Waiting by person, so the manager can review what is outstanding from a given colleague before a 1:1.
- Distinct deliverable due date versus my follow-up/reminder date when needed. The v0.1 convention currently treats a waiting item's single [due:...] as a follow-up date; do not silently treat that as the other person's promised delivery date.
- A review workflow to mark tasks done, carry forward follow-ups, or otherwise resolve items while retaining source context.

Open design questions: Which statuses are worth adding? Should the dashboard explicitly provide a daily/weekly review experience? No decision yet.

Decision (2026-11-02): Personal tasks use org-mode style TODO keywords on the item itself (`- TODO ...`, `## NEXT ...`), with sequences such as `TODO NEXT | DONE CANCELED` set for the notes root in `.lattice.json` and per note in YAML front matter. Matching is exact, like org. Done-state items appear in a DONE group. This replaces the `To Do` heading. See Amendment A in `LATTICE_SPEC.md`.

Decision (2026-11-01): A Waiting On item may add `[promised:YYYY-MM-DD]` for the date the other person committed to. `[due:...]` stays the user's follow-up date and alone drives sorting and overdue marks. The dashboard stays read-only: items are closed by editing the note.

### 5.3 AI-assisted discovery with approval

The user's AI agent can already process ordinary meeting notes. A future workflow should let the user ask it to review recent notes, find candidate commitments, delegated requests, dates, and people, and propose additions to To Do and Waiting On sections.

Requirements and guardrails:

- Human review before applying inferred commitments, especially ambiguous meeting statements.
- Do not invent deadlines, assignees, or agreements.
- Keep provenance to the original note and avoid creating duplicate commitments across repeated summaries.
- AI assistance is optional and provider-independent; the Lua plugin must work without an AI agent or internet.
- Prefer instructions/conventions that an existing AI agent can follow, rather than building an AI SDK into the plugin.

Open design question: Where should the review queue or proposal display live—an agent diff, a Markdown inbox, or a Lattice view?

### 5.4 iPhone Drafts capture / inbox

Earlier conversation proposed using Drafts as a convenient place to capture material away from the Mac and then bringing it into the existing notes folder. The v0.1 spec does not implement Drafts integration.

Desired outcome: captured notes can be reviewed, assigned to an appropriate PARA location, and processed for possible tasks without turning Lattice into a second notes application. The user has said the app can be Mac-only and entirely local; do not assume automatic phone-to-Mac sync or a web service.

Decision (2026-11-01): Lattice lists Markdown files from a local inbox folder, `Inbox/` in the notes root by default, on manual refresh. How files reach that folder is outside Lattice, so it depends on no sync service. Lattice lists and opens captures only; the user or an AI agent files them and adds tasks.

### 5.5 Reliability and long-term note hygiene

Potential future enhancements include better handling of duplicates, renames/moves of source files, faster rescans of large collections, and task history. These are implementation concerns to evaluate when real usage reveals a need, not requirements to build a database now.

## 6. Delivery phases (proposed, not dates)

| Phase                         | Goal                                        | Scope                                                                                                         |
|-------------------------------|---------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| **v0.1 — Visibility**         | Make explicitly tracked commitments visible | Strict headings, scanning/exclusions, personal and waiting dashboards, navigation, insertion, manual refresh. |
| **Later — Management review** | Make follow-up practical                    | Overdue/upcoming, per-person views, clear follow-up vs. delivery dates, closing out items.                    |
| **Later — Discovery**         | Recover commitments from unstructured notes | Agent instructions and reviewed proposals, provenance, duplicate avoidance.                                   |
| **Later — Capture**           | Make mobile input usable                    | Define a Drafts-to-Markdown workflow that fits the local-first architecture.                                  |

The order beyond v0.1 is deliberately provisional and should be based on hands-on use.

## 7. Product principles

1. Accountability over organization. PARA and AI already handle note organization; Lattice exists to surface what the manager owes and is waiting for.
2. Markdown is truth. The user can always understand and edit the records in LazyVim without opening a special app.
3. Explicit beats speculative. Automatic scans only recognize deliberately structured items; AI-discovered commitments must be reviewed.
4. Short, human-readable capture. Avoid mandatory proprietary tags, complex YAML, or new data-entry overhead when Markdown headings and lists are sufficient.
5. Source context stays available. Every surfaced obligation needs navigation back to where it was recorded.
6. Local-first, provider-agnostic. No server, account, database, or AI subscription is necessary for core utility.
7. Lattice is not Portico. Lattice is a personal manager's notes workflow, not an organizational project intake and lifecycle product.

## 8. How to measure success

During initial use, evaluate whether:

- The manager can open one dashboard and confidently identify all explicitly recorded open personal and delegated tasks across the included notes.
- Source navigation makes it easy to recover context and act on an item.
- Adding and completing tasks is faster than maintaining an independent tracker.
- The manager is able to run a repeatable review of outstanding commitments and follow-ups.
- The workflow continues to work offline and when the AI agent is unavailable.

Longer-term success means fewer missed promises or forgotten follow-ups, not simply more tasks discovered.

## 9. Traceability — what is captured where

| Original need                                          | v0.1 spec                | This vision document            |
|--------------------------------------------------------|--------------------------|---------------------------------|
| Existing LazyVim, Markdown, PARA and AI-friendly files | **Yes**                  | Preserved as principles         |
| Separate from Portico                                  | **Yes**                  | Reaffirmed                      |
| Personal to-dos and delegated tasks across notes       | **Yes**                  | Broader accountability framing  |
| Configurable folder exclusions                         | **Yes**                  | Preserved                       |
| Source links to original notes                         | **Yes**                  | Preserved                       |
| Promises/commitments hidden in ordinary prose          | **No**                   | Captured for reviewed discovery |
| Overdue/upcoming and per-person follow-up workflow     | **Partial**              | Captured as future requirements |
| Distinguish follow-up date from promised due date      | **No**                   | Captured as open design issue   |
| Drafts mobile capture into Markdown                    | **No**                   | Captured for future design      |
| AI review and propose changes with approval            | **No built-in workflow** | Captured with guardrails        |

## 10. Current decision and handoff

Keep lattice-v0.1.md as the small implementable contract. Use this document as the north star, and do not confuse a deferral with dropping a requirement. When asking Claude or another coding agent to build v0.1, instruct it to read both documents, implement the v0.1 acceptance criteria, and avoid expanding scope without discussion.
