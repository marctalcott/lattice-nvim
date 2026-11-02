local H = require("helpers")
local config, parser = H.config, H.parser
local test, eq, parse, texts = H.test, H.eq, H.parse, H.texts
local keywords = require("lattice.keywords")

local function with_sequences(sequences, text)
  local cfg = config.defaults()
  cfg.keywords = assert(keywords.build(sequences))
  return parser.parse(vim.split(text, "\n", { plain = true }), cfg)
end

local function states(result)
  return vim.tbl_map(function(task)
    return (task.state or "-") .. (task.done and " x" or "")
  end, result.tasks)
end

-- Keyword sequences ----------------------------------------------------------

test("parses org-style sequences", function()
  eq(keywords.parse_sequence("TODO NEXT | DONE CANCELED"), { open = { "TODO", "NEXT" }, done = { "DONE", "CANCELED" } })
  -- Without |, the last word is the done state.
  eq(keywords.parse_sequence("TODO NEXT DONE"), { open = { "TODO", "NEXT" }, done = { "DONE" } })
  -- Fast-access keys are dropped.
  eq(keywords.parse_sequence("TODO(t) WAIT(w@/!) | DONE(d!)"), { open = { "TODO", "WAIT" }, done = { "DONE" } })
  -- Org allows a sequence with no done state.
  eq(keywords.parse_sequence("TODO |"), { open = { "TODO" }, done = {} })
end)

test("rejects malformed sequences", function()
  for _, bad in ipairs({ "", "|", "A | B | C", "TO:DO | DONE", 5 }) do
    eq(keywords.parse_sequence(bad), nil)
  end
  eq(keywords.build({ "TODO | DONE", "DONE | TODO" }), nil)
  eq(keywords.build({}), nil)
end)

test("builds states from several sequences; the first open state leads", function()
  local built = keywords.build({ "TODO NEXT | DONE", "BUG | FIXED" })
  eq(built.states, { TODO = "open", NEXT = "open", DONE = "done", BUG = "open", FIXED = "done" })
  eq(built.first_open, "TODO")
  eq(keywords.build("| DONE").first_open, nil)
end)

-- Keyword items --------------------------------------------------------------

test("a keyword at the start of a bullet makes it a task anywhere in the note", function()
  local result = parse("# Meeting\n\nIntro\n- TODO Send update\n## Notes\n* DONE Book room\n+ Plain bullet")
  eq(texts(result), { "Send update", "Book room" })
  eq(states(result), { "TODO", "DONE x" })
  eq(result.tasks[1].line, 4)
  eq(result.tasks[1].section, "todo")
end)

test("a heading that starts with a keyword is a task", function()
  local result = parse("# TODO Draft plan [due:2026-11-05]\n###### DONE Ship it ##\n## TODO\n## Notes")
  eq(texts(result), { "Draft plan", "Ship it" })
  eq(result.tasks[1].due, "2026-11-05")
  eq(result.tasks[1].line, 1)
end)

test("keywords match exactly, like org", function()
  local misses = { "- todo Call", "- Todo Call", "- TODOs Call", "- TODO", "- TODO:", "-TODO Call", "- [TODO] Call" }
  for _, line in ipairs(misses) do
    eq(#parse(line).tasks, 0)
  end
  -- "TODO: Call" is not the keyword TODO followed by a title.
  eq(#parse("- TODO: Call").tasks, 0)
end)

test("custom sequences replace the default keywords", function()
  local result = with_sequences({ "NEXT WAIT | DONE CANCELED" }, "- NEXT A\n- WAIT B\n- CANCELED C\n- TODO D")
  eq(texts(result), { "A", "B", "C" })
  eq(states(result), { "NEXT", "WAIT", "CANCELED x" })
end)

test("nested bullets count when they carry a keyword", function()
  local result = parse("- Project\n  - TODO Child\n    - DONE Grandchild\n  - Plain child")
  eq(texts(result), { "Child", "Grandchild" })
end)

test("a checkbox before the keyword is allowed; the keyword decides the state", function()
  eq(states(parse("- [ ] TODO A\n- [x] TODO B\n- [ ] DONE C")), { "TODO", "TODO", "DONE x" })
end)

test("keywords in code fences and indented code are ignored", function()
  local result = parse("```\n- TODO Fenced\n# TODO Fenced heading\n```\n~~~\n- TODO Tilde\n~~~\n\n    - TODO Indented code\n- TODO Real")
  eq(texts(result), { "Real" })
end)

test("an unclosed fence hides everything after it", function()
  eq(texts(parse("- TODO One\n```\n- TODO Two")), { "One" })
end)

test("ordered items and prose are not tasks", function()
  eq(#parse("1. TODO Numbered\nTODO in prose\nSome text TODO").tasks, 0)
end)

test("reports source lines, handling CRLF and a BOM", function()
  local result = parse("\239\187\191# Notes\r\n\r\n- TODO Task\r")
  eq(result.tasks[1].line, 3)
  eq(result.tasks[1].text, "Task")
end)

test("identical items in one note are distinct tasks", function()
  local result = parse("- TODO Same\n- TODO Same")
  eq(#result.tasks, 2)
  eq(result.tasks[2].line, 2)
end)

-- Front matter: per-file sequences -------------------------------------------

test("front matter todo replaces the root sequences for that note", function()
  local text = "---\ntitle: Review\ntodo: NEXT WAITING | DONE CANCELED\n---\n- NEXT A\n- TODO B\n- CANCELED C"
  local result = parse(text)
  eq(texts(result), { "A", "C" })
  eq(result.keywords.first_open, "NEXT")
  eq(result.tasks[1].line, 5)
end)

test("front matter accepts quoted values and a block list of sequences", function()
  local result = parse("---\ntodo:\n  - \"TODO | DONE\"\n  - 'BUG | FIXED'\n---\n- BUG Crash\n- FIXED Leak\n- TODO Call")
  eq(states(result), { "BUG", "FIXED x", "TODO" })
end)

test("front matter lines are never tasks", function()
  local result = parse("---\ntodo:\n  - TODO NEXT | DONE\ntags:\n  - TODO Not a task\n---\n- TODO Real")
  eq(texts(result), { "Real" })
end)

test("invalid front matter keywords warn and fall back to the root sequences", function()
  local result = parse("---\ntodo: A | B | C\n---\n- TODO Still works")
  eq(texts(result), { "Still works" })
  eq(#result.warnings, 1)
  eq(result.warnings[1].line, 2)
  assert(result.warnings[1].message:find("more than one |", 1, true))
end)

test("front matter without todo, or not at the top, changes nothing", function()
  eq(texts(parse("---\ntitle: x\n---\n- TODO A")), { "A" })
  eq(texts(parse("# Title\n---\ntodo: NEXT | DONE\n---\n- TODO A\n- NEXT B")), { "A" })
  -- An unclosed front matter block is ordinary text.
  eq(texts(parse("---\ntodo: NEXT | DONE\n- TODO A")), { "A" })
end)

-- Waiting On sections --------------------------------------------------------

test("matches Waiting On at any ATX depth, exactly", function()
  for _, heading in ipairs({ "# Waiting On", "###### Waiting On", "##   Waiting On  ", "## Waiting On ##" }) do
    eq(#parse(heading .. "\n- Task").tasks, 1)
  end
  for _, heading in ipairs({ "## waiting on", "## Waiting For", "##Waiting On", "####### Waiting On" }) do
    eq(#parse(heading .. "\n- Task").tasks, 0)
  end
end)

test("honors a configured Waiting On heading", function()
  local cfg = config.defaults()
  cfg.headings.waiting = "Blocked"
  local result = parser.parse({ "## Blocked", "- Task", "## Waiting On", "- Other" }, cfg)
  eq(texts(result), { "Task" })
end)

test("plain bullets and checkboxes in Waiting On are open; [x] is done", function()
  local result = parse("## Waiting On\n- Dash\n* Star\n+ Plus\n- [ ] Box\n- [x] Lower\n- [X] Upper")
  eq(texts(result), { "Dash", "Star", "Plus", "Box", "Lower", "Upper" })
  eq(vim.tbl_map(function(t)
    return t.done
  end, result.tasks), { false, false, false, false, true, true })
  eq(result.tasks[1].section, "waiting")
end)

test("keyword items in Waiting On are waiting items with a state", function()
  local result = parse("## Waiting On\n- TODO @Raju Estimate\n- DONE @Asha Feedback\n  - TODO Nested follow-up")
  eq(states(result), { "TODO", "DONE x", "TODO" })
  eq(result.tasks[1].person, "Raju")
  eq(result.tasks[2].section, "waiting")
  eq(result.tasks[3].section, "waiting")
end)

test("a Waiting On section ends at the next heading, not at blank lines", function()
  eq(texts(parse("## Waiting On\n- One\n\n\n- Two\n###### Other\n- Three")), { "One", "Two" })
  eq(texts(parse("## Waiting On\n- One\n\nOther\n-----\n- Two")), { "One" })
end)

test("in Waiting On, plain nested bullets and ordered items are not tasks", function()
  local result = parse("## Waiting On\n- Parent\n  - Child\n\t- Tabbed\n1. Step\n   - Substep\n- Sibling")
  eq(texts(result), { "Parent", "Sibling" })
  eq(texts(parse("## Waiting On\n  - One\n  - Two")), { "One", "Two" })
end)

test("in Waiting On, fences and thematic breaks are not tasks", function()
  eq(texts(parse("## Waiting On\n- One\n```\n- Fenced\n```\n- - -\n- Two")), { "One", "Two" })
  eq(#parse("```\n## Waiting On\n- Task\n```").tasks, 0)
end)

test("skips empty items", function()
  eq(#parse("## Waiting On\n- \n- [ ]\n- [x] ").tasks, 0)
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

test("my TODO items never get an assignee", function()
  local task = parse("- TODO @Raju Call").tasks[1]
  eq(task.person, nil)
  eq(task.text, "@Raju Call")
end)

-- Dates ----------------------------------------------------------------------

test("parses valid due dates and strips the tag", function()
  local task = parse("- TODO Send update [due:2026-11-05]").tasks[1]
  eq(task.due, "2026-11-05")
  eq(task.text, "Send update")
end)

test("invalid dates leave the task undated and are reported", function()
  for _, value in ipairs({ "2026-13-01", "2026-02-30", "2026-2-1", "soon", "" }) do
    local result = parse(("# Notes\n- TODO Task [due:%s]"):format(value))
    eq(result.tasks[1].due, nil)
    eq(result.tasks[1].text, "Task")
    eq(result.date_errors, { { line = 2, tag = "due", value = value } })
  end
end)

test("invalid dates on done items are not reported", function()
  eq(parse("- DONE Task [due:soon]").date_errors, {})
  eq(parse("## Waiting On\n- [x] Task [due:soon]").date_errors, {})
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

test("promised is not a tag on my items", function()
  local task = parse("- TODO Call [promised:2026-11-03]").tasks[1]
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
    return ("%d %s %s %s %s %s"):format(
      t.line,
      t.section,
      t.state or "-",
      t.done and "x" or "-",
      t.person or "",
      t.due or ""
    )
  end, result.tasks)
  eq(summary, {
    "12 todo TODO -  ",
    "13 todo NEXT -  2026-11-05",
    "14 todo TODO -  2026-10-30",
    "15 todo DONE x  ",
    "16 todo CANCELED x  ",
    "17 todo TODO -  ",
    "20 waiting - - Raju 2026-11-06",
    "21 waiting - - Asha 2026-11-09",
    "22 waiting - -  ",
    "23 waiting DONE x Lee ",
    "25 todo NEXT -  ",
  })
  eq(result.warnings, {})
end)
