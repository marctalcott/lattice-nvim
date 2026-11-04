-- Regression tests for the code review of v0.1.0..v0.2.0. Each test is
-- named after the bug it pins down. Fictional volcanoes and people.
local H = require("helpers")
local test, eq, write, notes, reset = H.test, H.eq, H.write, H.notes, H.reset
local config, dashboard, lattice, scanner, timestamp = H.config, H.dashboard, H.lattice, H.scanner, H.timestamp
local agenda = require("lattice.agenda")
local mutate = require("lattice.mutate")
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

-- 1. Migration reopened finished tasks -------------------------------------

test("migrate: a checked v0.1 item becomes a done heading, not an open one", function()
  local out = mutate.migrate(L("# Notes\n- [x] TODO write report\n- [ ] DONE already done\n- [X] NEXT also done"), DEFAULT)
  eq(T(out), "# Notes\n\n## DONE write report\n\n## DONE already done\n\n## DONE also done")
  local waiting = mutate.migrate(L("## Waiting On\n- [x] @Raju estimate"), DEFAULT)
  eq(T(waiting), "## Waiting On\n\n### DONE estimate\n:PROPERTIES:\n:ASSIGNED: Raju\n:END:")
end)

-- 2. Migration deleted invalid dates ---------------------------------------

test("migrate: an invalid [due:] date stays in the title and is still reported", function()
  local out = mutate.migrate(L("# Notes\n- TODO pay [due:2026-02-30]"), DEFAULT)
  eq(T(out), "# Notes\n\n## TODO pay [due:2026-02-30]")
  local after = assert(tasks.parse(out, DEFAULT))
  eq(after.date_errors, { { line = 3, tag = "due", value = "2026-02-30" } })
end)

-- 3. Migration moved a parent's notes under a nested item ------------------

test("migrate: an item's own sub-lines stay with it, before nested headings", function()
  local out = mutate.migrate(L("# Notes\n- TODO outer\n  - TODO inner\n    - inner detail\n  - plain note"), DEFAULT)
  eq(T(out), "# Notes\n\n## TODO outer\n- plain note\n\n### TODO inner\n- inner detail")
  local after = assert(tasks.parse(out, DEFAULT))
  eq(after.tasks[2].parent, 1)
  eq(after.legacy, {})
end)

-- 4. Refile to a heading that changed went to the end of the note ----------

test("refile: a target heading that changed since the list was made is refused", function()
  local root = notes()
  write(root, ".lattice.json", "{}")
  local a = write(root, "a.md", "# Etna\n## TODO Move me\n")
  local b = write(root, "b.md", "# Fuji\n## Plans\ntext\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(a))
  vim.bo.filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local saved = vim.ui.select
  vim.ui.select = function(items, opts, callback)
    -- The target is renamed while the picker is open.
    local dest = mutate.note_buffer(b)
    vim.api.nvim_buf_set_lines(dest, 1, 2, false, { "## Renamed" })
    for _, item in ipairs(items) do
      if opts.format_item(item):find("Fuji › Plans", 1, true) then
        return callback(item)
      end
    end
  end
  lattice.refile()
  vim.ui.select = saved
  assert(H.last_notify().message:find("target heading changed", 1, true), H.last_notify().message)
  eq(T(vim.api.nvim_buf_get_lines(0, 0, -1, false)), "# Etna\n## TODO Move me")
  eq(T(vim.api.nvim_buf_get_lines(vim.fn.bufnr(b), 0, -1, false)), "# Fuji\n## Renamed\ntext")
end)

-- 5. Cycling misread multi-word states -------------------------------------

test("cycling recognises multi-word states", function()
  local kws = assert(H.keywords.from_workflow({ active = { "TODO", "IN PROGRESS" }, done = { "DONE" } }))
  eq((H.insert.cycle_line("- IN PROGRESS thing", kws, 1)), "- DONE thing")
  eq((H.insert.cycle_line("## IN PROGRESS thing", kws, 1)), "## DONE thing")
  eq((H.insert.cycle_line("## IN PROGRESS thing", kws, -1)), "## TODO thing")
  eq((H.insert.cycle_line("## IN thing", kws, 1)), "## TODO IN thing") -- "IN" alone is not a state
end)

-- 6. <leader>lt used the enclosing heading's own workflow ------------------

test("add TODO uses the workflow the new sibling heading inherits", function()
  local _, root = cfg_from({ workflows = { bugs = { active = { "OPEN" }, done = { "FIXED" } } } })
  reset(root)
  vim.cmd("enew!")
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, L("# Notes\n## OPEN crash\n:PROPERTIES:\n:WORKFLOW: bugs\n:END:"))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.notify("sentinel")
  local saved = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("new thing")
  end
  lattice.add_todo()
  vim.ui.input = saved
  eq(T(vim.api.nvim_buf_get_lines(0, 0, -1, false)), "# Notes\n## OPEN crash\n:PROPERTIES:\n:WORKFLOW: bugs\n:END:\n\n## TODO new thing")
  eq(H.last_notify().message, "sentinel") -- no false "won't list it" warning
end)

-- 7. enforce.* skipped headings without a state ----------------------------

test("enforce.todo and enforce.checkboxes also hold for a heading without a state", function()
  local cfg = cfg_from({ enforce = { todo = true, checkboxes = true } })
  local _, err = mutate.set_state(L("# Project\n## TODO child"), cfg, 1, "DONE")
  assert(err and err:find('subtask "child" is still open', 1, true), err)
  _, err = mutate.set_state(L("# Project\n- [ ] step"), cfg, 1, "DONE")
  assert(err and err:find("1 of 1 checkboxes are unchecked", 1, true), err)
end)

-- 8. Project names with spaces never matched -------------------------------

test("filters accept quoted values; Enter on a spaced project name lists its TODOs", function()
  local list = { { title = "Paint", text = "Paint", project = "Home Renovation", line = 1, tags = {}, inherited_tags = {} } }
  eq(#agenda.filter(list, 'project:"Home Renovation"'), 1)
  eq(#agenda.filter(list, '@"Elira Voss"'), 0)
  eq(agenda.parse_filter('project:"Home Renovation" paint').words, { "paint" })
  local root = notes()
  write(root, ".lattice.json", "{}")
  write(root, "a.md", "# House\n:PROPERTIES:\n:PROJECT: Home Renovation\n:END:\n## TODO Paint the hall\n")
  reset(root)
  lattice.open()
  dashboard.set_view("projects")
  H.press_enter_on("Home Renovation")
  local text = H.dashboard_text()
  assert(text:find('Filter: project:"Home Renovation"', 1, true), text)
  assert(text:find("ALL TODOS (1)", 1, true), text)
end)

-- 9. Repeats in the week agenda --------------------------------------------

test("week agenda: an hourly repeat shows once a day; an old daily repeat still shows", function()
  local function ts(raw)
    return assert(timestamp.parse(raw))
  end
  local function base(fields)
    return vim.tbl_extend("keep", fields, { kind = "heading", state = "TODO", done = false, rel = "a.md", line = 1, tags = {}, inherited_tags = {} })
  end
  local days = agenda.week({
    base({ title = "Hourly", scheduled = ts("<2026-11-02 Mon 09:00 +1h>") }),
    base({ title = "Ancient", line = 2, scheduled = ts("<2020-01-01 Wed +1d>") }),
  }, "2026-11-02", "2026-11-02")
  local monday = vim.tbl_map(function(e)
    return e.note .. " " .. e.task.title
  end, days[1].entries)
  eq(#vim.tbl_filter(function(x)
    return x == "Scheduled Hourly"
  end, monday), 1)
  for i = 1, 7 do
    local found = false
    for _, e in ipairs(days[i].entries) do
      found = found or (e.task.title == "Ancient" and e.note == "Scheduled")
    end
    assert(found, "Ancient missing on day " .. i)
  end
end)

-- 10. [-] counted as done on v0.1 items --------------------------------------

test("a v0.1 item with Org's partly checked [-] is not done", function()
  local r = assert(tasks.parse(L("- [-] TODO half done\n## Waiting On\n- [-] @Bob report"), DEFAULT))
  eq({ r.tasks[1].done, r.tasks[2].done, r.tasks[2].state }, { false, false, "WAITING" })
end)

-- 11. A bare heading crashed state and priority changes ----------------------

test("state and priority commands on an empty heading report it instead of crashing", function()
  local _, err = mutate.set_state(L("##"), DEFAULT, 1, "DONE")
  eq(err, "this heading has no text")
  _, err = mutate.shift_priority(L("##"), DEFAULT, 1, 1)
  eq(err, "this heading has no text")
end)

-- Efficiency -------------------------------------------------------------------

test("cached parses are reused across refreshes without copying", function()
  local root = notes()
  write(root, "a.md", "## TODO A\n")
  scanner.clear_cache()
  local first = scanner.collect(root).tasks[1]
  local second = scanner.collect(root).tasks[1]
  eq(rawequal(first, second), true)
  eq({ second.rel, second.title }, { "a.md", "A" })
end)
