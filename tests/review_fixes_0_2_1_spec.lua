-- Regression tests for the code review of v0.1.0..v0.2.1. Each test is
-- named after the bug it pins down. Fictional volcanoes and people.
local H = require("helpers")
local test, eq, write, notes, reset = H.test, H.eq, H.write, H.notes, H.reset
local config, dashboard, lattice, timestamp = H.config, H.dashboard, H.lattice, H.timestamp
local mutate = require("lattice.mutate")
local schedule = require("lattice.schedule")
local tasks = require("lattice.tasks")

local DEFAULT = config.defaults()

local function L(text)
  return vim.split(text, "\n", { plain = true })
end

local function T(lines)
  return table.concat(lines, "\n")
end

local function cfg_from(raw)
  local root = notes()
  write(root, ".lattice.json", vim.json.encode(raw))
  return assert(config.load(root)), root
end

local function in_note(root, rel, content, row)
  local path = write(root, rel, content)
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { row or 1, 0 })
  return path
end

local function buffer_text(buf)
  return T(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false))
end

-- 1. Refile within a note miscounted lines when the note ended in blanks --------

test("refile within a note ending in blank lines lands under the chosen heading", function()
  local lines = L("# Etna\n## TODO Move me\n\n# Fuji\n## Plans\ntext\n\n\n")
  local out = assert(mutate.refile(lines, 2, nil, 5))
  eq(T(out), "# Etna\n\n# Fuji\n## Plans\ntext\n\n### TODO Move me\n")
  -- A subtree followed by a blank line before the target.
  out = assert(mutate.refile(L("# A\n## TODO x\n\n## B\nb\n\n"), 2, nil, 4))
  eq(T(out), "# A\n\n## B\nb\n\n### TODO x\n")
end)

-- 2. locate() matched part of another line -----------------------------------------

test("dashboard locate matches whole task titles, not parts of other lines", function()
  local lines = L("# Notes\n## TODO Call Bob\nCall\n## TODO Call")
  -- Recorded line 4, but a line was added above: Call is now on 5.
  local moved = { "intro" }
  vim.list_extend(moved, lines)
  eq(dashboard.locate(moved, { line = 4, title = "Call" }, DEFAULT), 5)
  eq(dashboard.locate(moved, { line = 3, title = "Call Bob" }, DEFAULT), 3)
  eq(dashboard.locate(L("## TODO Call Bob"), { line = 1, title = "Call" }, DEFAULT), nil)
  -- Refile targets compare the raw heading text.
  eq(mutate.find_heading(L("# Fuji\n## Plans B\n## Plans"), 2, "Plans"), 3)
end)

-- 3. Migrating a TODO bullet nested in a plain item split the list -----------------

test("migrate leaves a TODO bullet inside a plain list item as written, and says why", function()
  local lines = L("# Notes\n- groceries\n  - TODO buy milk\n  - eggs")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count }, { T(lines), 0 })
  eq(#skipped, 1)
  eq(skipped[1].line, 3)
  assert(skipped[1].reason:find("plain list item", 1, true), skipped[1].reason)
end)

-- 4. Heading migration removed the wrong [due:] or dropped one silently ---------------

test("migrate on a heading removes the valid [due:] it converts, and keeps a conflicting one", function()
  local out = mutate.migrate(L("## TODO pay [due:2026-02-30] rent [due:2026-11-20]"), DEFAULT)
  eq(T(out), "## TODO pay [due:2026-02-30] rent\nDEADLINE: <2026-11-20 Fri>")
  local same = mutate.migrate(L("## TODO pay [due:2026-11-20]\nDEADLINE: <2026-11-20 Fri>"), DEFAULT)
  eq(T(same), "## TODO pay\nDEADLINE: <2026-11-20 Fri>")
  local lines = L("## TODO pay [due:2026-11-20]\nDEADLINE: <2026-11-25 Wed>")
  local kept, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(kept), count }, { T(lines), 0 })
  assert(skipped[1].reason:find("differs from its DEADLINE", 1, true), skipped[1].reason)
end)

-- 5. <leader>lt ignored the front matter's workflow --------------------------------

test("add TODO with no heading above uses the front matter's workflow", function()
  local _, root = cfg_from({ workflows = { bugs = { active = { "OPEN" }, done = { "FIXED" } } } })
  in_note(root, "a.md", "---\nworkflow: bugs\n---\nintro\n", 4)
  vim.notify("sentinel")
  local saved = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("crash on save")
  end
  lattice.add_todo()
  vim.ui.input = saved
  eq(buffer_text(), "---\nworkflow: bugs\n---\nintro\n\n## OPEN crash on save")
  eq(H.last_notify().message, "sentinel")
  local project = cfg_from({ workflows = { etna = { active = { "PLAN" }, done = { "SHIPPED" } } } })
  eq(tasks.parse(L("---\nproject: Etna\n---\ntext"), project).keywords.first_open, "PLAN")
end)

-- 6. A heading that is only a keyword was corrupted ---------------------------------

test("state and priority commands on a keyword-only heading report it, not corrupt it", function()
  local _, err = mutate.set_state(L("# TODO"), DEFAULT, 1, "DONE")
  eq(err, "this heading has no text")
  _, err = mutate.shift_priority(L("# TODO"), DEFAULT, 1, 1)
  eq(err, "this heading has no text")
end)

-- 7. Dashboard edits always refused a heading with [due:] mid-title ------------------

test("a dashboard row for a heading with [due:] mid-title can be edited", function()
  local lines = L("# Notes\n## TODO pay [due:2026-11-20] rent")
  local title = assert(tasks.parse(lines, DEFAULT)).tasks[1].title
  eq(title, "pay rent")
  eq(dashboard.locate(lines, { line = 2, title = title }, DEFAULT), 2)
end)

-- 8. @Name and [promised:] on WAITING headings were never migrated --------------------

test("migrate converts @Name and [promised:] on a WAITING heading", function()
  local out, count = mutate.migrate(L("## WAITING @Raju estimate [promised:2026-11-10]"), DEFAULT)
  eq(count, 1)
  eq(T(out), "## WAITING estimate\n:PROPERTIES:\n:PROMISED: 2026-11-10\n:ASSIGNED: Raju\n:END:")
  eq(assert(tasks.parse(out, DEFAULT)).legacy, {})
end)

-- 9. An unknown :WORKFLOW: was reported on every descendant --------------------------

test("an unknown :WORKFLOW: is reported once, where it is set", function()
  local r = assert(tasks.parse(L("# Etna\n:PROPERTIES:\n:WORKFLOW: nope\n:END:\n## TODO a\n### TODO b\n- item"), DEFAULT))
  local unknown = vim.tbl_filter(function(w)
    return w.category == "unknown-workflow"
  end, r.warnings)
  eq(#unknown, 1)
  eq(unknown[1].line, 1)
  local fm = assert(tasks.parse(L("---\nworkflow: nope\n---\n## TODO a\n## TODO b"), DEFAULT))
  eq(#fm.warnings, 1)
  eq(fm.warnings[1].line, 2)
end)

-- 10. archive.location could point at the note itself --------------------------------

test("archive.location %s.md is rejected: it would archive a note into itself", function()
  local root = notes()
  write(root, ".lattice.json", '{"archive": {"location": "%s.md"}}')
  assert(select(3, config.load(root)):find("the note itself", 1, true))
  write(root, ".lattice.json", '{"archive": {"location": "./%s.md"}}')
  assert(select(3, config.load(root)):find("the note itself", 1, true))
end)

-- 11. A note outside the root archived into the root ---------------------------------

test("a note outside the notes root archives beside itself", function()
  local root = notes()
  write(root, ".lattice.json", "{}")
  local elsewhere = notes()
  local path = write(elsewhere, "trip.md", "# Trip\n## DONE Book train\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  lattice.archive()
  eq(buffer_text(), "# Trip")
  eq(vim.fn.bufnr(elsewhere .. "/trip_archive.md") ~= -1, true)
  eq(vim.fn.bufnr(root .. "/trip_archive.md"), -1)
end)

-- 12. Cycling refused a v0.1 bullet with [-] ----------------------------------------

test("cycling a v0.1 bullet with Org's [-] box changes its state", function()
  local root = notes()
  write(root, ".lattice.json", "{}")
  in_note(root, "a.md", "# Notes\n- [-] TODO half\n  - [x] a\n  - [ ] b\n", 2)
  local state, err = H.insert.cycle(0, 2, DEFAULT, 1)
  eq({ state, err }, { "NEXT", nil })
  eq(vim.api.nvim_buf_get_lines(0, 1, 2, false)[1], "- [-] NEXT half")
end)

-- 13. Rescheduling a heading without a state dropped its repeater ---------------------

test("rescheduling keeps the repeater on a heading without a state", function()
  local edit = assert(H.insert.date_edit("SCHEDULED", "2026-11-12"))
  local out = assert(edit(L("## Water plants\nSCHEDULED: <2026-11-05 Thu +1w -1d>"), 1))
  eq(T(out), "## Water plants\nSCHEDULED: <2026-11-12 Thu +1w -1d>")
  local removed = assert(H.insert.date_edit("SCHEDULED", ""))
  eq(T(assert(removed(out, 1))), "## Water plants")
  eq(select(2, H.insert.date_edit("SCHEDULED", "someday")), '"someday" is not a date Lattice understands; nothing changed')
end)

-- 14. Outline paths kept states and priorities ---------------------------------------

test("outline paths (refile labels, ARCHIVE_OLPATH) hold titles without state, priority or tags", function()
  local r = assert(tasks.parse(L("# NEXT [#A] Plan :work:\n## Releases\n### DONE Ship"), DEFAULT))
  eq(r.headings[3].outline, { "Plan", "Releases", "Ship" })
  local _, archive = mutate.archive(L("# NEXT [#A] Plan\n## DONE Ship"), DEFAULT, 2, "a.md", nil, { date = "2026-11-04", time = "09:00" })
  assert(T(archive):find(":ARCHIVE_OLPATH: Plan\n", 1, true), T(archive))
end)

-- 15. Inactive timestamps counted as SCHEDULED / DEADLINE ----------------------------

test("an inactive SCHEDULED or DEADLINE is ignored and reported; CLOSED stays inactive", function()
  local r = assert(tasks.parse(L("## TODO a\nSCHEDULED: [2026-11-05 Thu] DEADLINE: [2026-11-06 Fri]"), DEFAULT))
  eq({ r.tasks[1].scheduled, r.tasks[1].deadline }, { nil, nil })
  eq(#r.warnings, 2)
  eq(r.warnings[1].category, "inactive-timestamp")
  local done = assert(tasks.parse(L("## DONE a\nCLOSED: [2026-11-05 Thu 10:00]"), DEFAULT))
  eq({ done.tasks[1].closed.date, done.warnings }, { "2026-11-05", {} })
end)

-- 16. Migration flattened items nested deeper than six levels -------------------------

test("migrate leaves an item that would need headings past ###### as written", function()
  local lines = L("##### Deep\n- TODO a\n  - TODO b\n    - TODO c")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count }, { T(lines), 0 })
  assert(skipped[1].reason:find("deeper than ######", 1, true), skipped[1].reason)
  -- One level less fits.
  local _, fits = mutate.migrate(L("#### Deep\n- TODO a\n  - TODO b"), DEFAULT)
  eq(fits, 2)
end)

-- 17. "Default" in another case bypassed the todo/default conflict ---------------------

test("workflow names are case-insensitive: Default conflicts with todo; Bugs and bugs collide", function()
  local root = notes()
  write(root, ".lattice.json", vim.json.encode({ todo = "TODO | DONE", workflows = { Default = { active = { "A" }, done = { "B" } } } }))
  assert(select(3, config.load(root)):find("either todo or workflows.default", 1, true))
  write(root, ".lattice.json", '{"workflows": {"Bugs": {"active": ["A"], "done": ["B"]}, "bugs": {"active": ["C"], "done": ["D"]}}}')
  assert(select(3, config.load(root)):find("differ only in case", 1, true))
end)

-- Efficiency -------------------------------------------------------------------------

test("a ++ repeat years in the past jumps ahead instead of stepping", function()
  local calls = 0
  local shift = schedule.shift
  schedule.shift = function(...)
    calls = calls + 1
    return shift(...)
  end
  local next_ts = schedule.next_occurrence(assert(timestamp.parse("<2016-11-04 Fri 09:00 ++1h>")), { date = "2026-11-04", time = "10:30" })
  schedule.shift = shift
  eq(schedule.format(next_ts), "<2026-11-04 Wed 11:00 ++1h>")
  assert(calls < 10, calls)
  -- Month ends still don't drift after a jump.
  local monthly = schedule.next_occurrence(assert(timestamp.parse("<2016-01-31 Sun ++1m>")), { date = "2026-05-15" })
  eq(monthly.date, "2026-05-31")
end)

test("a state change does not re-parse more than it needs to", function()
  local markdown = require("lattice.markdown")
  local calls = 0
  local parse = markdown.parse
  markdown.parse = function(...)
    calls = calls + 1
    return parse(...)
  end
  local cfg = cfg_from({ logging = { done = "time" } })
  assert(mutate.set_state(L("# Etna\n## TODO a\n## TODO b"), cfg, 2, "DONE", { date = "2026-11-04", time = "09:00" }))
  markdown.parse = parse
  assert(calls <= 3, calls)
end)

-- Second review (of the fixes above) ----------------------------------------------

test("migrate keeps a [promised:] that differs from the heading's :PROMISED:", function()
  local lines = L("## WAITING estimate [promised:2026-11-10]\n:PROPERTIES:\n:PROMISED: 2026-12-01\n:END:")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count }, { T(lines), 0 })
  assert(skipped[1].reason:find("differs from its :PROMISED:", 1, true), skipped[1].reason)
  local same = mutate.migrate(L("## WAITING estimate [promised:2026-12-01]\n:PROPERTIES:\n:PROMISED: 2026-12-01\n:END:"), DEFAULT)
  eq(T(same), "## WAITING estimate\n:PROPERTIES:\n:PROMISED: 2026-12-01\n:END:")
end)

test("migrate doesn't replace an inactive DEADLINE with a [due:] date", function()
  local lines = L("## TODO pay [due:2026-11-10]\nDEADLINE: [2026-11-20 Fri]")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count }, { T(lines), 0 })
  assert(skipped[1].reason:find("DEADLINE [2026-11-20 Fri]", 1, true), skipped[1].reason)
end)

test("migrate leaves a legacy tree alone when a nested item sits in a plain item", function()
  local lines = L("# Notes\n- TODO outer\n  - plain\n    - TODO inner\n    - after inner\n  - plain2")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count }, { T(lines), 0 })
  eq(skipped[1].line, 2)
  assert(skipped[1].reason:find("line 4 is inside a plain list item", 1, true), skipped[1].reason)
end)

test("migrate leaves a WAITING heading or item whose title is only @Name", function()
  local lines = L("## WAITING @Bob\n## Waiting On\n- @Ana")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count, #skipped }, { T(lines), 0, 2 })
  assert(skipped[1].reason:find("only @Name", 1, true), skipped[1].reason)
end)

test("a zero-length repeater is reported, not crashed on", function()
  local ts, err = timestamp.parse("<2026-10-01 Thu +0d>")
  eq(ts, nil)
  assert(err:find("never moves", 1, true), err)
  local r = assert(tasks.parse(L("## TODO a\nSCHEDULED: <2026-10-01 Thu ++0d>"), DEFAULT))
  eq(r.tasks[1].scheduled, nil)
  eq(r.warnings[1].category, "invalid-timestamp")
end)

test("a row edit is refused when one of two tasks with the same title was renamed", function()
  local lines = L("# A\n## TODO Call Ana\n# B\n## TODO Call")
  -- Drawn when both said "Call" (twins = 2); line 2 has since been renamed.
  local target = { line = 2, title = "Call", raw = "## TODO Call", twins = 2 }
  eq(dashboard.locate(lines, target, DEFAULT), nil)
  -- Lines added above both: each is still found, the nearer one wins.
  local shifted = L("intro\n# A\n## TODO Call\n# B\n## TODO Call")
  eq(dashboard.locate(shifted, target, DEFAULT), 3)
  -- With both still there, an unchanged line is found.
  eq(dashboard.locate(L("# A\n## TODO Call\n# B\n## TODO Call"), target, DEFAULT), 2)
  eq(mutate.find_heading(L("## Plans X\n## Plans"), 1, "Plans", 2), nil)
end)

test("archiving a buffer that has no file is refused", function()
  local root = notes()
  write(root, ".lattice.json", "{}")
  reset(root)
  vim.cmd("enew!")
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "## DONE x" })
  lattice.archive()
  assert(H.last_notify().message:find("save this note to a file first", 1, true), H.last_notify().message)
  eq(vim.fn.bufnr("_archive.md"), -1)
  eq(buffer_text(), "## DONE x")
end)

test("dashboard edits and Enter on an unchanged note parse it at most once", function()
  local markdown = require("lattice.markdown")
  local calls = 0
  local parse = markdown.parse
  markdown.parse = function(...)
    calls = calls + 1
    return parse(...)
  end
  local line = dashboard.locate(L("# A\n## TODO Call"), { line = 2, title = "Call", raw = "## TODO Call", twins = 1 }, DEFAULT)
  markdown.parse = parse
  eq({ line, calls }, { 2, 0 })
end)
