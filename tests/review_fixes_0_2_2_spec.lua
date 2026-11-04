-- Regression tests for the code review of the 0.2.2 fixes. Each test is
-- named after the bug it pins down. Fictional volcanoes and people.
local H = require("helpers")
local test, eq = H.test, H.eq
local config, dashboard = H.config, H.dashboard
local mutate = require("lattice.mutate")
local agenda = require("lattice.agenda")

local DEFAULT = config.defaults()

local function L(text)
  return vim.split(text, "\n", { plain = true })
end

local function T(lines)
  return table.concat(lines, "\n")
end

-- The target the dashboard draws for the task on `line`, with its twins
-- counted as the dashboard counts them.
local function target_for(lines, line, path)
  local parsed = assert(H.parser.parse(lines, DEFAULT))
  for _, task in ipairs(parsed.tasks) do
    task.path = path or "a.md"
  end
  local counts = agenda.tally(parsed.tasks, agenda.task_key)
  for _, task in ipairs(parsed.tasks) do
    if task.line == line then
      return { line = line, title = task.title, kind = task.kind, twins = counts[agenda.task_key(task)] }
    end
  end
end

-- 1. A heading and a v0.1 bullet with the same title -------------------------------

test("a heading row is still found when a v0.1 bullet shares its title", function()
  local lines = L("# Notes\n## TODO Call\n- TODO Call")
  local target = target_for(lines, 2)
  eq(target.twins, 1)
  local moved = L("added\n# Notes\n## TODO Call\n- TODO Call")
  eq(dashboard.locate(moved, target, DEFAULT), 3)
end)

-- 2. The unchanged-line shortcut skipped the twin check -----------------------------

test("deleting one of two equal headings refuses an edit on the other's row", function()
  local lines = L("# A\n## TODO Review\n## TODO Review")
  local first = target_for(lines, 2)
  eq(first.twins, 2)
  -- The first is deleted; the second moves onto line 2.
  eq(dashboard.locate(L("# A\n## TODO Review"), first, DEFAULT), nil)
  -- yyP: a copy above, so the original is now on line 3.
  local single = target_for(L("# A\n## TODO Review"), 2)
  eq(dashboard.locate(L("# A\n## TODO Review\n## TODO Review"), single, DEFAULT), nil)
  -- Refile targets behave the same.
  eq(mutate.find_heading(L("# A\n## Plans"), 2, "Plans", 2), nil)
end)

-- 3. A new task with the same title took the edit -----------------------------------

test("a new task with the same title makes the edit refuse, not pick the newcomer", function()
  local lines = L("# A\nintro\n## TODO Call")
  local target = target_for(lines, 3)
  local pasted = L("# A\nadded\n## NEXT Call\n## TODO Call")
  eq(dashboard.locate(pasted, target, DEFAULT), nil)
  eq(mutate.find_heading(L("## Plans\n## Plans"), 1, "Plans", 1), nil)
end)

-- 4. Migration lost a second valid date ---------------------------------------------

test("migrate leaves an item or heading with two valid [due:] dates as written", function()
  local lines = L("# Notes\n- TODO pay [due:2026-11-10] [due:2026-11-12]\n## TODO rent [due:2026-11-10] [due:2026-11-12]")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count, #skipped }, { T(lines), 0, 2 })
  assert(skipped[1].reason:find("more than one [due:] date", 1, true), skipped[1].reason)
end)

-- 5. A date-only title was reported as "only @Name" ----------------------------------

test("an item whose title is only a date gets an accurate reason", function()
  local _, _, skipped = mutate.migrate(L("# Notes\n- TODO [due:2026-11-10]"), DEFAULT)
  eq(skipped[1].reason, "it has no title besides its dates; add a title first")
  local _, _, nested = mutate.migrate(L("# Notes\n- TODO outer\n  - TODO [due:2026-11-10]"), DEFAULT)
  eq(nested[1].line, 2)
  eq(nested[1].reason, "line 3: it has no title besides its dates; add a title first")
end)

-- 6. A heading whose title was only a date became "## TODO" --------------------------

test("a heading whose title is only [due:] is left as written, like an item", function()
  local lines = L("## TODO [due:2026-11-10]")
  local out, count, skipped = mutate.migrate(lines, DEFAULT)
  eq({ T(out), count }, { T(lines), 0 })
  eq(skipped[1].reason, "it has no title besides its dates; add a title first")
end)

-- 7. Rescheduling replaced an unreadable date silently -------------------------------

test("rescheduling refuses to overwrite a date it can't read; removing it still works", function()
  local lines = L("## TODO water\nSCHEDULED: <2026-10-01 Thu +0d -2d>")
  local _, err = mutate.set_date(lines, 1, "SCHEDULED", { date = "2026-11-05" })
  eq(err, "this heading's SCHEDULED <2026-10-01 Thu +0d -2d> can't be read (see WARNINGS); fix or remove it first")
  eq(T(assert(mutate.set_date(lines, 1, "SCHEDULED", nil))), "## TODO water")
  -- A readable date is still replaced, keeping its repeater.
  local ok = assert(mutate.set_date(L("## TODO water\nSCHEDULED: <2026-10-01 Thu +1d>"), 1, "SCHEDULED", { date = "2026-11-05" }))
  eq(ok[2], "SCHEDULED: <2026-11-05 Thu +1d>")
end)

-- Review of 0.2.4 ---------------------------------------------------------------------

test("rescheduling refuses a heading with two SCHEDULED entries, in either order", function()
  for _, planning in ipairs({ "SCHEDULED: <bad> SCHEDULED: <2026-10-01 Thu +1d>", "SCHEDULED: <2026-10-01 Thu +1d> SCHEDULED: <bad>" }) do
    local _, err = mutate.set_date(L("## TODO w\n" .. planning), 1, "SCHEDULED", { date = "2026-11-05" })
    eq(err, "this heading has 2 SCHEDULED entries; keep one, then try again")
  end
end)

test("a new task with the same title but a different state also refuses the edit", function()
  local target = target_for(L("# A\n## TODO Call"), 2)
  target.raw = "## TODO Call" -- what 0.2.4's unchanged-line shortcut used
  eq(dashboard.locate(L("# A\n## TODO Call\n## NEXT Call"), target, DEFAULT), nil)
end)

test("rescheduling an inactive SCHEDULED makes it active and keeps its repeater", function()
  local out = assert(mutate.set_date(L("## TODO x\nSCHEDULED: [2026-10-01 Thu +1w]"), 1, "SCHEDULED", { date = "2026-11-05" }))
  eq(T(out), "## TODO x\nSCHEDULED: <2026-11-05 Thu +1w>")
end)

test("the same [due:] date written twice is not a conflict", function()
  local out, count, skipped = mutate.migrate(L("# Notes\n- TODO pay [due:2026-11-10] [due:2026-11-10]"), DEFAULT)
  eq({ count, #skipped }, { 1, 0 })
  eq(T(out), "# Notes\n\n## TODO pay\nDEADLINE: <2026-11-10 Tue>")
end)

-- Review of 0.2.5 ---------------------------------------------------------------------

test("completing a repeat refuses a heading with two SCHEDULED entries instead of overwriting one", function()
  local lines = L("## TODO w\nSCHEDULED: [2026-09-01 Tue] SCHEDULED: <2026-10-01 Thu +1d>")
  local out, err = mutate.set_state(lines, DEFAULT, 1, "DONE", { date = "2026-10-01", time = "09:00" })
  eq({ out, err }, { nil, "this heading has 2 SCHEDULED entries; keep one, then try again" })
end)

test("removing a date refuses a heading with two entries; a single unreadable one can be removed", function()
  local _, err = mutate.set_date(L("## TODO w\nSCHEDULED: <bad> SCHEDULED: <2026-10-01 Thu>"), 1, "SCHEDULED", nil)
  eq(err, "this heading has 2 SCHEDULED entries; keep one, then try again")
  eq(T(assert(mutate.set_date(L("## TODO w\nSCHEDULED: <bad>"), 1, "SCHEDULED", nil))), "## TODO w")
end)

test("migrating a heading removes every copy of a repeated [due:] or [promised:]", function()
  local out, count = mutate.migrate(L("## TODO pay [due:2026-11-10] [due:2026-11-10]"), DEFAULT)
  eq({ T(out), count }, { "## TODO pay\nDEADLINE: <2026-11-10 Tue>", 1 })
  local waiting = mutate.migrate(L("## WAITING @Ana ship [promised:2026-11-10] [promised:2026-11-10]"), DEFAULT)
  eq(T(waiting), "## WAITING ship\n:PROPERTIES:\n:PROMISED: 2026-11-10\n:ASSIGNED: Ana\n:END:")
  eq(assert(H.parser.parse(waiting, DEFAULT)).legacy, {})
end)

test("parent cookies still update when a child gains or loses its state", function()
  local out = assert(mutate.set_state(L("## TODO Plan [0/1]\n### TODO a\n### b"), DEFAULT, 3, "TODO"))
  eq(out[1], "## TODO Plan [0/2]")
  out = assert(mutate.set_state(out, DEFAULT, 2, ""))
  eq(out[1], "## TODO Plan [0/1]")
end)
