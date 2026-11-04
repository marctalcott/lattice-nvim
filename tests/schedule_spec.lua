-- Milestone C: scheduling engine (LATTICE_SYNTAX_SPEC §8–§10, §15.3;
-- acceptance tests PAR-016..021 and the §10.5 edge cases).
local H = require("helpers")
local test, eq = H.test, H.eq
local timestamp = H.timestamp
local schedule = require("lattice.schedule")
local tasks = require("lattice.tasks")

local function ts(raw)
  return assert(timestamp.parse(raw))
end

-- Next occurrence of `raw` completed at "YYYY-MM-DD[ HH:MM]", as Org text.
local function after(raw, completed)
  local date, time = completed:match("^(%S+)%s*(%S*)$")
  return schedule.format(schedule.next_occurrence(ts(raw), { date = date, time = time ~= "" and time or nil }))
end

-- Calendar ---------------------------------------------------------------------

test("day numbers round-trip and agree with weekdays", function()
  for _, date in ipairs({ "1970-01-01", "2000-02-29", "2026-11-02", "2028-12-31", "2100-03-01" }) do
    local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
    local n = schedule.day_number(tonumber(y), tonumber(m), tonumber(d))
    eq(("%04d-%02d-%02d"):format(schedule.from_day_number(n)), date)
  end
  eq(schedule.days("1970-01-01"), 0)
  eq(schedule.add_days("2026-12-28", 7), "2027-01-04")
  eq(schedule.add_days("2028-02-28", 1), "2028-02-29")
end)

test("format renders timestamps back to Org text", function()
  eq(schedule.format(ts("<2026-11-09 Mon 09:30 +1w -3d>")), "<2026-11-09 Mon 09:30 +1w -3d>")
  eq(schedule.format(ts("[2026-11-09 Mon 14:30]")), "[2026-11-09 Mon 14:30]")
  eq(schedule.format(ts("<2026-11-09>")), "<2026-11-09 Mon>")
end)

-- Repeaters (PAR-016..019) ----------------------------------------------------

test("PAR-016 weekly + repeater: one interval from the occurrence, on time, early or late", function()
  eq(after("<2026-11-09 Mon +1w>", "2026-11-09"), "<2026-11-16 Mon +1w>")
  eq(after("<2026-11-09 Mon +1w>", "2026-11-05"), "<2026-11-16 Mon +1w>") -- early
  -- Late: + catches up one interval at a time, so it can stay in the past.
  eq(after("<2026-11-09 Mon +1w>", "2026-11-25"), "<2026-11-16 Mon +1w>")
end)

test("PAR-017 monthly arithmetic is calendar based, with Org's month-end overflow", function()
  eq(after("<2026-11-30 Mon +1m>", "2026-11-30"), "<2026-12-30 Wed +1m>")
  eq(after("<2026-12-15 Tue +1m>", "2026-12-15"), "<2027-01-15 Fri +1m>") -- year rollover
  eq(after("<2026-01-31 Sat +1m>", "2026-01-31"), "<2026-03-03 Tue +1m>") -- Feb 31 overflows
  eq(after("<2028-01-31 Mon +1m>", "2028-01-31"), "<2028-03-02 Thu +1m>") -- leap February
  eq(after("<2028-02-29 Tue +1y>", "2028-02-29"), "<2029-03-01 Thu +1y>")
  eq(after("<2028-02-29 Tue +4y>", "2028-02-29"), "<2032-02-29 Sun +4y>")
end)

test("PAR-018 ++ repeater skips missed occurrences to the next future one", function()
  eq(after("<2026-11-12 Thu ++1m>", "2027-02-20"), "<2027-03-12 Fri ++1m>")
  eq(after("<2026-11-09 Mon ++1w>", "2026-11-25"), "<2026-11-30 Mon ++1w>")
  -- Always at least one interval, even when completed early or on the day.
  eq(after("<2026-11-12 Thu ++1m>", "2026-11-01"), "<2026-12-12 Sat ++1m>")
  eq(after("<2026-11-12 Thu ++1m>", "2026-11-12"), "<2026-12-12 Sat ++1m>")
  -- Missing several month-end occurrences does not drift the day.
  eq(after("<2026-01-31 Sat ++1m>", "2026-05-15"), "<2026-05-31 Sun ++1m>")
end)

test("PAR-019 .+ repeater counts from the completion date", function()
  eq(after("<2026-11-15 Sun .+1w>", "2026-11-20"), "<2026-11-27 Fri .+1w>")
  eq(after("<2026-11-15 Sun .+1w>", "2026-11-10"), "<2026-11-17 Tue .+1w>") -- early
  eq(after("<2026-11-15 Sun .+1m>", "2027-01-31"), "<2027-03-03 Wed .+1m>")
end)

test("time of day is preserved; hour repeaters roll over days", function()
  eq(after("<2026-11-09 Mon 09:30 +1w>", "2026-11-09"), "<2026-11-16 Mon 09:30 +1w>")
  eq(after("<2026-11-15 Sun 23:00 +2h>", "2026-11-15"), "<2026-11-16 Mon 01:00 +2h>")
  eq(after("<2026-11-15 Sun 08:00 .+2h>", "2026-11-20 13:45"), "<2026-11-20 Fri 15:45 .+2h>")
  eq(after("<2026-11-15 Sun 08:00 .+1d>", "2026-11-20 13:45"), "<2026-11-21 Sat 08:00 .+1d>")
  -- ++ with a time compares against the completion time.
  eq(after("<2026-11-09 Mon 09:30 ++1d>", "2026-11-09 08:00"), "<2026-11-10 Tue 09:30 ++1d>")
  eq(after("<2026-11-09 Mon 09:30 ++1d>", "2026-11-12 10:00"), "<2026-11-13 Fri 09:30 ++1d>")
end)

test("a warning period is kept when the timestamp moves", function()
  eq(after("<2026-11-09 Mon +1w -2d>", "2026-11-09"), "<2026-11-16 Mon +1w -2d>")
end)

test("no repeater, no next occurrence", function()
  eq(schedule.next_occurrence(ts("<2026-11-09 Mon>"), { date = "2026-11-09" }), nil)
end)

test("SCHEDULED and DEADLINE repeaters advance together, each by its own", function()
  local task = {
    scheduled = ts("<2026-11-09 Mon +1w>"),
    deadline = ts("<2026-11-11 Wed .+2d>"),
  }
  local changes = schedule.advance(task, { date = "2026-11-12" })
  eq({ changes.scheduled.raw, changes.deadline.raw }, { "<2026-11-16 Mon +1w>", "<2026-11-14 Sat .+2d>" })
  -- A timestamp without a repeater is left alone.
  local one = schedule.advance({ scheduled = ts("<2026-11-09 Mon +1w>"), deadline = ts("<2026-11-20 Fri>") }, { date = "2026-11-09" })
  eq({ one.scheduled.raw, one.deadline }, { "<2026-11-16 Mon +1w>", nil })
  eq(schedule.advance({ deadline = ts("<2026-11-20 Fri>") }, { date = "2026-11-09" }), nil)
end)

test("§15.3 recurrence fixture", function()
  local result = assert(tasks.parse({ "# Fuji", "## TODO Review monthly report", "SCHEDULED: <2026-11-12 Thu ++1m>" }, H.config.defaults()))
  local t = result.tasks[1]
  eq(t.recurrence, { kind = "++", n = 1, unit = "m" })
  local changes = schedule.advance(t, { date = "2026-11-12" })
  eq(changes.scheduled.raw, "<2026-12-12 Sat ++1m>")
end)

-- Deadlines and scheduling (PAR-020, PAR-021) ---------------------------------

test("PAR-020 deadline warning periods, Org's day conversion", function()
  eq(schedule.warning_days(ts("<2026-11-09 Mon -3d>"), 14), 3)
  eq(schedule.warning_days(ts("<2026-11-09 Mon -1w>"), 14), 7)
  eq(schedule.warning_days(ts("<2026-11-09 Mon -1m>"), 14), 30)
  eq(schedule.warning_days(ts("<2026-11-09 Mon>"), 14), 14)
  eq({ schedule.deadline_status("2026-11-09", "2026-11-06", 3) }, { "upcoming", 3 })
  eq({ schedule.deadline_status("2026-11-09", "2026-11-05", 3) }, { nil, 4 })
  eq({ schedule.deadline_status("2026-11-09", "2026-11-09", 3) }, { "today", 0 })
  eq({ schedule.deadline_status("2026-11-09", "2026-11-12", 3) }, { "overdue", -3 })
end)

test("PAR-021 an overdue scheduled task stays on the agenda", function()
  eq({ schedule.scheduled_status(ts("<2026-11-01 Sun>"), "2026-11-04") }, { "past", 3 })
  eq({ schedule.scheduled_status(ts("<2026-11-04 Wed>"), "2026-11-04") }, { "today", 0 })
  eq({ schedule.scheduled_status(ts("<2026-11-05 Thu>"), "2026-11-04") }, { "future", -1 })
  -- A -2d delay hides it for two days after its date.
  eq({ schedule.scheduled_status(ts("<2026-11-03 Tue -2d>"), "2026-11-04") }, { "delayed", 1 })
  eq({ schedule.scheduled_status(ts("<2026-11-03 Tue -2d>"), "2026-11-05") }, { "past", 2 })
end)
