-- The mutation layer (LATTICE_SYNTAX_SPEC §14, milestone D). Every edit
-- Lattice makes to a note goes through here.
--
-- Operations are pure: they take a note's lines and return new lines (or
-- nil and an error). apply() then writes only the lines that changed,
-- found with Neovim's line diff, after checking that the buffer still
-- holds exactly the lines the operation was computed from. A stale or
-- repeated command is therefore refused rather than applied twice (§10.3,
-- §14.2). Edits go to the buffer as one undo step and are never saved.
local config = require("lattice.config")
local markdown = require("lattice.markdown")
local metadata = require("lattice.metadata")
local schedule = require("lattice.schedule")
local tasks = require("lattice.tasks")
local timestamp = require("lattice.timestamp")

local M = {}

-- Helpers ----------------------------------------------------------------------

local function copy(lines)
  return vim.list_extend({}, lines)
end

local function parse_structure(lines)
  local structure, err = markdown.parse(lines)
  if not structure then
    error(err, 0)
  end
  return structure
end

local function heading_at(structure, line)
  for index, heading in ipairs(structure.headings) do
    if heading.line == line then
      return heading, index
    end
  end
end

-- Metadata of a heading, read as tasks.lua reads it.
local function heading_meta(lines, structure, index)
  local heading = structure.headings[index]
  local next_heading = structure.headings[index + 1]
  local last = next_heading and next_heading.line - 1 or #lines
  return metadata.read(lines, heading.line + 1, math.min(last, heading.stop), function() end)
end

--- How many entries of `list` share each `key(entry)`: the `expected`
--- count M.nearest checks, taken when a list of targets is drawn.
function M.tally(list, key)
  local counts = {}
  for _, entry in ipairs(list) do
    local k = key(entry)
    counts[k] = (counts[k] or 0) + 1
  end
  return counts
end

--- The line in `matches` nearest to `line`. nil when there is none, or when
--- the number of matches is not `expected` (the count when the target was
--- shown): a heading with that text was renamed, removed or added since, so
--- which one was meant can't be told. Refusing is safer than guessing.
function M.nearest(matches, line, expected)
  if expected and #matches ~= expected then
    return nil
  end
  local best
  for _, n in ipairs(matches) do
    if not best or math.abs(n - line) < math.abs(best - line) then
      best = n
    end
  end
  return best
end

--- The heading whose text is `text`: on `line` if it is still there, else
--- the nearest such heading (see M.nearest for `expected`). For refile
--- targets chosen from a scan that may be out of date.
function M.find_heading(lines, line, text, expected)
  local structure = parse_structure(lines)
  local matches = {}
  for _, heading in ipairs(structure.headings) do
    if heading.text == text then
      matches[#matches + 1] = heading.line
    end
  end
  return M.nearest(matches, line, expected)
end

-- A planning entry as written ("<2026-11-20 Fri>"), active, inactive or
-- unreadable, from the heading's planning lines.
local function written_planning(lines, planning_lines, keyword)
  for _, at in ipairs(planning_lines or {}) do
    for _, token in ipairs(metadata.planning_pairs(lines[at])) do
      if token.keyword == keyword then
        return token.raw
      end
    end
  end
end

--- "Now" for completion: local date and time, unless the caller passes one.
function M.now()
  return { date = os.date("%Y-%m-%d"), time = os.date("%H:%M") }
end

local function inactive(now)
  local y, m, d = now.date:match("^(%d+)%-(%d+)%-(%d+)$")
  return ("[%s %s%s]"):format(now.date, timestamp.weekday(tonumber(y), tonumber(m), tonumber(d)), now.time and (" " .. now.time) or "")
end

-- Splits a heading line into hashes+space, state (nil), and the rest. A
-- heading that is only a state ("# TODO") has that state and an empty rest,
-- so edits never treat the state word as title text.
local function split_heading(line, kws)
  local prefix, text = line:match("^( ? ? ?#+[ \t]+)(.*)$")
  if not prefix then
    return nil
  end
  local state, gap = tasks.leading_state(text, kws)
  if not state then
    return prefix, nil, text
  end
  return prefix, state, text:sub(#state + #gap + 1)
end

-- Planning ---------------------------------------------------------------------

local ORDER = { CLOSED = 1, DEADLINE = 2, SCHEDULED = 3 }


local function render_planning(indent, tokens)
  local parts = {}
  for _, token in ipairs(tokens) do
    parts[#parts + 1] = token.keyword .. ": " .. token.raw
  end
  return indent .. table.concat(parts, " ")
end

--- Sets (or, with raw = nil, removes) one planning entry of the heading on
--- `line`: "CLOSED", "DEADLINE" or "SCHEDULED". A new entry joins the
--- first planning line in Org's order (CLOSED, DEADLINE, SCHEDULED), or
--- starts one directly under the heading. A line left empty is removed.
--- `structure` may be passed when the caller already parsed these lines.
function M.set_planning(lines, line, keyword, raw, structure)
  structure = structure or parse_structure(lines)
  local _, index = heading_at(structure, line)
  if not index then
    return nil, "no heading on this line"
  end
  local meta = heading_meta(lines, structure, index)
  lines = copy(lines)
  for _, at in ipairs(meta.planning_lines) do
    local indent = lines[at]:match("^(%s*)")
    local tokens = metadata.planning_pairs(lines[at])
    for i, token in ipairs(tokens) do
      if token.keyword == keyword then
        if raw then
          token.raw = raw
        else
          table.remove(tokens, i)
        end
        if #tokens == 0 then
          table.remove(lines, at)
        else
          lines[at] = render_planning(indent, tokens)
        end
        return lines
      end
    end
  end
  if not raw then
    return lines
  end
  local at = meta.planning_lines[1]
  if at then
    local tokens = metadata.planning_pairs(lines[at])
    tokens[#tokens + 1] = { keyword = keyword, raw = raw }
    table.sort(tokens, function(a, b)
      return ORDER[a.keyword] < ORDER[b.keyword]
    end)
    lines[at] = render_planning(lines[at]:match("^(%s*)"), tokens)
  else
    table.insert(lines, line + 1, keyword .. ": " .. raw)
  end
  return lines
end

--- Sets SCHEDULED or DEADLINE of the heading on `line` to `when`
--- ({ date, time? }), keeping an existing repeater and warning period as
--- Org's C-c C-s keeps them; `when` nil removes it. Works on any heading,
--- task or not.
function M.set_date(lines, line, keyword, when)
  if not when then
    return M.set_planning(lines, line, keyword, nil)
  end
  local structure = parse_structure(lines)
  local _, index = heading_at(structure, line)
  if not index then
    return nil, "no heading on this line"
  end
  local meta = heading_meta(lines, structure, index)
  local existing = meta[keyword:lower()]
  local written = written_planning(lines, meta.planning_lines, keyword)
  if written and not existing then
    -- Unreadable (or inactive): replacing it would drop whatever repeater
    -- or warning the user wrote, so say so instead.
    return nil, ("this heading's %s %s can't be read (see WARNINGS); fix or remove it first"):format(keyword, written)
  end
  local ts, err = timestamp.parse("<" .. when.date .. (when.time and (" " .. when.time) or "") .. ">")
  if not ts then
    return nil, err
  end
  if existing then
    ts.repeater, ts.warning = existing.repeater, existing.warning
  end
  return M.set_planning(lines, line, keyword, schedule.format(ts), structure)
end

-- Properties -------------------------------------------------------------------

--- Sets (or, with value = nil, removes) a property in the heading's
--- drawer, keeping the name's existing spelling. A missing drawer is
--- created after the planning lines; a drawer left empty is removed.
function M.set_property(lines, line, name, value)
  local structure = parse_structure(lines)
  local _, index = heading_at(structure, line)
  if not index then
    return nil, "no heading on this line"
  end
  local meta = heading_meta(lines, structure, index)
  lines = copy(lines)
  local key = name:upper()
  if meta.drawer then
    for at = meta.drawer.start + 1, meta.drawer.stop - 1 do
      local existing = vim.trim(lines[at]):match("^:([^:%s]+):")
      if existing and existing:upper() == key then
        if value then
          lines[at] = (":%s: %s"):format(existing, value)
        else
          table.remove(lines, at)
          if meta.drawer.stop - meta.drawer.start == 2 then
            table.remove(lines, meta.drawer.start + 1) -- :END:
            table.remove(lines, meta.drawer.start)
          end
        end
        return lines
      end
    end
    if value then
      table.insert(lines, meta.drawer.stop, (":%s: %s"):format(name, value))
    end
    return lines
  end
  if value then
    local after = meta.planning_lines[#meta.planning_lines] or line
    table.insert(lines, after + 1, ":END:")
    table.insert(lines, after + 1, (":%s: %s"):format(name, value))
    table.insert(lines, after + 1, ":PROPERTIES:")
  end
  return lines
end

-- Progress cookies and checkboxes ---------------------------------------------

local checked = tasks.checked

local function cookie_text(line, done, total)
  local fraction = line:match("%[%d*/%d*%]")
  if fraction then
    return (line:gsub("%[%d*/%d*%]", ("[%d/%d]"):format(done, total), 1))
  end
  if line:match("%[%d*%%%]") then
    local pct = total == 0 and 0 or math.floor(100 * done / total)
    return (line:gsub("%[%d*%%%]", ("[%d%%%%]"):format(pct), 1))
  end
  return line
end

-- Writes a box character into an item's line.
local function set_box(lines, item, box)
  local line = lines[item.line]
  local before = line:sub(1, item.col)
  local rest = line:sub(item.col + 1)
  rest = rest:gsub("^([-*+]%s+)%[[ xX%-]%]", "%1[" .. box .. "]", 1)
  rest = rest:gsub("^(%d+[.)]%s+)%[[ xX%-]%]", "%1[" .. box .. "]", 1)
  lines[item.line] = before .. rest
end

--- Recomputes Org's derived checkbox values around `line` (§11.4, §11.5,
--- Amendment 1): each ancestor item's box from its child boxes ([x] all,
--- [ ] none, [-] some), and the progress cookies of those items and of the
--- enclosing headings. Only ancestors change, so unrelated cookies are
--- left as written.
function M.update_progress(lines, line, cfg)
  lines = copy(lines)
  local structure = parse_structure(lines)
  -- The item on the line, if any, and the heading enclosing the line.
  local item_index
  for index, item in ipairs(structure.items) do
    if item.line == line then
      item_index = index
    end
  end
  local children = {}
  for index, item in ipairs(structure.items) do
    if item.parent then
      children[item.parent] = children[item.parent] or {}
      table.insert(children[item.parent], index)
    end
  end
  local function box_counts(list)
    local done, total, partial = 0, 0, 0
    for _, index in ipairs(list or {}) do
      local box = structure.items[index].checkbox
      if box then
        total = total + 1
        if checked(box) then
          done = done + 1
        elseif box == "-" then
          partial = partial + 1
        end
      end
    end
    return done, total, partial
  end

  -- Items: walk up from the item itself (its own cookie counts its children).
  local up = item_index
  while up do
    local item = structure.items[up]
    local done, total, partial = box_counts(children[up])
    if total > 0 then
      if item.checkbox then
        local box = done == total and "x" or ((done > 0 or partial > 0) and "-" or " ")
        if not (box == "x" and checked(item.checkbox)) and box ~= item.checkbox then
          set_box(lines, item, box)
          item.checkbox = box
        end
      end
      lines[item.line] = cookie_text(lines[item.line], done, total)
    end
    up = item.parent
  end

  -- Headings: every heading containing the line, innermost first. Cookie
  -- edits don't change task states, so one parse serves all of them.
  local parsed_once
  for index = #structure.headings, 1, -1 do
    local heading = structure.headings[index]
    if heading.line <= line and heading.stop >= line then
      local top = {}
      for i, item in ipairs(structure.items) do
        if not item.parent and item.heading == index then
          top[#top + 1] = i
        end
      end
      local done, total = box_counts(top)
      if total == 0 then
        -- Child TODO headings, as tasks.lua counts them. Parsed once, and
        -- only if some heading needs it.
        parsed_once = parsed_once or tasks.parse(lines, cfg or config.defaults()) or { tasks = {} }
        local parsed = parsed_once
        for _, task in ipairs(parsed and parsed.tasks or {}) do
          if task.kind == "heading" and task.parent then
            local parent = parsed.tasks[task.parent]
            if parent.line == heading.line then
              total = total + 1
              done = done + (task.done and 1 or 0)
            end
          end
        end
      end
      if total > 0 then
        lines[heading.line] = cookie_text(lines[heading.line], done, total)
      end
    end
  end
  return lines
end

--- Toggles the checkbox on `line` (Org's C-c C-c), writing Markdown's
--- lowercase [x]. A parent's children follow it; then ancestors' boxes and
--- cookies are recomputed.
function M.toggle_checkbox(lines, line, cfg)
  local structure = parse_structure(lines)
  local target
  for index, item in ipairs(structure.items) do
    if item.line == line then
      target = index
    end
  end
  if not target or not structure.items[target].checkbox then
    return nil, "no checkbox on this line"
  end
  lines = copy(lines)
  local box = checked(structure.items[target].checkbox) and " " or "x"
  set_box(lines, structure.items[target], box)
  -- Descendants take the parent's new state.
  for _, item in ipairs(structure.items) do
    local up = item.parent
    while up do
      if up == target then
        if item.checkbox then
          set_box(lines, item, box)
        end
        break
      end
      up = structure.items[up].parent
    end
  end
  return M.update_progress(lines, line, cfg)
end

-- States -----------------------------------------------------------------------

local function settings(cfg)
  return {
    logging = cfg.logging or { done = false, ["repeat"] = "time" },
    enforce = cfg.enforce or { checkboxes = false, todo = false },
    repeat_to_state = cfg.repeat_to_state,
  }
end

-- Org's state-change note: '- State "DONE"       from "TODO"       [ts]'.
local function state_note(new, old, now)
  return ('- State %-12s from %-12s %s'):format('"' .. new .. '"', old and ('"' .. old .. '"') or "", inactive(now))
end

--- Changes the state of the heading on `line` to `new` ("" or nil clears
--- it), following Org (§4.3, §4.4, §10.3):
---   * completing a task with a repeating SCHEDULED or DEADLINE advances
---     them, keeps the task open (back to its previous state, or
---     `repeat_to_state`), records :LAST_REPEAT: and a state note when
---     `logging.repeat` is "time";
---   * otherwise completing adds CLOSED when `logging.done` is "time";
---   * reopening removes CLOSED;
---   * `enforce.checkboxes` / `enforce.todo` block completion while boxes
---     or child tasks are open;
---   * parent cookies that count child tasks are updated.
--- Returns new lines and a message for the user, or nil and an error.
function M.set_state(lines, cfg, line, new, now)
  now = now or M.now()
  local opts = settings(cfg)
  local parsed, err = tasks.parse(lines, cfg)
  if not parsed then
    return nil, err
  end
  local kws = parsed.keywords_at[line]
  local structure = parsed.structure
  local _, index = heading_at(structure, line)
  if not index or not kws then
    return nil, "put the cursor on a heading"
  end
  local prefix, old, rest = split_heading(lines[line], kws)
  if not prefix or rest == "" then
    return nil, "this heading has no text"
  end
  new = new ~= "" and new or nil
  if new and not kws.states[new] then
    return nil, ("%s is not a state in this heading's workflow"):format(new)
  end
  if new == old then
    return lines, nil
  end
  local task
  for _, t in ipairs(parsed.tasks) do
    if t.line == line then
      task = t
    end
  end
  local was_done = old ~= nil and kws.states[old] == "done"
  local done = new ~= nil and kws.states[new] == "done"

  if done and not was_done then
    -- From the structure, so a heading without a state is held to the same
    -- rules as a task (Org checks any heading).
    if opts.enforce.checkboxes then
      local open, total = 0, 0
      for _, item in ipairs(structure.items) do
        if item.heading == index and not item.parent and item.checkbox then
          total = total + 1
          if not checked(item.checkbox) then
            open = open + 1
          end
        end
      end
      if open > 0 then
        return nil, ("%d of %d checkboxes are unchecked (enforce.checkboxes)"):format(open, total)
      end
    end
    if opts.enforce.todo then
      for _, child in ipairs(structure.headings) do
        if child.parent == index then
          for _, t in ipairs(parsed.tasks) do
            if t.line == child.line and not t.done then
              return nil, ("subtask %q is still open (enforce.todo)"):format(t.title)
            end
          end
        end
      end
    end
  end

  local function set_word(state, out)
    out[line] = prefix .. (state and (state .. " ") or "") .. rest
    return out
  end

  local message
  local out = copy(lines)
  -- A heading without a state is not a task yet, but Org repeats it too
  -- when it becomes done: read its dates directly.
  local dated = task or heading_meta(lines, structure, index)
  local changes = done and not was_done and schedule.advance(dated, now)
  if changes then
    -- A repeating task stays open: back to its previous state (Org's
    -- default), unless that was not an open state.
    local back = opts.repeat_to_state
    if not back or not kws.states[back] then
      back = (old and kws.states[old] == "open") and old or kws.first_open
    end
    out = set_word(back, out)
    for field, ts in pairs(changes) do
      out = assert(M.set_planning(out, line, field:upper(), ts.raw))
    end
    if opts.logging["repeat"] == "time" then
      out = assert(M.set_property(out, line, "LAST_REPEAT", inactive(now)))
      local s = parse_structure(out)
      local _, i = heading_at(s, line)
      local meta = heading_meta(out, s, i)
      table.insert(out, math.max(meta.last, line) + 1, state_note(new, old, now))
    end
    local next_date = (changes.scheduled or changes.deadline).date
    message = ("repeats: next on %s, state back to %s"):format(next_date, back or "none")
  else
    -- Only the heading's text changed, so the structure still fits.
    out = set_word(new, out)
    if done and not was_done and opts.logging.done == "time" then
      out = assert(M.set_planning(out, line, "CLOSED", inactive(now), structure))
    elseif was_done and not done then
      out = assert(M.set_planning(out, line, "CLOSED", nil, structure))
    end
  end
  if structure.headings[index].parent then
    out = M.update_progress(out, structure.headings[structure.headings[index].parent].line, cfg)
  end
  return out, message
end

-- Priority ---------------------------------------------------------------------

--- Raises (direction 1) or lowers (-1) the heading's [#X] cookie, Org
--- style: no cookie starts at the default; going past the highest or
--- lowest value removes it.
function M.shift_priority(lines, cfg, line, direction)
  local structure = parse_structure(lines)
  if not heading_at(structure, line) then
    return nil, "put the cursor on a heading"
  end
  local parsed = tasks.parse(lines, cfg)
  local kws = parsed and parsed.keywords_at[line] or cfg.keywords
  local prefix, state, rest = split_heading(lines[line], kws)
  if not prefix or rest == "" then
    return nil, "this heading has no text"
  end
  local values = (cfg.priorities or {}).values or { "A", "B", "C" }
  local default = (cfg.priorities or {}).default or values[math.ceil(#values / 2)]
  local current, after = rest:match("^%[#(%w)%]%s*(.*)$")
  local position
  for i, value in ipairs(values) do
    if value == current then
      position = i
    end
  end
  local new
  if not position then
    new = default
    after = current and after or rest
  else
    local next_position = position - direction
    new = values[next_position] -- nil past either end: removed
  end
  local out = copy(lines)
  out[line] = prefix .. (state and (state .. " ") or "") .. (new and ("[#" .. new .. "] ") or "") .. after
  return out
end

-- Migration --------------------------------------------------------------------

local function date_stamp(date)
  local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
  return ("<%s %s>"):format(date, timestamp.weekday(tonumber(y), tonumber(m), tonumber(d)))
end

-- The workflow's first done state, for a finished v0.1 item whose own
-- state is still active (`- [x] TODO x`).
local function first_done(kws, state)
  for _, cycle in ipairs(kws.cycles or {}) do
    if vim.tbl_contains(cycle, state) then
      for _, candidate in ipairs(cycle) do
        if kws.states[candidate] == "done" then
          return candidate
        end
      end
    end
  end
  for _, cycle in ipairs(kws.cycles or {}) do
    for _, candidate in ipairs(cycle) do
      if kws.states[candidate] == "done" then
        return candidate
      end
    end
  end
end

--- Rewrites the note's Lattice v0.1 forms as Org (plan D3): each legacy
--- item becomes a heading one level below its enclosing heading (deeper
--- for nested ones), with `[due:]` as DEADLINE and `@Name` / `[promised:]`
--- as :ASSIGNED: / :PROMISED:. A finished item (checked box or done state)
--- gets a done state. The item's own sub-lines stay directly below its
--- heading, before the headings of nested legacy items, so nothing changes
--- owner. Invalid `[due:]` dates stay in the title. On headings, `[due:]`
--- becomes DEADLINE and a WAITING heading's `@Name` / `[promised:]` become
--- :ASSIGNED: / :PROMISED:.
---
--- Some forms are left as written, so nothing is lost or reordered: an item
--- nested inside a plain list item (a heading would split that list), an
--- item that would need headings deeper than ######, and a `[due:]` on a
--- heading that already has a different DEADLINE.
--- Returns new lines, the number of items converted, and the skipped ones
--- as { line, reason }.
function M.migrate(lines, cfg)
  local parsed, err = tasks.parse(lines, cfg)
  if not parsed then
    return nil, err
  end
  local structure = parse_structure(lines)
  local item_at = {}
  for _, item in ipairs(structure.items) do
    item_at[item.line] = item
  end

  local count = 0
  local children = {}
  for index, task in ipairs(parsed.tasks) do
    if task.kind == "item" and task.parent and parsed.tasks[task.parent].kind == "item" then
      children[task.parent] = children[task.parent] or {}
      table.insert(children[task.parent], index)
    end
  end

  local function last_line(task)
    local stop = task.source.end_line
    while stop > task.line and vim.trim(lines[stop] or "") == "" do
      stop = stop - 1
    end
    return stop
  end

  -- The Org lines for one legacy item and, recursively, its legacy children.
  local function convert(index, level)
    local task = parsed.tasks[index]
    count = count + 1
    local item = item_at[task.line]
    local state = task.state
    if task.done and parsed.keywords_at[task.line] then
      local kws = parsed.keywords_at[task.line]
      if kws.states[state] ~= "done" then
        state = first_done(kws, state) or state
      end
    end
    local block = { ("%s %s %s"):format(("#"):rep(level), state, task.title) }
    if task.legacy.due then
      block[#block + 1] = "DEADLINE: " .. date_stamp(task.legacy.due)
    end
    local props = {}
    if task.legacy.assigned then
      props[#props + 1] = ":ASSIGNED: " .. task.legacy.assigned
    end
    if task.legacy.promised then
      props[#props + 1] = ":PROMISED: " .. task.legacy.promised
    end
    if #props > 0 then
      block[#block + 1] = ":PROPERTIES:"
      vim.list_extend(block, props)
      block[#block + 1] = ":END:"
    end
    -- Continuation lines sit at the item's content column: just past its
    -- marker and the spaces after it.
    local marker = lines[task.line]:sub(item.col + 1):match("^([-*+]%s+)")
      or lines[task.line]:sub(item.col + 1):match("^(%d+[.)]%s+)")
      or "- "
    local width = item.col + #marker
    local skip = {}
    for _, child in ipairs(children[index] or {}) do
      local c = parsed.tasks[child]
      for at = c.line, last_line(c) do
        skip[at] = true
      end
    end
    local own = {}
    for at = task.line + 1, last_line(task) do
      if not skip[at] then
        local text = lines[at]
        local lead = #text:match("^(%s*)")
        own[#own + 1] = lead >= width and text:sub(width + 1) or vim.trim(text) == "" and "" or text:gsub("^%s+", "")
      end
    end
    while #own > 0 and vim.trim(own[#own]) == "" do
      table.remove(own)
    end
    vim.list_extend(block, own)
    for _, child in ipairs(children[index] or {}) do
      block[#block + 1] = ""
      vim.list_extend(block, convert(child, level + 1))
    end
    return block
  end

  -- Reasons any legacy task (item or heading) can't be converted.
  local function common_blocker(task)
    if task.title == "" then
      if task.legacy.assigned then
        return "its title is only @Name; add a title first"
      end
      return "it has no title besides its dates; add a title first"
    end
    for tag in pairs(task.legacy_multiple or {}) do
      return ("it has more than one [%s:] date; keep one"):format(tag)
    end
  end

  -- Why the legacy item (and its legacy children) at `level` can't become
  -- headings without losing or reordering something, or nil.
  local function blocker(index, level, nested)
    local task = parsed.tasks[index]
    local reason = common_blocker(task)
    if reason then
      -- A nested item's reason names its line; "it" would read as the parent.
      return nested and ("line %d: %s"):format(task.line, reason) or reason
    end
    if level > 6 then
      return "it would need headings deeper than ######"
    end
    for _, child in ipairs(children[index] or {}) do
      local item = item_at[parsed.tasks[child].line]
      if structure.items[item.parent].line ~= task.line then
        return ("line %d is inside a plain list item; move it out of that list first"):format(item.line)
      end
      local reason = blocker(child, level + 1, true)
      if reason then
        return reason
      end
    end
  end

  -- Why a heading's legacy forms can't be converted, or nil.
  local function heading_blocker(task)
    local legacy = task.legacy
    local reason = common_blocker(task)
    if reason then
      return reason
    end
    local deadline = written_planning(lines, task.planning_lines, "DEADLINE")
    if legacy.due and deadline and not (task.deadline and task.deadline.date == legacy.due) then
      return ("its [due:%s] differs from its DEADLINE %s; keep one"):format(legacy.due, deadline)
    end
    local promised = task.properties.PROMISED
    if legacy.promised and promised and promised ~= legacy.promised then
      return ("its [promised:%s] differs from its :PROMISED: %s; keep one"):format(legacy.promised, promised)
    end
  end

  -- Top-level legacy items and headings with legacy forms. Tasks come in
  -- line order, so `skipped` does too; `work` is applied bottom-up so
  -- earlier line numbers stay valid.
  local work, skipped = {}, {}
  local function skip(line, reason)
    skipped[#skipped + 1] = { line = line, reason = reason }
  end
  for index, task in ipairs(parsed.tasks) do
    local nested = task.kind == "item" and task.parent and parsed.tasks[task.parent].kind == "item"
    if task.kind == "item" and not nested then
      local item = item_at[task.line]
      local base = item.heading and structure.headings[item.heading].level or 1
      local reason = item.parent and "it is inside a plain list item; move it out of the list first" or blocker(index, base + 1)
      if reason then
        skip(task.line, reason)
      else
        work[#work + 1] = index
      end
    elseif task.kind == "heading" and next(task.legacy) then
      local reason = heading_blocker(task)
      if reason then
        skip(task.line, reason)
      else
        work[#work + 1] = index
      end
    end
  end
  table.sort(work, function(a, b)
    return parsed.tasks[a].line > parsed.tasks[b].line
  end)

  local out = copy(lines)
  for _, index in ipairs(work) do
    local task = parsed.tasks[index]
    if task.kind == "heading" then
      count = count + 1 -- items are counted by convert()
      local legacy = task.legacy
      -- Removes the first "[tag:value]" with exactly this value.
      local function drop(tag, value)
        out[task.line] = out[task.line]:gsub("[ \t]*%[" .. tag .. ":" .. vim.pesc(value) .. "%]", "", 1)
      end
      if legacy.due then
        drop("due", legacy.due)
        if not task.deadline then
          out = assert(M.set_planning(out, task.line, "DEADLINE", date_stamp(legacy.due)))
        end
      end
      if legacy.promised then
        drop("promised", legacy.promised)
        if not task.properties.PROMISED then
          out = assert(M.set_property(out, task.line, "PROMISED", legacy.promised))
        end
      end
      if legacy.assigned then
        out[task.line] = out[task.line]:gsub("([ \t])@" .. vim.pesc(legacy.assigned) .. "[ \t]*", "%1", 1)
        out = assert(M.set_property(out, task.line, "ASSIGNED", legacy.assigned))
      end
    else
      local item = item_at[task.line]
      local base = item.heading and structure.headings[item.heading].level or 1
      local block = convert(index, base + 1)
      local stop = last_line(task)
      if task.line > 1 and vim.trim(out[task.line - 1]) ~= "" then
        table.insert(block, 1, "")
      end
      if out[stop + 1] ~= nil and vim.trim(out[stop + 1]) ~= "" then
        block[#block + 1] = ""
      end
      for _ = task.line, stop do
        table.remove(out, task.line)
      end
      for i = #block, 1, -1 do
        table.insert(out, task.line, block[i])
      end
    end
  end
  return out, count, skipped
end

-- Refile and archive (§14.2) -----------------------------------------------

-- The subtree of the heading on `line`: first and last line (trailing
-- blank lines left out), its level, and the lines of every heading in it.
local function subtree(lines, line)
  local structure = parse_structure(lines)
  local heading = heading_at(structure, line)
  if not heading then
    return nil, "put the cursor on a heading"
  end
  local last = heading.stop
  while last > line and vim.trim(lines[last] or "") == "" do
    last = last - 1
  end
  local inner = {}
  for _, h in ipairs(structure.headings) do
    if h.line >= line and h.line <= last then
      inner[#inner + 1] = h.line
    end
  end
  return { first = line, last = last, level = heading.level, headings = inner }
end

-- The subtree's lines with every heading moved `delta` levels.
local function shifted_block(lines, tree, delta)
  local block = vim.list_slice(lines, tree.first, tree.last)
  for _, at in ipairs(tree.headings) do
    local i = at - tree.first + 1
    local indent, hashes, rest = block[i]:match("^( ? ? ?)(#+)(.*)$")
    local level = #hashes + delta
    if level > 6 then
      return nil, "the subtree would need headings deeper than ######"
    end
    block[i] = indent .. ("#"):rep(level) .. rest
  end
  return block
end

-- The lines without the subtree. Also returns how many lines went at the
-- subtree's place, so a line below it can be found again (trailing blank
-- lines trimmed at the end of the note don't count).
local function remove_block(lines, tree)
  local out = copy(lines)
  local removed = tree.last - tree.first + 1
  for _ = tree.first, tree.last do
    table.remove(out, tree.first)
  end
  -- Don't leave two blank lines where the subtree was.
  if tree.first > 1 and vim.trim(out[tree.first - 1] or "") == "" and vim.trim(out[tree.first] or "") == "" then
    table.remove(out, tree.first)
    removed = removed + 1
  end
  while #out > 1 and vim.trim(out[#out]) == "" and vim.trim(out[#out - 1]) == "" do
    table.remove(out)
  end
  return out, removed
end

-- Inserts `block` at the end of the subtree of the heading on `line`, or at
-- the end of the note when `line` is nil, with blank lines around it.
local function insert_block(lines, line, block)
  local out = copy(lines)
  local after = #out
  if line then
    local structure = parse_structure(out)
    local heading = heading_at(structure, line)
    after = heading.stop
  end
  while after > 0 and vim.trim(out[after] or "") == "" and (not line or after > line) do
    after = after - 1
  end
  local insert = vim.list_extend({}, block)
  if after > 0 then
    table.insert(insert, 1, "")
  end
  if out[after + 1] ~= nil and vim.trim(out[after + 1]) ~= "" then
    insert[#insert + 1] = ""
  end
  if #out == 1 and out[1] == "" then
    return vim.list_extend({}, block)
  end
  for i = #insert, 1, -1 do
    table.insert(out, after + 1, insert[i])
  end
  return out
end

--- Moves the subtree on `line` under the heading on `dest_line` (one level
--- below it; its headings re-levelled), or to the end of the note when
--- `dest_line` is nil, keeping its level. With `dest_lines` nil the target
--- is in the same note. Returns new source lines and new destination lines
--- (nil for the same note), or nil and an error.
function M.refile(lines, line, dest_lines, dest_line)
  local tree, err = subtree(lines, line)
  if not tree then
    return nil, err
  end
  local delta = 0
  local target_lines = dest_lines or lines
  if dest_line then
    local dest = heading_at(parse_structure(target_lines), dest_line)
    if not dest then
      return nil, "the target is not a heading"
    end
    delta = dest.level + 1 - tree.level
  end
  local block, block_err = shifted_block(lines, tree, delta)
  if not block then
    return nil, block_err
  end
  if dest_lines then
    return remove_block(lines, tree), insert_block(dest_lines, dest_line, block)
  end
  if dest_line and dest_line >= tree.first and dest_line <= tree.last then
    return nil, "a heading can't be refiled under itself"
  end
  local rest, removed = remove_block(lines, tree)
  if dest_line and dest_line > tree.last then
    dest_line = dest_line - removed
  end
  return insert_block(rest, dest_line, block), nil
end

--- Archives the subtree on `line`, Org style: it becomes a top-level
--- heading at the end of the archive note, with :ARCHIVE_TIME:,
--- :ARCHIVE_FILE:, :ARCHIVE_OLPATH:, :ARCHIVE_CATEGORY: and
--- :ARCHIVE_TODO:. `archive_lines` nil starts a new archive note. Returns
--- new source lines and new archive lines, or nil and an error.
function M.archive(lines, cfg, line, rel, archive_lines, now)
  now = now or M.now()
  local tree, err = subtree(lines, line)
  if not tree then
    return nil, err
  end
  local block, block_err = shifted_block(lines, tree, 1 - tree.level)
  if not block then
    return nil, block_err
  end
  local parsed = tasks.parse(lines, cfg)
  local outline, todo = {}, nil
  for _, heading in ipairs(parsed and parsed.headings or {}) do
    if heading.line == line then
      outline = vim.list_slice(heading.outline, 1, #heading.outline - 1)
    end
  end
  for _, task in ipairs(parsed and parsed.tasks or {}) do
    if task.line == line then
      todo = task.state
    end
  end
  local category = vim.fn.fnamemodify(rel, ":t:r")
  for _, entry in ipairs({
    { "ARCHIVE_TIME", inactive(now) },
    { "ARCHIVE_FILE", rel },
    { "ARCHIVE_OLPATH", #outline > 0 and table.concat(outline, "/") or nil },
    { "ARCHIVE_CATEGORY", category },
    { "ARCHIVE_TODO", todo },
  }) do
    if entry[2] then
      block = assert(M.set_property(block, 1, entry[1], entry[2]))
    end
  end
  if archive_lines == nil or (#archive_lines == 1 and archive_lines[1] == "") then
    archive_lines = { ("Archived entries from %s."):format(rel) }
  end
  return remove_block(lines, tree), insert_block(archive_lines, nil, block)
end

--- The buffer for a note, loaded (hidden but listed) if it is not open,
--- so edits keep any unsaved changes already there and stay visible.
function M.note_buffer(path)
  local buf = vim.fn.bufadd(path)
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  vim.bo[buf].buflisted = true
  return buf
end

--- Applies edits to two buffers together: both are checked first, so
--- either both change or neither does.
function M.apply_pair(buf_a, old_a, new_a, buf_b, old_b, new_b)
  for _, pair in ipairs({ { buf_a, old_a }, { buf_b, old_b } }) do
    if not vim.deep_equal(vim.api.nvim_buf_get_lines(pair[1], 0, -1, false), pair[2]) then
      return nil, "a note changed since this edit was prepared; nothing was changed"
    end
  end
  assert(M.apply(buf_b, old_b, new_b))
  assert(M.apply(buf_a, old_a, new_a))
  return true
end

-- Applying ---------------------------------------------------------------------

--- Writes `new` over `old` in `buf`: only the changed hunks, bottom-up, as
--- one undo step. Refuses, changing nothing, when the buffer no longer
--- holds `old` (§14.2 source validation).
function M.apply(buf, old, new)
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not vim.deep_equal(current, old) then
    return nil, "the note changed since this edit was prepared; nothing was changed"
  end
  local a = table.concat(old, "\n") .. "\n"
  local b = table.concat(new, "\n") .. "\n"
  local hunks = vim.diff(a, b, { result_type = "indices" })
  for i = #hunks, 1, -1 do
    local start_a, count_a, start_b, count_b = unpack(hunks[i])
    local replacement = count_b > 0 and vim.list_slice(new, start_b, start_b + count_b - 1) or {}
    local first = count_a > 0 and start_a - 1 or start_a
    vim.api.nvim_buf_set_lines(buf, first, first + count_a, false, replacement)
  end
  return #hunks
end

return M
