-- Task identification and hierarchy (LATTICE_SYNTAX_SPEC §3, §11, §12),
-- built on the Markdown structure from markdown.lua.
--
-- A task is:
--   * an ATX heading whose text starts with a workflow state (§3.1);
--   * a list item with a task marker, `- [ ]` / `- [x]` / `1. [ ]` (§3.2);
--   * a list item without a marker whose text starts with a workflow state,
--     `- TODO x` (Extended: Lattice v0.1 syntax kept as a task).
-- Every list-item task has kind "checkbox"; `checkbox` is nil for the last
-- form. Each task's parent is its nearest enclosing task, heading or item.
local keywords = require("lattice.keywords")
local markdown = require("lattice.markdown")

local M = {}

-- Workflow states, longest first, so a multi-word state such as
-- "IN PROGRESS" wins over a shorter one that is a prefix of it.
local function ordered_states(states)
  local list = vim.tbl_keys(states)
  table.sort(list, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return list
end

--- Splits "<STATE> <title>" when `text` starts with a declared state
--- (exact case) followed by whitespace and a non-empty title.
--- @return string|nil state
--- @return string title  the whole text when there is no state
function M.split_state(text, ordered)
  for _, state in ipairs(ordered) do
    if text:sub(1, #state) == state then
      local title = text:sub(#state + 1):match("^[ \t]+(.-)%s*$")
      if title and title ~= "" then
        return state, title
      end
    end
  end
  return nil, text
end

-- The first done state of the sequence holding the first open state, used
-- for a checked box without an explicit state (§3.3).
local function default_states(kws)
  local first_cycle = kws.cycles[1] or {}
  local open, done
  for _, state in ipairs(first_cycle) do
    if kws.states[state] == "open" then
      open = open or state
    else
      done = done or state
    end
  end
  return open, done
end

local function new_task(kind, line, stop, title)
  return {
    id = nil,
    kind = kind,
    title = title,
    state = nil,
    done = false,
    checkbox = nil,
    priority = nil,
    scheduled = nil,
    deadline = nil,
    closed = nil,
    recurrence = nil,
    tags = {},
    properties = {},
    parent = nil, -- index into the file's task list
    children = {},
    project = nil,
    workflow = nil,
    line = line,
    source = { start_line = line, end_line = stop },
    diagnostics = {},
  }
end

--- Parses one note.
--- @param lines string[]
--- @param cfg { keywords: table }  keywords: the root keyword table
--- @return { tasks: table[], diagnostics: table[], keywords: table }|nil
--- @return string|nil err  when the Markdown parser is unavailable
function M.parse(lines, cfg)
  local structure, err = markdown.parse(lines)
  if not structure then
    return nil, err
  end
  local result = { tasks = {}, diagnostics = {}, keywords = cfg.keywords }

  local function diagnose(line, severity, category, message)
    result.diagnostics[#result.diagnostics + 1] =
      { line = line, severity = severity, category = category, message = message }
  end

  -- Per-note sequences from front matter `todo:` (Lattice v0.1 syntax).
  local sequences, todo_line = keywords.front_matter(lines)
  if sequences then
    local own, build_err = keywords.build(sequences)
    if own then
      result.keywords = own
    else
      diagnose(todo_line, "warning", "workflow", ("front matter todo: %s; using the root keywords"):format(build_err))
    end
  end
  local kws = result.keywords
  local ordered = ordered_states(kws.states)
  local default_open, default_done = default_states(kws)

  -- Tasks are collected in source order: headings and items interleave by line.
  -- heading/item index -> task index, and back (task index -> source).
  local heading_task, item_task, source_of = {}, {}, {}
  local entries = {}
  for index, heading in ipairs(structure.headings) do
    entries[#entries + 1] = { line = heading.line, heading = index }
  end
  for index, item in ipairs(structure.items) do
    entries[#entries + 1] = { line = item.line, item = index }
  end
  table.sort(entries, function(a, b)
    return a.line < b.line
  end)

  for _, entry in ipairs(entries) do
    local task
    if entry.heading then
      local heading = structure.headings[entry.heading]
      local state, title = M.split_state(heading.text, ordered)
      if state then
        task = new_task("heading", heading.line, heading.stop, title)
        task.level = heading.level
        task.state = state
        task.done = kws.states[state] == "done"
        heading_task[entry.heading] = #result.tasks + 1
        source_of[#result.tasks + 1] = entry
      end
    else
      local item = structure.items[entry.item]
      local state, title = M.split_state(item.text, ordered)
      if item.checkbox or state then
        task = new_task("checkbox", item.line, item.stop, title)
        task.checkbox = item.checkbox
        task.ordered = item.ordered
        task.keyword = state
        if item.checkbox then
          local checked = item.checkbox ~= " "
          task.state = state or (checked and default_done or default_open)
          -- The marker is basic completion (§3.3 rule 1).
          task.done = checked
          if state and (kws.states[state] == "done") ~= checked then
            diagnose(
              item.line,
              "warning",
              "state-conflict",
              ("%s is %s but the box is %s"):format(
                state,
                kws.states[state] == "done" and "a done state" or "an unfinished state",
                checked and "checked" or "unchecked"
              )
            )
          end
        else
          task.state = state
          task.done = kws.states[state] == "done"
        end
        item_task[entry.item] = #result.tasks + 1
        source_of[#result.tasks + 1] = entry
      end
    end

    if task then
      result.tasks[#result.tasks + 1] = task
    end
  end

  -- Hierarchy: the nearest enclosing task, looking through list items
  -- first, then headings.
  local function heading_ancestor(index)
    while index do
      if heading_task[index] then
        return heading_task[index]
      end
      index = structure.headings[index].parent
    end
  end

  for index, task in ipairs(result.tasks) do
    local parent
    local entry = source_of[index]
    if entry.heading then
      parent = heading_ancestor(structure.headings[entry.heading].parent)
    else
      local up = structure.items[entry.item].parent
      while up and not item_task[up] do
        up = structure.items[up].parent
      end
      parent = up and item_task[up] or heading_ancestor(structure.items[entry.item].heading)
    end
    if parent then
      task.parent = parent
      table.insert(result.tasks[parent].children, index)
    end
  end

  return result
end

return M
