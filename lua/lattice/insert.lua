-- Explicit, user-triggered edits to the current note. Nothing here saves to disk.
local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
local keywords = require("lattice.keywords")
local markdown = require("lattice.markdown")
local mutate = require("lattice.mutate")
local tasks = require("lattice.tasks")

local M = {}

local function warn(message)
  vim.notify("Lattice: " .. message, vim.log.levels.WARN)
end

local function current_markdown_buffer(purpose)
  local buf = vim.api.nvim_get_current_buf()
  local markdown = vim.bo[buf].filetype == "markdown" or vim.api.nvim_buf_get_name(buf):match("%.md$")
  if dashboard.is_dashboard(buf) or vim.bo[buf].buftype ~= "" or not markdown then
    warn("open a Markdown note to " .. (purpose or "add a task"))
    return nil
  end
  if not vim.bo[buf].modifiable then
    warn("this buffer is not modifiable")
    return nil
  end
  return buf
end

-- Parses the buffer's lines. If the Markdown parser is unavailable, warns
-- and returns an empty result, so commands change nothing.
local function parse(lines, cfg)
  local result, err = tasks.parse(lines, cfg)
  if not result then
    warn(err)
    return { tasks = {}, sections = {}, keywords = cfg.keywords, keywords_at = {}, failed = true }
  end
  return result
end

local function load_config()
  local root = config.options.root
  if not root then
    return config.defaults()
  end
  local cfg, _, err = config.load(root)
  if not cfg then
    vim.notify("Lattice: " .. err, vim.log.levels.ERROR)
    return nil
  end
  return cfg
end

--- Warns when the entry at `line` is not read back as a task, which happens
--- when it lands inside a code block (for example one that is never closed).
function M.check_visible(buf, line, cfg)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, task in ipairs(parse(lines, cfg).tasks) do
    if task.line == line then
      return true
    end
  end
  warn(("line %d was added, but Lattice won't list it as a task: it may be inside a code block (```) that is never closed. Move it out, or close the block."):format(line))
  return false
end

--- Inserts an Org heading task, "<hashes> <STATE> <text>", plus any
--- `drawer` lines below it. Like Org's C-S-RET, the new heading takes the
--- level of the heading the cursor is in and goes after that heading's
--- subtree; with no heading above the cursor it is a level-2 heading on
--- the line below (after any front matter). Blank lines keep headings
--- apart, as Markdown linters expect.
--- Returns the heading's 1-based line, or nil and an error.
function M.insert_heading(buf, state, text, cfg, cursor, drawer)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local structure, err = markdown.parse(lines)
  if not structure then
    return nil, err
  end
  local parsed = parse(lines, cfg)
  cursor = math.max(cursor, structure.front_matter)

  local enclosing
  for _, heading in ipairs(structure.headings) do
    if heading.line <= cursor and heading.stop >= cursor then
      enclosing = heading -- the innermost wins: headings come in order
    end
  end

  -- The new heading is the enclosing heading's sibling, so it inherits
  -- what that heading inherits (from its parent), not the heading's own
  -- :WORKFLOW: or project.
  local parent = enclosing and enclosing.parent and structure.headings[enclosing.parent]
  local kws = parent and parsed.keywords_at[parent.line] or parsed.keywords
  if state == "first_open" then
    state = kws.first_open
    if not state then
      return nil, "this note's workflow has no active state"
    end
  elseif not kws.states[state] then
    return nil, ("this note's workflow has no %s state"):format(state)
  end

  local level = enclosing and enclosing.level or 2
  local after = enclosing and enclosing.stop or cursor
  if #lines == 1 and lines[1] == "" then
    after = 0
  end
  while after > 0 and vim.trim(lines[after] or "") == "" and (not enclosing or after > enclosing.line) do
    after = after - 1
  end

  local block = { ("%s %s %s"):format(("#"):rep(level), state, text) }
  vim.list_extend(block, drawer or {})
  local heading_line = after + 1
  if after > 0 then
    table.insert(block, 1, "")
    heading_line = after + 2
  end
  local next_line = lines[after + 1]
  if next_line ~= nil and vim.trim(next_line) ~= "" then
    block[#block + 1] = ""
  end
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, block)
  else
    vim.api.nvim_buf_set_lines(buf, after, after, false, block)
  end
  return heading_line
end

-- The state after `current` (nil = no keyword) in `direction` (1 forward,
-- -1 back). Like org: an item steps through the sequence that holds its
-- keyword, then back to no keyword; an item without one starts on the
-- first sequence.
local function step(cycles, current, direction)
  local cycle = cycles[1]
  local index = 0
  for _, candidate in ipairs(cycles) do
    for i, keyword in ipairs(candidate) do
      if keyword == current then
        cycle, index = candidate, i
        break
      end
    end
    if index > 0 then
      break
    end
  end
  if index == 0 then
    index = direction > 0 and 0 or #cycle + 1
  end
  return cycle[index + direction] -- nil past either end: no keyword
end

--- Splits a list item or ATX heading into its prefix (marker and any
--- checkbox, or the hashes) and the text after it. nil for other lines.
local function item_parts(line)
  local prefix, text = line:match("^([ \t]*[-*+][ \t]+%[[ xX%-]%][ \t]+)(.*)$")
  if not prefix then
    prefix, text = line:match("^([ \t]*[-*+][ \t]+)(.*)$")
  end
  if not prefix then
    prefix, text = line:match("^( ? ? ?#+[ \t]+)(.*)$")
    if prefix and #prefix:match("#+") > 6 then
      prefix = nil
    end
  end
  return prefix, text
end

--- The line with its keyword moved one state in `direction` (1 forward, -1
--- back), using the note's keyword table. Returns the new line, the 0-based
--- start and end columns of the replaced span, the new state (nil when the
--- keyword was removed) and the text that replaces the span; or nil and an
--- error.
function M.cycle_line(line, kws, direction)
  local prefix, text = item_parts(line)
  if not prefix then
    return nil, "put the cursor on a list item (- …) or a heading (# …)"
  end
  -- Longest state first, so "IN PROGRESS" is one state, not "IN".
  local current, gap = tasks.leading_state(text, kws)
  local old = current and current .. gap or ""
  local rest = text:sub(#old + 1)
  local state = step(kws.cycles, current, direction)
  if state and rest:match("^%s*$") then
    return nil, "this item has no text; type the task first"
  end
  local new = state and state .. " " or ""
  return prefix .. new .. rest, #prefix, #prefix + #old, state, new
end

--- Moves the keyword of the item on `row` (1-based) one state in
--- `direction`. Edits only that span of the line, so the change is one undo
--- step. Refuses, changing nothing, when Lattice would not list the result
--- (for example inside a code block). Returns the new state ("" for none),
--- or nil and an error.
function M.cycle(buf, row, cfg, direction)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local _, _, front_end = keywords.front_matter(lines)
  if row <= front_end then
    return nil, "the cursor is in the front matter; put it on a list item or heading"
  end
  local parsed = parse(lines, cfg)
  if parsed.failed then
    return nil, "the Markdown parser is unavailable"
  end
  -- The workflow in effect at this line (project, :WORKFLOW:, or note).
  local kws = parsed.keywords_at[row] or parsed.keywords
  if #kws.cycles == 0 then
    return nil, "this note has no keyword sequences"
  end
  local line = lines[row]
  if not line:match("^ ? ? ?#") then
    -- Org has no list-item tasks. A Lattice v0.1 keyword bullet can still
    -- change or drop its state, but a plain item never gains one.
    local _, text = item_parts(line)
    local word = text and text:match("^%[[ xX%-]%][ \t]+(%S.*)$") or text
    local has_state = word and tasks.split_state(word, kws) ~= nil
    if text and not has_state then
      return nil, "list items aren't tasks in Org; put the cursor on a heading (## TODO …), or use <leader>lt to add one"
    end
  end
  local new_line, start, stop, state, inserted = M.cycle_line(line, kws, direction)
  if not new_line then
    return nil, start
  end
  local original = vim.list_extend({}, lines)
  if state then
    lines[row] = new_line
    local listed = false
    for _, task in ipairs(parse(lines, cfg).tasks) do
      listed = listed or task.line == row
    end
    if not listed then
      return nil, "Lattice wouldn't list this line as an item: it is inside a code block or indented as code"
    end
  end
  if line:match("^ ? ? ?#") then
    -- Headings go through the mutation layer: CLOSED, repeaters, logging
    -- and parent cookies, as Org's S-Right does.
    local new_lines, message = mutate.set_state(original, cfg, row, state or "")
    if not new_lines then
      return nil, message
    end
    local ok, apply_err = mutate.apply(buf, original, new_lines)
    if not ok then
      return nil, apply_err
    end
    if message then
      vim.notify("Lattice: " .. message, vim.log.levels.INFO)
    end
    return state or "", nil, message
  end
  vim.api.nvim_buf_set_text(buf, row - 1, start, row - 1, stop, { inserted })
  return state or ""
end

local function cycle_command(direction)
  local buf = current_markdown_buffer("change a task's state")
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local _, err = M.cycle(buf, vim.api.nvim_win_get_cursor(0)[1], cfg, direction)
  if err then
    warn(err)
  end
end

function M.next_state()
  cycle_command(1)
end

function M.prev_state()
  cycle_command(-1)
end

local function usable(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    warn("the note is no longer available; task not added")
    return false
  end
  return true
end

-- nil means cancelled; "" means left blank.
local function ask(label, on_value)
  vim.ui.input({ prompt = label }, function(value)
    if type(value) == "string" then
      on_value(vim.trim(value))
    end
  end)
end

-- Inserts a heading once the prompts are answered. The cursor line is
-- captured when the command starts, so the placement matches what the
-- user saw.
local function finish(buf, state, text, cursor, drawer)
  if not usable(buf) then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local line, err = M.insert_heading(buf, state, text, cfg, cursor, drawer)
  if line then
    M.check_visible(buf, line, cfg)
  else
    warn(err .. "; task not added")
  end
end

function M.add_todo()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  ask("TODO: ", function(text)
    if text ~= "" then
      finish(buf, "first_open", text, cursor)
    end
  end)
end

--- Adds "## WAITING <text>", with an :ASSIGNED: drawer when a name is
--- given: Org's way of tracking what others owe you.
function M.add_waiting()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  ask("Waiting on (name, optional): ", function(person)
    person = vim.trim((person:gsub("^@", "")))
    ask("Waiting for: ", function(text)
      if text == "" then
        return
      end
      local drawer = person ~= "" and { ":PROPERTIES:", ":ASSIGNED: " .. person, ":END:" } or nil
      finish(buf, "WAITING", text, cursor, drawer)
    end)
  end)
end

-- Edit commands (milestone D) -------------------------------------------------

-- Runs a pure mutation on the current note: `op(lines, cfg, row)` returns
-- new lines and an optional message, or nil and an error.
local function edit(purpose, op)
  local buf = current_markdown_buffer(purpose)
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ok, new_lines, message = pcall(op, lines, cfg, row)
  if not ok then
    warn(tostring(new_lines))
    return
  end
  if not new_lines then
    warn(message)
    return
  end
  local applied, err = mutate.apply(buf, lines, new_lines)
  if not applied then
    warn(err)
  elseif message then
    vim.notify("Lattice: " .. message, vim.log.levels.INFO)
  end
end

--- Org's C-c C-t with selection: pick any state of the heading's workflow.
function M.set_state()
  local buf = current_markdown_buffer("change a task's state")
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local parsed = parse(lines, cfg)
  local kws = parsed.keywords_at[row]
  if not kws or not lines[row]:match("^ ? ? ?#") then
    warn("put the cursor on a heading")
    return
  end
  vim.ui.select(keywords.choices(kws), { prompt = "State: " }, function(choice)
    if not choice then
      return
    end
    if not usable(buf) then
      return
    end
    local new_lines, message = mutate.set_state(lines, cfg, row, choice == keywords.NO_STATE and "" or choice)
    if not new_lines then
      warn(message)
      return
    end
    local applied, err = mutate.apply(buf, lines, new_lines)
    if not applied then
      warn(err)
    elseif message then
      vim.notify("Lattice: " .. message, vim.log.levels.INFO)
    end
  end)
end

function M.toggle_checkbox()
  edit("toggle a checkbox", function(lines, cfg, row)
    return mutate.toggle_checkbox(lines, row, cfg)
  end)
end

function M.priority_up()
  edit("change a priority", function(lines, cfg, row)
    return mutate.shift_priority(lines, cfg, row, 1)
  end)
end

function M.priority_down()
  edit("change a priority", function(lines, cfg, row)
    return mutate.shift_priority(lines, cfg, row, -1)
  end)
end

M.read_date = require("lattice.schedule").read_date

--- The prompt for a SCHEDULED or DEADLINE answer.
function M.date_prompt(keyword)
  local label = keyword == "SCHEDULED" and "Schedule" or "Deadline"
  return label .. " (YYYY-MM-DD, today, +3d, optional HH:MM; empty removes): "
end

--- The edit for a date answer: a function(lines, line) that sets SCHEDULED
--- or DEADLINE ("" removes it), keeping any repeater and warning period.
--- nil and an error for an answer Lattice can't read. Shared by the note
--- commands and the dashboard's S/D.
function M.date_edit(keyword, answer)
  local when
  if answer ~= "" then
    when = M.read_date(answer, os.date("%Y-%m-%d"))
    if not when then
      return nil, ("%q is not a date Lattice understands; nothing changed"):format(answer)
    end
  end
  return function(lines, line)
    return mutate.set_date(lines, line, keyword, when)
  end
end

-- Org's C-c C-s / C-c C-d: set or remove SCHEDULED / DEADLINE.
local function plan_command(keyword)
  local buf = current_markdown_buffer("schedule a task")
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not lines[row]:match("^ ? ? ?#") then
    warn("put the cursor on a heading")
    return
  end
  ask(M.date_prompt(keyword), function(answer)
    if not usable(buf) then
      return
    end
    local op, op_err = M.date_edit(keyword, answer)
    if not op then
      warn(op_err)
      return
    end
    local new_lines, err = op(lines, row)
    if not new_lines then
      warn(err)
      return
    end
    local applied, apply_err = mutate.apply(buf, lines, new_lines)
    if not applied then
      warn(apply_err)
    end
  end)
end

function M.schedule()
  plan_command("SCHEDULED")
end

function M.deadline()
  plan_command("DEADLINE")
end

--- Converts the current note's Lattice v0.1 forms to Org headings, after
--- asking. One undo step; the note is not saved.
function M.migrate()
  local buf = current_markdown_buffer("migrate")
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local new_lines, count, skipped = mutate.migrate(lines, cfg)
  if not new_lines then
    warn(count)
    return
  end
  if #skipped > 0 then
    local reasons = {}
    for _, entry in ipairs(skipped) do
      reasons[#reasons + 1] = ("line %d: %s"):format(entry.line, entry.reason)
    end
    warn(("%d item(s) left as written:\n%s"):format(#skipped, table.concat(reasons, "\n")))
  end
  if count == 0 then
    if #skipped == 0 then
      vim.notify("Lattice: this note has no Lattice v0.1 items to convert", vim.log.levels.INFO)
    end
    return
  end
  vim.ui.select({ "Yes", "No" }, {
    prompt = ("Convert %d Lattice v0.1 item(s) in this note to Org headings?"):format(count),
  }, function(choice)
    if choice ~= "Yes" or not usable(buf) then
      return
    end
    local applied, err = mutate.apply(buf, lines, new_lines)
    if not applied then
      warn(err)
    else
      vim.notify(("Lattice: converted %d item(s); review, then save"):format(count), vim.log.levels.INFO)
    end
  end)
end

-- Refile and archive (§14.2) ------------------------------------------------

-- The note's path relative to the notes root and the root, or its file
-- name and its own folder when it is outside the root.
local function relative(path)
  local root = config.options.root
  local real_root = root and (vim.uv.fs_realpath(root) or root)
  local real = vim.uv.fs_realpath(path) or path
  if real_root and real:sub(1, #real_root + 1) == real_root .. "/" then
    return real:sub(#real_root + 2), real_root
  end
  return vim.fn.fnamemodify(real, ":t"), vim.fn.fnamemodify(real, ":h")
end

--- Org's C-c C-w: moves the subtree under the cursor under a heading
--- chosen from every note (or to the end of a note), re-levelling it.
function M.refile()
  local buf = current_markdown_buffer("refile a task")
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local root = config.options.root
  if not root then
    warn("set the notes root to refile")
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not lines[row]:match("^ ? ? ?#+%s") then
    warn("put the cursor on a heading")
    return
  end
  local here = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) or vim.api.nvim_buf_get_name(buf)
  local result = require("lattice.scanner").collect(root)
  local choices = {}
  local seen_files = {}
  for _, heading in ipairs(result.outlines or {}) do
    if not seen_files[heading.path] then
      seen_files[heading.path] = true
      choices[#choices + 1] = { label = heading.rel .. "  (end of note)", path = heading.path }
    end
    choices[#choices + 1] = {
      label = heading.rel .. " › " .. table.concat(heading.outline, " › "),
      path = heading.path,
      line = heading.line,
      text = heading.text,
    }
  end
  vim.ui.select(choices, {
    prompt = "Refile to: ",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice or not usable(buf) then
      return
    end
    local same = (vim.uv.fs_realpath(choice.path) or choice.path) == here
    if same then
      -- The target line may have moved if the note changed since the scan.
      local dest = choice.line and dashboard.locate(lines, { line = choice.line, text = choice.text })
      if choice.line and not dest then
        warn("the target heading changed since the list was made; nothing was moved. Try again.")
        return
      end
      local new_lines, err = mutate.refile(lines, row, nil, dest)
      if not new_lines then
        warn(err)
        return
      end
      local ok, apply_err = mutate.apply(buf, lines, new_lines)
      if not ok then
        warn(apply_err)
      end
      return
    end
    local dest_buf = mutate.note_buffer(choice.path)
    local dest_lines = vim.api.nvim_buf_get_lines(dest_buf, 0, -1, false)
    local dest = choice.line and dashboard.locate(dest_lines, { line = choice.line, text = choice.text })
    if choice.line and not dest then
      warn("the target heading changed since the list was made; nothing was moved. Try again.")
      return
    end
    local new_src, new_dest = mutate.refile(lines, row, dest_lines, dest)
    if not new_src then
      warn(new_dest)
      return
    end
    local ok, err = mutate.apply_pair(buf, lines, new_src, dest_buf, dest_lines, new_dest)
    if not ok then
      warn(err)
    else
      vim.notify(("Lattice: refiled to %s (both notes unsaved)"):format(vim.fn.fnamemodify(choice.path, ":t")), vim.log.levels.INFO)
    end
  end)
end

--- Org's archive: moves the subtree under the cursor to the archive note
--- (`archive.location`, default "<note>_archive.md" beside it).
function M.archive()
  local buf = current_markdown_buffer("archive a task")
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not lines[row]:match("^ ? ? ?#+%s") then
    warn("put the cursor on a heading")
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local rel, base = relative(path)
  local location = (cfg.archive or {}).location or "%s_archive.md"
  local stem = rel:gsub("%.md$", "")
  local target = base .. "/" .. location:gsub("%%s", function()
    return stem
  end)
  local real_target = vim.uv.fs_realpath(target) or vim.fs.normalize(target)
  if real_target == (vim.uv.fs_realpath(path) or path) then
    warn(("archive.location %s points at this note itself; change it in .lattice.json"):format(location))
    return
  end
  if vim.fn.isdirectory(vim.fn.fnamemodify(target, ":h")) == 0 then
    warn(("the folder for %s doesn't exist; create it or change archive.location"):format(vim.fn.fnamemodify(target, ":~")))
    return
  end
  local dest_buf = mutate.note_buffer(target)
  local dest_lines = vim.api.nvim_buf_get_lines(dest_buf, 0, -1, false)
  local new_src, new_dest = mutate.archive(lines, cfg, row, rel, dest_lines)
  if not new_src then
    warn(new_dest)
    return
  end
  local ok, err = mutate.apply_pair(buf, lines, new_src, dest_buf, dest_lines, new_dest)
  if not ok then
    warn(err)
  else
    vim.notify(("Lattice: archived to %s (both notes unsaved)"):format(vim.fn.fnamemodify(target, ":~:.")), vim.log.levels.INFO)
  end
end

return M
