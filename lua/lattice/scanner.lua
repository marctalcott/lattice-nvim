-- Read-only walk of the notes root. Nothing here writes to disk.
local config = require("lattice.config")
local tasks = require("lattice.tasks")

local M = {}

local function matcher(globs)
  local patterns = vim.tbl_map(vim.glob.to_lpeg, globs)
  return function(path)
    for _, pattern in ipairs(patterns) do
      if pattern:match(path) then
        return true
      end
    end
    return false
  end
end

--- Lists matching notes as sorted paths relative to root. Symlinks are never
--- followed, so the walk cannot leave the root.
--- @return string[] files
--- @return { path: string, message: string }[] errors
function M.list_files(root, scan)
  local included, excluded = matcher(scan.include), matcher(scan.exclude)
  local files, errors = {}, {}

  local function visit(dir)
    local abs = dir == "" and root or (root .. "/" .. dir)
    local handle, err = vim.uv.fs_scandir(abs)
    if not handle then
      errors[#errors + 1] = { path = dir == "" and "." or dir, message = tostring(err) }
      return
    end
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local rel = dir == "" and name or (dir .. "/" .. name)
      if not kind or kind == "unknown" then
        local stat = vim.uv.fs_lstat(root .. "/" .. rel)
        kind = stat and stat.type
      end
      if kind == "directory" then
        -- Git metadata is never scanned, whatever the exclude list says.
        if name ~= ".git" and not (excluded(rel) or excluded(rel .. "/")) then
          visit(rel)
        end
      elseif kind == "file" and rel:match("%.md$") and included(rel) and not excluded(rel) then
        files[#files + 1] = rel
      end
    end
  end

  visit("")
  table.sort(files)
  return files, errors
end

local function read_lines(path)
  local file, err = io.open(path, "r")
  if not file then
    return nil, err
  end
  local content, read_err = file:read("*a")
  file:close()
  if not content then
    return nil, read_err
  end
  return vim.split(content, "\n", { plain = true })
end

local function capture_title(lines, fallback)
  for _, line in ipairs(lines) do
    local text = vim.trim(line:gsub("\r$", ""))
    if text ~= "" and not text:match("^%-%-%-+$") then
      text = text:gsub("^#+[ \t]+", "")
      return text
    end
  end
  return fallback
end

--- Lists Markdown captures in the inbox folder, oldest first. The scan globs
--- do not apply, so excluding the inbox from task scanning keeps it listed.
--- A missing or symlinked inbox yields nil and no captures.
function M.list_inbox(root, inbox_path, unreadable)
  local dir = root .. "/" .. inbox_path
  local stat = vim.uv.fs_lstat(dir)
  if not stat or stat.type ~= "directory" then
    return nil
  end

  local files, errors = M.list_files(dir, { include = { "**/*.md" }, exclude = {} })
  for _, item in ipairs(errors) do
    unreadable[#unreadable + 1] = { path = inbox_path .. "/" .. item.path, message = item.message }
  end

  local captures = {}
  for _, name in ipairs(files) do
    local rel = inbox_path .. "/" .. name
    local path = root .. "/" .. rel
    local lines, err = read_lines(path)
    local file_stat = vim.uv.fs_stat(path)
    if lines and file_stat then
      local fallback = vim.fn.fnamemodify(name, ":t:r")
      captures[#captures + 1] = {
        rel = rel,
        path = path,
        title = capture_title(lines, fallback),
        date = os.date("%Y-%m-%d", file_stat.mtime.sec),
        mtime = file_stat.mtime.sec,
      }
    else
      unreadable[#unreadable + 1] = { path = rel, message = tostring(err) }
    end
  end

  table.sort(captures, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime < b.mtime
    end
    return a.rel < b.rel
  end)
  return captures
end

-- Parsed notes from earlier scans, so a refresh re-parses only notes that
-- changed (spec §13.3 rule 9, PAR-029). Keyed by path; dropped wholesale
-- when the root or configuration changes.
local cache = { key = nil, files = {} }

--- Forgets cached parses (tests, and :LatticeRefresh with a bang).
function M.clear_cache()
  cache = { key = nil, files = {} }
end

-- Loaded buffers with unsaved changes, by real path: their text is newer
-- than the file, so Lattice reads them instead (§14.1 "respect unsaved
-- buffers").
local function modified_buffers()
  local map = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        map[vim.uv.fs_realpath(name) or name] = buf
      end
    end
  end
  return map
end

-- Reads one note, from its unsaved buffer or from disk, reusing the cached
-- parse when nothing changed. Returns parsed, mtime, or nil and an error.
local function read_note(path, cfg, buffers, result)
  local buf = next(buffers) and buffers[vim.uv.fs_realpath(path) or path]
  local stamp, lines, mtime
  if buf then
    stamp = "buf:" .. buf .. ":" .. vim.api.nvim_buf_get_changedtick(buf)
    mtime = os.time()
  else
    local stat, err = vim.uv.fs_stat(path)
    if not stat then
      return nil, nil, err
    end
    stamp = ("disk:%d:%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
    mtime = stat.mtime.sec
  end
  local cached = cache.files[path]
  if cached and cached.stamp == stamp then
    return cached.parsed, mtime
  end
  if buf then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    local read_err
    lines, read_err = read_lines(path)
    if not lines then
      return nil, nil, read_err
    end
  end
  local parsed, parse_err = tasks.parse(lines, cfg)
  if not parsed then
    return nil, nil, parse_err, true
  end
  result.parsed = result.parsed + 1
  cache.files[path] = { stamp = stamp, parsed = parsed }
  return parsed, mtime
end

function M.scan(root, cfg)
  local files, unreadable = M.list_files(root, cfg.scan)
  local result = { tasks = {}, date_errors = {}, warnings = {}, legacy = {}, outlines = {}, unreadable = unreadable, files = #files, parsed = 0 }
  local key = root .. "\0" .. (cfg.signature or "")
  if cache.key ~= key then
    cache = { key = key, files = {} }
  end
  local buffers = modified_buffers()
  local seen = {}
  local ids = {} -- :ID: -> first task with it, across notes (§13.4)
  result.inbox = M.list_inbox(root, cfg.inbox.path, unreadable)

  for _, rel in ipairs(files) do
    local path = root .. "/" .. rel
    seen[path] = true
    local parsed, mtime, err, fatal = read_note(path, cfg, buffers, result)
    if fatal then
      result.error = err
      return result
    end
    if parsed then
      -- Cached parses are shared between scans, not copied: the fields set
      -- below are the same every time, and callers treat results as
      -- read-only (edits go through the mutation layer and a rescan).
      for _, heading in ipairs(parsed.headings or {}) do
        heading.rel, heading.path = rel, path
        result.outlines[#result.outlines + 1] = heading
      end
      for _, task in ipairs(parsed.tasks) do
        task.rel, task.path, task.mtime = rel, path, mtime
        task.source.path = path
        result.tasks[#result.tasks + 1] = task
        if task.id then
          local first = ids[task.id]
          if first and first.path ~= path then
            result.warnings[#result.warnings + 1] = {
              rel = rel,
              path = path,
              line = task.line,
              severity = "warning",
              category = "duplicate-id",
              message = (":ID: %s is also used in %s:%d"):format(task.id, first.rel, first.line),
            }
          elseif not first then
            ids[task.id] = task
          end
        end
      end
      for _, entry in ipairs(parsed.legacy) do
        entry.rel, entry.path = rel, path
        result.legacy[#result.legacy + 1] = entry
      end
      for _, bad in ipairs(parsed.date_errors) do
        bad.rel, bad.path = rel, path
        result.date_errors[#result.date_errors + 1] = bad
      end
      for _, warning in ipairs(parsed.warnings) do
        warning.rel, warning.path = rel, path
        result.warnings[#result.warnings + 1] = warning
      end
    else
      unreadable[#unreadable + 1] = { path = rel, message = tostring(err) }
    end
  end
  for path in pairs(cache.files) do
    if not seen[path] then
      cache.files[path] = nil
    end
  end
  return result
end

--- Loads config and scans. Returns a result with `error` set, and no tasks,
--- when the root or config is unusable, so nothing unintended is scanned.
function M.collect(root)
  if not root then
    return {
      tasks = {},
      date_errors = {},
      warnings = {},
      unreadable = {},
      error = 'Notes root is not set.\nAdd it to your plugin config: require("lattice").setup({ root = "~/notes" })',
    }
  end

  local function failed(message)
    return { root = root, tasks = {}, date_errors = {}, warnings = {}, unreadable = {}, error = message }
  end

  local stat = vim.uv.fs_stat(root)
  if not stat or stat.type ~= "directory" then
    return failed(("Notes root %s is not a directory.\nCheck `root` in your plugin config."):format(root))
  end

  local cfg, notice, err = config.load(root)
  if not cfg then
    return failed(err)
  end

  local result = M.scan(root, cfg)
  if result.error then
    return failed(result.error)
  end
  result.root, result.notice, result.headings, result.keywords = root, notice, cfg.headings, cfg.keywords
  result.workflows = cfg.workflows
  result.deadlines = cfg.deadlines
  result.priorities = cfg.priorities
  result.cfg = cfg
  return result
end

return M
