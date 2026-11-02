local H = require("helpers")
local config, dashboard, lattice, parser, scanner = H.config, H.dashboard, H.lattice, H.parser, H.scanner
local test, eq, parse, texts, write, read = H.test, H.eq, H.parse, H.texts, H.write, H.read
local notes, reset, dashboard_text, press_enter_on = H.notes, H.reset, H.dashboard_text, H.press_enter_on

-- Parsing: headings ----------------------------------------------------------

test("matches any ATX depth and ignores surrounding spaces", function()
  for _, heading in ipairs({ "# To Do", "###### To Do", "##   To Do  ", "## To Do ##", "### Waiting On" }) do
    eq(#parse(heading .. "\n- Task").tasks, 1)
  end
end)

test("rejects near-miss headings", function()
  local misses = { "## TODO", "## Todos", "## to do", "## Waiting for", "## waiting on", "##To Do", "####### To Do" }
  for _, heading in ipairs(misses) do
    eq(#parse(heading .. "\n- Task").tasks, 0)
  end
end)

test("honors configured heading names exactly", function()
  local result = parser.parse({ "## Next", "- Task", "## To Do", "- Other" }, { todo = "Next", waiting = "Blocked" })
  eq(texts(result), { "Task" })
end)

-- Parsing: section boundaries ------------------------------------------------

test("a section ends at the next heading of any depth, not at blank lines", function()
  local result = parse("## To Do\n- One\n\n\n- Two\n###### Other\n- Three\n# To Do\n- Four")
  eq(texts(result), { "One", "Two", "Four" })
end)

test("a setext heading ends a section", function()
  eq(texts(parse("## To Do\n- One\n\nOther\n-----\n- Two")), { "One" })
end)

test("ignores bullets under unrelated headings and before any heading", function()
  eq(#parse("- Loose\n## Notes\n- Note\n* Other").tasks, 0)
end)

test("ignores nested bullets", function()
  local result = parse("## To Do\n- Parent\n  - Child\n    - Grandchild\n\t- Tabbed\n- Sibling")
  eq(texts(result), { "Parent", "Sibling" })
end)

test("does not treat 2-space-indented siblings as nested", function()
  eq(texts(parse("## To Do\n  - One\n  - Two")), { "One", "Two" })
end)

test("ignores bullets nested under an ordered item", function()
  eq(texts(parse("## To Do\n1. Step\n   - Substep\n- Real")), { "Real" })
end)

test("ignores bullets and headings in code fences", function()
  local result = parse("## To Do\n- One\n```md\n- Fenced\n## Notes\n```\n~~~\n- Tilde\n```\n~~~\n- Two")
  eq(texts(result), { "One", "Two" })
end)

test("an unclosed fence hides everything after it", function()
  eq(texts(parse("## To Do\n- One\n```\n- Two\n## Waiting On\n- Three")), { "One" })
end)

test("a fenced heading does not open a section", function()
  eq(#parse("```\n## To Do\n- Task\n```").tasks, 0)
end)

test("thematic breaks are not tasks", function()
  eq(texts(parse("## To Do\n- One\n\n- - -\n* * *\n- Two")), { "One", "Two" })
end)

-- Parsing: items -------------------------------------------------------------

test("accepts all list markers and open forms", function()
  local result = parse("## To Do\n- Dash\n* Star\n+ Plus\n- [ ] Box")
  eq(texts(result), { "Dash", "Star", "Plus", "Box" })
  for _, task in ipairs(result.tasks) do
    eq(task.done, false)
    eq(task.section, "todo")
  end
end)

test("detects completion", function()
  local result = parse("## To Do\n- [x] Lower\n- [X] Upper\n- [ ] Open")
  eq(result.tasks[1].done, true)
  eq(result.tasks[2].done, true)
  eq(result.tasks[3].done, false)
end)

test("skips empty items", function()
  eq(#parse("## To Do\n- \n- [ ]\n- [x] ").tasks, 0)
end)

test("reports source lines, handling CRLF and a BOM", function()
  local result = parse("\239\187\191## To Do\r\n\r\n- Task\r")
  eq(result.tasks[1].line, 3)
  eq(result.tasks[1].text, "Task")
end)

test("extracts @person only at the start of a Waiting On item", function()
  local result = parse("## Waiting On\n- @Raju Estimate\n- [ ] @Taylor-Smith Review\n- No one\n- Ask @Asha")
  eq(result.tasks[1].person, "Raju")
  eq(result.tasks[1].text, "Estimate")
  eq(result.tasks[2].person, "Taylor-Smith")
  eq(result.tasks[3].person, nil)
  eq(result.tasks[4].person, nil)
  eq(result.tasks[4].text, "Ask @Asha")
end)

test("To Do items never get an assignee", function()
  local task = parse("## To Do\n- @Raju Call").tasks[1]
  eq(task.person, nil)
  eq(task.text, "@Raju Call")
end)

test("parses valid due dates and strips the tag", function()
  local task = parse("## To Do\n- Send update [due:2026-11-05]").tasks[1]
  eq(task.due, "2026-11-05")
  eq(task.text, "Send update")
end)

test("invalid dates leave the task undated and are reported", function()
  for _, value in ipairs({ "2026-13-01", "2026-02-30", "2026-2-1", "soon", "" }) do
    local result = parse(("## To Do\n- Task [due:%s]"):format(value))
    eq(result.tasks[1].due, nil)
    eq(result.tasks[1].text, "Task")
    eq(result.date_errors, { { line = 2, tag = "due", value = value } })
  end
end)

test("parses promised dates on Waiting On items and strips the tag", function()
  local task = parse("## Waiting On\n- @Raju Estimate [due:2026-11-05] [promised:2026-11-03]").tasks[1]
  eq(task.due, "2026-11-05")
  eq(task.promised, "2026-11-03")
  eq(task.text, "Estimate")
end)

test("invalid promised dates are reported and the task stays visible", function()
  local result = parse("## Waiting On\n- Estimate [promised:soon]")
  eq(result.tasks[1].promised, nil)
  eq(result.tasks[1].text, "Estimate")
  eq(result.date_errors, { { line = 2, tag = "promised", value = "soon" } })
end)

test("promised is not a To Do tag", function()
  local task = parse("## To Do\n- Call [promised:2026-11-03]").tasks[1]
  eq(task.promised, nil)
  eq(task.text, "Call [promised:2026-11-03]")
end)

test("validates leap days", function()
  eq(parser.valid_date("2028-02-29"), true)
  eq(parser.valid_date("2026-02-29"), false)
  eq(parser.valid_date("1900-02-29"), false)
  eq(parser.valid_date("2000-02-29"), true)
end)

-- Examples -------------------------------------------------------------------

test("examples/sample-notes.md parses as its comments describe", function()
  local lines = vim.fn.readfile(H.repo .. "/examples/sample-notes.md")
  local result = parser.parse(lines, H.HEADINGS)
  local summary = vim.tbl_map(function(t)
    return ("%d %s %s %s %s"):format(t.line, t.section, t.done and "x" or "-", t.person or "", t.due or "")
  end, result.tasks)
  eq(summary, {
    "7 todo -  ",
    "8 todo -  2026-11-05",
    "9 todo -  2026-10-30",
    "10 todo x  ",
    "14 waiting - Raju 2026-11-06",
    "15 waiting - Asha 2026-11-09",
    "16 waiting -  ",
  })
end)
