-- Milestone A: Markdown structure, task identification, hierarchy
-- (LATTICE_SYNTAX_SPEC §3, §11, §13 with Amendment 1, strict Org:
-- only headings are tasks; checkboxes are sub-steps that count toward
-- progress). Acceptance tests PAR-001..006.
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
  cfg.workflows = { default = cfg.keywords }
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

test("PAR-002 checkboxes are not tasks in Org; they count toward the heading's progress", function()
  local r = parse("## TODO Release [1/3]\n- [ ] Review configuration\n* [x] Complete documentation\n1. [ ] Numbered\n   - [x] nested, not counted")
  eq(summary(r), { "heading TODO Release [1/3]" })
  eq(r.tasks[1].progress, { done = 1, total = 3, of = "checkboxes" })
  eq(r.tasks[1].cookie, { kind = "fraction", text = "[1/3]" })
end)

test("a heading with no checkboxes counts its child TODO headings", function()
  local r = parse("## TODO Release [33%]\n### DONE Tests\n### TODO Docs\n### NEXT Notes\n#### DONE Deeper, not counted")
  eq(r.tasks[1].progress, { done = 1, total = 3, of = "subtasks" })
  eq(r.tasks[1].cookie, { kind = "percent", text = "[33%]" })
end)

test("Org's partly checked box [-] counts as unchecked", function()
  local r = parse("## TODO A\n- [-] partly\n  - [x] one\n  - [ ] two\n- [X] done")
  eq(r.tasks[1].progress, { done = 1, total = 2, of = "checkboxes" })
  eq(assert(markdown.parse(lines("- [-] partly"))).items[1].checkbox, "-")
end)

test("plain checkboxes outside a task heading are ordinary list items", function()
  eq(summary(parse("# Notes\n- [ ] Buy milk\n- [x] Done thing")), {})
end)

test("Lattice v0.1 keyword bullets still read, as legacy items", function()
  local r = parse("- TODO Send update\n- [ ] NEXT Boxed\n- DONE Shipped\n- [x] TODO Checked\n1. TODO Numbered is not one\n- plain bullet")
  eq(summary(r), { "item TODO Send update", "item NEXT Boxed", "item DONE Shipped", "item TODO Checked" })
  -- v0.1 rules: a done state or a checked box means done.
  eq(vim.tbl_map(function(t)
    return t.done
  end, r.tasks), { false, false, true, true })
  eq(#r.legacy, 4)
  eq(r.diagnostics, {})
end)

test("PAR-006 fenced and indented code produce no tasks", function()
  local r = parse("```\n## TODO in fence\n- TODO fenced bullet\n```\n\n    ## TODO indented code\n~~~md\n## TODO tilde\n~~~\n## TODO real")
  eq(summary(r), { "heading TODO real" })
end)

test("multi-word states match longest first", function()
  local kws = assert(keywords.from_workflow({ active = { "IN", "IN PROGRESS" }, done = { "DONE" } }))
  local r = parse("## IN PROGRESS Migrate cluster\n## IN Draft", kws)
  eq(summary(r), { "heading IN PROGRESS Migrate cluster", "heading IN Draft" })
end)

test("front matter todo: still sets the note's states", function()
  local r = parse("---\ntodo: ASK | ANSWERED\n---\n## ASK Headcount\n## TODO not a state here")
  eq(summary(r), { "heading ASK Headcount" })
end)

-- Hierarchy (PAR-003, PAR-004, PAR-005, §15.4) ---------------------------------

test("PAR-003 nested headings: subtree runs to the next heading of equal or higher level", function()
  local r = parse("# Fuji\n## TODO Prepare release\n### TODO Complete tests\n### TODO Review documentation\n## TODO Next thing")
  eq(parents(r), { "", "Prepare release", "Prepare release", "" })
  eq(r.tasks[1].children, { 2, 3 })
  eq(r.tasks[1].source.end_line, 4)
end)

test("an organizational heading between tasks is skipped in the tree", function()
  local r = parse("## TODO Outer\n### Notes\n#### TODO inner")
  eq(parents(r), { "", "Outer" })
end)

test("PAR-004 checkbox nesting follows list structure, any indent width", function()
  local s = assert(markdown.parse(lines("- [ ] Prepare release\n    - [x] Complete tests\n    - [ ] Review documentation\n        - [ ] Deep")))
  eq(vim.tbl_map(function(item)
    return item.parent or 0
  end, s.items), { 0, 1, 1, 3 })
  eq(s.items[1].stop, 4)
end)

test("PAR-005 mixed hierarchy: the §15.4 fixture under strict Org", function()
  local r = parse(table.concat({
    "# Vesuvius",
    "## TODO Prepare release",
    "- [ ] Complete validation [1/2]",
    "  - [x] Review unit tests",
    "  - [ ] Review integration tests",
    "- [ ] Prepare documentation",
  }, "\n"))
  -- The heading is the task; its two top-level boxes are its progress.
  eq(summary(r), { "heading TODO Prepare release" })
  eq(r.tasks[1].progress, { done = 0, total = 2, of = "checkboxes" })
  eq(r.tasks[1].done, false)
end)

test("a v0.1 item under a heading task is its child", function()
  local r = parse("## TODO Plan\n- TODO legacy step")
  eq(parents(r), { "", "Plan" })
end)

test("parsing is deterministic", function()
  local text = "# Etna\n## TODO A\n- [ ] b\n  - [x] c\n## NEXT d"
  eq(parse(text), parse(text))
end)
