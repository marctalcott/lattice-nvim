-- Regression tests for the code review of the 0.2.2 fixes. Each test is
-- named after the bug it pins down. Fictional volcanoes and people.
local H = require("helpers")
local test, eq = H.test, H.eq
local config, dashboard = H.config, H.dashboard
local mutate = require("lattice.mutate")

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
  local counts = mutate.tally(parsed.tasks, dashboard.twin_key)
  for _, task in ipairs(parsed.tasks) do
    if task.line == line then
      return { line = line, title = task.title, kind = task.kind, raw = task.raw, twins = counts[dashboard.twin_key(task)] }
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
