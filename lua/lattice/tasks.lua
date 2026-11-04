-- Task identification, metadata, workflows and hierarchy
-- (LATTICE_SYNTAX_SPEC §3–§7, §11, §12), on the structure from markdown.lua.
--
-- A task is:
--   * an ATX heading whose text starts with a state of its workflow (§3.1);
--   * a list item with a task marker, `- [ ]` / `- [x]` / `1. [ ]` (§3.2);
--   * a list item without a marker whose text starts with a state,
--     `- TODO x` (Extended: Lattice v0.1 syntax kept as a task);
--   * v0.1 legacy: a top-level bullet under a `Waiting On` heading.
-- Every list-item task has kind "checkbox"; `checkbox` is nil for the last
-- two forms. Each task's parent is its nearest enclosing task.
--
-- Nodes (headings and list items) are visited in source order, so a node's
-- ancestors are resolved first: their inherited properties, tags, project
-- and workflow form its context.
local keywords = require("lattice.keywords")
local markdown = require("lattice.markdown")
local metadata = require("lattice.metadata")
local timestamp = require("lattice.timestamp")

local M = {}

-- Properties every node inherits (D2), on top of `properties.inherit`.
local ALWAYS_INHERITED = { PROJECT = true, WORKFLOW = true }

-- States longest first, so "IN PROGRESS" wins over a shorter prefix.
local function ordered_states(kws)
  if kws.ordered then
    return kws.ordered
  end
  local list = {}
  for state in pairs(kws.states) do
    list[#list + 1] = state
  end
  table.sort(list, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  kws.ordered = list
  return list
end

--- True for a checked box, "[x]" or "[X]". Org's "[-]" is not checked.
function M.checked(box)
  return box == "x" or box == "X"
end
local checked = M.checked

--- The state `text` starts with (longest first, exact case), followed by
--- whitespace or the end of the text, and the whitespace after it; nil if
--- none. Unlike split_state, the title may be empty.
function M.leading_state(text, kws)
  for _, state in ipairs(ordered_states(kws)) do
    if text:sub(1, #state) == state then
      local gap = text:sub(#state + 1):match("^[ \t]*")
      if gap ~= "" or #text == #state then
        return state, gap
      end
    end
  end
end

--- Splits "<STATE> <title>" when `text` starts with a declared state
--- (exact case) followed by whitespace and a non-empty title.
--- @return string|nil state
--- @return string title  the whole text when there is no state
function M.split_state(text, kws)
  for _, state in ipairs(ordered_states(kws)) do
    if text:sub(1, #state) == state then
      local title = text:sub(#state + 1):match("^[ \t]+(.-)%s*$")
      if title and title ~= "" then
        return state, title
      end
    end
  end
  return nil, text
end

-- Default unfinished and done states for a box without an explicit state
-- (§3.3): the first of each kind in the workflow's first sequence.
local function default_states(kws)
  local open, done
  for _, state in ipairs(kws.cycles[1] or {}) do
    if kws.states[state] == "open" then
      open = open or state
    else
      done = done or state
    end
  end
  return open, done
end

-- Trailing Org tags " :a:b:" (§6.1). Returns the text without them and
-- the tag list.
local function split_tags(text)
  local before, tags = text:match("^(.-)%s+(:[%w_@#%%:]+:)%s*$")
  if not before then
    tags = text:match("^(:[%w_@#%%:]+:)%s*$")
    before = tags and "" or text
  end
  local list = {}
  for tag in (tags or ""):gmatch("[^:]+") do
    list[#list + 1] = tag
  end
  return before, list
end

-- v0.1 inline dates: [due:YYYY-MM-DD], and [promised:...] on waiting items.
local function legacy_dates(text, waiting, bad)
  local dates = {}
  for _, tag in ipairs(waiting and { "due", "promised" } or { "due" }) do
    for value in text:gmatch("%[" .. tag .. ":([^%]]*)%]") do
      if timestamp.valid_date(value) then
        dates[tag] = dates[tag] or value
      else
        bad[#bad + 1] = { tag = tag, value = value }
      end
    end
    -- Only valid dates leave the text: an invalid one stays visible (and in
    -- WARNINGS), so nothing the user typed is lost, e.g. by :LatticeMigrate.
    text = vim.trim((text:gsub("[ \t]*%[" .. tag .. ":([^%]]*)%][ \t]*", function(value)
      return timestamp.valid_date(value) and " " or nil
    end)))
  end
  return text, dates
end

local function merge_tags(inherited, own)
  local seen, list = {}, {}
  for _, source in ipairs({ inherited, own }) do
    for _, tag in ipairs(source) do
      if not seen[tag] then
        seen[tag] = true
        list[#list + 1] = tag
      end
    end
  end
  return list
end

local function new_task(kind, line, stop)
  return {
    id = nil,
    kind = kind,
    title = "",
    state = nil,
    done = false,
    checkbox = nil,
    priority = nil,
    scheduled = nil,
    deadline = nil,
    closed = nil,
    recurrence = nil,
    tags = {}, -- local tags
    inherited_tags = {},
    properties = {}, -- local, UPPERCASE keys
    property_names = {}, -- original spelling
    inherited_properties = {},
    parent = nil, -- index into the file's task list
    children = {},
    project = nil,
    workflow = nil,
    line = line,
    source = { start_line = line, end_line = stop },
    legacy = {},
  }
end

--- Parses one note.
--- @param lines string[]
--- @param cfg table  config.defaults() shape: keywords, workflows, priorities,
---   inherit, headings
--- @return table|nil result  { tasks, warnings, keywords (at the note's
---   root, after front matter), keywords_at, sections, date_errors, legacy,
---   front_matter, headings, structure }
--- @return string|nil err  when the Markdown parser is unavailable
function M.parse(lines, cfg)
  local structure, err = markdown.parse(lines)
  if not structure then
    return nil, err
  end
  local workflows = cfg.workflows or { default = cfg.keywords }
  local priorities = cfg.priorities or { values = { "A", "B", "C" } }
  local inherit = cfg.inherit or { tags = true, properties = {} }
  local waiting_heading = (cfg.headings or {}).waiting

  local result = {
    tasks = {},
    keywords = workflows.default or cfg.keywords,
    keywords_at = {}, -- line of each heading and list item -> its keyword table
    sections = {}, -- v0.1 Waiting On sections, for insertion
    date_errors = {}, -- v0.1 invalid [due:] dates on open tasks
    warnings = {}, -- { line, severity, category, message }, shown on the dashboard
    legacy = {}, -- { line, form } for v0.1 syntax still in use
    front_matter = structure.front_matter,
    headings = {}, -- every heading, for refile targets: { line, level, text, outline }
    structure = structure, -- markdown.parse's result, for callers that need both
  }

  local function warn(line, category, message)
    result.warnings[#result.warnings + 1] = { line = line, severity = "warning", category = category, message = message }
  end

  -- File-level context: front matter `todo:` (v0.1), `project:`, `workflow:`.
  local file_kws
  local sequences, todo_line = keywords.front_matter(lines)
  if sequences then
    local own, build_err = keywords.build(sequences)
    if own then
      file_kws = own
      result.keywords = own
    else
      warn(todo_line, "workflow", ("front matter todo: %s; using the root keywords"):format(build_err))
    end
  end
  local root_props, root_lines = {}, {}
  for _, key in ipairs({ "project", "workflow" }) do
    root_props[key:upper()], root_lines[key:upper()] = keywords.front_matter_scalar(lines, key)
  end
  local root = { props = root_props, tags = {}, project = root_props.PROJECT }

  -- Which keyword table applies, from a node's effective properties. An
  -- unknown workflow is reported once, where it is set (`own`), not again
  -- on every node that inherits it.
  local function resolve(props, project, line, own)
    local name = props.WORKFLOW and props.WORKFLOW:lower()
    if name and not workflows[name] then
      if own then
        warn(line, "unknown-workflow", ("workflow %q is not configured; using the default"):format(props.WORKFLOW))
      end
      name = nil
    end
    if not name and project and workflows[project:lower()] then
      name = project:lower()
    end
    if name then
      return workflows[name], name
    end
    if file_kws then
      return file_kws, "file"
    end
    return workflows.default or cfg.keywords, "default"
  end
  -- The keywords at the root: what a new top-level heading gets.
  result.keywords = resolve(root_props, root.project, root_lines.WORKFLOW or 1, root_props.WORKFLOW ~= nil)

  -- States that belong to some workflow, to flag ones used out of place.
  local known_elsewhere = {}
  for _, kws in pairs(workflows) do
    for state in pairs(kws.states) do
      known_elsewhere[state] = true
    end
  end

  local priority_ok = {}
  for _, value in ipairs(priorities.values) do
    priority_ok[value] = true
  end

  -- Child structure bounds, for where a node's own metadata can be.
  local first_child_heading, first_child_item = {}, {}
  for _, heading in ipairs(structure.headings) do
    if heading.parent and not first_child_heading[heading.parent] then
      first_child_heading[heading.parent] = heading.line
    end
  end
  for _, item in ipairs(structure.items) do
    if item.parent and not first_child_item[item.parent] then
      first_child_item[item.parent] = item.line
    end
  end

  -- v0.1 Waiting On sections end at the next heading of any level,
  -- setext headings included.
  local boundaries = {}
  for _, heading in ipairs(structure.headings) do
    boundaries[#boundaries + 1] = heading.line
  end
  for _, line in ipairs(structure.setext) do
    boundaries[#boundaries + 1] = line
  end
  table.sort(boundaries)
  for _, heading in ipairs(structure.headings) do
    if waiting_heading and heading.text == waiting_heading then
      local stop = #lines
      for _, line in ipairs(boundaries) do
        if line > heading.line then
          stop = line - 1
          break
        end
      end
      local last = stop
      while last > heading.line and vim.trim(lines[last] or "") == "" do
        last = last - 1
      end
      result.sections[#result.sections + 1] = { kind = "waiting", line = heading.line, stop = stop, last = last }
    end
  end
  local function in_waiting_section(line)
    for _, section in ipairs(result.sections) do
      if line > section.line and line <= section.stop then
        return true
      end
    end
    return false
  end

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

  local heading_ctx, item_ctx = {}, {}
  local heading_task, item_task, source_of = {}, {}, {}

  for _, entry in ipairs(entries) do
    local node, parent_ctx, text, first, last
    if entry.heading then
      node = structure.headings[entry.heading]
      parent_ctx = node.parent and heading_ctx[node.parent] or root
      text = node.text
      first = node.line + 1
      local limit = node.stop
      if first_child_heading[entry.heading] then
        limit = math.min(limit, first_child_heading[entry.heading] - 1)
      end
      last = limit
    else
      node = structure.items[entry.item]
      parent_ctx = node.parent and item_ctx[node.parent] or (node.heading and heading_ctx[node.heading]) or root
      text = node.text
      first = node.line + 1
      last = first_child_item[entry.item] and first_child_item[entry.item] - 1 or node.stop
    end

    -- Org metadata belongs to headings only (strict Org, D14).
    local meta = { properties = {}, names = {}, planning_lines = {} }
    if entry.heading then
      meta = metadata.read(lines, first, last, function(line, category, message)
        warn(line, category, message)
      end)
    end

    -- Effective properties: inherited, then this node's own.
    local props = {}
    for key, value in pairs(parent_ctx.props) do
      props[key] = value
    end
    for key, value in pairs(meta.properties) do
      props[key] = value
    end

    -- Heading text: tags come off the end first.
    local own_tags = {}
    if entry.heading then
      text, own_tags = split_tags(text)
    end
    local inherited_tags = inherit.tags and parent_ctx.tags or {}

    -- Project (D2): explicit property, else a top-level heading naming a
    -- configured workflow, else the parent's.
    local project = props.PROJECT or parent_ctx.project
    if not props.PROJECT and entry.heading and node.level == 1 then
      local name = text
      local maybe_state, rest = M.split_state(text, workflows.default or cfg.keywords)
      if maybe_state then
        name = rest
      end
      local key = name:lower()
      if key ~= "default" and workflows[key] then
        project = name
      end
    end

    local kws, workflow_name = resolve(props, project, node.line, meta.properties.WORKFLOW ~= nil)
    result.keywords_at[node.line] = kws

    -- Context handed to descendants.
    local ctx = { props = {}, tags = merge_tags(inherited_tags, own_tags), project = project }
    for key, value in pairs(props) do
      if ALWAYS_INHERITED[key] or inherit.properties == true or (type(inherit.properties) == "table" and vim.tbl_contains(inherit.properties, key)) then
        ctx.props[key] = value
      end
    end
    if entry.heading then
      heading_ctx[entry.heading] = ctx
    else
      item_ctx[entry.item] = ctx
    end

    -- Identification.
    local state, title = M.split_state(text, kws)
    local task
    local in_waiting = entry.item and in_waiting_section(node.line)
    -- v0.1: a top-level unordered bullet in Waiting On is a task by itself.
    local legacy_plain = in_waiting and not node.parent and not node.ordered
    local legacy_waiting = false
    if entry.heading then
      if state then
        task = new_task("heading", node.line, node.stop)
        task.level = node.level
        task.state = state
        task.done = kws.states[state] == "done"
      else
        local word = text:match("^(%u[%u_%-]*)%s+%S")
        if word and known_elsewhere[word] then
          warn(node.line, "unknown-state", ("%s is not a state in this heading's workflow (%s)"):format(word, workflow_name))
        end
      end
    elseif title ~= "" and not node.ordered and (state or legacy_plain) then
      -- Org has no list-item tasks; these are Lattice v0.1 forms, read until
      -- the note is migrated (ORG_MARKDOWN_PLAN.md D3, D14).
      task = new_task("item", node.line, node.stop)
      task.checkbox = node.checkbox
      task.keyword = state
      local _, default_done = default_states(kws)
      if not state then
        legacy_waiting = true
        state = checked(node.checkbox) and default_done or (kws.states.WAITING and "WAITING") or kws.first_open
      end
      task.state = state
      -- v0.1: a checked box or a done state means done. Org's partly
      -- checked [-] is not checked.
      task.done = checked(node.checkbox) or kws.states[state] == "done"
      result.legacy[#result.legacy + 1] = { line = node.line, form = state == task.keyword and "TODO bullet" or "Waiting On item" }
    end

    if task then
      local index = #result.tasks + 1
      if entry.heading then
        heading_task[entry.heading] = index
      else
        item_task[entry.item] = index
      end
      source_of[index] = entry

      -- Priority (§5): the [#A] cookie after a heading's state, as in Org.
      if entry.heading then
        local value, rest = title:match("^%[#(%w)%]%s*(.*)$")
        if value then
          title = rest
          if priority_ok[value] then
            task.priority = value
          else
            warn(node.line, "invalid-priority", ("[#%s] is not a configured priority"):format(value))
          end
        end
      end
      -- v0.1 forms: @Name on waiting items, [due:] and [promised:].
      -- v0.1: every task in a Waiting On section is a waiting item.
      local waiting = state == "WAITING" or in_waiting
      if waiting and not meta.properties.ASSIGNED then
        local name, rest = title:match("^@(%S+)[ \t]*(.*)$")
        if name then
          title = rest
          task.legacy.assigned = name
          result.legacy[#result.legacy + 1] = { line = node.line, form = "@Name" }
        end
      end
      local bad = {}
      local dates
      title, dates = legacy_dates(title, waiting, bad)
      if dates.due then
        task.legacy.due = dates.due
        result.legacy[#result.legacy + 1] = { line = node.line, form = "[due:]" }
      end
      if dates.promised then
        task.legacy.promised = dates.promised
        result.legacy[#result.legacy + 1] = { line = node.line, form = "[promised:]" }
      end

      if not task.done then
        for _, entry_bad in ipairs(bad) do
          entry_bad.line = node.line
          result.date_errors[#result.date_errors + 1] = entry_bad
        end
      end

      task.title = title
      task.tags = own_tags
      task.inherited_tags = {}
      for _, tag in ipairs(inherited_tags) do
        if not vim.tbl_contains(own_tags, tag) then
          task.inherited_tags[#task.inherited_tags + 1] = tag
        end
      end
      task.properties = meta.properties
      task.property_names = meta.names
      task.inherited_properties = parent_ctx.props
      task.id = meta.properties.ID
      task.scheduled, task.deadline, task.closed = meta.scheduled, meta.deadline, meta.closed
      task.recurrence = (meta.scheduled and meta.scheduled.repeater) or (meta.deadline and meta.deadline.repeater)
      task.planning_lines = meta.planning_lines
      task.drawer = meta.drawer
      task.project = project
      task.workflow = workflow_name

      -- Fields the v0.1 dashboard reads.
      task.text = title
      task.section = waiting and "waiting" or "todo"
      task.person = meta.properties.ASSIGNED or props.ASSIGNED or task.legacy.assigned
      task.due = task.deadline and task.deadline.date or task.legacy.due
      task.promised = meta.properties.PROMISED or task.legacy.promised

      result.tasks[index] = task
    end
  end

  -- Hierarchy: the nearest enclosing task, through list items, then headings.
  local function heading_ancestor(index)
    while index do
      if heading_task[index] then
        return heading_task[index]
      end
      index = structure.headings[index].parent
    end
  end
  for index, task in ipairs(result.tasks) do
    local entry = source_of[index]
    local parent
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

  -- Progress (§11.4), as Org counts it for a heading's [1/3] / [33%%]
  -- cookie: the checkboxes of the lists directly in its entry (top-level
  -- items only, org-checkbox-hierarchical-statistics), else its child TODO
  -- headings (org-hierarchical-todo-statistics). "[-]" is partly done.
  local boxes = {}
  for _, item in ipairs(structure.items) do
    if item.checkbox and not item.parent and item.heading then
      local count = boxes[item.heading] or { done = 0, total = 0 }
      count.total = count.total + 1
      if checked(item.checkbox) then
        count.done = count.done + 1
      end
      boxes[item.heading] = count
    end
  end
  for index, task in ipairs(result.tasks) do
    local entry = source_of[index]
    if entry.heading then
      local count = boxes[entry.heading]
      if count then
        task.progress = { done = count.done, total = count.total, of = "checkboxes" }
      else
        local done, total = 0, 0
        for _, child in ipairs(task.children) do
          if result.tasks[child].kind == "heading" then
            total = total + 1
            done = done + (result.tasks[child].done and 1 or 0)
          end
        end
        if total > 0 then
          task.progress = { done = done, total = total, of = "subtasks" }
        end
      end
      local a, b = task.title:match("%[(%d*)/(%d*)%]")
      local pct = task.title:match("%[(%d*)%%%]")
      if a then
        task.cookie = { kind = "fraction", text = ("[%s/%s]"):format(a, b) }
      elseif pct then
        task.cookie = { kind = "percent", text = ("[%s%%]"):format(pct) }
      end
    end
  end

  -- Every heading with its outline path, for refile targets and
  -- :ARCHIVE_OLPATH: (§14.2). As in Org, the path holds each heading's
  -- title without its state, priority or tags.
  local function outline_title(heading)
    local text = split_tags(heading.text)
    local kws = result.keywords_at[heading.line]
    local state, gap
    if kws then
      state, gap = M.leading_state(text, kws)
    end
    if state then
      text = text:sub(#state + #gap + 1)
    end
    return (text:gsub("^%[#%w%][ \t]*", ""))
  end
  for _, heading in ipairs(structure.headings) do
    local titles = {}
    local up = heading
    while up do
      table.insert(titles, 1, outline_title(up))
      up = up.parent and structure.headings[up.parent]
    end
    result.headings[#result.headings + 1] = { line = heading.line, level = heading.level, text = heading.text, outline = titles }
  end

  -- Duplicate IDs within the note (§13.4); the scanner checks across notes.
  local seen_ids = {}
  for _, task in ipairs(result.tasks) do
    if task.id then
      if seen_ids[task.id] then
        warn(task.line, "duplicate-id", (":ID: %s is also used on line %d"):format(task.id, seen_ids[task.id]))
      else
        seen_ids[task.id] = task.line
      end
    end
  end

  return result
end

return M
