-- Milestone D: the mutation layer (LATTICE_SYNTAX_SPEC §4.3, §4.4, §10.3,
-- §11.4, §11.5, §14, Amendment 1; acceptance tests PAR-022..024, PAR-026,
-- PAR-027). Fictional volcanoes and people.
local H = require("helpers")
local test, eq, write, notes = H.test, H.eq, H.write, H.notes
local config = H.config
local mutate = require("lattice.mutate")

local NOW = { date = "2026-11-09", time = "14:30" }

local function L(text)
  return vim.split(text, "\n", { plain = true })
end

local function T(lines)
  return table.concat(lines, "\n")
end

local function cfg_from(raw)
  local root = notes()
  write(root, ".lattice.json", vim.json.encode(raw or {}))
  return assert(config.load(root))
end

local DEFAULT = config.defaults()

local function state(text, line, new, cfg)
  local out, message = mutate.set_state(L(text), cfg or DEFAULT, line, new, NOW)
  return out and T(out), message
end

-- States (§4.3, §4.4) ---------------------------------------------------------

test("PAR-024 set_state replaces the keyword and keeps priority and tags", function()
  eq(state("## TODO [#A] Draft plan :etna:", 1, "NEXT"), "## NEXT [#A] Draft plan :etna:")
  eq(state("## Draft plan", 1, "TODO"), "## TODO Draft plan")
  eq(state("## TODO Draft plan", 1, ""), "## Draft plan")
  local _, err = state("## TODO Draft", 1, "BOGUS")
  assert(err:find("not a state", 1, true), err)
end)

test("completing adds CLOSED only when logging.done is \"time\" (Org's org-log-done)", function()
  eq(state("## TODO Ship\nbody", 1, "DONE"), "## DONE Ship\nbody")
  local cfg = cfg_from({ logging = { done = "time" } })
  eq(state("## TODO Ship\nDEADLINE: <2026-11-10 Tue>\nbody", 1, "DONE", cfg), "## DONE Ship\nCLOSED: [2026-11-09 Mon 14:30] DEADLINE: <2026-11-10 Tue>\nbody")
  eq(state("## TODO Ship\nbody", 1, "CANCELED", cfg), "## CANCELED Ship\nCLOSED: [2026-11-09 Mon 14:30]\nbody")
end)

test("reopening removes CLOSED, keeping other planning entries", function()
  eq(state("## DONE Ship\nCLOSED: [2026-11-01 Sun 10:00] DEADLINE: <2026-11-10 Tue>", 1, "TODO"), "## TODO Ship\nDEADLINE: <2026-11-10 Tue>")
  eq(state("## DONE Ship\nCLOSED: [2026-11-01 Sun 10:00]\nbody", 1, "TODO"), "## TODO Ship\nbody")
  -- Moving between two done states keeps it.
  eq(state("## DONE Ship\nCLOSED: [2026-11-01 Sun 10:00]", 1, "CANCELED"), "## CANCELED Ship\nCLOSED: [2026-11-01 Sun 10:00]")
end)

test("completing a repeating task advances it and keeps it open (§10.3)", function()
  local out, message = state(table.concat({
    "## NEXT Review metrics",
    "SCHEDULED: <2026-11-09 Mon +1w>",
    "Notes.",
  }, "\n"), 1, "DONE")
  eq(out, table.concat({
    "## NEXT Review metrics",
    "SCHEDULED: <2026-11-16 Mon +1w>",
    ":PROPERTIES:",
    ":LAST_REPEAT: [2026-11-09 Mon 14:30]",
    ":END:",
    '- State "DONE"       from "NEXT"       [2026-11-09 Mon 14:30]',
    "Notes.",
  }, "\n"))
  eq(message, "repeats: next on 2026-11-16, state back to NEXT")
end)

test("repeating: both timestamps advance, no CLOSED, logging and repeat_to_state are configurable", function()
  local cfg = cfg_from({ logging = { done = "time", ["repeat"] = false }, repeat_to_state = "TODO" })
  eq(state("## WAITING Report\nDEADLINE: <2026-11-11 Wed ++1m> SCHEDULED: <2026-11-09 Mon .+2d>", 1, "DONE", cfg),
    "## TODO Report\nDEADLINE: <2026-12-11 Fri ++1m> SCHEDULED: <2026-11-11 Wed .+2d>")
  -- From a non-open state (none), a repeating task returns to the first active state.
  eq(state("## Report\nSCHEDULED: <2026-11-09 Mon +1d>", 1, "DONE", cfg_from({ logging = { ["repeat"] = false } })),
    "## TODO Report\nSCHEDULED: <2026-11-10 Tue +1d>")
end)

test("a stale or repeated completion is refused, so a repeater never double-advances", function()
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  local before = L("## TODO Review\nSCHEDULED: <2026-11-09 Mon +1w>")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, before)
  local after = assert(mutate.set_state(before, cfg_from({ logging = { ["repeat"] = false } }), 1, "DONE", NOW))
  assert(mutate.apply(buf, before, after))
  local ok, err = mutate.apply(buf, before, after)
  eq(ok, nil)
  assert(err:find("changed since", 1, true), err)
  eq(T(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), "## TODO Review\nSCHEDULED: <2026-11-16 Mon +1w>")
end)

test("enforce.checkboxes and enforce.todo block completion while steps are open", function()
  local cfg = cfg_from({ enforce = { checkboxes = true, todo = true } })
  local _, err = state("## TODO Release [1/2]\n- [x] Tests\n- [ ] Docs", 1, "DONE", cfg)
  assert(err:find("1 of 2 checkboxes are unchecked", 1, true), err)
  _, err = state("## TODO Release\n### TODO Docs", 1, "DONE", cfg)
  assert(err:find('subtask "Docs" is still open', 1, true), err)
  eq(state("## TODO Release\n- [x] Tests", 1, "DONE", cfg), "## DONE Release\n- [x] Tests")
  -- Off by default, as in Org.
  eq(state("## TODO Release\n- [ ] Docs", 1, "DONE"), "## DONE Release\n- [ ] Docs")
end)

test("a parent heading's subtask cookie follows its children's states", function()
  eq(state("## TODO Release [0/2]\n### TODO Tests\n### TODO Docs", 2, "DONE"), "## TODO Release [1/2]\n### DONE Tests\n### TODO Docs")
  eq(state("## TODO Release [50%]\n### DONE Tests\n### TODO Docs", 3, "DONE"), "## TODO Release [100%]\n### DONE Tests\n### DONE Docs")
end)

-- Checkboxes and cookies (PAR-022, PAR-023, §11.4, §11.5) ---------------------

local function toggle(text, line)
  local out, err = mutate.toggle_checkbox(L(text), line, DEFAULT)
  return out and T(out) or err
end

test("toggling writes Markdown's [x] and back", function()
  eq(toggle("- [ ] Task", 1), "- [x] Task")
  eq(toggle("- [X] Task", 1), "- [ ] Task")
  eq(toggle("1. [ ] Numbered", 1), "1. [x] Numbered")
  eq(toggle("- no box", 1), "no checkbox on this line")
end)

test("PAR-022 cookies on the item and the heading are recalculated", function()
  eq(toggle("## TODO Release [0/2]\n- [ ] Tests\n- [ ] Docs", 2), "## TODO Release [1/2]\n- [x] Tests\n- [ ] Docs")
  eq(toggle("## TODO Release [33%]\n- [x] A\n- [ ] B\n- [ ] C", 3), "## TODO Release [66%]\n- [x] A\n- [x] B\n- [ ] C")
  eq(toggle("- [ ] Validate [/]\n  - [ ] Unit\n  - [ ] Integration", 2), "- [-] Validate [1/2]\n  - [x] Unit\n  - [ ] Integration")
end)

test("PAR-023 parent boxes follow their children: [-] for some, [x] for all", function()
  local text = "- [ ] Release\n  - [x] Tests\n  - [ ] Docs"
  eq(toggle(text, 3), "- [x] Release\n  - [x] Tests\n  - [x] Docs")
  eq(toggle("- [x] Release\n  - [x] Tests\n  - [x] Docs", 2), "- [-] Release\n  - [ ] Tests\n  - [x] Docs")
  eq(toggle("- [-] Release\n  - [ ] Tests\n  - [x] Docs", 3), "- [ ] Release\n  - [ ] Tests\n  - [ ] Docs")
  -- Toggling a parent sets its children, then nothing contradicts it.
  eq(toggle("- [-] Release\n  - [ ] Tests\n  - [x] Docs\n    - [ ] Deep", 1), "- [x] Release\n  - [x] Tests\n  - [x] Docs\n    - [x] Deep")
end)

test("heading states never change because of their checkboxes", function()
  eq(toggle("## TODO Release\n- [ ] Only step", 2), "## TODO Release\n- [x] Only step")
end)

test("unrelated cookies elsewhere in the note are left as written", function()
  eq(toggle("## TODO A [9/9]\n- [ ] x\n## TODO B [0/1]\n- [ ] y", 4), "## TODO A [9/9]\n- [ ] x\n## TODO B [1/1]\n- [x] y")
end)

-- Planning, properties, priority ---------------------------------------------

test("set_planning joins Org's order, replaces, removes, and drops empty lines", function()
  local function plan(text, keyword, raw)
    return T(assert(mutate.set_planning(L(text), 1, keyword, raw)))
  end
  eq(plan("## TODO A\nbody", "SCHEDULED", "<2026-11-05 Thu>"), "## TODO A\nSCHEDULED: <2026-11-05 Thu>\nbody")
  eq(plan("## TODO A\nSCHEDULED: <2026-11-05 Thu>", "DEADLINE", "<2026-11-09 Mon>"), "## TODO A\nDEADLINE: <2026-11-09 Mon> SCHEDULED: <2026-11-05 Thu>")
  eq(plan("## TODO A\nDEADLINE: <2026-11-09 Mon> SCHEDULED: <2026-11-05 Thu>", "SCHEDULED", "<2026-11-06 Fri +1w>"), "## TODO A\nDEADLINE: <2026-11-09 Mon> SCHEDULED: <2026-11-06 Fri +1w>")
  eq(plan("## TODO A\nDEADLINE: <2026-11-09 Mon> SCHEDULED: <2026-11-05 Thu>", "DEADLINE", nil), "## TODO A\nSCHEDULED: <2026-11-05 Thu>")
  eq(plan("## TODO A\nSCHEDULED: <2026-11-05 Thu>\nbody", "SCHEDULED", nil), "## TODO A\nbody")
  -- After the blank line a Markdown formatter adds (D15).
  eq(plan("## TODO A\n\nSCHEDULED: <2026-11-05 Thu>", "SCHEDULED", "<2026-11-07 Sat>"), "## TODO A\n\nSCHEDULED: <2026-11-07 Sat>")
end)

test("set_property creates, updates (keeping spelling) and removes drawer entries", function()
  local function prop(text, name, value)
    return T(assert(mutate.set_property(L(text), 1, name, value)))
  end
  eq(prop("## TODO A\nSCHEDULED: <2026-11-05 Thu>\nbody", "ASSIGNED", "Elira Voss"), "## TODO A\nSCHEDULED: <2026-11-05 Thu>\n:PROPERTIES:\n:ASSIGNED: Elira Voss\n:END:\nbody")
  eq(prop("## TODO A\n:PROPERTIES:\n:Assigned: Old\n:Effort: 1:00\n:END:", "assigned", "Tavren Solis"), "## TODO A\n:PROPERTIES:\n:Assigned: Tavren Solis\n:Effort: 1:00\n:END:")
  eq(prop("## TODO A\n:PROPERTIES:\n:X: 1\n:END:", "Y", "2"), "## TODO A\n:PROPERTIES:\n:X: 1\n:Y: 2\n:END:")
  eq(prop("## TODO A\n:PROPERTIES:\n:X: 1\n:END:\nbody", "X", nil), "## TODO A\nbody")
end)

test("priority cycles like Org's S-Up / S-Down", function()
  local function shift(text, direction, cfg)
    return T(assert(mutate.shift_priority(L(text), cfg or DEFAULT, 1, direction)))
  end
  eq(shift("## TODO Plan", 1), "## TODO [#B] Plan") -- starts at the default
  eq(shift("## TODO [#B] Plan", 1), "## TODO [#A] Plan")
  eq(shift("## TODO [#A] Plan", 1), "## TODO Plan") -- past the highest: removed
  eq(shift("## TODO [#C] Plan", -1), "## TODO Plan")
  eq(shift("## [#B] Notes :x:", -1), "## [#C] Notes :x:")
  local cfg = cfg_from({ priorities = { values = { "1", "2", "3", "4" }, default = "3" } })
  eq(shift("## TODO Plan", -1, cfg), "## TODO [#3] Plan")
end)

test("read_date understands dates, today, tomorrow, +N and a time", function()
  local read = H.insert.read_date
  eq(read("2026-11-20", "2026-11-09"), { date = "2026-11-20" })
  eq(read("tomorrow", "2026-11-09"), { date = "2026-11-10" })
  eq(read("+2w", "2026-11-09"), { date = "2026-11-23" })
  eq(read("+1m 9:05", "2026-01-31"), { date = "2026-03-03", time = "09:05" })
  eq(read("today 25:00", "2026-11-09"), nil)
  eq(read("next week", "2026-11-09"), nil)
end)

-- Migration (plan D3) ---------------------------------------------------------

test(":LatticeMigrate turns v0.1 items into Org headings", function()
  local out, count = mutate.migrate(L(table.concat({
    "# Review",
    "- TODO Prepare plan",
    "- NEXT Send update [due:2026-11-05]",
    "  - detail",
    "",
    "## Waiting On",
    "- @Raju Provide estimate [due:2026-11-06]",
    "- [ ] @Asha Feedback [promised:2026-11-07]",
    "- [x] Old thing",
    "",
    "## NEXT Draft Q1 [due:2026-11-20]",
  }, "\n")), DEFAULT)
  eq(count, 6)
  eq(T(out), table.concat({
    "# Review",
    "",
    "## TODO Prepare plan",
    "",
    "## NEXT Send update",
    "DEADLINE: <2026-11-05 Thu>",
    "- detail",
    "",
    "## Waiting On",
    "",
    "### WAITING Provide estimate",
    "DEADLINE: <2026-11-06 Fri>",
    ":PROPERTIES:",
    ":ASSIGNED: Raju",
    ":END:",
    "",
    "### WAITING Feedback",
    ":PROPERTIES:",
    ":ASSIGNED: Asha",
    ":PROMISED: 2026-11-07",
    ":END:",
    "",
    "### DONE Old thing",
    "",
    "## NEXT Draft Q1",
    "DEADLINE: <2026-11-20 Fri>",
  }, "\n"))
  local after = assert(H.parser.parse(out, DEFAULT))
  eq(after.legacy, {})
  eq(after.warnings, {})
end)

test("migrating the v0.1 example keeps every task, person and date", function()
  local lines = vim.fn.readfile(H.repo .. "/examples/legacy-v0.1-notes.md")
  local before = assert(H.parser.parse(lines, DEFAULT))
  local out = assert(mutate.migrate(lines, DEFAULT))
  local after = assert(H.parser.parse(out, DEFAULT))
  local function facts(result)
    local list = vim.tbl_map(function(t)
      return ("%s|%s|%s|%s|%s|%s"):format(t.state, t.title, t.done and "x" or "-", t.person or "", t.due or "", t.promised or "")
    end, result.tasks)
    table.sort(list)
    return list
  end
  eq(facts(after), facts(before))
  eq(after.legacy, {})
  eq(after.warnings, {})
  -- Nothing to do the second time.
  eq(select(2, mutate.migrate(out, DEFAULT)), 0)
end)

-- Applying (PAR-026, PAR-027) -------------------------------------------------

test("PAR-026 only changed lines are written; marks on other lines stay put", function()
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  local before = L("## TODO A [0/1]\nkeep me\n- [ ] step\ntail")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, before)
  local ns = vim.api.nvim_create_namespace("lattice-test")
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, 1, 2, {})
  local after = assert(mutate.toggle_checkbox(before, 3, DEFAULT))
  eq(mutate.apply(buf, before, after), 2) -- the heading's cookie and the box
  eq(vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {}), { 1, 2 })
  eq(T(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), "## TODO A [1/1]\nkeep me\n- [x] step\ntail")
end)

test("PAR-027 edits go to the unsaved buffer, never the file, as one undo step", function()
  local root = notes()
  local path = write(root, "a.md", "## TODO A\n- [ ] one\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "unsaved line" }) -- the user's own unsaved edit
  vim.cmd("let &undolevels = &undolevels")
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local after = assert(mutate.set_state(before, cfg_from({ logging = { done = "time" } }), 1, "DONE", NOW))
  assert(mutate.apply(buf, before, after))
  eq(T(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), "## DONE A\nCLOSED: [2026-11-09 Mon 14:30]\nunsaved line\n- [ ] one")
  eq(H.read(path), "## TODO A\n- [ ] one\n")
  vim.cmd("silent undo")
  eq(T(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), "## TODO A\nunsaved line\n- [ ] one")
  vim.cmd("bwipeout!")
end)
