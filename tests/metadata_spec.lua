-- Milestone B: planning lines, priorities, tags, properties, states,
-- projects and workflows (LATTICE_SYNTAX_SPEC §3.3–§7, §15; acceptance
-- tests PAR-007..014, PAR-025, PAR-028). Fictional volcanoes and people.
local H = require("helpers")
local test, eq, write, notes = H.test, H.eq, H.write, H.notes
local config, keywords, scanner, timestamp = H.config, H.keywords, H.scanner, H.timestamp
local tasks = require("lattice.tasks")

local function lines(text)
  return vim.split(text, "\n", { plain = true })
end

-- A config as .lattice.json would produce it.
local function cfg_from(raw)
  local root = notes()
  write(root, ".lattice.json", vim.json.encode(raw))
  return assert(config.load(root))
end

local WORKFLOWS = cfg_from({
  workflows = {
    default = { active = { "TODO", "NEXT", "WAITING" }, done = { "DONE", "CANCELED" } },
    etna = { active = { "BACKLOG", "READY", "IN PROGRESS", "BLOCKED" }, done = { "COMPLETE", "CANCELED" } },
    krakatoa = { active = { "TODO", "REVIEW", "APPROVED" }, done = { "DONE" } },
  },
})

local function parse(text, cfg)
  return assert(tasks.parse(lines(text), cfg or WORKFLOWS))
end

local function categories(result)
  return vim.tbl_map(function(d)
    return d.line .. " " .. d.category
  end, result.diagnostics)
end

-- §15 fixtures ------------------------------------------------------------------

test("§15.1 heading fixture", function()
  local r = parse(table.concat({
    "# Etna",
    "## TODO [#A] Review architecture :engineering:",
    "SCHEDULED: <2026-11-05 Thu>",
    "DEADLINE: <2026-11-09 Mon>",
    ":PROPERTIES:",
    ":ASSIGNED: Tavren Solis",
    ":END:",
  }, "\n"), cfg_from({ workflows = { etna = { active = { "TODO" }, done = { "DONE" } } } }))
  local t = r.tasks[1]
  eq({ t.project, t.kind, t.state, t.priority }, { "Etna", "heading", "TODO", "A" })
  eq({ t.scheduled.date, t.deadline.date }, { "2026-11-05", "2026-11-09" })
  eq(t.properties.ASSIGNED, "Tavren Solis")
  eq({ t.title, t.tags }, { "Review architecture", { "engineering" } })
  eq(r.diagnostics, {})
end)

test("§15.2 checkbox fixture", function()
  local r = parse(table.concat({
    "# Krakatoa",
    "- [ ] Review release checklist",
    "  SCHEDULED: <2026-11-06 Fri>",
    "  :PROPERTIES:",
    "  :STATE: REVIEW",
    "  :ASSIGNED: Elira Voss",
    "  :END:",
  }, "\n"))
  local t = r.tasks[1]
  eq({ t.project, t.kind, t.state, t.done, t.workflow }, { "Krakatoa", "checkbox", "REVIEW", false, "krakatoa" })
  eq({ t.scheduled.date, t.properties.ASSIGNED, t.person }, { "2026-11-06", "Elira Voss", "Elira Voss" })
  eq(r.diagnostics, {})
end)

-- Planning (PAR-007, PAR-008) -------------------------------------------------

test("PAR-007/008 planning lines on headings and checkboxes, several per line", function()
  local r = parse("## TODO Plan\nSCHEDULED: <2026-11-05 Thu 09:30> DEADLINE: <2026-11-09 Mon -3d>\n- [ ] Item\n  DEADLINE: <2026-11-10 Tue +1w>")
  eq({ r.tasks[1].scheduled.time, r.tasks[1].deadline.warning }, { "09:30", { n = 3, unit = "d", first = false } })
  eq(r.tasks[2].deadline.repeater, { kind = "+", n = 1, unit = "w" })
  eq(r.tasks[2].recurrence, { kind = "+", n = 1, unit = "w" })
  eq(r.tasks[1].due, "2026-11-09") -- the dashboard's date
end)

test("metadata is read only directly below the title", function()
  local r = parse("## TODO Plan\nSome prose.\nSCHEDULED: <2026-11-05 Thu>\n- [ ] Item\n\n  DEADLINE: <2026-11-09 Mon>")
  eq({ r.tasks[1].scheduled, r.tasks[2].deadline }, { nil, nil })
end)

test("metadata never attaches to a neighbouring or parent checkbox (§3.4)", function()
  local r = parse("- [ ] Parent\n  - [ ] Child\n    SCHEDULED: <2026-11-05 Thu>\n- [ ] Next\n  DEADLINE: <2026-11-09 Mon>")
  eq(vim.tbl_map(function(t)
    return { t.title, t.scheduled and t.scheduled.date or "-", t.deadline and t.deadline.date or "-" }
  end, r.tasks), { { "Parent", "-", "-" }, { "Child", "2026-11-05", "-" }, { "Next", "-", "2026-11-09" } })
end)

test("metadata inside fenced code is ignored", function()
  local r = parse("## TODO Plan\n```\nSCHEDULED: <2026-11-05 Thu>\n```")
  eq(r.tasks[1].scheduled, nil)
end)

test("closed timestamps are inactive", function()
  local r = parse("## DONE Shipped\nCLOSED: [2026-11-09 Mon 14:30]")
  eq({ r.tasks[1].closed.active, r.tasks[1].closed.time }, { false, "14:30" })
end)

test("invalid timestamps and wrong weekdays are diagnostics", function()
  local r = parse("## TODO A\nSCHEDULED: <2026-02-30 Mon>\n## TODO B\nDEADLINE: <2026-11-09 Fri>\n## TODO C\nSCHEDULED: <2026-11-05 Do>")
  eq(categories(r), { "2 invalid-timestamp", "4 weekday-mismatch" })
  assert(r.diagnostics[2].message:find("is a Mon, not Fri", 1, true), r.diagnostics[2].message)
end)

test("timestamp parser", function()
  local ts = assert(timestamp.parse("<2026-11-12 Thu ++1m>"))
  eq({ ts.date, ts.weekday, ts.repeater }, { "2026-11-12", "Thu", { kind = "++", n = 1, unit = "m" } })
  eq(assert(timestamp.parse("<2026-11-15 Sun .+1w --2d>")).warning, { n = 2, unit = "d", first = true })
  eq(select(2, timestamp.parse("<2026-11-15 Sun 25:00>")), "<2026-11-15 Sun 25:00> has an invalid time")
  eq(timestamp.parse("<2026-11-15 Sun"), nil)
  eq(timestamp.weekday(2028, 2, 29), "Tue")
end)

-- Priorities (PAR-009) --------------------------------------------------------

test("PAR-009 heading [#A] and checkbox :PRIORITY:", function()
  local r = parse("## TODO [#A] Resolve\n## TODO [#B] Review\n- [ ] Configure\n  :PROPERTIES:\n  :PRIORITY: C\n  :END:\n## TODO Organize")
  eq(vim.tbl_map(function(t)
    return (t.priority or "-") .. " " .. t.title
  end, r.tasks), { "A Resolve", "B Review", "C Configure", "- Organize" })
end)

test("a priority outside the configured values is a diagnostic", function()
  local r = parse("## TODO [#Z] Odd")
  eq({ r.tasks[1].priority, categories(r) }, { nil, { "1 invalid-priority" } })
  local cfg = cfg_from({ priorities = { values = { "1", "2", "3", "4" }, default = "3" } })
  eq(parse("## TODO [#4] Low", cfg).tasks[1].priority, "4")
end)

-- Tags (PAR-010, PAR-011) -----------------------------------------------------

test("PAR-010 heading tags and checkbox :TAGS:", function()
  local r = parse("## TODO Review deployment :etna:infrastructure:\n- [ ] Review\n  :PROPERTIES:\n  :TAGS: etna infrastructure\n  :END:")
  eq(r.tasks[1].tags, { "etna", "infrastructure" })
  eq(r.tasks[1].title, "Review deployment")
  eq(r.tasks[2].tags, { "etna", "infrastructure" })
end)

test("PAR-011 tags inherit from parent headings, kept apart from local ones", function()
  -- Fuji has no workflow of its own, so TODO applies (Etna's would not).
  local r = parse("# Fuji :engineering:\n## TODO Review architecture :design:\n- [ ] Sub :not-a-tag:\n### TODO Detail :engineering:")
  eq({ r.tasks[1].tags, r.tasks[1].inherited_tags }, { { "design" }, { "engineering" } })
  eq({ r.tasks[2].tags, r.tasks[2].inherited_tags, r.tasks[2].title }, { {}, { "engineering", "design" }, "Sub :not-a-tag:" })
  -- A tag set locally is not repeated as inherited.
  eq({ r.tasks[3].tags, r.tasks[3].inherited_tags }, { { "engineering" }, { "design" } })
  local off = cfg_from({ inherit = { tags = false } })
  eq(parse("# Fuji :engineering:\n## TODO A :design:", off).tasks[1].inherited_tags, {})
end)

-- Properties (PAR-012, PAR-013) -----------------------------------------------

test("PAR-012/013 drawers: any name, unknown ones kept, case-insensitive lookup", function()
  local r = parse("## TODO Review\n:PROPERTIES:\n:ID: etna-review-001\n:Effort: 2:00\n:custom_thing: kept as is\n:END:")
  local t = r.tasks[1]
  eq({ t.id, t.properties.EFFORT, t.property_names.EFFORT, t.properties.CUSTOM_THING }, { "etna-review-001", "2:00", "Effort", "kept as is" })
end)

test(":NAME+: appends, as in Org", function()
  local r = parse("## TODO A\n:PROPERTIES:\n:TAGS: one\n:TAGS+: two\n:END:")
  eq(r.tasks[1].properties.TAGS, "one two")
end)

test("malformed drawers are diagnostics", function()
  local r = parse("## TODO A\n:PROPERTIES:\nnot a property\n:END:\n## TODO B\n:PROPERTIES:\n:X: 1")
  eq(categories(r), { "3 malformed-drawer", "6 malformed-drawer" })
  eq(r.tasks[2].properties, {})
end)

test("configured properties inherit; PROJECT and WORKFLOW always do", function()
  local cfg = cfg_from({ inherit = { properties = { "assigned" } } })
  local r = parse("# Notes\n:PROPERTIES:\n:ASSIGNED: Tavren Solis\n:EFFORT: 1:00\n:END:\n## TODO A\n- [ ] B", cfg)
  eq({ r.tasks[1].person, r.tasks[2].person }, { "Tavren Solis", "Tavren Solis" })
  eq(r.tasks[1].inherited_properties, { ASSIGNED = "Tavren Solis" })
  eq(parse("# Notes\n:PROPERTIES:\n:ASSIGNED: Tavren Solis\n:END:\n## TODO A").tasks[1].person, nil)
end)

-- States (PAR-014, PAR-015, §3.3) ---------------------------------------------

test("a checkbox state comes from :STATE:, else the box", function()
  local r = parse("- [ ] Plain\n- [x] Done plain\n- [ ] Waits\n  :PROPERTIES:\n  :STATE: WAITING\n  :END:")
  eq(vim.tbl_map(function(t)
    return t.state .. (t.done and " x" or "")
  end, r.tasks), { "TODO", "DONE x", "WAITING" })
  eq(r.tasks[3].section, "waiting")
end)

test("PAR-014 an unknown state is a diagnostic, kept, and never counts as done", function()
  local r = parse("- [ ] Odd\n  :PROPERTIES:\n  :STATE: PONDERING\n  :END:\n## BACKLOG Not in this workflow")
  eq({ r.tasks[1].state, r.tasks[1].done }, { "PONDERING", false })
  eq(categories(r), { "1 unknown-state", "5 unknown-state" })
  eq(#r.tasks, 1)
end)

test(":STATE: disagreeing with an inline state, or with the box, is a diagnostic", function()
  local r = parse("- [ ] NEXT Thing\n  :PROPERTIES:\n  :STATE: WAITING\n  :END:\n- [x] Other\n  :PROPERTIES:\n  :STATE: NEXT\n  :END:")
  eq({ r.tasks[1].state, r.tasks[2].state, r.tasks[2].done }, { "WAITING", "NEXT", true })
  eq(categories(r), { "1 state-conflict", "5 state-conflict" })
end)

-- Projects and workflows (PAR-025, D2) ----------------------------------------

test("PAR-025 a project's workflow applies to its tasks", function()
  local r = parse("# Etna\n## IN PROGRESS Migrate cluster\n## READY Plan\n# Fuji\n## TODO Survey\n## READY Not a state here")
  eq(vim.tbl_map(function(t)
    return ("%s|%s|%s|%s"):format(t.project or "-", t.workflow, t.state, t.title)
  end, r.tasks), {
    "Etna|etna|IN PROGRESS|Migrate cluster",
    "Etna|etna|READY|Plan",
    "-|default|TODO|Survey",
  })
  eq(categories(r), { "6 unknown-state" })
end)

test("not every note has a project: an ordinary title is not one", function()
  local r = parse("# Meeting notes\n## TODO Follow up")
  eq({ r.tasks[1].project, r.tasks[1].workflow }, { nil, "default" })
end)

test(":PROJECT: and :WORKFLOW: properties, and front matter project:", function()
  local r = parse("# Notes\n:PROPERTIES:\n:PROJECT: Krakatoa\n:END:\n## REVIEW Checklist\n## TODO Other\n:PROPERTIES:\n:WORKFLOW: etna\n:END:")
  eq({ r.tasks[1].project, r.tasks[1].state }, { "Krakatoa", "REVIEW" })
  eq(#r.tasks, 1) -- "TODO" is not an etna state, so "## TODO Other" is organizational
  local fm = parse("---\nproject: Etna\n---\n- [ ] Plain box\n## BACKLOG Idea")
  eq({ fm.tasks[1].state, fm.tasks[2].state, fm.tasks[2].project }, { "BACKLOG", "BACKLOG", "Etna" })
end)

test("an unknown :WORKFLOW: falls back to the default with a diagnostic", function()
  local r = parse("## TODO A\n:PROPERTIES:\n:WORKFLOW: vesuvius\n:END:")
  eq({ r.tasks[1].workflow, categories(r) }, { "default", { "1 unknown-workflow" } })
end)

test("keywords_at reports the workflow in effect for cycling", function()
  local r = parse("# Etna\n- item")
  eq(r.keywords_at[2].first_open, "BACKLOG")
end)

-- Config ----------------------------------------------------------------------

test(".lattice.json workflows, priorities and inheritance are validated", function()
  local root = notes()
  local function load(raw)
    write(root, ".lattice.json", vim.json.encode(raw))
    local _, _, err = config.load(root)
    return err
  end
  assert(load({ workflows = { etna = { active = { "A|B" } } } }):find("not a valid state name", 1, true))
  assert(load({ workflows = { etna = { active = { "X" }, done = { "X" } } } }):find("both an active and a done", 1, true))
  assert(load({ workflows = { ["two words"] = { active = { "X" } } } }):find("single word", 1, true))
  assert(load({ todo = "A | B", workflows = { default = { active = { "X" } } } }):find("not both", 1, true))
  assert(load({ priorities = { values = { "AB" } } }):find("single letter", 1, true))
  assert(load({ priorities = { default = "Q" } }):find("not one of", 1, true))
  assert(load({ inherit = { tags = "yes" } }):find("true or false", 1, true))
  assert(load({ deadlines = { warning_days = -1 } }):find("whole number", 1, true))
  eq(load({ workflows = {} }), nil)
end)

test("the default workflow is the spec's, and todo still sets it", function()
  eq(config.defaults().workflows.default.sequences, { "TODO NEXT WAITING | DONE CANCELED" })
  eq(cfg_from({ todo = "ASK | ANSWERED" }).workflows.default.first_open, "ASK")
end)

-- Legacy v0.1 syntax (D3) -----------------------------------------------------

test("v0.1 forms still read, and are listed as legacy", function()
  local r = parse("## Waiting On\n- @Raju Estimate [due:2026-11-06]\n- [ ] @Asha Feedback [promised:2026-11-07]\n- TODO Mine [due:2026-11-08]")
  eq(vim.tbl_map(function(t)
    return ("%s|%s|%s|%s|%s"):format(t.section, t.state, t.person or "-", t.due or "-", t.promised or "-")
  end, r.tasks), {
    "waiting|WAITING|Raju|2026-11-06|-",
    "waiting|WAITING|Asha|-|2026-11-07",
    "waiting|TODO|-|2026-11-08|-",
  })
  local forms = vim.tbl_map(function(e)
    return e.line .. " " .. e.form
  end, r.legacy)
  assert(vim.tbl_contains(forms, "2 @Name"), vim.inspect(forms))
  assert(vim.tbl_contains(forms, "2 [due:]"), vim.inspect(forms))
  assert(vim.tbl_contains(forms, "3 [promised:]"), vim.inspect(forms))
end)

test("a DEADLINE wins over a v0.1 [due:] date", function()
  local r = parse("- [ ] Thing [due:2026-11-01]\n  DEADLINE: <2026-11-09 Mon>")
  eq(r.tasks[1].due, "2026-11-09")
end)

-- Duplicate IDs (PAR-028) -----------------------------------------------------

test("PAR-028 duplicate :ID: in one note and across notes", function()
  local r = parse("## TODO A\n:PROPERTIES:\n:ID: x1\n:END:\n## TODO B\n:PROPERTIES:\n:ID: x1\n:END:")
  eq(categories(r), { "5 duplicate-id" })
  local root = notes()
  write(root, "a.md", "## TODO A\n:PROPERTIES:\n:ID: shared\n:END:\n")
  write(root, "b.md", "- [ ] B\n  :PROPERTIES:\n  :ID: shared\n  :END:\n")
  local result = scanner.collect(root)
  local dupes = vim.tbl_filter(function(w)
    return w.category == "duplicate-id"
  end, result.warnings)
  eq(#dupes, 1)
  eq({ dupes[1].rel, dupes[1].line }, { "b.md", 1 })
  assert(dupes[1].message:find("a.md:1", 1, true), dupes[1].message)
end)

test("scanning leaves the note untouched", function()
  local root = notes()
  local text = "## TODO [#A] x :t:\nSCHEDULED: <2026-11-05 Fri>\n:PROPERTIES:\n:STATE: odd\n"
  local path = write(root, "a.md", text)
  scanner.collect(root)
  eq(H.read(path), text)
end)

test("examples/sample-notes.md parses as its comments describe, with no warnings", function()
  local root = H.repo .. "/examples"
  local cfg = assert(config.load(root))
  local result = assert(tasks.parse(vim.fn.readfile(root .. "/sample-notes.md"), cfg))
  eq(vim.tbl_map(function(t)
    return ("%d %s %s%s %s %s"):format(t.line, t.project or "-", t.state, t.done and " x" or "", t.priority or "-", t.due or "-")
  end, result.tasks), {
    "12 Etna IN PROGRESS A 2026-11-05",
    "17 Etna COMPLETE x - -",
    "18 Etna BACKLOG - -",
    "21 Etna BLOCKED - -",
    "25 Krakatoa REVIEW B 2026-10-30",
    "36 - TODO - -",
    "37 - WAITING - 2026-11-06",
    "43 - WAITING - -",
    "50 - DONE x - -",
    "51 - CANCELED x - -",
  })
  eq(result.tasks[3].parent, 1) -- a checkbox under a heading task
  eq(result.tasks[1].inherited_tags, { "engineering" })
  eq(result.diagnostics, {})
  eq(result.legacy, {})
end)
