-- Run from anywhere: nvim -l tests/run.lua
local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(script, ":p:h:h")
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
local lattice = require("lattice")
local parser = require("lattice.parser")
local scanner = require("lattice.scanner")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end

local function eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local HEADINGS = config.defaults().headings

local function parse(text)
  return parser.parse(vim.split(text, "\n", { plain = true }), HEADINGS)
end

local function texts(result)
  return vim.tbl_map(function(task)
    return task.text
  end, result.tasks)
end

local function write(root, rel, content)
  local path = root .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
  return path
end

local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local function notes()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return vim.uv.fs_realpath(root)
end

local function reset(root)
  dashboard.close()
  vim.cmd("silent! %bwipeout!")
  config.options.root = root
end

-- Silence notifications, keeping the last one for assertions.
local last_notify
vim.notify = function(message, level)
  last_notify = { message = message, level = level }
end

local function dashboard_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function press_enter_on(text)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      dashboard.jump()
      return
    end
  end
  error("no dashboard line contains " .. text)
end

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

-- Config ---------------------------------------------------------------------

test("a missing config uses defaults with a notice", function()
  local cfg, notice, err = config.load(notes())
  eq(cfg, config.defaults())
  assert(notice:find(".lattice.json", 1, true))
  eq(err, nil)
end)

test("malformed configs give an error and scan nothing", function()
  local bad = {
    "{ nope",
    "",
    '{"version": 2}',
    '{"scan": "x"}',
    '{"scan": {"include": "**/*.md"}}',
    '{"scan": {"exclude": [1]}}',
    '{"scan": {"include": ["../**/*.md"]}}',
    '{"scan": {"include": ["/etc/**"]}}',
    '{"headings": {"todo": ""}}',
    '{"headings": {"todo": "Same", "waiting": "Same"}}',
  }
  for _, content in ipairs(bad) do
    local root = notes()
    write(root, ".lattice.json", content)
    write(root, "a.md", "## To Do\n- Task")
    local result = scanner.collect(root)
    assert(result.error, "expected an error for: " .. content)
    eq(result.tasks, {})
  end
end)

test("rejects an inbox outside the notes root", function()
  for _, path in ipairs({ "../Inbox", "/tmp/Inbox", "~/Inbox", "a/../../b", "", 1 }) do
    local root = notes()
    write(root, ".lattice.json", vim.json.encode({ inbox = { path = path } }))
    assert(scanner.collect(root).error, "expected an error for: " .. tostring(path))
  end
end)

test("an unset or missing root is an error, never a fallback", function()
  assert(scanner.collect(nil).error)
  assert(scanner.collect("/no/such/lattice/root").error)
end)

test("partial config keeps other defaults; an empty exclude removes Archives", function()
  local root = notes()
  write(root, ".lattice.json", '{"scan": {"exclude": []}}')
  write(root, "Archives/old.md", "## To Do\n- Old")
  local result = scanner.collect(root)
  eq(result.tasks[1].text, "Old")
end)

test("setup can disable or override keymaps", function()
  local saved = vim.deepcopy(config.options)
  lattice.setup({ root = "~/x", keymaps = { refresh = false, open = "<leader>zz" } })
  eq(vim.fn.maparg("<leader>zz", "n") ~= "" or vim.fn.mapcheck("<leader>zz", "n") ~= "", true)
  eq(config.options.keymaps.refresh, false)
  eq(config.options.keymaps.add_todo, "<leader>lt")
  eq(config.setup({ keymaps = false }).keymaps, false)
  config.options = saved
end)

-- Scanning -------------------------------------------------------------------

test("scans PARA folders and honors exclusions", function()
  local root = notes()
  write(root, ".lattice.json", '{"scan": {"include": ["**/*.md"], "exclude": ["Archives/**", "**/drafts/**", "Areas/skip.md"]}}')
  local task = "## To Do\n- Task"
  for _, rel in ipairs({ "Projects/a/n.md", "Areas/n.md", "Resources/n.md", "top.md" }) do
    write(root, rel, task)
  end
  for _, rel in ipairs({ "Archives/old/n.md", "Projects/drafts/n.md", "Areas/skip.md", "Projects/a/n.txt" }) do
    write(root, rel, task)
  end
  local files = scanner.list_files(root, config.load(root).scan)
  eq(files, { "Areas/n.md", "Projects/a/n.md", "Resources/n.md", "top.md" })
end)

test("* stays within one path segment", function()
  local root = notes()
  write(root, "Projects/a.md", "")
  write(root, "Projects/deep/b.md", "")
  local files = scanner.list_files(root, { include = { "Projects/*.md" }, exclude = {} })
  eq(files, { "Projects/a.md" })
end)

test("excluded directories are not entered", function()
  local root = notes()
  write(root, "Archives/secret/n.md", "")
  vim.fn.setfperm(root .. "/Archives/secret", "---------")
  local _, errors = scanner.list_files(root, config.defaults().scan)
  vim.fn.setfperm(root .. "/Archives/secret", "rwxr-xr-x")
  eq(errors, {})
end)

test("symlinks are never followed", function()
  local root, outside = notes(), notes()
  write(outside, "out.md", "## To Do\n- Outside")
  write(root, "in.md", "## To Do\n- Inside")
  assert(vim.uv.fs_symlink(outside, root .. "/linked"))
  assert(vim.uv.fs_symlink(outside .. "/out.md", root .. "/linked.md"))
  eq(scanner.list_files(root, config.defaults().scan), { "in.md" })
end)

test("unreadable files are reported and do not stop the scan", function()
  local root = notes()
  write(root, "good.md", "## To Do\n- Good")
  local bad = write(root, "bad.md", "## To Do\n- Bad")
  vim.fn.setfperm(bad, "---------")
  local result = scanner.collect(root)
  vim.fn.setfperm(bad, "rw-r--r--")
  eq(texts(result), { "Good" })
  eq(#result.unreadable, 1)
  eq(result.unreadable[1].path, "bad.md")
end)

test("scanning changes no file", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\r\n- [x] Done\n")
  local before = read(path)
  local mtime = vim.uv.fs_stat(path).mtime
  scanner.collect(root)
  eq(read(path), before)
  eq(vim.uv.fs_stat(path).mtime, mtime)
  eq(vim.fn.readdir(root), { "a.md" })
end)

-- Inbox ----------------------------------------------------------------------

test("a missing inbox produces no list and no error", function()
  local root = notes()
  write(root, "a.md", "")
  eq(scanner.collect(root).inbox, nil)
end)

test("lists captures oldest first with titles from the first line", function()
  local root = notes()
  local new = write(root, "Inbox/new.md", "\n\n# Heard in hallway\nBody")
  local old = write(root, "Inbox/sub/old.md", "Plain first line\n")
  write(root, "Inbox/empty-capture.md", "")
  write(root, "Inbox/skip.txt", "ignored")
  vim.uv.fs_utime(new, 2000000000, 2000000000)
  vim.uv.fs_utime(old, 1000000000, 1000000000)
  vim.uv.fs_utime(root .. "/Inbox/empty-capture.md", 1500000000, 1500000000)
  local inbox = scanner.collect(root).inbox
  eq(vim.tbl_map(function(c)
    return c.title
  end, inbox), { "Plain first line", "empty-capture", "Heard in hallway" })
  eq(inbox[1].rel, "Inbox/sub/old.md")
end)

test("the inbox ignores scan.exclude, while excluding it hides its tasks", function()
  local root = notes()
  write(root, ".lattice.json", '{"scan": {"exclude": ["Inbox/**"]}}')
  write(root, "Inbox/cap.md", "## To Do\n- Captured")
  local result = scanner.collect(root)
  eq(result.tasks, {})
  eq(#result.inbox, 1)
end)

test("inbox tasks are scanned unless excluded", function()
  local root = notes()
  write(root, "Inbox/cap.md", "## To Do\n- Captured")
  local result = scanner.collect(root)
  eq(texts(result), { "Captured" })
  eq(#result.inbox, 1)
end)

test("honors a configured inbox path", function()
  local root = notes()
  write(root, ".lattice.json", '{"inbox": {"path": "Areas/Capture/"}}')
  write(root, "Areas/Capture/cap.md", "Capture")
  write(root, "Inbox/other.md", "Other")
  local inbox = scanner.collect(root).inbox
  eq(#inbox, 1)
  eq(inbox[1].rel, "Areas/Capture/cap.md")
end)

test("a symlinked inbox is not followed", function()
  local root, outside = notes(), notes()
  write(outside, "out.md", "Outside")
  assert(vim.uv.fs_symlink(outside, root .. "/Inbox"))
  eq(scanner.collect(root).inbox, nil)
end)

test("unreadable captures are reported and the rest still list", function()
  local root = notes()
  write(root, "Inbox/good.md", "Good")
  local bad = write(root, "Inbox/bad.md", "Bad")
  vim.fn.setfperm(bad, "---------")
  local result = scanner.collect(root)
  vim.fn.setfperm(bad, "rw-r--r--")
  eq(#result.inbox, 1)
  local paths = vim.tbl_map(function(item)
    return item.path
  end, result.unreadable)
  assert(vim.tbl_contains(paths, "Inbox/bad.md"))
end)

test("listing the inbox changes no file", function()
  local root = notes()
  local path = write(root, "Inbox/cap.md", "Capture\n")
  local mtime = vim.uv.fs_stat(path).mtime
  scanner.collect(root)
  eq(read(path), "Capture\n")
  eq(vim.uv.fs_stat(path).mtime, mtime)
end)

test("Enter opens a capture and a filed capture leaves after refresh", function()
  local root = notes()
  local path = write(root, "Inbox/cap.md", "Call the vendor\nMore")
  reset(root)
  lattice.open()
  assert(dashboard_text():find("INBOX%s+%(1%)"))
  press_enter_on("Call the vendor")
  eq(vim.api.nvim_buf_get_name(0), path)
  eq(vim.api.nvim_win_get_cursor(0)[1], 1)

  vim.fn.mkdir(root .. "/Projects", "p")
  assert(os.rename(path, root .. "/Projects/cap.md"))
  lattice.open()
  lattice.refresh()
  assert(dashboard_text():find("INBOX%s+%(0%)"))
end)

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

test("renders groups, counts, assignees, dates, and overdue marks", function()
  local view = dashboard.render({
    tasks = {
      task({ text = "Send update", due = "2026-11-05", path = "/n/a.md", line = 4 }),
      task({ text = "Old", due = "2026-10-01" }),
      task({ section = "waiting", person = "Raju", text = "Estimate", path = "/n/a.md", line = 9 }),
      task({ section = "waiting", text = "Nobody", due = "2027-01-02" }),
      task({ text = "Hidden", done = true }),
    },
    date_errors = {},
    unreadable = {},
  }, "2026-11-01")
  local text = table.concat(view.lines, "\n")
  assert(text:find("MY TO DO%s+%(2%)"))
  assert(text:find("WAITING ON%s+%(2%)"))
  assert(text:find("Send update  Nov 5"))
  assert(text:find("Oct 1  overdue", 1, true))
  assert(text:find("Raju", 1, true))
  assert(text:find("Unassigned", 1, true))
  assert(text:find("Jan 2, 2027", 1, true))
  assert(not text:find("Hidden", 1, true))
  local groups = vim.tbl_filter(function(h)
    return h.hl == "DiagnosticError"
  end, view.highlights)
  eq(#groups, 1)
end)

test("shows promised dates without marking them overdue or sorting by them", function()
  local waiting = { section = "waiting" }
  local tasks = {
    task(vim.tbl_extend("keep", { text = "Past promise", promised = "2026-10-01" }, waiting)),
    task(vim.tbl_extend("keep", { text = "Both", due = "2026-11-05", promised = "2026-11-03" }, waiting)),
  }
  eq(dashboard.sorted(tasks, "waiting")[1].text, "Both")
  local view = dashboard.render({ tasks = tasks, date_errors = {}, unreadable = {} }, "2026-11-01")
  local text = table.concat(view.lines, "\n")
  assert(text:find("Nov 5  promised Nov 3", 1, true))
  assert(text:find("promised Oct 1", 1, true))
  assert(not text:find("overdue", 1, true))
end)

test("a date due today is not overdue", function()
  local view = dashboard.render({
    tasks = { task({ due = "2026-11-01" }) },
    date_errors = {},
    unreadable = {},
  }, "2026-11-01")
  assert(not table.concat(view.lines, "\n"):find("overdue", 1, true))
end)

test("shows empty groups and scan problems", function()
  local view = dashboard.render({
    tasks = {},
    notice = "No config",
    unreadable = { { path = "bad.md", message = "EACCES" } },
    date_errors = { { rel = "a.md", path = "/n/a.md", line = 3, tag = "due", value = "soon" } },
  }, "2026-11-01")
  local text = table.concat(view.lines, "\n")
  assert(text:find("(none)", 1, true))
  assert(text:find("No config", 1, true))
  assert(text:find("bad.md: EACCES", 1, true))
  assert(text:find("a.md:3 [due:soon]", 1, true))
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

test("Enter on an invalid-date notice opens that line", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\n- Other [due:soon]\n")
  reset(root)
  lattice.open()
  press_enter_on("a.md:3")
  eq(vim.api.nvim_buf_get_name(0), path)
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
end)

test("Enter on a deleted file warns instead of creating a buffer", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  os.remove(path)
  press_enter_on("Task")
  eq(vim.bo.filetype, "lattice")
  assert(last_notify.message:find("no longer exists", 1, true))
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
  eq(last_notify.level, vim.log.levels.ERROR)
end)

-- Insertion ------------------------------------------------------------------

local function with_inputs(values, fn)
  local saved = vim.ui.input
  vim.ui.input = function(_, callback)
    callback(table.remove(values, 1))
  end
  fn()
  vim.ui.input = saved
end

local function note_buffer(text)
  vim.cmd("enew!")
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

test("adds to the end of an existing section, past blanks and subitems", function()
  reset(nil)
  note_buffer("## To Do\n- One\n  - Sub\n\n## Notes\nText")
  with_inputs({ "New task" }, lattice.add_todo)
  eq(buffer_text(), "## To Do\n- One\n  - Sub\n- [ ] New task\n\n## Notes\nText")
end)

test("adds under a heading with an empty section", function()
  reset(nil)
  note_buffer("## Waiting On\n\n## Notes")
  with_inputs({ "Estimate", "@Raju" }, lattice.add_waiting)
  eq(buffer_text(), "## Waiting On\n- [ ] @Raju Estimate\n\n## Notes")
end)

test("creates a missing section at the end of the note", function()
  reset(nil)
  note_buffer("# Title\nText")
  with_inputs({ "Task" }, lattice.add_todo)
  eq(buffer_text(), "# Title\nText\n\n## To Do\n- [ ] Task")
end)

test("does not reuse a section-like heading inside a code fence", function()
  reset(nil)
  note_buffer("```\n## To Do\n```")
  with_inputs({ "Task" }, lattice.add_todo)
  eq(buffer_text(), "```\n## To Do\n```\n\n## To Do\n- [ ] Task")
end)

test("fills an empty note", function()
  reset(nil)
  note_buffer("")
  with_inputs({ "Task" }, lattice.add_todo)
  eq(buffer_text(), "## To Do\n- [ ] Task")
end)

test("uses headings from .lattice.json", function()
  local root = notes()
  write(root, ".lattice.json", '{"headings": {"todo": "Mine"}}')
  reset(root)
  note_buffer("## Mine\n- One")
  with_inputs({ "Two" }, lattice.add_todo)
  eq(buffer_text(), "## Mine\n- One\n- [ ] Two")
end)

test("rejects a multi-word assignee", function()
  reset(nil)
  note_buffer("# Title")
  with_inputs({ "Task", "Two Words" }, lattice.add_waiting)
  eq(buffer_text(), "# Title")
end)

test("cancelled prompts change nothing", function()
  reset(nil)
  note_buffer("# Title")
  with_inputs({ false }, lattice.add_todo)
  with_inputs({ "" }, lattice.add_todo)
  with_inputs({ "Task", false }, lattice.add_waiting)
  eq(buffer_text(), "# Title")
end)

test("insertion leaves the buffer unsaved and the file untouched", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- One\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  with_inputs({ "Two" }, lattice.add_todo)
  eq(vim.bo.modified, true)
  eq(read(path), "## To Do\n- One\n")
  vim.cmd("bwipeout!")
end)

test("never inserts into the dashboard or a non-Markdown buffer", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
  reset(root)
  lattice.open()
  local before = dashboard_text()
  with_inputs({ "Nope" }, lattice.add_todo)
  eq(dashboard_text(), before)

  vim.cmd("enew!")
  vim.bo.filetype = "lua"
  with_inputs({ "Nope" }, lattice.add_todo)
  eq(buffer_text(), "")
end)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
