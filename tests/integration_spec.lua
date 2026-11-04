-- Milestone E: unified index, agenda and project queries, dashboard views
-- and editing, refile and archive, and end-to-end navigation
-- (LATTICE_SYNTAX_SPEC §8.2, §9.3, §5, §14.2; acceptance tests PAR-029,
-- PAR-030). Fictional volcanoes and people.
local H = require("helpers")
local test, eq, write, notes, reset = H.test, H.eq, H.write, H.notes, H.reset
local config, dashboard, lattice, scanner, timestamp = H.config, H.dashboard, H.lattice, H.scanner, H.timestamp
local agenda = require("lattice.agenda")
local mutate = require("lattice.mutate")

local function ts(raw)
  return assert(timestamp.parse(raw))
end

local function task(fields)
  return vim.tbl_extend("keep", fields, {
    kind = "heading",
    state = "TODO",
    title = fields.text or "Task",
    text = fields.title or "Task",
    done = false,
    rel = "a.md",
    line = 1,
    tags = {},
    inherited_tags = {},
    properties = {},
    inherited_properties = {},
    section = "todo",
  })
end

local function titles(list)
  return vim.tbl_map(function(t)
    return t.title
  end, list)
end

-- Select the item whose text contains `wanted` from a vim.ui.select call.
local function with_select(wanted, fn)
  local saved = vim.ui.select
  vim.ui.select = function(items, opts, callback)
    for _, item in ipairs(items) do
      local label = opts.format_item and opts.format_item(item) or item
      if label:find(wanted, 1, true) then
        return callback(item)
      end
    end
    error("no choice contains " .. wanted .. " in " .. vim.inspect(items))
  end
  fn()
  vim.ui.select = saved
end

local function with_input(answer, fn)
  local saved = vim.ui.input
  vim.ui.input = function(_, callback)
    callback(answer)
  end
  fn()
  vim.ui.input = saved
end

local function cursor_on(text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error("no line contains " .. text)
end

-- Filters ----------------------------------------------------------------------

test("filters by tag (own or inherited), priority, project, person, state and words", function()
  local tasks = {
    task({ title = "Review architecture", tags = { "design" }, inherited_tags = { "etna" }, priority = "A", project = "Etna", state = "NEXT" }),
    task({ title = "Load test", inherited_tags = { "etna" }, project = "Etna", person = "Tavren Solis" }),
    task({ title = "Release checklist", priority = "B", project = "Krakatoa", state = "WAITING" }),
  }
  eq(titles(agenda.filter(tasks, "+etna")), { "Review architecture", "Load test" })
  eq(titles(agenda.filter(tasks, "+etna -design")), { "Load test" })
  eq(titles(agenda.filter(tasks, "#A #B")), { "Review architecture", "Release checklist" })
  eq(titles(agenda.filter(tasks, "project:krakatoa")), { "Release checklist" })
  eq(titles(agenda.filter(tasks, "@tavren")), { "Load test" })
  eq(titles(agenda.filter(tasks, "state:NEXT")), { "Review architecture" })
  eq(titles(agenda.filter(tasks, "LOAD")), { "Load test" })
  eq(#agenda.filter(tasks, ""), 3)
end)

test("the TODO list sorts by priority; no priority counts as the default, never the highest", function()
  local list = agenda.todo_list({
    task({ title = "none", line = 1 }),
    task({ title = "C", priority = "C", line = 2 }),
    task({ title = "A", priority = "A", line = 3 }),
    task({ title = "B due", priority = "B", due = "2026-11-05", line = 4 }),
    task({ title = "done", done = true, line = 5 }),
  }, nil, { values = { "A", "B", "C" }, default = "B" })
  eq(titles(list), { "A", "B due", "none", "C" })
end)

-- Week agenda --------------------------------------------------------------------

test("week_start is the Monday on or before a date", function()
  eq(agenda.week_start("2026-11-02"), "2026-11-02")
  eq(agenda.week_start("2026-11-08"), "2026-11-02")
  eq(agenda.week_start("2027-01-01"), "2026-12-28")
end)

test("the week agenda places scheduled items, deadlines and repeats on their days", function()
  local days = agenda.week({
    task({ title = "Standup", scheduled = ts("<2026-11-03 Tue 09:30 +1d>") }),
    task({ title = "Report", deadline = ts("<2026-11-06 Fri>"), due = "2026-11-06" }),
    task({ title = "Old", scheduled = ts("<2026-10-29 Thu>") }),
    task({ title = "Late", deadline = ts("<2026-10-31 Sat>"), due = "2026-10-31" }),
    task({ title = "Far", deadline = ts("<2026-11-20 Fri>"), due = "2026-11-20" }),
    task({ title = "Done", done = true, scheduled = ts("<2026-11-03 Tue>") }),
  }, "2026-11-02", "2026-11-02", { warning_days = 14 })
  local function day(i)
    return vim.tbl_map(function(e)
      return (e.time and (e.time .. " ") or "") .. e.note .. " " .. e.task.title
    end, days[i].entries)
  end
  eq(days[1].today, true)
  -- Deadlines first, most overdue leading; "Far" is beyond its 14-day warning.
  eq(day(1), { "2 d. ago Late", "In 4 d. Report", "Sched. 4x Old" })
  eq(day(2), { "09:30 Scheduled Standup" })
  eq(day(3), { "09:30 Scheduled Standup" }) -- the daily repeat
  eq(day(5), { "09:30 Scheduled Standup", "Deadline Report" })
  eq(day(7), { "09:30 Scheduled Standup" })
end)

-- Projects ---------------------------------------------------------------------

test("projects: counts, next action and :PROJECT_STATUS:", function()
  local list = agenda.projects({
    task({ title = "Plan", project = "Etna", state = "TODO", line = 1 }),
    task({ title = "Migrate", project = "Etna", state = "NEXT", line = 2, inherited_properties = { PROJECT_STATUS = "active" } }),
    task({ title = "Old", project = "Etna", done = true, state = "DONE", line = 3 }),
    task({ title = "Checklist", project = "Krakatoa", line = 4 }),
    task({ title = "No project", line = 5 }),
  })
  eq(vim.tbl_map(function(p)
    return ("%s %d/%d %s %s"):format(p.name, p.open, p.done, p.next and p.next.title or "-", p.status or "-")
  end, list), { "Etna 2/1 Migrate active", "Krakatoa 1/0 Checklist -" })
end)

-- Dashboard views ----------------------------------------------------------------

local NOTE = table.concat({
  "# Etna :engineering:",
  "",
  "## NEXT [#A] Review architecture",
  "SCHEDULED: <2026-11-02 Mon>",
  "",
  "## TODO Load test",
  "DEADLINE: <2026-11-04 Wed>",
  "",
  "# Team",
  "",
  "## WAITING Venue reply",
  ":PROPERTIES:",
  ":ASSIGNED: Elira Voss",
  ":END:",
}, "\n")

local function open_on(note, raw_config)
  local root = notes()
  write(root, ".lattice.json", vim.json.encode(raw_config or { workflows = { etna = { active = { "TODO", "NEXT" }, done = { "DONE" } } } }))
  local path = write(root, "a.md", note or NOTE)
  reset(root)
  lattice.open()
  return root, path
end

test("views: week agenda, all TODOs, projects, and the filter line", function()
  local today = os.date("%Y-%m-%d")
  local result = scanner.collect((open_on()))
  local week = table.concat(dashboard.render(result, "2026-11-02", { view = "week", week_start = "2026-11-02" }).lines, "\n")
  assert(week:find("View: Week agenda", 1, true), week)
  assert(week:find("Mon Nov 02 %(%d+%)  %[today%]"), week)
  assert(week:find("Scheduled    NEXT [#A] Review architecture", 1, true), week)
  assert(week:find("In 2 d.      TODO Load test", 1, true), week)
  local todo = table.concat(dashboard.render(result, today, { view = "todo" }).lines, "\n")
  assert(todo:find("ALL TODOS (3)", 1, true), todo)
  local first, second = todo:find("NEXT [#A] Review architecture", 1, true), todo:find("WAITING Elira Voss", 1, true)
  assert(first and second and first < second, todo)
  local projects = table.concat(dashboard.render(result, today, { view = "projects" }).lines, "\n")
  assert(projects:find("Etna   2 open, 0 done   next: NEXT Review architecture", 1, true), projects)
  local filtered = table.concat(dashboard.render(result, today, { view = "todo", query = "@elira" }).lines, "\n")
  assert(filtered:find("Filter: @elira", 1, true), filtered)
  assert(filtered:find("ALL TODOS (1)", 1, true), filtered)
end)

test("dashboard keys switch views, filter, and open a project's TODOs", function()
  open_on()
  dashboard.set_view("projects")
  H.press_enter_on("Etna")
  local text = H.dashboard_text()
  assert(text:find("View: All TODOs    Filter: project:Etna", 1, true), text)
  assert(not text:find("Venue reply", 1, true))
  with_input("", dashboard.prompt_filter)
  assert(H.dashboard_text():find("Venue reply", 1, true))
  dashboard.set_view("week")
  assert(H.dashboard_text():find("View: Week agenda", 1, true))
  dashboard.shift_week(1)
  dashboard.shift_week(0)
  dashboard.set_view("overview")
  assert(H.dashboard_text():find("MY TO DO", 1, true))
end)

-- Editing from the dashboard ---------------------------------------------------

test("t, + and S on a row edit the note's buffer, unsaved; the dashboard shows it; s saves", function()
  local _, path = open_on()
  cursor_on("Load test")
  with_select("DONE", dashboard.row_state)
  local text = H.dashboard_text()
  assert(text:find("DONE Load test", 1, true), text)
  local buf = vim.fn.bufnr(path)
  eq(vim.bo[buf].modified, true)
  assert(H.read(path):find("## TODO Load test", 1, true)) -- file untouched
  cursor_on("Review architecture")
  dashboard.row_priority(-1)
  assert(H.dashboard_text():find("NEXT [#B] Review architecture", 1, true))
  cursor_on("Venue reply")
  with_input("2026-11-20", function()
    dashboard.row_date("DEADLINE")
  end)
  assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[12] == "DEADLINE: <2026-11-20 Fri>", vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
  dashboard.save_edited()
  eq(vim.bo[buf].modified, false)
  local saved = H.read(path)
  assert(saved:find("## DONE Load test", 1, true), saved)
  assert(saved:find("## NEXT [#B] Review architecture", 1, true), saved)
end)

test("a row edit on a task that changed underneath is refused", function()
  local _, path = open_on()
  local buf = mutate.note_buffer(path)
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "## TODO Load test renamed elsewhere" })
  cursor_on("Load test")
  local target_line = vim.api.nvim_win_get_cursor(0)[1]
  -- The title still contains "Load test", so it is found; rename it fully:
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "## TODO Something else" })
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  dashboard.row_priority(1)
  assert(H.last_notify().message:find("moved or changed", 1, true), H.last_notify().message)
end)

test("saving a note refreshes an open dashboard (incremental refresh)", function()
  local root, path = open_on()
  local dash = vim.api.nvim_get_current_buf()
  vim.cmd("split " .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 5, 6, false, { "## TODO Load test, rescheduled" })
  vim.cmd("silent write")
  local text = table.concat(vim.api.nvim_buf_get_lines(dash, 0, -1, false), "\n")
  assert(text:find("Load test, rescheduled", 1, true), text)
  vim.cmd("close")
  local _ = root
end)

-- Navigation (PAR-030) -------------------------------------------------------

test("PAR-030 Enter opens the right task even after lines moved in the open note", function()
  local _, path = open_on()
  local buf = mutate.note_buffer(path)
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "Two new lines", "at the top" })
  H.press_enter_on("Venue reply")
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(vim.api.nvim_get_current_line(), "## WAITING Venue reply")
end)

-- Refile and archive (§14.2) ---------------------------------------------------

test("refile within a note: under another heading, re-levelled", function()
  local lines = vim.split("# Etna\n## TODO Move me\n### NEXT Child\n- [ ] step\n# Fuji\n## Plans\ntext", "\n")
  local out = assert(mutate.refile(lines, 2, nil, 6))
  eq(table.concat(out, "\n"), "# Etna\n# Fuji\n## Plans\ntext\n\n### TODO Move me\n#### NEXT Child\n- [ ] step")
  local _, err = mutate.refile(lines, 2, nil, 3)
  assert(err:find("under itself", 1, true), err)
end)

test("refile across notes moves the subtree from one buffer to the other", function()
  local root = notes()
  write(root, ".lattice.json", "{}")
  local a = write(root, "a.md", "# Etna\n## TODO Move me\nbody\n## TODO Stay\n")
  local b = write(root, "b.md", "# Fuji\n## Plans\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(a))
  vim.bo.filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  with_select("b.md › Fuji › Plans", lattice.refile)
  eq(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "# Etna\n## TODO Stay")
  local dest = vim.fn.bufnr(b)
  eq(table.concat(vim.api.nvim_buf_get_lines(dest, 0, -1, false), "\n"), "# Fuji\n## Plans\n\n### TODO Move me\nbody")
  eq(vim.bo[dest].modified, true)
  assert(H.read(b) == "# Fuji\n## Plans\n") -- nothing saved
end)

test("archive moves the subtree to <note>_archive.md with Org's ARCHIVE properties", function()
  local root = notes()
  write(root, ".lattice.json", "{}")
  local path = write(root, "Projects/etna.md", "# Etna\n## Releases\n### DONE Ship 1.0\nCLOSED: [2026-11-01 Sun 10:00]\nnotes\n### TODO Ship 2.0\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  lattice.archive()
  eq(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "# Etna\n## Releases\n### TODO Ship 2.0")
  local archive = vim.fn.bufnr(root .. "/Projects/etna_archive.md")
  local text = table.concat(vim.api.nvim_buf_get_lines(archive, 0, -1, false), "\n")
  local got = vim.split(text, "\n", { plain = true })
  assert(got[6]:match("^:ARCHIVE_TIME: %[%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d%]$"), got[6])
  got[6] = ":ARCHIVE_TIME: <time>"
  eq(got, {
    "Archived entries from Projects/etna.md.",
    "",
    "# DONE Ship 1.0",
    "CLOSED: [2026-11-01 Sun 10:00]",
    ":PROPERTIES:",
    ":ARCHIVE_TIME: <time>",
    ":ARCHIVE_FILE: Projects/etna.md",
    ":ARCHIVE_OLPATH: Etna/Releases",
    ":ARCHIVE_CATEGORY: etna",
    ":ARCHIVE_TODO: DONE",
    ":END:",
    "notes",
  })
  -- Archive notes are excluded from scanning by default.
  vim.api.nvim_buf_call(archive, function()
    vim.cmd("silent write")
  end)
  eq(scanner.list_files(root, config.defaults().scan), { "Projects/etna.md" })
end)

test("archive.location is validated, and a missing folder is reported, not created", function()
  local root = notes()
  write(root, ".lattice.json", '{"archive": {"location": "nowhere.md"}}')
  assert(select(3, config.load(root)):find("containing %s", 1, true))
  write(root, ".lattice.json", '{"archive": {"location": "../%s.md"}}')
  assert(select(3, config.load(root)):find("inside the notes root", 1, true))
  write(root, ".lattice.json", '{"archive": {"location": "Archives/%s_archive.md"}}')
  local path = write(root, "a.md", "## DONE Old\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.filetype = "markdown"
  lattice.archive()
  assert(H.last_notify().message:find("doesn't exist", 1, true), H.last_notify().message)
  eq(vim.fn.isdirectory(root .. "/Archives"), 0)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "## DONE Old" })
end)

test("F opens the filter; / is left to Vim's search", function()
  open_on()
  local function local_desc(lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if map.lhs == lhs then
        return map.desc
      end
    end
  end
  eq(local_desc("F"), "Lattice: filter")
  eq(local_desc("/"), nil)
  assert(H.dashboard_text():find("F Filter", 1, true))
end)
