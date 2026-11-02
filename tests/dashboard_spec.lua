local H = require("helpers")
local config, dashboard, lattice, parser, scanner = H.config, H.dashboard, H.lattice, H.parser, H.scanner
local test, eq, parse, texts, write, read = H.test, H.eq, H.parse, H.texts, H.write, H.read
local notes, reset, dashboard_text, press_enter_on = H.notes, H.reset, H.dashboard_text, H.press_enter_on

-- Rendering ------------------------------------------------------------------

local function task(fields)
  return vim.tbl_extend("keep", fields, { section = "todo", text = "Task", done = false, rel = "a.md", line = 1 })
end

test("sorts dated first by date, then undated by file and line", function()
  local sorted = dashboard.sorted({
    task({ rel = "b.md", line = 1, text = "undated b" }),
    task({ rel = "a.md", line = 9, text = "undated a9" }),
    task({ rel = "a.md", line = 2, text = "undated a2" }),
    task({ rel = "z.md", due = "2026-11-02", text = "early" }),
    task({ rel = "a.md", due = "2026-11-09", text = "late" }),
    task({ text = "done", done = true }),
    task({ text = "other", section = "waiting" }),
  }, "todo")
  eq(vim.tbl_map(function(t)
    return t.text
  end, sorted), { "early", "late", "undated a2", "undated a9", "undated b" })
end)

local function render(tasks, today, extra)
  local result = vim.tbl_extend("keep", extra or {}, { tasks = tasks, date_errors = {}, unreadable = {} })
  local view = dashboard.render(result, today or "2026-11-02")
  return table.concat(view.lines, "\n"), view
end

local function section(text, title)
  local body = text:match(title .. " %(%d+%)[^\n]*\n(.-)\n\n")
  return body or error("no section " .. title)
end

test("renders the header, owner groups, counts, assignees, and dates", function()
  local text, view = render({
    task({ text = "Send update", due = "2026-11-05", path = "/n/a.md", line = 4 }),
    task({ text = "Old", due = "2026-10-01" }),
    task({ section = "waiting", person = "Raju", text = "Estimate", path = "/n/a.md", line = 9 }),
    task({ section = "waiting", text = "Nobody", due = "2027-01-02" }),
    task({ text = "Hidden", done = true }),
  }, "2026-11-02", { root = "/n", files = 3 })
  assert(text:find("^LATTICE%s+Mon Nov 02\n"))
  assert(text:find("My management workspace — local notes", 1, true))
  assert(text:find("/n  (3 notes)", 1, true))
  assert(text:find("MY TO DO (2)", 1, true))
  assert(text:find("WAITING ON (2)", 1, true))
  assert(text:find("\n  %[ %] Send update%s+Nov 05\n"))
  assert(text:find("Raju — Estimate", 1, true))
  assert(text:find("Unassigned — Nobody", 1, true))
  assert(text:find("Jan 02, 2027", 1, true))
  assert(not text:find("Hidden", 1, true))
  assert(text:find("Enter  Open note    r  Refresh    q  Close    ?  Help", 1, true))
  -- Every task row is a jump target.
  eq(vim.tbl_count(view.targets) >= 4, true)
end)

test("overdue lists past-due tasks oldest first, from both owner groups", function()
  local text = render({
    task({ text = "Recent", due = "2026-11-01" }),
    task({ section = "waiting", person = "Asha", text = "Oldest", due = "2026-10-01" }),
    task({ text = "Today", due = "2026-11-02" }),
    task({ text = "Undated" }),
    task({ text = "Done late", due = "2026-10-02", done = true }),
  })
  assert(text:find("OVERDUE (2)", 1, true))
  local overdue = section(text, "OVERDUE")
  eq(select(2, overdue:gsub("\n", "")) + 1, 2)
  assert(overdue:find("^  !  Asha — Oldest%s+Oct 01\n  !  Recent%s+Nov 01$"), overdue)
end)

test("due soon covers today through 7 days ahead, soonest first, excluding overdue", function()
  local text = render({
    task({ text = "Day eight", due = "2026-11-10" }),
    task({ text = "Day seven", due = "2026-11-09" }),
    task({ text = "Today", due = "2026-11-02" }),
    task({ text = "Yesterday", due = "2026-11-01" }),
  })
  assert(text:find("DUE SOON (2)  [within next 7 days; excludes overdue]", 1, true))
  local soon = section(text, "DUE SOON")
  assert(soon:find("Today.-Day seven"))
  assert(not soon:find("Day eight", 1, true))
  assert(not soon:find("Yesterday", 1, true))
end)

test("due soon crosses month and year ends", function()
  eq(dashboard.add_days("2026-12-28", 7), "2027-01-04")
  eq(dashboard.add_days("2028-02-25", 7), "2028-03-03")
  local text = render({ task({ text = "New year", due = "2027-01-04" }) }, "2026-12-28")
  assert(section(text, "DUE SOON"):find("New year", 1, true))
end)

test("a task can appear in its owner group and in a date group", function()
  local text = render({ task({ text = "Budget", due = "2026-10-30" }) })
  local _, count = text:gsub("Budget", "")
  eq(count, 2)
end)

test("shows promised dates without marking them overdue or sorting by them", function()
  local waiting = { section = "waiting" }
  local tasks = {
    task(vim.tbl_extend("keep", { text = "Past promise", promised = "2026-10-01" }, waiting)),
    task(vim.tbl_extend("keep", { text = "Both", due = "2026-11-05", promised = "2026-11-03" }, waiting)),
  }
  eq(dashboard.sorted(tasks, "waiting")[1].text, "Both")
  local text = render(tasks)
  assert(text:find("Nov 05  promised Nov 03", 1, true))
  assert(text:find("promised Oct 01", 1, true))
  assert(text:find("OVERDUE (0)", 1, true))
end)

test("only overdue dates are highlighted as errors", function()
  local _, view = render({ task({ text = "Late", due = "2026-10-01" }), task({ text = "Now", due = "2026-11-02" }) })
  local errors = vim.tbl_filter(function(h)
    return h.hl == "DiagnosticError" and h.len == #"Oct 01"
  end, view.highlights)
  eq(#errors, 2) -- the date in MY TO DO and in OVERDUE
end)

test("an empty scan explains what Lattice looks for and shows the root", function()
  local text = render({}, nil, { root = "/notes", files = 0, headings = { todo = "To Do", waiting = "Waiting On" } })
  assert(text:find("No open tasks found.", 1, true))
  assert(text:find('"To Do" or "Waiting On"', 1, true))
  assert(text:find("/notes  (0 notes)", 1, true))
  assert(text:find("(none)", 1, true))
end)

test("points to :LatticeHealth for warnings and shows the config notice", function()
  local text = render({}, nil, {
    notice = "No config",
    unreadable = { { path = "bad.md", message = "EACCES" } },
    date_errors = { { rel = "a.md", path = "/n/a.md", line = 3, tag = "due", value = "soon" } },
  })
  assert(text:find("No config", 1, true))
  assert(text:find("2 warnings (unreadable files or invalid dates): run :LatticeHealth", 1, true))
end)

test("help lists keys, commands, and configured keymaps", function()
  local view = dashboard.render({ tasks = {}, date_errors = {}, unreadable = {} }, "2026-11-02", {
    help = true,
    keymaps = { open = "<leader>ll", refresh = false, add_todo = "<leader>lt", add_waiting = "<leader>ld" },
  })
  local text = table.concat(view.lines, "\n")
  assert(text:find(":LatticeHealth", 1, true))
  assert(text:find("Keymaps: <leader>ll dashboard, <leader>lt add To Do", 1, true))
  assert(not text:find("refresh,", 1, true))
end)

-- Dashboard and navigation ---------------------------------------------------

test("Enter opens the original file at the exact line", function()
  local root = notes()
  local path = write(root, "Projects/my note #1.md", "# Title\n\n## Waiting On\n\n- @Raju Estimate\n")
  reset(root)
  lattice.open()
  eq(vim.bo.filetype, "lattice")
  press_enter_on("Estimate")
  eq(vim.api.nvim_buf_get_name(0), path)
  eq(vim.api.nvim_win_get_cursor(0)[1], 5)
end)

test("? toggles help in the dashboard", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  vim.api.nvim_feedkeys("?", "x", false)
  assert(dashboard_text():find("KEYS", 1, true))
  vim.api.nvim_feedkeys("?", "x", false)
  assert(not dashboard_text():find("KEYS", 1, true))
end)

test("the dashboard window has no line numbers or wrapping", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  vim.wo.number, vim.wo.relativenumber, vim.wo.wrap = true, true, true
  lattice.open()
  eq({ vim.wo.number, vim.wo.relativenumber, vim.wo.wrap }, { false, false, false })
end)

test("Enter keeps unsaved edits in an already-open note", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved line" })
  lattice.open()
  press_enter_on("Task")
  eq(vim.api.nvim_buf_get_name(0), path)
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "unsaved line")
  eq(vim.bo.modified, true)
  eq(read(path), "## To Do\n- Task\n")
  vim.cmd("bwipeout!")
end)

-- Health ---------------------------------------------------------------------

test("health reports root, config, counts, unreadable files, and invalid dates", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n- [x] Done\n- Other [due:2026-02-30]\n")
  local result = scanner.collect(root)
  result.unreadable = { { path = "secret.md", message = "EACCES: permission denied" } }
  local messages = {}
  for _, item in ipairs(H.health.report(result)) do
    messages[#messages + 1] = item.level .. " " .. item.message
  end
  local text = table.concat(messages, "\n")
  assert(text:find("ok Notes root: " .. vim.fn.fnamemodify(root, ":~") .. " (1 Markdown notes scanned)", 1, true))
  assert(text:find("warn No .lattice.json", 1, true))
  assert(text:find("ok 2 open tasks, 1 completed", 1, true))
  assert(text:find("warn Could not read secret.md: EACCES", 1, true))
  assert(text:find("[due:2026-02-30] in a.md line 4", 1, true))
end)

test("health reports a broken config as an error", function()
  local root = notes()
  write(root, ".lattice.json", '{"version": 2}')
  local items = H.health.report(scanner.collect(root))
  eq(items[#items].level, "error")
  assert(items[#items].message:find("unsupported version 2", 1, true))
end)

test(":LatticeHealth runs checkhealth without errors", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task [due:nope]\n")
  reset(root)
  lattice.setup({ root = root, keymaps = false })
  vim.cmd("silent LatticeHealth")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(text:find("[due:nope]", 1, true), text)
  vim.cmd("silent! tabclose")
end)

test("Enter on a deleted file warns instead of creating a buffer", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  os.remove(path)
  press_enter_on("Task")
  eq(vim.bo.filetype, "lattice")
  assert(H.last_notify().message:find("no longer exists", 1, true))
end)

test("Enter on a non-task line does nothing", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  dashboard.jump()
  eq(vim.bo.filetype, "lattice")
end)

test("open focuses the existing dashboard", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("split")
  vim.cmd("enew")
  lattice.open()
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(#vim.fn.win_findbuf(buf), 1)
  vim.cmd("only")
end)

test("the dashboard reopens after jumping away", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  local buf = vim.api.nvim_get_current_buf()
  press_enter_on("Task")
  lattice.open()
  eq(vim.api.nvim_get_current_buf(), buf)
end)

test("q closes and returns to the previous buffer", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  lattice.open()
  dashboard.close()
  eq(vim.api.nvim_buf_get_name(0), path)
  lattice.open()
  eq(vim.bo.filetype, "lattice")
end)

test("refresh reflects external completion and config changes", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- [ ] Check me\n")
  write(root, "Skip/b.md", "## To Do\n- Excluded later\n")
  reset(root)
  lattice.open()
  assert(dashboard_text():find("Check me", 1, true))
  assert(dashboard_text():find("Excluded later", 1, true))

  write(root, "a.md", "## To Do\n- [x] Check me\n")
  write(root, ".lattice.json", '{"scan": {"exclude": ["Skip/**"]}}')
  lattice.refresh()
  assert(not dashboard_text():find("Check me", 1, true))
  assert(not dashboard_text():find("Excluded later", 1, true))
  eq(read(path), "## To Do\n- [x] Check me\n")
end)

test("refresh picks up moved line numbers", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  write(root, "a.md", "# New title\n\nIntro\n\n## To Do\n- Task\n")
  lattice.refresh()
  press_enter_on("Task")
  eq(vim.api.nvim_buf_get_name(0), path)
  eq(vim.api.nvim_win_get_cursor(0)[1], 6)
end)

test("a config broken at refresh clears tasks and shows the error", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  write(root, ".lattice.json", "{ nope")
  lattice.refresh()
  assert(dashboard_text():find("ERROR", 1, true))
  assert(not dashboard_text():find("Task", 1, true))
  eq(H.last_notify().level, vim.log.levels.ERROR)
end)
