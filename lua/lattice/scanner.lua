-- Read-only walk of the notes root. Nothing here writes to disk.
local config = require("lattice.config")
local parser = require("lattice.parser")

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
        if not (excluded(rel) or excluded(rel .. "/")) then
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

function M.scan(root, cfg)
  local files, unreadable = M.list_files(root, cfg.scan)
  local result = { tasks = {}, date_errors = {}, unreadable = unreadable, files = #files }
  result.inbox = M.list_inbox(root, cfg.inbox.path, unreadable)

  for _, rel in ipairs(files) do
    local path = root .. "/" .. rel
    local lines, err = read_lines(path)
    if lines then
      local parsed = parser.parse(lines, cfg.headings)
      for _, task in ipairs(parsed.tasks) do
        task.rel, task.path = rel, path
        result.tasks[#result.tasks + 1] = task
      end
      for _, bad in ipairs(parsed.date_errors) do
        bad.rel, bad.path = rel, path
        result.date_errors[#result.date_errors + 1] = bad
      end
    else
      unreadable[#unreadable + 1] = { path = rel, message = tostring(err) }
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
      unreadable = {},
      error = 'Notes root is not set.\nAdd it to your plugin config: require("lattice").setup({ root = "~/notes" })',
    }
  end

  local function failed(message)
    return { root = root, tasks = {}, date_errors = {}, unreadable = {}, error = message }
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
  result.root, result.notice = root, notice
  return result
end

return M
