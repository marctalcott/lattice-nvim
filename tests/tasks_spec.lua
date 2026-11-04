-- Milestone A: Markdown structure, task identification, hierarchy
-- (LATTICE_SYNTAX_SPEC §3, §11, §13; acceptance tests PAR-001..006).
-- Fixtures are fictional: volcano projects, invented people.
local H = require("helpers")
local test, eq = H.test, H.eq
local config, keywords = H.config, H.keywords
local markdown = require("lattice.markdown")
local tasks = require("lattice.tasks")

local function lines(text)
  return vim.split(text, "\n", { plain = true })
end

local DEFAULT = assert(keywords.build({ "TODO NEXT WAITING | DONE CANCELED" }))

local function parse(text, kws)
  local cfg = config.defaults()
  cfg.keywords = kws or DEFAULT
  return assert(tasks.parse(lines(text), cfg))
end

-- "kind STATE title" for each task, in source order.
local function summary(result)
  return vim.tbl_map(function(task)
    return ("%s %s %s"):format(task.kind, task.state or "-", task.title)
  end, result.tasks)
end

-- Each task's parent title ("" at the top), in source order.
local function parents(result)
  return vim.tbl_map(function(task)
    return task.parent and result.tasks[task.parent].title or ""
  end, result.tasks)
end

-- Structure -------------------------------------------------------------------

test("structure: headings carry level, text and section range", function()
  local s = assert(markdown.parse(lines("# Etna\ntext\n## TODO Review ##\nmore\n# Fuji")))
  eq(#s.headings, 3)
  eq({ s.headings[1].line, s.headings[1].level, s.headings[1].text, s.headings[1].stop }, { 1, 1, "Etna", 4 })
  eq({ s.headings[2].line, s.headings[2].level, s.headings[2].text, s.headings[2].stop }, { 3, 2, "TODO Review", 4 })
  eq(s.headings[2].parent, 1)
  eq(s.headings[3].parent, nil)
end)

test("structure: list items carry marker, checkbox, text and nesting", function()
  local s = assert(markdown.parse(lines("- [ ] One\n  - [X] Two\n1. [ ] Three\n* plain")))
  eq(#s.items, 4)
  eq({ s.items[1].marker, s.items[1].checkbox, s.items[1].text, s.items[1].stop }, { "-", " ", "One", 2 })
  eq({ s.items[2].checkbox, s.items[2].parent, s.items[2].col }, { "X", 1, 2 })
  eq({ s.items[3].marker, s.items[3].ordered, s.items[3].checkbox }, { "1.", true, " " })
  eq({ s.items[4].checkbox, s.items[4].text }, { nil, "plain" })
end)

test("structure: front matter is recognized and is not content", function()
  local s = assert(markdown.parse(lines("---\ntitle: x\n---\n# Etna")))
  eq(s.front_matter, 3)
  eq(#s.headings, 1)
end)

-- Identification (PAR-001, PAR-002, PAR-006) ----------------------------------

test("PAR-001 heading TODO", function()
  local r = parse("# Etna\n## TODO Review system architecture\n### NEXT Prepare proposal\n### DONE Document requirements")
  eq(summary(r), {
    "heading TODO Review system architecture",
    "heading NEXT Prepare proposal",
    "heading DONE Document requirements",
  })
  eq(r.tasks[1].level, 2)
  eq(r.tasks[3].done, true)
  eq(r.tasks[1].source, { start_line = 2, end_line = 4 })
end)

test("a heading without a state is organizational, not a task", function()
  eq(summary(parse("# Etna\n## Notes\n## todo lowercase\n## TODOS plural")), {})
end)

test("PAR-002 checkbox tasks, every marker form", function()
  local r = parse("- [ ] Review configuration\n* [x] Complete documentation\n+ [X] Upper\n1. [ ] Numbered\n2) [ ] Paren")
  eq(summary(r), {
    "checkbox TODO Review configuration",
    "checkbox DONE Complete documentation",
    "checkbox DONE Upper",
    "checkbox TODO Numbered",
    "checkbox TODO Paren",
  })
  eq({ r.tasks[1].done, r.tasks[2].done, r.tasks[3].done }, { false, true, true })
  eq(r.tasks[4].ordered, true)
end)

test("a checkbox may carry an inline state (Extended)", function()
  local r = parse("- [ ] WAITING Reply from Tavren Solis\n- [x] CANCELED Old plan")
  eq(summary(r), { "checkbox WAITING Reply from Tavren Solis", "checkbox CANCELED Old plan" })
  eq(r.diagnostics, {})
end)

test("a keyword bullet without a box is still a task (Extended)", function()
  local r = parse("- TODO Send update\n- DONE Shipped\n- plain bullet")
  eq(summary(r), { "checkbox TODO Send update", "checkbox DONE Shipped" })
  eq({ r.tasks[1].checkbox, r.tasks[2].done }, { nil, true })
end)

test("PAR-015 checkbox and state conflict is a diagnostic; the box decides completion", function()
  local r = parse("- [x] TODO Checked but open\n- [ ] DONE Unchecked but done")
  eq({ r.tasks[1].done, r.tasks[2].done }, { true, false })
  eq(#r.diagnostics, 2)
  eq({ r.diagnostics[1].line, r.diagnostics[1].category }, { 1, "state-conflict" })
  assert(r.diagnostics[2].message:find("unchecked", 1, true), r.diagnostics[2].message)
end)

test("PAR-006 fenced and indented code produce no tasks", function()
  local r = parse("```\n- [ ] in fence\n## TODO in fence\n```\n\n    - [ ] indented code\n~~~md\n- TODO tilde\n~~~\n- [ ] real")
  eq(summary(r), { "checkbox TODO real" })
end)

test("multi-word states match longest first", function()
  local kws = assert(keywords.build({ "IN | DONE", "BACKLOG READY IN_PROGRESS | COMPLETE" }))
  kws.states["IN PROGRESS"] = "open" -- multi-word states arrive with .lattice.json workflows
  local r = parse("## IN PROGRESS Migrate cluster\n## IN Draft", kws)
  eq(summary(r), { "heading IN PROGRESS Migrate cluster", "heading IN Draft" })
end)

test("front matter todo: still sets the note's states", function()
  local r = parse("---\ntodo: ASK | ANSWERED\n---\n- ASK Headcount\n- TODO not a state here")
  eq(summary(r), { "checkbox ASK Headcount" })
end)

-- Hierarchy (PAR-003, PAR-004, PAR-005, §15.4) ---------------------------------

test("PAR-003 nested headings: subtree runs to the next heading of equal or higher level", function()
  local r = parse("# Fuji\n## TODO Prepare release\n### TODO Complete tests\n### TODO Review documentation\n## TODO Next thing")
  eq(parents(r), { "", "Prepare release", "Prepare release", "" })
  eq(r.tasks[1].children, { 2, 3 })
  eq(r.tasks[1].source.end_line, 4)
end)

test("an organizational heading between tasks is skipped in the tree", function()
  local r = parse("## TODO Outer\n### Notes\n- [ ] inner")
  eq(parents(r), { "", "Outer" })
end)

test("PAR-004 nested checkboxes follow list structure, any indent width", function()
  local r = parse("- [ ] Prepare release\n    - [x] Complete tests\n    - [ ] Review documentation\n        - [ ] Deep")
  eq(parents(r), { "", "Prepare release", "Prepare release", "Review documentation" })
  eq(r.tasks[1].source.end_line, 4)
end)

test("a plain bullet between checkboxes is looked through", function()
  local r = parse("- [ ] Parent\n  - grouping text\n    - [ ] Grandchild")
  eq(parents(r), { "", "Parent" })
end)

test("PAR-005 mixed hierarchy, and the §15.4 fixture", function()
  local r = parse(table.concat({
    "# Vesuvius",
    "## TODO Prepare release",
    "- [ ] Complete validation [1/2]",
    "  - [x] Review unit tests",
    "  - [ ] Review integration tests",
    "- [ ] Prepare documentation",
  }, "\n"))
  eq(summary(r), {
    "heading TODO Prepare release",
    "checkbox TODO Complete validation [1/2]",
    "checkbox DONE Review unit tests",
    "checkbox TODO Review integration tests",
    "checkbox TODO Prepare documentation",
  })
  eq(parents(r), { "", "Prepare release", "Complete validation [1/2]", "Complete validation [1/2]", "Prepare release" })
  eq(r.tasks[2].children, { 3, 4 })
  eq(r.tasks[2].done, false)
end)

test("metadata lines stay inside their own item (§3.4 ownership)", function()
  local r = parse(table.concat({
    "- [ ] First",
    "  SCHEDULED: <2026-11-05 Thu>",
    "  :PROPERTIES:",
    "  :ASSIGNED: Tavren Solis",
    "  :END:",
    "- [ ] Second",
  }, "\n"))
  eq({ r.tasks[1].source, r.tasks[2].source }, { { start_line = 1, end_line = 5 }, { start_line = 6, end_line = 6 } })
end)

test("parsing is deterministic", function()
  local text = "# Etna\n## TODO A\n- [ ] b\n  - [x] c\n## NEXT d"
  eq(parse(text), parse(text))
end)
