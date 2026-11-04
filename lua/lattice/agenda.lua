-- Agenda and project queries over the unified task index (LATTICE_SYNTAX_SPEC
-- §8.2, §9.3, §5, milestone E). Pure: tasks in, lists out.
local schedule = require("lattice.schedule")

local M = {}

-- Filters ----------------------------------------------------------------------

--- Parses a filter such as "+etna -later #A project:Krakatoa @elira
--- state:NEXT budget". Terms:
---   +tag / -tag     has / lacks the tag (own or inherited)
---   #A              has that priority (several: any of them)
---   project:Name    in that project (case-insensitive)
---   @name           :ASSIGNED: contains it (case-insensitive)
---   state:NEXT      in that state (several: any of them)
---   anything else   appears in the title (case-insensitive)
--- @return { tags: string[], not_tags: string[], priorities: table, project: string|nil,
---   person: string|nil, states: table, words: string[] }
function M.parse_filter(text)
  local filter = { tags = {}, not_tags = {}, priorities = {}, states = {}, words = {} }
  for term in (text or ""):gmatch("%S+") do
    local tag = term:match("^%+(.+)$")
    local not_tag = term:match("^%-(.+)$")
    local priority = term:match("^#(%w)$")
    local project = term:match("^project:(.+)$")
    local person = term:match("^@(.+)$")
    local state = term:match("^state:(.+)$")
    if tag then
      filter.tags[#filter.tags + 1] = tag
    elseif not_tag then
      filter.not_tags[#filter.not_tags + 1] = not_tag
    elseif priority then
      filter.priorities[priority] = true
    elseif project then
      filter.project = project:lower()
    elseif person then
      filter.person = person:lower()
    elseif state then
      filter.states[state] = true
    else
      filter.words[#filter.words + 1] = term:lower()
    end
  end
  return filter
end

--- A task's own and inherited tags together.
function M.effective_tags(task)
  local list = vim.list_extend({}, task.inherited_tags or {})
  return vim.list_extend(list, task.tags or {})
end

local function matches(task, filter)
  local tags = {}
  for _, tag in ipairs(M.effective_tags(task)) do
    tags[tag] = true
  end
  for _, tag in ipairs(filter.tags) do
    if not tags[tag] then
      return false
    end
  end
  for _, tag in ipairs(filter.not_tags) do
    if tags[tag] then
      return false
    end
  end
  if next(filter.priorities) and not filter.priorities[task.priority or ""] then
    return false
  end
  if next(filter.states) and not filter.states[task.state or ""] then
    return false
  end
  if filter.project and (task.project or ""):lower() ~= filter.project then
    return false
  end
  if filter.person and not (task.person or ""):lower():find(filter.person, 1, true) then
    return false
  end
  local title = (task.text or task.title or ""):lower()
  for _, word in ipairs(filter.words) do
    if not title:find(word, 1, true) then
      return false
    end
  end
  return true
end

--- Tasks matching a filter string (or a parsed filter).
function M.filter(tasks, query)
  if query == nil or query == "" then
    return tasks
  end
  local filter = type(query) == "table" and query or M.parse_filter(query)
  return vim.tbl_filter(function(task)
    return matches(task, filter)
  end, tasks)
end

--- True when a filter string has no terms.
function M.is_empty(query)
  return query == nil or vim.trim(query) == ""
end

-- Sorting ----------------------------------------------------------------------

--- Priority rank: lower is more urgent. A missing priority ranks as the
--- default, never as the highest (§5).
function M.priority_rank(task, priorities)
  local values = priorities and priorities.values or { "A", "B", "C" }
  local default = priorities and priorities.default or values[math.ceil(#values / 2)]
  local wanted = task.priority or default
  for i, value in ipairs(values) do
    if value == wanted then
      return i
    end
  end
  return #values + 1
end

local function by_source(a, b)
  if (a.rel or "") ~= (b.rel or "") then
    return (a.rel or "") < (b.rel or "")
  end
  return a.line < b.line
end

--- Open tasks for Org's global TODO list: by priority, then deadline,
--- then source.
function M.todo_list(tasks, query, priorities)
  local list = vim.tbl_filter(function(task)
    return not task.done
  end, M.filter(tasks, query))
  table.sort(list, function(a, b)
    local pa, pb = M.priority_rank(a, priorities), M.priority_rank(b, priorities)
    if pa ~= pb then
      return pa < pb
    end
    if a.due ~= b.due then
      if a.due and b.due then
        return a.due < b.due
      end
      return a.due ~= nil
    end
    return by_source(a, b)
  end)
  return list
end

-- Week agenda ------------------------------------------------------------------

--- The Monday on or before `date`.
function M.week_start(date)
  local n = schedule.days(date)
  -- 1970-01-01 was a Thursday: (n + 3) % 7 is 0 on Mondays.
  return schedule.add_days(date, -((n + 3) % 7))
end

-- Dates a timestamp falls on within [first, last]: the date itself, and
-- for a repeater every later occurrence (as Org's agenda shows repeats).
local function occurrences(ts, first, last)
  local dates = {}
  local last_n = schedule.days(last)
  local first_n = schedule.days(first)
  local current = ts
  local step = 0
  while schedule.days(current.date) <= last_n and step < 1000 do
    if schedule.days(current.date) >= first_n then
      dates[#dates + 1] = current.date
    end
    if not ts.repeater then
      break
    end
    step = step + 1
    current = schedule.shift(ts, ts.repeater.n * step, ts.repeater.unit)
  end
  return dates
end

--- Org's agenda for the 7 days from `first` (§8.2, §9.3). Each day lists
--- tasks scheduled or due that day, repeats included. Today also lists
--- what is still open from earlier ("Sched. 3x", "3 d. ago") and deadlines
--- inside their warning period ("In 4 d."). Done tasks are left out.
--- Within a day: timed entries by time, then by priority, then source.
--- @return { date: string, today: boolean, entries: { task: table, kind: string, note: string, time: string|nil }[] }[]
function M.week(tasks, first, today, opts)
  opts = opts or {}
  local warning_default = opts.warning_days or 14
  local last = schedule.add_days(first, 6)
  local days = {}
  for i = 0, 6 do
    local date = schedule.add_days(first, i)
    days[i + 1] = { date = date, today = date == today, entries = {} }
  end
  local function day_of(date)
    for _, day in ipairs(days) do
      if day.date == date then
        return day
      end
    end
  end
  local function add(day, task, kind, note, time, date)
    if day then
      table.insert(day.entries, { task = task, kind = kind, note = note, time = time, date = date })
    end
  end

  for _, task in ipairs(M.filter(tasks, opts.query)) do
    if not task.done then
      if task.scheduled then
        for _, date in ipairs(occurrences(task.scheduled, first, last)) do
          add(day_of(date), task, "scheduled", "Scheduled", task.scheduled.time, date)
        end
        local status, since = schedule.scheduled_status(task.scheduled, today)
        if status == "past" then
          add(day_of(today), task, "scheduled", ("Sched. %dx"):format(since), nil, task.scheduled.date)
        end
      end
      local due = task.deadline and task.deadline.date or task.due
      if due then
        -- A v0.1 [due:] date has no timestamp: treat it as a plain one.
        for _, date in ipairs(occurrences(task.deadline or { date = due }, first, last)) do
          add(day_of(date), task, "deadline", "Deadline", task.deadline and task.deadline.time, date)
        end
        local warning = task.deadline and schedule.warning_days(task.deadline, warning_default) or warning_default
        local status, diff = schedule.deadline_status(due, today, warning)
        if status == "overdue" then
          add(day_of(today), task, "deadline", ("%d d. ago"):format(-diff), nil, due)
        elseif status == "upcoming" then
          add(day_of(today), task, "deadline", ("In %d d."):format(diff), nil, due)
        end
      end
    end
  end

  for _, day in ipairs(days) do
    table.sort(day.entries, function(a, b)
      if (a.time ~= nil) ~= (b.time ~= nil) then
        return a.time ~= nil
      end
      if a.time and b.time and a.time ~= b.time then
        return a.time < b.time
      end
      local pa, pb = M.priority_rank(a.task, opts.priorities), M.priority_rank(b.task, opts.priorities)
      if pa ~= pb then
        return pa < pb
      end
      if a.kind ~= b.kind then
        return a.kind == "deadline"
      end
      -- Oldest first, so what is most overdue leads.
      if a.date ~= b.date then
        return (a.date or "") < (b.date or "")
      end
      if (a.task.rel or "") ~= (b.task.rel or "") or a.task.line ~= b.task.line then
        return by_source(a.task, b.task)
      end
      return (a.task.title or "") < (b.task.title or "")
    end)
  end
  return days
end

-- Projects ---------------------------------------------------------------------

--- One entry per project (§4.2 D2): open and done counts, the first open
--- task in a NEXT-like state (else the first open task) as its next
--- action, and its :PROJECT_STATUS: if any task carries or inherits one.
--- Sorted by name.
function M.projects(tasks, priorities)
  local by_name, names = {}, {}
  for _, task in ipairs(tasks) do
    if task.project then
      local key = task.project:lower()
      local project = by_name[key]
      if not project then
        project = { name = task.project, open = 0, done = 0, tasks = {} }
        by_name[key] = project
        names[#names + 1] = key
      end
      table.insert(project.tasks, task)
      if task.done then
        project.done = project.done + 1
      else
        project.open = project.open + 1
      end
      local status = (task.properties or {}).PROJECT_STATUS or (task.inherited_properties or {}).PROJECT_STATUS
      project.status = project.status or status
    end
  end
  table.sort(names)
  local list = {}
  for _, key in ipairs(names) do
    local project = by_name[key]
    local open = M.todo_list(project.tasks, nil, priorities)
    for _, task in ipairs(open) do
      if task.state == "NEXT" and not project.next then
        project.next = task
      end
    end
    project.next = project.next or open[1]
    list[#list + 1] = project
  end
  return list
end

return M
