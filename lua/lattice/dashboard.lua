-- Dashboard rendering and its buffer. render() is pure; the rest drives Neovim.
local config = require("lattice.config")
local scanner = require("lattice.scanner")

local M = {}

local BUFFER_NAME = "lattice://dashboard"
local MIN_WIDTH = 50
local MAX_TEXT_COLUMN = 60
-- Org's org-deadline-warning-days, when .lattice.json sets none.
local DEFAULT_WARNING_DAYS = 14
local DONE_LIMIT = 20 -- most recent done items shown
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local FOOTER = "Enter  Open note    r  Refresh    q  Close    ?  Help"
local FOOTER_2 = "1 Overview  2 Week  3 TODOs  4 Projects    F Filter    t State  +/- Priority  S/D Dates  s Save"
local VIEW_NAMES = { overview = "Overview", week = "Week agenda", todo = "All TODOs", projects = "Projects" }

local WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = false,
  list = false,
  spell = false,
  cursorline = true,
}

local ns = vim.api.nvim_create_namespace("lattice.dashboard")
local state = {
  buf = nil,
  prev_buf = nil,
  result = nil,
  targets = {},
  help = false,
  view = "overview", -- overview | week | todo | projects
  query = "", -- agenda filter (agenda.parse_filter)
  week_start = nil, -- Monday shown by the week view; nil: this week
  edited = {}, -- buffers changed from the dashboard, by number
}

local function width(text)
  return vim.fn.strdisplaywidth(text)
end

local function pad(text, column)
  return text .. (" "):rep(math.max(0, column - width(text)))
end

local schedule = require("lattice.schedule")
local agenda = require("lattice.agenda")

-- English weekday abbreviation of an ISO date, independent of locale.
local function weekday(iso)
  local y, m, d = iso:match("^(%d+)-(%d+)-(%d+)$")
  return require("lattice.timestamp").weekday(tonumber(y), tonumber(m), tonumber(d))
end

local function date_label(iso, today)
  local y, m, d = iso:match("^(%d+)-(%d+)-(%d+)$")
  local label = ("%s %s"):format(MONTHS[tonumber(m)], d)
  if y ~= today:sub(1, 4) then
    label = label .. ", " .. y
  end
  return label
end

-- English names regardless of locale, matching the row date labels.
local function header_date(today)
  local _, m, d = today:match("^(%d+)-(%d+)-(%d+)$")
  return ("%s %s %s"):format(weekday(today), MONTHS[tonumber(m)], d)
end

local function by_due_then_source(a, b)
  if a.due ~= b.due then
    if a.due and b.due then
      return a.due < b.due
    end
    return a.due ~= nil
  end
  if a.rel ~= b.rel then
    return (a.rel or "") < (b.rel or "")
  end
  return a.line < b.line
end

local function sort_open(tasks, keep)
  local open = vim.tbl_filter(function(task)
    return not task.done and keep(task)
  end, tasks)
  table.sort(open, by_due_then_source)
  return open
end

--- Open tasks in one section: dated by ascending date, then undated, both in
--- stable file-and-line order.
function M.sorted(tasks, section)
  return sort_open(tasks, function(task)
    return task.section == section
  end)
end

--- Items in a done state (DONE, CANCELED, ...): most recently modified file
--- first, then file and line. Checked `[x]` items without a keyword stay
--- hidden.
function M.done(tasks)
  local done = vim.tbl_filter(function(task)
    return task.done and task.state ~= nil
  end, tasks)
  table.sort(done, function(a, b)
    if (a.mtime or 0) ~= (b.mtime or 0) then
      return (a.mtime or 0) > (b.mtime or 0)
    end
    if a.rel ~= b.rel then
      return (a.rel or "") < (b.rel or "")
    end
    return a.line < b.line
  end)
  return done
end

--- Open tasks with a deadline (or v0.1 [due:]) before today, oldest first.
function M.overdue(tasks, today)
  return sort_open(tasks, function(task)
    return task.due ~= nil and schedule.deadline_status(task.due, today, 0) == "overdue"
  end)
end

--- Org's daily agenda for today (§8.2, §9.3): open tasks scheduled today,
--- or earlier and still open, and deadlines due today. Scheduled first, by
--- date, then deadlines.
function M.today(tasks, today)
  local list = vim.tbl_filter(function(task)
    if task.done then
      return false
    end
    if task.scheduled then
      local status = schedule.scheduled_status(task.scheduled, today)
      if status == "today" or status == "past" then
        return true
      end
    end
    return task.due ~= nil and task.due == today
  end, tasks)
  table.sort(list, function(a, b)
    local sa, sb = a.scheduled and a.scheduled.date or "9999", b.scheduled and b.scheduled.date or "9999"
    if sa ~= sb then
      return sa < sb
    end
    return by_due_then_source(a, b)
  end)
  return list
end

--- Open tasks whose deadline is after today but inside its warning period:
--- the deadline's own `-Nd`, else `warning_days` (§9.2). Soonest first.
function M.due_soon(tasks, today, warning_days)
  warning_days = warning_days or DEFAULT_WARNING_DAYS
  return sort_open(tasks, function(task)
    if task.due == nil then
      return false
    end
    local warning = task.deadline and schedule.warning_days(task.deadline, warning_days) or warning_days
    return schedule.deadline_status(task.due, today, warning) == "upcoming"
  end)
end

-- forward declaration; defined after build_rows
local build_rows

-- The DONE group: the most recent DONE_LIMIT items, with the full count in
-- the title and a closing line for the rest.
function M.done_group(tasks, today, col)
  local done = M.done(tasks)
  local shown = vim.list_slice(done, 1, DONE_LIMIT)
  local group = { title = "DONE", count = #done, rows = build_rows(shown, today, "[x]", "DiagnosticOk", col, true) }
  if #done > DONE_LIMIT then
    group.more = ("  … and %d more (the %d most recent are shown)"):format(#done - DONE_LIMIT, DONE_LIMIT)
  end
  return group
end

-- "STATE Name — text", plus highlight spans relative to the label start.
local function task_label(task)
  local label, spans = "", {}
  if task.state then
    spans[#spans + 1] = { col = 0, len = #task.state, hl = task.done and "DiagnosticOk" or "Todo" }
    label = task.state .. " "
  end
  if task.priority then
    local cookie = "[#" .. task.priority .. "]"
    spans[#spans + 1] = { col = #label, len = #cookie, hl = "Special" }
    label = label .. cookie .. " "
  end
  local person = task.person
  if task.section == "waiting" then
    person = person or "Unassigned"
  end
  if person then
    spans[#spans + 1] = { col = #label, len = #person, hl = "Identifier" }
    label = label .. person .. " — "
  end
  label = label .. (task.text ~= "" and task.text or "(no description)")
  local tags = task.tags or {}
  if #tags > 0 then
    local text = " :" .. table.concat(tags, ":") .. ":"
    spans[#spans + 1] = { col = #label + 1, len = #text - 1, hl = "Comment" }
    label = label .. text
  end
  return label, spans
end

-- Width of the widest task label, capped, so dates line up across groups.
local function label_column(tasks)
  local column = 0
  for _, task in ipairs(tasks) do
    column = math.max(column, width((task_label(task))))
  end
  return math.min(column, MAX_TEXT_COLUMN)
end

-- Builds one row per task: `mark` prefix, label, then dates in a column
-- (unless `no_dates`).
function build_rows(tasks, today, mark, mark_hl, text_col, no_dates)
  local rows = {}
  for _, task in ipairs(tasks) do
    local label, spans = task_label(task)
    rows[#rows + 1] = { task = task, label = label, spans = spans }
  end

  local prefix = "  " .. mark .. " "
  for _, row in ipairs(rows) do
    local task = no_dates and { line = row.task.line } or row.task
    local parts = { { col = 2, len = #mark, hl = mark_hl } }
    for _, span in ipairs(row.spans) do
      parts[#parts + 1] = { col = #prefix + span.col, len = span.len, hl = span.hl }
    end
    local line = prefix .. row.label
    if task.due or task.promised or task.scheduled then
      -- "  [ ] " is the widest prefix; dates line up after it in every group.
      line = pad(line, 6 + text_col) .. "    "
    end
    if task.due then
      local label = date_label(task.due, today)
      parts[#parts + 1] = { col = #line, len = #label, hl = task.due < today and "DiagnosticError" or "Comment" }
      line = line .. label .. ((task.promised or task.scheduled) and "  " or "")
    end
    if task.scheduled then
      local label = "sched " .. date_label(task.scheduled.date, today)
      parts[#parts + 1] = { col = #line, len = #label, hl = "Comment" }
      line = line .. label .. (task.promised and "  " or "")
    end
    if task.promised then
      local label = "promised " .. date_label(task.promised, today)
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
    local line = pad("  " .. capture.title, 2 + title_col) .. "    "
    local label = date_label(capture.date, today)
    return {
      task = { path = capture.path, line = 1 },
      line = line .. label,
      parts = { { col = #line, len = #label, hl = "Comment" } },
    }
  end, captures)
end

local function help_lines(keymaps)
  local lines = {
    "KEYS",
    "  Enter   Open the note at the task (on a project: list its TODOs)",
    "  1 2 3 4 Overview, week agenda, all TODOs (by priority), projects",
    "  F       Filter: +tag -tag #A project:Name @person state:NEXT words",
    "  /       Search the dashboard text, as in any buffer",
    "  b f .   Previous, next, this week (week agenda)",
    "  t       Change the task's state (Org agenda's t)",
    "  + -     Raise or lower its priority",
    "  S D     Set or remove its SCHEDULED / DEADLINE",
    "  s       Save the notes edited from here",
    "  r       Rescan changed notes and reread .lattice.json",
    "  q       Close the dashboard",
    "  ?       Toggle this help",
    "",
    "COMMANDS",
    "  :Lattice            Open the dashboard",
    "  :LatticeRefresh     Rescan notes and reread .lattice.json",
    "  :LatticeHealth      Show config, unreadable files, invalid dates",
    "  :LatticeAddTodo     Add a ## TODO heading",
    "  :LatticeAddWaiting  Add a ## WAITING heading",
    "  :LatticeNextState   Move the heading under the cursor to its next state",
    "  :LatticePrevState   Move the heading under the cursor to its previous state",
    "  :LatticeSetState    Choose the heading's state",
    "  :LatticeToggleCheckbox  Toggle the checkbox under the cursor",
    "  :LatticeSchedule / :LatticeDeadline  Set or remove a date",
    "  :LatticePriorityUp / :LatticePriorityDown  Change [#A]",
    "  :LatticeMigrate     Convert this note's v0.1 items to Org",
    "  :LatticeRefile / :LatticeArchive  Move a subtree / archive it",
  }
  if keymaps then
    local mapped = {}
    for _, item in ipairs({
      { "open", "dashboard" },
      { "refresh", "refresh" },
      { "add_todo", "add TODO" },
      { "add_waiting", "add Waiting On" },
      { "next_state", "next state" },
      { "prev_state", "previous state" },
      { "set_state", "choose state" },
      { "toggle_checkbox", "toggle box" },
      { "schedule", "schedule" },
      { "deadline", "deadline" },
      { "priority_up", "priority up" },
      { "priority_down", "priority down" },
      { "refile", "refile" },
      { "archive", "archive" },
    }) do
      if keymaps[item[1]] then
        mapped[#mapped + 1] = ("%s %s"):format(keymaps[item[1]], item[2])
      end
    end
    if #mapped > 0 then
      lines[#lines + 1] = "  Keymaps: " .. table.concat(mapped, ", ")
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Lattice reads saved notes and unsaved open buffers; saving a note refreshes this view."
  return lines
end

local WEEK_NOTE_WIDTH = 12

--- Org's week agenda as dashboard groups: one per day, entries labelled
--- "Scheduled", "Deadline", "Sched. 3x", "In 4 d." or "2 d. ago", timed
--- entries with their time.
function M.week_groups(tasks, today, first, warning_days, priorities)
  local days = agenda.week(tasks, first, today, { warning_days = warning_days, priorities = priorities })
  local all = {}
  for _, day in ipairs(days) do
    for _, entry in ipairs(day.entries) do
      all[#all + 1] = entry.task
    end
  end
  local col = label_column(all)
  local groups = {}
  for _, day in ipairs(days) do
    local rows = {}
    for _, entry in ipairs(day.entries) do
      local note = entry.time and (entry.time .. " " .. entry.note) or entry.note
      local hl = entry.kind == "deadline" and (note:find("ago", 1, true) and "DiagnosticError" or "DiagnosticWarn") or "DiagnosticInfo"
      local row = build_rows({ entry.task }, today, pad(note, WEEK_NOTE_WIDTH), hl, col, true)[1]
      rows[#rows + 1] = row
    end
    local y, m, d = day.date:match("^(%d+)-(%d+)-(%d+)$")
    local label = ("%s %s %s"):format(weekday(day.date), MONTHS[tonumber(m)], d)
    if y ~= today:sub(1, 4) then
      label = label .. ", " .. y
    end
    groups[#groups + 1] = { title = label, note = day.today and "[today]" or nil, rows = rows }
  end
  return groups
end

--- The projects view: one row per project with counts, status and next
--- action. Enter lists the project's TODOs.
function M.projects_group(projects)
  local name_col = 0
  for _, project in ipairs(projects) do
    name_col = math.max(name_col, width(project.name))
  end
  local rows = {}
  for _, project in ipairs(projects) do
    local line = pad("  " .. project.name, 2 + name_col) .. ("   %d open, %d done"):format(project.open, project.done)
    local parts = { { col = 2, len = #project.name, hl = "Title" } }
    if project.status then
      line = line .. "   status: " .. project.status
    end
    if project.next then
      local next_text = "   next: " .. project.next.state .. " " .. project.next.title
      parts[#parts + 1] = { col = #line + 3, len = #next_text - 3, hl = "Comment" }
      line = line .. next_text
    end
    rows[#rows + 1] = { line = line, parts = parts, project = project.name, task = {} }
  end
  return { title = "PROJECTS", note = "[Enter lists a project's TODOs]", rows = rows }
end

--- @param result table  output of scanner.collect
--- @param today string  YYYY-MM-DD
--- @param opts? { help: boolean, keymaps: table|false }  keymaps: the ones actually mapped
--- @return { lines: string[], highlights: table[], targets: table<integer, table> }
function M.render(result, today, opts)
  opts = opts or {}
  local lines, highlights, targets = {}, {}, {}
  -- How many tasks in each note share a kind and title, so an edit can
  -- tell when one of them changed (M.locate counts the same way).
  local twins
  local function twin_count(task)
    twins = twins or agenda.tally(result.tasks or {}, agenda.task_key)
    return twins[agenda.task_key(task)]
  end

  local function add(line, group)
    lines[#lines + 1] = line
    if group then
      highlights[#highlights + 1] = { line = #lines - 1, col = 0, len = #line, hl = group }
    end
  end

  local groups = {}
  local open_count = 0
  local view = opts.view or "overview"
  if not result.error then
    local tasks = agenda.filter(result.tasks, opts.query)
    local warning_days = (result.deadlines or {}).warning_days or DEFAULT_WARNING_DAYS
    local todo, waiting = M.sorted(tasks, "todo"), M.sorted(tasks, "waiting")
    open_count = #todo + #waiting
    if view == "week" then
      groups = M.week_groups(tasks, today, opts.week_start or agenda.week_start(today), warning_days, result.priorities)
    elseif view == "todo" then
      local list = agenda.todo_list(tasks, nil, result.priorities)
      groups = {
        {
          title = "ALL TODOS",
          note = "[by priority, then deadline]",
          rows = build_rows(list, today, "[ ]", "Comment", label_column(list)),
        },
      }
    elseif view == "projects" then
      groups = { M.projects_group(agenda.projects(tasks, result.priorities)) }
      open_count = math.max(open_count, #groups[1].rows)
    else
      local col = label_column(vim.list_extend(vim.list_extend({}, todo), waiting))
      groups = {
        { title = "MY TO DO", rows = build_rows(todo, today, "[ ]", "Comment", col) },
        { title = "WAITING ON", rows = build_rows(waiting, today, "[ ]", "Comment", col) },
        { title = "OVERDUE", rows = build_rows(M.overdue(tasks, today), today, "! ", "DiagnosticError", col) },
        {
          title = "TODAY",
          note = "[scheduled today or earlier and still open; deadlines today]",
          rows = build_rows(M.today(tasks, today), today, "» ", "DiagnosticInfo", col),
        },
        {
          title = "DUE SOON",
          note = ("[deadlines within their warning period, default %d days]"):format(warning_days),
          rows = build_rows(M.due_soon(tasks, today, warning_days), today, "· ", "DiagnosticWarn", col),
        },
        M.done_group(tasks, today, col),
      }
      if result.inbox then
        groups[#groups + 1] = { title = "INBOX", rows = build_inbox_rows(result.inbox, today) }
      end
    end
  end

  local rule_width = MIN_WIDTH
  for _, group in ipairs(groups) do
    for _, row in ipairs(group.rows) do
      rule_width = math.max(rule_width, width(row.line))
    end
  end

  local date = header_date(today)
  add(pad("LATTICE", rule_width - width(date)) .. date, "Title")
  add("My management workspace — local notes", "Comment")
  if result.root then
    local where = vim.fn.fnamemodify(result.root, ":~")
    if result.files then
      where = ("%s  (%d note%s)"):format(where, result.files, result.files == 1 and "" or "s")
    end
    add(where, "Comment")
  end
  if view ~= "overview" or not agenda.is_empty(opts.query) then
    local status = "View: " .. VIEW_NAMES[view]
    if not agenda.is_empty(opts.query) then
      status = status .. "    Filter: " .. opts.query .. "    (F then Enter clears)"
    end
    add(status, "Special")
  end
  add(("─"):rep(rule_width), "Comment")

  if opts.help then
    for _, line in ipairs(help_lines(opts.keymaps)) do
      add(line, line:match("^%u+$") and "Title" or nil)
    end
    add(("─"):rep(rule_width), "Comment")
  end

  if result.error then
    add("ERROR", "DiagnosticError")
    for _, line in ipairs(vim.split(result.error, "\n", { plain = true })) do
      add("  " .. line)
    end
    add("")
  elseif open_count == 0 and agenda.is_empty(opts.query) and view == "overview" then
    local defaults = config.defaults()
    local headings = result.headings or defaults.headings
    local sequences = (result.keywords or defaults.keywords).sequences
    add("No open tasks found.", "Title")
    add(('  As in Org-mode, tasks are headings that start with a state (%s),'):format(table.concat(sequences, "; ")))
    add('  such as "## TODO Plan". Checkboxes are steps inside a task.')
    add("")
  end

  for _, group in ipairs(groups) do
    local title = ("%s (%d)"):format(group.title, group.count or #group.rows)
    add(title, "Title")
    if group.note then
      lines[#lines] = title .. "  " .. group.note
      highlights[#highlights + 1] = { line = #lines - 1, col = #title, len = #group.note + 2, hl = "Comment" }
    end
    if #group.rows == 0 then
      add("  (none)", "Comment")
    end
    for _, row in ipairs(group.rows) do
      add(row.line)
      targets[#lines] = row.project and { project = row.project }
        or {
          path = row.task.path,
          line = row.task.line,
          title = row.task.title,
          kind = row.task.kind,
          twins = row.task.title and twin_count(row.task),
        }
      for _, part in ipairs(row.parts) do
        highlights[#highlights + 1] = { line = #lines - 1, col = part.col, len = part.len, hl = part.hl }
      end
    end
    if group.more then
      add(group.more, "Comment")
    end
    add("")
  end

  if result.notice then
    add(result.notice, "DiagnosticWarn")
  end
  local unreadable, date_errors = result.unreadable or {}, result.date_errors or {}
  local file_warnings = result.warnings or {}
  local warnings = #unreadable + #date_errors + #file_warnings
  if warnings > 0 then
    local title = ("WARNINGS (%d)"):format(warnings)
    local note = "Enter opens the line; :LatticeHealth for details"
    add(title .. "  " .. note, "DiagnosticWarn")
    for _, item in ipairs(unreadable) do
      add(("  Could not read %s: %s"):format(item.path, item.message))
    end
    for _, item in ipairs(date_errors) do
      add(("  Invalid date, shown undated: %s:%d [%s:%s]"):format(item.rel, item.line, item.tag, item.value))
      targets[#lines] = { path = item.path, line = item.line }
    end
    for _, item in ipairs(file_warnings) do
      add(("  %s:%d %s"):format(item.rel, item.line, item.message))
      targets[#lines] = { path = item.path, line = item.line }
    end
    add("")
  end

  add(("─"):rep(rule_width), "Comment")
  add(FOOTER, "Comment")
  add(FOOTER_2, "Comment")
  return { lines = lines, highlights = highlights, targets = targets }
end

local function buffer_ready()
  return state.buf ~= nil and vim.api.nvim_buf_is_loaded(state.buf)
end

local function paint()
  local view = M.render(state.result, os.date("%Y-%m-%d"), {
    help = state.help,
    keymaps = config.active_keymaps,
    view = state.view,
    query = state.query,
    week_start = state.week_start,
  })
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
  local problems = #result.unreadable + #result.date_errors + #(result.warnings or {})
  if problems > 0 then
    summary = ("%s; %d warning(s), see :LatticeHealth"):format(summary, problems)
  end
  vim.notify(summary, problems > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

--- Rereads config and notes (only the ones that changed) and repaints.
--- `quiet` skips the summary message.
function M.refresh(quiet)
  state.result = scanner.collect(config.options.root)
  if buffer_ready() then
    paint()
  end
  if quiet ~= true then
    report()
  end
end

--- Repaints an open dashboard after a note under the root was saved
--- (incremental refresh: only that note is re-parsed).
function M.on_note_saved(path)
  local root = config.options.root
  if not buffer_ready() or not root then
    return
  end
  local real_root = vim.uv.fs_realpath(root) or root
  local real = vim.uv.fs_realpath(path) or path
  if real:sub(1, #real_root + 1) == real_root .. "/" then
    M.refresh(true)
  end
end

function M.set_view(view)
  if not buffer_ready() then
    return
  end
  state.view = view
  paint()
  local first
  for line in pairs(state.targets) do
    first = first and math.min(first, line) or line
  end
  if first then
    vim.api.nvim_win_set_cursor(0, { first, 0 })
  end
end

--- Prompts for an agenda filter ("+tag -tag #A project:Name @person
--- state:NEXT words"); an empty answer clears it.
function M.prompt_filter()
  if not buffer_ready() then
    return
  end
  vim.ui.input({ prompt = "Filter (+tag -tag #A project:Name @person state:NEXT words): ", default = state.query }, function(answer)
    if answer == nil then
      return
    end
    state.query = vim.trim(answer)
    paint()
  end)
end

function M.shift_week(weeks)
  if not buffer_ready() then
    return
  end
  local today = os.date("%Y-%m-%d")
  if weeks == 0 then
    state.week_start = nil
  else
    state.week_start = schedule.add_days(state.week_start or agenda.week_start(today), 7 * weeks)
  end
  if state.view ~= "week" then
    state.view = "week"
  end
  paint()
end

local function note_buffer(path)
  return require("lattice.mutate").note_buffer(path)
end

-- The line of a task in `lines`: the nearest task of the same kind whose
-- title equals `target.title`, read with `cfg`, so edits elsewhere in the
-- note don't send Lattice to the wrong line (PAR-030). nil when none
-- matches, or when the number of such tasks is not `target.twins`, the
-- count when the dashboard was drawn (agenda.task_key): one was renamed,
-- removed or added, so which was meant is unknown. One rule, one parse;
-- the parse is returned for the caller to reuse.
function M.locate(lines, target, cfg)
  if target.title == nil then
    return target.line
  end
  local parsed = require("lattice.tasks").parse(lines, cfg or require("lattice.config").defaults())
  local matches = {}
  for _, task in ipairs(parsed and parsed.tasks or {}) do
    if task.kind == (target.kind or "heading") and task.title == target.title then
      matches[#matches + 1] = task.line
    end
  end
  return require("lattice.mutate").nearest(matches, target.line, target.twins), parsed
end

-- Runs `op(lines, cfg, line, parsed)` from mutate on the note behind the
-- row under the cursor, writes the result into that note's buffer (never the file),
-- and repaints. Org's agenda edits the same way.
local function edit_row(op)
  local target = state.targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not target or not target.path or target.kind ~= "heading" then
    vim.notify("Lattice: put the cursor on a task row", vim.log.levels.WARN)
    return
  end
  local cfg = state.result.cfg
  local buf = note_buffer(target.path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line, parsed = M.locate(lines, target, cfg)
  if not line then
    vim.notify("Lattice: that task has moved or changed; press r to refresh", vim.log.levels.WARN)
    return
  end
  local mutate = require("lattice.mutate")
  -- locate's parse is of these very lines, so the edit reuses it.
  local ok, new_lines, message = pcall(op, lines, cfg, line, parsed)
  if not ok or not new_lines then
    vim.notify("Lattice: " .. tostring(ok and message or new_lines), vim.log.levels.WARN)
    return
  end
  local applied, err = mutate.apply(buf, lines, new_lines)
  if not applied then
    vim.notify("Lattice: " .. err, vim.log.levels.WARN)
    return
  end
  if applied > 0 then
    state.edited[buf] = true
  end
  M.refresh(true)
  if message then
    vim.notify("Lattice: " .. message, vim.log.levels.INFO)
  end
end

function M.row_state()
  local target = state.targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not target or target.kind ~= "heading" then
    vim.notify("Lattice: put the cursor on a task row", vim.log.levels.WARN)
    return
  end
  local cfg = state.result.cfg
  local buf = note_buffer(target.path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line, parsed = M.locate(lines, target, cfg)
  parsed = line and (parsed or require("lattice.tasks").parse(lines, cfg))
  local kws = parsed and parsed.keywords_at[line]
  if not kws then
    vim.notify("Lattice: that task has moved or changed; press r to refresh", vim.log.levels.WARN)
    return
  end
  local keywords = require("lattice.keywords")
  vim.ui.select(keywords.choices(kws), { prompt = "State: " }, function(choice)
    if choice then
      edit_row(function(l, c, n, p)
        return require("lattice.mutate").set_state(l, c, n, choice == keywords.NO_STATE and "" or choice, nil, p)
      end)
    end
  end)
end

function M.row_priority(direction)
  edit_row(function(lines, cfg, line, parsed)
    return require("lattice.mutate").shift_priority(lines, cfg, line, direction, parsed)
  end)
end

function M.row_date(keyword)
  local target = state.targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not target or target.kind ~= "heading" then
    vim.notify("Lattice: put the cursor on a task row", vim.log.levels.WARN)
    return
  end
  local insert = require("lattice.insert")
  vim.ui.input({ prompt = insert.date_prompt(keyword) }, function(answer)
    if answer == nil then
      return
    end
    local op, err = insert.date_edit(keyword, vim.trim(answer))
    if not op then
      vim.notify("Lattice: " .. err, vim.log.levels.WARN)
      return
    end
    edit_row(function(lines, _, line)
      return op(lines, line)
    end)
  end)
end

--- Saves the notes changed from the dashboard (Org agenda's `s`).
function M.save_edited()
  local saved = 0
  for buf in pairs(state.edited) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
      saved = saved + 1
    end
  end
  state.edited = {}
  M.refresh(true)
  vim.notify(("Lattice: saved %d note(s)"):format(saved), vim.log.levels.INFO)
end

function M.is_dashboard(buf)
  return buf == state.buf
end

function M.toggle_help()
  if not buffer_ready() then
    return
  end
  state.help = not state.help
  paint()
end

function M.jump()
  local target = state.targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    return
  end
  if target.project then
    state.view = "todo"
    state.query = "project:" .. agenda.quote(target.project)
    paint()
    return
  end
  if vim.fn.filereadable(target.path) == 0 then
    vim.notify("Lattice: " .. target.path .. " no longer exists; press r to refresh", vim.log.levels.WARN)
    return
  end
  -- :edit switches to an already-loaded buffer without reloading it, so
  -- unsaved changes in the note are kept.
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target.path))
  if not ok then
    vim.notify("Lattice: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local last = vim.api.nvim_buf_line_count(0)
  local line = M.locate(vim.api.nvim_buf_get_lines(0, 0, -1, false), target, state.result and state.result.cfg) or target.line
  vim.api.nvim_win_set_cursor(0, { math.min(line, last), 0 })
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
  state.buf, state.prev_buf, state.result, state.targets, state.help = nil, nil, nil, {}, false
  state.view, state.query, state.week_start = "overview", "", nil
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
  map("?", M.toggle_help, "Lattice: toggle help")
  map("1", function()
    M.set_view("overview")
  end, "Lattice: overview")
  map("2", function()
    M.set_view("week")
  end, "Lattice: week agenda")
  map("3", function()
    M.set_view("todo")
  end, "Lattice: all TODOs")
  map("4", function()
    M.set_view("projects")
  end, "Lattice: projects")
  map("F", M.prompt_filter, "Lattice: filter")
  map("b", function()
    M.shift_week(-1)
  end, "Lattice: previous week")
  map("f", function()
    M.shift_week(1)
  end, "Lattice: next week")
  map(".", function()
    M.shift_week(0)
  end, "Lattice: this week")
  map("t", M.row_state, "Lattice: change state")
  map("+", function()
    M.row_priority(1)
  end, "Lattice: raise priority")
  map("-", function()
    M.row_priority(-1)
  end, "Lattice: lower priority")
  map("S", function()
    M.row_date("SCHEDULED")
  end, "Lattice: schedule")
  map("D", function()
    M.row_date("DEADLINE")
  end, "Lattice: deadline")
  map("s", M.save_edited, "Lattice: save edited notes")

  -- A plain, unwrapped view in whichever window shows the dashboard.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      for option, value in pairs(WINDOW_OPTIONS) do
        vim.api.nvim_set_option_value(option, value, { scope = "local", win = win })
      end
    end,
  })
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
