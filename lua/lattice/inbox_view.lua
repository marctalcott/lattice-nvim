-- The inbox view (LATTICE_INBOX_SPEC §8, §12, A1.2, A1.10): captures grouped
-- by repository, a read-only preview, filing into a new, unsaved note, and
-- dismissal. Lattice writes nothing itself: the user's save files the
-- capture, and only then is it removed from GitHub.
local config = require("lattice.config")
local process = require("lattice.inbox_process")
local sync = require("lattice.inbox_sync")

local M = {}

local BUFFER_NAME = "lattice://inbox"
local PREVIEW_NAME = "lattice://inbox/preview"
local FOOTER = "Enter  Preview / fold    f  File    t  Task    o  Open    D  Dismiss    R  Refresh    q  Close"
local ns = vim.api.nvim_create_namespace("lattice.inbox")

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

-- Session state. `pending` maps sync.key(capture) to the buffer of the
-- capture's unsaved note. Filed and dismissed captures are tracked by
-- sync.state.removals until GitHub removal succeeds.
local state = {
  buf = nil,
  prev_buf = nil,
  preview_win = nil,
  targets = {},
  collapsed = {},
  pending = {},
}
M.state = state

local key = sync.key

-- A path relative to the notes root, for messages.
local function relative(path)
  local root = config.options.root
  if path and root and vim.startswith(path, root .. "/") then
    return path:sub(#root + 2)
  end
  return path and vim.fn.fnamemodify(path, ":~") or "?"
end

--- Asks before dismissing (§12.4). Overridable for tests.
function M.confirm(message)
  return vim.fn.confirm(message, "&Dismiss\n&Cancel", 2, "Question") == 1
end

-- Title, body and time of a capture, reread only when its file changes.
local info_cache = {}
function M.info(capture)
  local stat = vim.uv.fs_stat(capture.path)
  local stamp = stat and ("%d:%d:%d"):format(stat.size, stat.mtime.sec, stat.mtime.nsec) or ""
  local hit = info_cache[capture.path]
  if hit and hit.stamp == stamp then
    return hit.info
  end
  local file = io.open(capture.path, "r")
  local text = file and file:read("*a") or ""
  if file then
    file:close()
  end
  local body = process.body_lines(text, capture.body_line)
  local time = process.epoch(capture.created)
  if not time then
    -- Fall back to the timestamp in the file name (YYYY-MM-DD-HHMMSS-…).
    local y, mo, d, h, mi, s = capture.file:match("^(%d%d%d%d)-(%d%d)-(%d%d)-(%d%d)(%d%d)(%d%d)")
    time = y and process.epoch(("%s-%s-%sT%s:%s:%sZ"):format(y, mo, d, h, mi, s))
  end
  local info = { body = body, title = process.title(body, capture.created), time = time }
  info_cache[capture.path] = { stamp = stamp, info = info }
  return info
end

local function display_date(capture)
  local date, time = (capture.created or ""):match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d)")
  if date then
    return date .. " " .. time
  end
  local y, mo, d, h, mi = capture.file:match("^(%d%d%d%d)-(%d%d)-(%d%d)-(%d%d)(%d%d)")
  return y and ("%s-%s-%s %s:%s"):format(y, mo, d, h, mi) or "                "
end

--- Groups to show: active repositories in configuration order, each with
--- its captures sorted by time (newest first unless configured otherwise).
function M.groups()
  local newest_first = not (sync.state.settings and sync.state.settings.sort_order == "oldest_first")
  local groups = {}
  for _, name in ipairs(sync.state.order or {}) do
    local entry = sync.state.repos[name]
    if entry.role == "active" then
      local captures = vim.deepcopy(entry.captures or {})
      for _, capture in ipairs(captures) do
        capture.info = capture.error and { body = {}, title = capture.file } or M.info(capture)
        capture.removal = (sync.state.removals or {})[key(capture)]
      end
      table.sort(captures, function(a, b)
        local ta, tb = a.info.time or 0, b.info.time or 0
        if ta ~= tb then
          if newest_first then
            return ta > tb
          end
          return ta < tb
        end
        return a.file < b.file
      end)
      groups[#groups + 1] = { name = name, entry = entry, captures = captures }
    end
  end
  return groups
end

--- Lines, highlights and per-line targets for the inbox buffer.
function M.render(groups, opts)
  opts = opts or {}
  local lines, highlights, targets = {}, {}, {}
  local function add(text, hl, target)
    lines[#lines + 1] = text
    if hl then
      highlights[#highlights + 1] = { line = #lines - 1, col = 0, len = #text, hl = hl }
    end
    targets[#lines] = target
  end
  local function mark(col, len, hl)
    highlights[#highlights + 1] = { line = #lines - 1, col = col, len = len, hl = hl }
  end

  add("LATTICE INBOX" .. (opts.running and "  (fetching…)" or ""), "Title")
  add("")
  if opts.message then
    for _, line in ipairs(vim.split(opts.message, "\n")) do
      add(line, opts.message_hl)
    end
  end
  for _, group in ipairs(groups) do
    local open = 0
    for _, capture in ipairs(group.captures) do
      if not capture.removal then
        open = open + 1
      end
    end
    local collapsed = opts.collapsed and opts.collapsed[group.name]
    add(("%s %s (%d)"):format(collapsed and "▸" or "▾", group.name, open), "Directory", { group = group.name })
    if not collapsed then
      if group.entry.status == "error" then
        add("  ! " .. group.entry.error, "ErrorMsg", { group = group.name })
      end
      if #group.captures == 0 then
        add("  No captures", "Comment", { group = group.name })
      end
      for _, capture in ipairs(group.captures) do
        local removal = capture.removal
        local suffix = ""
        if removal then
          if removal.kind == "dismissed" then
            suffix = "  · dismissing…"
          elseif removal.status == "removing" then
            suffix = "  · filed, removing…"
          else
            suffix = "  · filed, removal pending"
          end
        end
        if capture.error then
          add(("  ⚠ %s: %s%s"):format(capture.file, capture.error, suffix), removal and "Comment" or "WarningMsg", { capture = capture })
        else
          local date = display_date(capture)
          add(("  %s  %s%s"):format(date, capture.info.title, suffix), removal and "Comment" or nil, { capture = capture })
          if not removal then
            mark(2, #date, "Comment")
          end
        end
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

-- An explanation when there is nothing to list.
local function status_message()
  if sync.state.config_error then
    return sync.state.config_error, "ErrorMsg"
  end
  if not sync.state.configured then
    return ("Inbox is off: no configuration at %s"):format(vim.fn.fnamemodify(sync.config_path(), ":~")), "Comment"
  end
  for _, name in ipairs(sync.state.order or {}) do
    if sync.state.repos[name].role == "active" then
      return nil
    end
  end
  return "No enabled repository uses this notes root; see :LatticeInboxStatus", "Comment"
end

function M.paint()
  if not buffer_ready() then
    return
  end
  local message, hl = status_message()
  local view = M.render(M.groups(), {
    running = sync.state.running,
    collapsed = state.collapsed,
    message = message,
    message_hl = hl,
  })
  state.targets = view.targets
  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, item in ipairs(view.highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, item.line, item.col, { end_col = item.col + item.len, hl_group = item.hl })
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_cursor(win)[1] > #view.lines then
      vim.api.nvim_win_set_cursor(win, { #view.lines, 0 })
    end
  end
end

local function current_target()
  return state.targets[vim.api.nvim_win_get_cursor(0)[1]]
end

local function current_capture()
  local target = current_target()
  return target and target.capture
end

-- Folder choices for a capture: its suggestion first (A1.9). Returns the
-- list, the suggestion (nil when none is usable) and a note explaining a
-- missing default folder.
function M.folder_choices(capture, root)
  local lattice_cfg = config.load(root) or config.defaults()
  local folders = process.folders(root, lattice_cfg)
  local entry = sync.state.repos[capture.repo]
  local aliases = entry and entry.repo and entry.repo.aliases or {}
  local default = sync.state.settings and sync.state.settings.default_folder or "Resources"
  local suggestion, score = process.suggest(capture.info.body, folders, aliases, default)
  local note
  if score == 0 and not vim.tbl_contains(folders, default) then
    note = ("default folder %s does not exist or is excluded"):format(default)
    suggestion = nil
  end
  local choices = suggestion and { suggestion } or {}
  for _, folder in ipairs(folders) do
    if folder ~= suggestion then
      choices[#choices + 1] = folder
    end
  end
  return choices, suggestion, note
end

local function close_preview()
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    vim.api.nvim_win_close(state.preview_win, true)
  end
  state.preview_win = nil
end

--- Shows the read-only preview (§8.3) of the capture under the cursor.
function M.preview(capture)
  capture = capture or current_capture()
  if not capture then
    return
  end
  local lines
  if capture.error then
    lines = { capture.file, "", "Cannot be filed: " .. capture.error, "", "o  Open    D  Dismiss" }
  else
    local _, suggestion, note = M.folder_choices(capture, config.options.root)
    lines = {
      "Title:    " .. capture.info.title,
      "Captured: " .. (capture.created or "unknown"),
      "From:     " .. capture.repo,
      "Folder:   " .. (suggestion or ("none (" .. note .. ")")),
      "",
    }
    vim.list_extend(lines, capture.info.body)
    vim.list_extend(lines, { "", "f  File    t  Task    o  Open    D  Dismiss" })
  end
  local buf = vim.fn.bufnr(PREVIEW_NAME)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, PREVIEW_NAME)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  if not (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) then
    local inbox_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    state.preview_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(inbox_win)
  end
  vim.api.nvim_win_set_buf(state.preview_win, buf)
  vim.wo[state.preview_win].wrap = true
end

--- Enter: fold or unfold a group, or preview a capture.
function M.activate()
  local target = current_target()
  if not target then
    return
  end
  if target.group then
    state.collapsed[target.group] = not state.collapsed[target.group]
    M.paint()
  elseif target.capture then
    M.preview(target.capture)
  end
end

--- o: opens the cached capture read-only. It is not processed (§8.4).
function M.open_capture()
  local capture = current_capture()
  if not capture then
    return
  end
  close_preview()
  vim.cmd.edit(vim.fn.fnameescape(capture.path))
  vim.bo.readonly = true
  vim.bo.modifiable = false
end

-- After the user saves a prepared note (A1.2 step 3): read the file back and
-- mark the capture filed only if it carries the capture's ID; then remove
-- it from GitHub (A1.6).
local function on_saved(buf, capture)
  local k = key(capture)
  if (sync.state.removals or {})[k] then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if not process.file_has_capture_id(path, capture.id) then
    vim.notify(
      ("Lattice Inbox: %s was saved without :CAPTURE_ID: %s, so the capture stays in the inbox"):format(
        vim.fn.fnamemodify(path, ":~:."),
        capture.id
      ),
      vim.log.levels.WARN
    )
    return
  end
  state.pending[k] = nil
  -- Filed: later saves of the note are ordinary saves.
  pcall(vim.api.nvim_del_augroup_by_name, "lattice.inbox.note." .. buf)
  vim.notify(("Lattice Inbox: filed as %s"):format(relative(path)))
  sync.remove(capture, "filed", path)
  M.paint()
end

-- Opens a new, unsaved note for the capture (A1.2 step 1).
local function prepare(capture, title, folder, keyword)
  local root = config.options.root
  local dir = root .. "/" .. folder
  local real_root, real_dir = vim.uv.fs_realpath(root), vim.uv.fs_realpath(dir)
  local stat = real_dir and vim.uv.fs_stat(real_dir)
  if not (stat and stat.type == "directory" and real_root and vim.startswith(real_dir .. "/", real_root .. "/")) then
    vim.notify(("Lattice Inbox: %s is not a folder in the notes root; nothing was created"):format(folder), vim.log.levels.ERROR)
    return
  end
  local path = process.free_path(dir, process.file_stem(title))
  close_preview()
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, process.note_lines(capture, capture.info.body, title, keyword))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local k = key(capture)
  state.pending[k] = buf
  vim.b[buf].lattice_capture = { repo = capture.repo, id = capture.id, file = capture.file }
  local group = vim.api.nvim_create_augroup("lattice.inbox.note." .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      on_saved(buf, capture)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      if state.pending[k] == buf then
        state.pending[k] = nil
      end
    end,
  })
  vim.notify(("Lattice Inbox: review the note, then save it to file the capture (%s)"):format(
    vim.fn.fnamemodify(path, ":~:.")
  ))
end

--- f / t: file the capture under the cursor as a note or a task (§11).
--- Asks for the title, then the folder; the note opens unsaved.
function M.process(kind)
  local capture = current_capture()
  if not capture then
    return
  end
  if capture.error then
    vim.notify(("Lattice Inbox: %s cannot be filed: %s"):format(capture.file, capture.error), vim.log.levels.WARN)
    return
  end
  local k = key(capture)
  local removal = (sync.state.removals or {})[k]
  if removal then
    if removal.kind == "dismissed" then
      vim.notify("Lattice Inbox: this capture is being dismissed")
    else
      vim.notify(("Lattice Inbox: already filed as %s; R retries its removal"):format(relative(removal.note)))
    end
    return
  end
  local pending = state.pending[k]
  if pending and vim.api.nvim_buf_is_valid(pending) then
    close_preview()
    vim.api.nvim_win_set_buf(0, pending)
    vim.notify("Lattice Inbox: this capture's note is already open; save it to file the capture")
    return
  end
  local root = config.options.root
  vim.ui.input({ prompt = "Title: ", default = capture.info.title }, function(title)
    title = title and vim.trim(title)
    if not title or title == "" then
      return
    end
    local choices, suggestion, note = M.folder_choices(capture, root)
    if #choices == 0 then
      vim.notify("Lattice Inbox: no folders to file into" .. (note and (" (" .. note .. ")") or ""), vim.log.levels.WARN)
      return
    end
    vim.ui.select(choices, {
      prompt = "Folder: ",
      format_item = function(item)
        return item == suggestion and (item .. "  (suggested)") or item
      end,
    }, function(folder)
      if not folder then
        return
      end
      local keyword
      if kind == "task" then
        local cfg = config.load(root) or config.defaults()
        keyword = cfg.workflows and cfg.workflows.default and cfg.workflows.default.first_open or "TODO"
      end
      prepare(capture, title, folder, keyword)
    end)
  end)
end

--- D: dismiss the capture under the cursor after confirmation: it is
--- deleted from GitHub without being filed (§12.4).
function M.dismiss()
  local capture = current_capture()
  if not capture then
    return
  end
  local k = key(capture)
  local removal = (sync.state.removals or {})[k]
  if removal then
    if removal.kind == "filed" then
      vim.notify(("Lattice Inbox: already filed as %s; R retries its removal"):format(relative(removal.note)))
    end
    return
  end
  local pending = state.pending[k]
  if pending and vim.api.nvim_buf_is_valid(pending) then
    vim.notify("Lattice Inbox: this capture's note is open and unsaved; save it to file the capture, or close it first", vim.log.levels.WARN)
    return
  end
  local name = capture.error and capture.file or capture.info.title
  if not M.confirm(("Dismiss %q from %s? It is deleted from GitHub and not filed."):format(name, capture.repo)) then
    return
  end
  sync.remove(capture, "dismissed")
  M.paint()
end

function M.refresh()
  sync.fetch("manual")
  M.paint()
end

function M.close()
  if not buffer_ready() then
    return
  end
  close_preview()
  local buf, prev = state.buf, state.prev_buf
  if prev and prev ~= buf and vim.api.nvim_buf_is_loaded(prev) then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_set_buf(win, prev)
    end
  end
  state.buf, state.prev_buf, state.targets = nil, nil, {}
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFFER_NAME)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "lattice-inbox"
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", M.activate, "Lattice Inbox: preview capture or fold group")
  map("<Tab>", M.activate, "Lattice Inbox: preview capture or fold group")
  map("f", function()
    M.process("file")
  end, "Lattice Inbox: file as a note")
  map("t", function()
    M.process("task")
  end, "Lattice Inbox: file as a task")
  map("o", M.open_capture, "Lattice Inbox: open capture read-only")
  map("D", M.dismiss, "Lattice Inbox: dismiss capture")
  map("R", M.refresh, "Lattice Inbox: fetch captures")
  map("q", M.close, "Lattice Inbox: close")
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

local listening = false

--- :LatticeInbox — opens the inbox, or focuses it. Fetches first if this
--- session has not fetched yet.
function M.open()
  if not listening then
    listening = true
    table.insert(sync.listeners, function()
      M.paint()
    end)
  end
  local current = vim.api.nvim_get_current_buf()
  if buffer_ready() then
    local win = vim.fn.bufwinid(state.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      state.prev_buf = current
      vim.api.nvim_win_set_buf(0, state.buf)
    end
    M.paint()
    return
  end
  state.prev_buf = current
  state.buf = create_buffer()
  vim.api.nvim_win_set_buf(0, state.buf)
  if not sync.state.configured and not sync.state.running then
    sync.fetch("manual")
  end
  M.paint()
  -- Start on the first capture.
  for line = 1, vim.api.nvim_buf_line_count(state.buf) do
    if state.targets[line] and state.targets[line].capture then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      break
    end
  end
end

return M
