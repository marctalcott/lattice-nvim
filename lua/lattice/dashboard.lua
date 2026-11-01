-- Dashboard rendering and its buffer. render() is pure; the rest drives Neovim.
local config = require("lattice.config")
local scanner = require("lattice.scanner")

local M = {}

local BUFFER_NAME = "lattice://dashboard"
local MIN_WIDTH = 34
local MAX_TEXT_COLUMN = 60
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local FOOTER = "Enter: Open original note   r: Refresh   q: Close"

local ns = vim.api.nvim_create_namespace("lattice.dashboard")
local state = { buf = nil, prev_buf = nil, result = nil, targets = {} }

local function width(text)
  return vim.fn.strdisplaywidth(text)
end

local function pad(text, column)
  return text .. (" "):rep(math.max(0, column - width(text)))
end

local function date_label(iso, today)
  local y, m, d = iso:match("^(%d+)-(%d+)-(%d+)$")
  local label = ("%s %d"):format(MONTHS[tonumber(m)], tonumber(d))
  if y ~= today:sub(1, 4) then
    label = label .. ", " .. y
  end
  return label
end

--- Open tasks in one section: dated by ascending date, then undated, both in
--- stable file-and-line order.
function M.sorted(tasks, section)
  local open = vim.tbl_filter(function(task)
    return task.section == section and not task.done
  end, tasks)
  table.sort(open, function(a, b)
    if a.due ~= b.due then
      if a.due and b.due then
        return a.due < b.due
      end
      return a.due ~= nil
    end
    if a.rel ~= b.rel then
      return a.rel < b.rel
    end
    return a.line < b.line
  end)
  return open
end

local function build_rows(tasks, today)
  local name_col, text_col = 0, 0
  local rows = {}
  for _, task in ipairs(tasks) do
    local row = { task = task, text = task.text ~= "" and task.text or "(no description)" }
    if task.section == "waiting" then
      row.name = task.person or "Unassigned"
      name_col = math.max(name_col, width(row.name))
    end
    text_col = math.max(text_col, width(row.text))
    rows[#rows + 1] = row
  end
  text_col = math.min(text_col, MAX_TEXT_COLUMN)

  for _, row in ipairs(rows) do
    local line = "  "
    local parts = {}
    if row.name then
      parts[#parts + 1] = { col = #line, len = #row.name, hl = "Identifier" }
      line = line .. pad(row.name, name_col) .. "  "
    end
    line = line .. row.text
    local due, promised = row.task.due, row.task.promised
    if due or promised then
      line = pad(line, 2 + (row.name and name_col + 2 or 0) + text_col) .. "  "
    end
    if due then
      local label = date_label(due, today)
      local overdue = due < today
      if overdue then
        label = label .. "  overdue"
      end
      parts[#parts + 1] = { col = #line, len = #label, hl = overdue and "DiagnosticError" or "Comment" }
      line = line .. label .. (promised and "  " or "")
    end
    if promised then
      local label = "promised " .. date_label(promised, today)
      parts[#parts + 1] = { col = #line, len = #label, hl = "Comment" }
      line = line .. label
    end
    row.line, row.parts = line, parts
  end
  return rows
end

local function build_inbox_rows(captures, today)
  local title_col = 0
  for _, capture in ipairs(captures) do
    title_col = math.max(title_col, width(capture.title))
  end
  title_col = math.min(title_col, MAX_TEXT_COLUMN)

  return vim.tbl_map(function(capture)
    local line = pad("  " .. capture.title, 2 + title_col) .. "  "
    local label = date_label(capture.date, today)
    return {
      task = { path = capture.path, line = 1 },
      line = line .. label,
      parts = { { col = #line, len = #label, hl = "Comment" } },
    }
  end, captures)
end

--- @param result table  output of scanner.collect
--- @param today string  YYYY-MM-DD
--- @return { lines: string[], highlights: table[], targets: table<integer, table> }
function M.render(result, today)
  local lines, highlights, targets = {}, {}, {}

  local function add(line, group)
    lines[#lines + 1] = line
    if group then
      highlights[#highlights + 1] = { line = #lines - 1, col = 0, len = #line, hl = group }
    end
  end

  local groups = {}
  if not result.error then
    for _, group in ipairs({ { "MY TO DO", "todo" }, { "WAITING ON", "waiting" } }) do
      groups[#groups + 1] = { title = group[1], rows = build_rows(M.sorted(result.tasks, group[2]), today) }
    end
    if result.inbox then
      groups[#groups + 1] = { title = "INBOX", rows = build_inbox_rows(result.inbox, today) }
    end
  end

  local rule_width = MIN_WIDTH
  for _, group in ipairs(groups) do
    for _, row in ipairs(group.rows) do
      rule_width = math.max(rule_width, width(row.line))
    end
  end

  add("LATTICE", "Title")
  add(("─"):rep(rule_width), "Comment")

  if result.error then
    add("ERROR", "DiagnosticError")
    for _, line in ipairs(vim.split(result.error, "\n", { plain = true })) do
      add("  " .. line)
    end
    add("")
  end

  for _, group in ipairs(groups) do
    local count = ("(%d)"):format(#group.rows)
    add(pad(group.title, rule_width - #count) .. count, "Title")
    if #group.rows == 0 then
      add("  (none)", "Comment")
    end
    for _, row in ipairs(group.rows) do
      add(row.line)
      targets[#lines] = { path = row.task.path, line = row.task.line }
      for _, part in ipairs(row.parts) do
        highlights[#highlights + 1] = { line = #lines - 1, col = part.col, len = part.len, hl = part.hl }
      end
    end
    add("")
  end

  local has_notices = result.notice or #result.unreadable > 0 or #result.date_errors > 0
  if has_notices then
    add("NOTICES", "DiagnosticWarn")
    if result.notice then
      add("  " .. result.notice)
    end
    if #result.unreadable > 0 then
      add(("  Could not read %d path(s):"):format(#result.unreadable))
      for _, item in ipairs(result.unreadable) do
        add(("    %s: %s"):format(item.path, item.message))
      end
    end
    if #result.date_errors > 0 then
      add(("  Invalid dates, ignored (%d):"):format(#result.date_errors))
      for _, item in ipairs(result.date_errors) do
        add(("    %s:%d [%s:%s]"):format(item.rel, item.line, item.tag, item.value))
        targets[#lines] = { path = item.path, line = item.line }
      end
    end
    add("")
  end

  add(FOOTER, "Comment")
  return { lines = lines, highlights = highlights, targets = targets }
end

local function buffer_ready()
  return state.buf ~= nil and vim.api.nvim_buf_is_loaded(state.buf)
end

local function paint()
  local view = M.render(state.result, os.date("%Y-%m-%d"))
  local buf = state.buf
  state.targets = view.targets

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, item in ipairs(view.highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, item.line, item.col, {
      end_col = item.col + item.len,
      hl_group = item.hl,
    })
  end

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    if cursor[1] > #view.lines then
      vim.api.nvim_win_set_cursor(win, { #view.lines, 0 })
    end
  end
end

local function report()
  local result = state.result
  if result.error then
    vim.notify("Lattice: " .. result.error, vim.log.levels.ERROR)
    return
  end
  local summary = ("Lattice: %d to do, %d waiting"):format(
    #M.sorted(result.tasks, "todo"),
    #M.sorted(result.tasks, "waiting")
  )
  if result.inbox and #result.inbox > 0 then
    summary = ("%s, %d in inbox"):format(summary, #result.inbox)
  end
  local problems = #result.unreadable + #result.date_errors
  if problems > 0 then
    summary = ("%s; %d notice(s), see dashboard"):format(summary, problems)
  end
  vim.notify(summary, problems > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

--- Rereads config and Markdown from disk.
function M.refresh()
  state.result = scanner.collect(config.options.root)
  if buffer_ready() then
    paint()
  end
  report()
end

function M.is_dashboard(buf)
  return buf == state.buf
end

function M.jump()
  local target = state.targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    return
  end
  if vim.fn.filereadable(target.path) == 0 then
    vim.notify("Lattice: " .. target.path .. " no longer exists; press r to refresh", vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target.path))
  if not ok then
    vim.notify("Lattice: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(target.line, last), 0 })
end

function M.close()
  local buf = state.buf
  if not buffer_ready() then
    return
  end
  local prev = state.prev_buf
  if prev and prev ~= buf and vim.api.nvim_buf_is_loaded(prev) then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_set_buf(win, prev)
    end
  end
  state.buf, state.prev_buf, state.result, state.targets = nil, nil, nil, {}
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function create_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFFER_NAME)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "lattice"

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", M.jump, "Lattice: open original note")
  map("r", M.refresh, "Lattice: refresh")
  map("q", M.close, "Lattice: close")
  return buf
end

--- Opens the dashboard, or focuses it if it already exists.
function M.open()
  local current = vim.api.nvim_get_current_buf()

  if buffer_ready() then
    local win = vim.fn.bufwinid(state.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      state.prev_buf = current
      vim.api.nvim_win_set_buf(0, state.buf)
    end
    return
  end

  state.prev_buf = current
  state.buf = create_buffer()
  state.result = scanner.collect(config.options.root)
  vim.api.nvim_win_set_buf(0, state.buf)
  paint()

  local first
  for line in pairs(state.targets) do
    first = first and math.min(first, line) or line
  end
  if first then
    vim.api.nvim_win_set_cursor(0, { first, 0 })
  end
  if state.result.error then
    report()
  end
end

return M
