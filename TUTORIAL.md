# Using Lattice day to day

This tutorial assumes you know Neovim and Markdown and already have Lattice installed (see the [README](README.md)). It covers daily use and follows a normal workday.

Lattice reads tasks from your Markdown notes and shows them in one dashboard. Your notes are the only record, and Lattice never saves a file for you. All keys below are the defaults; the plugin's own keys start with `<leader>l`.

## 1. What a task looks like

As in Org-mode, **a task is a heading that starts with a state**:

```markdown
# Team

## TODO [#A] Draft the Q1 plan [0/2] :planning:
DEADLINE: <2026-11-09 Mon -3d>
SCHEDULED: <2026-11-05 Thu>
:PROPERTIES:
:ID: q1-plan
:END:
- [ ] Gather headcount numbers
- [ ] Write the summary

## WAITING Reply about the offsite venue
:PROPERTIES:
:ASSIGNED: Elira Voss
:PROMISED: 2026-11-07
:END:

## Meeting notes
- [ ] This checkbox is just a checklist item, not a task.
```

The rules that matter in practice:

- **Any heading level works** (`#` to `######`). A heading without a state is just a heading. Nested task headings are subtasks.
- **Checkboxes under a task are steps.** They count toward the task's `[0/2]` progress but don't get their own rows on the dashboard.
- **States are case-sensitive.** `TODO` counts; `todo`, `TODO:` and `TODOs` don't.
- **The default workflow** is `TODO NEXT WAITING | DONE CANCELED`.
- **Metadata goes directly under the heading.** That means the planning line (`DEADLINE`, `SCHEDULED`, `CLOSED`) and the `:PROPERTIES:` drawer. Blank lines in between are fine.
- **Priority** is written `[#A]`, `[#B]` or `[#C]`. **Tags** go at the end of the heading, `:tag:other:`, and nested headings inherit them.
- **`:ASSIGNED:`** names the person you're waiting on. Any task in the `WAITING` state appears under WAITING ON.

You never have to type the metadata yourself; the commands below write it for you.

## 2. Morning: check the dashboard

Press `<leader>ll` (`:Lattice`). The **Overview** shows these groups:

| Group | What's in it |
|---|---|
| **MY TO DO** | Your open tasks except `WAITING` ones: those with a deadline first, soonest first, then the rest |
| **WAITING ON** | `WAITING` tasks, showing who you're waiting on and any promised date |
| **OVERDUE** | Open tasks whose deadline has passed |
| **TODAY** | Tasks scheduled today, tasks scheduled earlier that are still open, and deadlines due today |
| **DUE SOON** | Deadlines inside their warning period (14 days by default, or the deadline's own `-3d`) |
| **DONE** | Up to 20 finished tasks, from the most recently changed notes first |
| **INBOX** | Only shown if an `Inbox/` folder exists in your notes root |
| **WARNINGS** | Problems such as invalid dates, broken drawers or duplicate `:ID:`s; `Enter` jumps to the line |

A task can appear in two groups at once, for example MY TO DO and OVERDUE.

### Switching views

| Key | View |
|---|---|
| `1` | Overview (the groups above) |
| `2` | Week agenda, Monday to Sunday. `b` / `f` go to the previous / next week, `.` returns to this week |
| `3` | Every open task, sorted by priority, then deadline |
| `4` | Projects: open and done counts plus the next action. `Enter` lists that project's tasks |

### Filtering

`F` sets a filter that applies to every view. Terms combine:

```
+planning -later #A @elira state:NEXT project:"Home Renovation" budget
```

- `+tag` / `-tag` keep tasks that have or lack the tag.
- `#A` keeps that priority.
- `@name` matches the assignee.
- `state:` and `project:` match the state and project.
- A bare word matches the title.

Press `F`, then Enter with an empty answer, to clear the filter. `/` still does a normal buffer search.

### Other keys

- `Enter` opens the task's note at its line.
- `r` refreshes.
- `q` closes the dashboard and returns you to where you were.
- `?` shows help.

## 3. Working tasks from the dashboard

You can triage without opening each note, like Org's agenda:

| Key | Action |
|---|---|
| `t` | Pick a new state, including done states |
| `+` / `-` | Raise / lower priority |
| `S` / `D` | Set or remove SCHEDULED / DEADLINE |
| `s` | **Save** the notes you edited from here |

Edits go into the note's buffer, which opens in the background if needed. They are **not saved until you press `s`**. A typical morning pass: press `D` on things that need a date, `-` on things that can slip, `t` → DONE on things already finished, then `s`.

## 4. During the day: capture in your notes

Write meeting notes as usual. When an action item comes up, add it with a key instead of typing the syntax.

- **`<leader>lt`**: prompts for text and adds a TODO heading at the level of the heading you're in, after its subtree (like Org's `C-S-RET`).
- **`<leader>ld`**: prompts for an optional person, then the item, and adds a `WAITING` heading with an `:ASSIGNED:` drawer.

`Esc` at any prompt leaves the buffer untouched.

### Editing the task under your cursor

| Key | Does |
|---|---|
| `<leader>ln` / `<leader>lp` | Next / previous state: none → TODO → NEXT → WAITING → DONE → CANCELED → none. This also turns a plain heading into a task |
| `<leader>ls` | Pick any state from a list |
| `<leader>lx` | Toggle the checkbox under the cursor. Parent boxes and the `[n/m]` progress counts update automatically |
| `<leader>lS` / `<leader>lD` | Set SCHEDULED / DEADLINE |
| `<leader>l+` / `<leader>l-` | Priority up / down. Going past A or C removes it |

**Date prompts** accept:

- `2026-11-12`
- `today`, `tomorrow`
- `+3d`, `+2w`, `+1m`, `+1y`
- any of these followed by a time, like `14:30`

An empty answer removes the date.

Every edit is a single undo step (`u`), and nothing is saved until you `:w`. Saving any note under the notes root refreshes an open dashboard automatically.

## 5. Recurring tasks

Add an Org repeater to the date:

```markdown
## TODO Review team metrics
SCHEDULED: <2026-11-02 Mon +1w>
```

When you mark it DONE, Lattice moves the date to the next occurrence and keeps the task open in its previous state. It also logs `:LAST_REPEAT:` and a state-change note. The repeater types work as in Org:

- `+1w` adds one interval to the scheduled date.
- `++1w` keeps adding intervals until the date is in the future.
- `.+1w` counts one interval from the day you complete it.

## 6. End of day: tidy up

- **Refile** with `<leader>lw`. It moves the heading under the cursor, with everything below it, under any heading in any note. Targets are listed like `note.md › Etna › Releases`.
- **Archive** with `<leader>lA`. It moves the heading under the cursor, with everything below it, to `<note>_archive.md` with Org's archive properties. Archive files aren't scanned, so archived tasks leave the dashboard.
- **Process the Inbox.** Captures you dropped into `Inbox/` (for example from your phone) show up as INBOX rows. Open each one, then move the file into your folder structure; it leaves the list on the next refresh.

As with the other edits, refile and archive change buffers only, so save both notes afterwards.

## 7. A few habits that help

- **Use `NEXT`** for the one thing you'd actually do next on a project. The Projects view (`4`) shows it as the project's next action.
- **Use `DEADLINE` for real due dates and `SCHEDULED` for when you plan to start.** Only deadlines put a task in OVERDUE and DUE SOON. Scheduled tasks show up in TODAY and stay there until they're done.
- **Projects with their own states** (for example `BACKLOG READY IN PROGRESS BLOCKED`) are set up in `.lattice.json` in your notes root. A top-level `# Etna` heading that matches a workflow name makes the tasks under it use those states. Changes to that file apply when you press `r`, with no restart.
- **If a task is missing**, run `:LatticeHealth` to see how many notes were scanned, which states each workflow allows, and any warnings. The usual causes are:
  - a lowercase state
  - a checkbox instead of a heading
  - a heading inside a code block
  - a file excluded from scanning

  The same command also lists any `<leader>l…` keys skipped because another mapping already used them.
- **LazyVim note:** `<leader>l` on its own opens `:Lazy`, so after typing it there's a short pause before the next key is read. Rebind the keys with `opts.keymaps` if that bothers you.

For every detail and option, see the [README](README.md) and `:help lattice`.
