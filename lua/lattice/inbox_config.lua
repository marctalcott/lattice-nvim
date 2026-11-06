-- Loads and validates the inbox configuration (LATTICE_INBOX_SPEC A1.4):
-- the GitHub capture repositories Lattice fetches. The file is the opt-in
-- for network access: without it the inbox is off.
local M = {}

--- The default location: $XDG_CONFIG_HOME/lattice/inbox.json, else
--- ~/.config/lattice/inbox.json.
function M.default_path()
  local base = vim.env.XDG_CONFIG_HOME
  if not base or base == "" then
    base = vim.fs.normalize("~/.config")
  end
  return base .. "/lattice/inbox.json"
end

function M.defaults()
  return {
    auto_fetch = true,
    sort_order = "newest_first",
    notification_duration_ms = 3000,
    default_folder = "Resources",
  }
end

local INBOX_KEYS = { auto_fetch = true, sort_order = true, notification_duration_ms = true, default_folder = true }
local REPO_KEYS = {
  name = true,
  url = true,
  branch = true,
  directory = true,
  enabled = true,
  notes_root = true,
  aliases = true,
}

--- Hides credentials embedded in a URL (`https://user:token@host`), for
--- messages and logs.
function M.redact(text)
  return (tostring(text):gsub("(%a[%w+.-]*://)[^/@%s]+@", "%1***@"))
end

local function unknown_key(object, allowed, where)
  local names = {}
  for key in pairs(object) do
    if not allowed[key] then
      names[#names + 1] = tostring(key)
    end
  end
  if #names > 0 then
    table.sort(names)
    return ("%s: unknown key %q"):format(where, names[1])
  end
end

-- A relative folder path with no `..`, `.` or empty segments, not starting
-- with `-` (it is passed to git). Trailing slashes are removed.
local function relative_path(value)
  value = value:gsub("/+$", "")
  if value:sub(1, 1) == "/" or value:sub(1, 1) == "~" or value:sub(1, 1) == "-" then
    return nil
  end
  for part in (value .. "/"):gmatch("([^/]*)/") do
    if part == "" or part == "." or part == ".." then
      return nil
    end
  end
  return value
end

local function valid_branch(value)
  return value:match("^[%w._/-]+$") ~= nil
    and value:sub(1, 1) ~= "-"
    and value:sub(1, 1) ~= "/"
    and value:sub(-1) ~= "/"
    and not value:find("..", 1, true)
    and not value:find("//", 1, true)
    and not value:match("%.lock$")
end

-- Checks a repository URL. Credentials must not be in the file (§5.1), so
-- an HTTP(S) URL may not carry a user or token.
local function check_url(url)
  if url:match("%s") or url:sub(1, 1) == "-" then
    return "must be a Git remote URL without spaces"
  end
  if url:match("^[Hh][Tt][Tt][Pp][Ss]?://[^/]*@") then
    return "must not contain credentials; use a credential helper or SSH instead"
  end
end

local function validate_repo(raw, index, seen)
  local where = ("repositories[%d]"):format(index)
  if type(raw) ~= "table" or vim.islist(raw) and next(raw) ~= nil then
    return nil, where .. " must be a JSON object"
  end
  if type(raw.name) == "string" and raw.name ~= "" then
    where = ("repository %q"):format(raw.name)
  end
  local err = unknown_key(raw, REPO_KEYS, where)
  if err then
    return nil, err
  end
  for _, key in ipairs({ "name", "url", "notes_root" }) do
    if type(raw[key]) ~= "string" or vim.trim(raw[key]) == "" then
      return nil, ("%s: %s is required and must be a string"):format(where, key)
    end
  end
  local repo = {
    name = vim.trim(raw.name),
    url = vim.trim(raw.url),
    branch = "main",
    directory = "",
    enabled = true,
    notes_root = vim.trim(raw.notes_root),
    aliases = {},
  }
  if seen[repo.name] then
    return nil, ("two repositories are named %q"):format(repo.name)
  end
  seen[repo.name] = true
  err = check_url(repo.url)
  if err then
    return nil, ("%s: url %s"):format(where, err)
  end
  if raw.branch ~= nil then
    if type(raw.branch) ~= "string" or not valid_branch(raw.branch) then
      return nil, ("%s: branch %s is not a valid branch name"):format(where, vim.inspect(raw.branch))
    end
    repo.branch = raw.branch
  end
  if raw.directory ~= nil then
    local dir = type(raw.directory) == "string" and raw.directory
    if dir and dir ~= "" then
      dir = relative_path(dir)
    end
    if not dir then
      return nil, ("%s: directory %s must be a relative folder without .."):format(where, vim.inspect(raw.directory))
    end
    repo.directory = dir
  end
  if raw.enabled ~= nil then
    if type(raw.enabled) ~= "boolean" then
      return nil, ("%s: enabled must be true or false"):format(where)
    end
    repo.enabled = raw.enabled
  end
  if raw.aliases ~= nil then
    if type(raw.aliases) ~= "table" or (vim.islist(raw.aliases) and next(raw.aliases) ~= nil) then
      return nil, ("%s: aliases must map folders to lists of keywords"):format(where)
    end
    for folder, words in pairs(raw.aliases) do
      local rel = type(folder) == "string" and relative_path(folder)
      if not rel then
        return nil, ("%s: aliases folder %q must be relative to notes_root"):format(where, tostring(folder))
      end
      if type(words) ~= "table" or not vim.islist(words) then
        return nil, ("%s: aliases[%q] must be a list of keywords"):format(where, folder)
      end
      for _, word in ipairs(words) do
        if type(word) ~= "string" or vim.trim(word) == "" then
          return nil, ("%s: aliases[%q] must contain only non-empty strings"):format(where, folder)
        end
      end
      repo.aliases[rel] = vim.tbl_map(vim.trim, words)
    end
  end
  return repo
end

--- Validates decoded JSON.
--- @return table|nil cfg  { inbox = settings, repositories = list }
--- @return string|nil err
function M.validate(raw)
  if type(raw) ~= "table" or (vim.islist(raw) and next(raw) ~= nil) then
    return nil, "the top level must be a JSON object"
  end
  local err = unknown_key(raw, { inbox = true, repositories = true }, "top level")
  if err then
    return nil, err
  end
  local settings = M.defaults()
  local inbox = raw.inbox or {}
  if type(inbox) ~= "table" or (vim.islist(inbox) and next(inbox) ~= nil) then
    return nil, "inbox must be a JSON object"
  end
  err = unknown_key(inbox, INBOX_KEYS, "inbox")
  if err then
    return nil, err
  end
  if inbox.auto_fetch ~= nil then
    if type(inbox.auto_fetch) ~= "boolean" then
      return nil, "inbox.auto_fetch must be true or false"
    end
    settings.auto_fetch = inbox.auto_fetch
  end
  if inbox.sort_order ~= nil then
    if inbox.sort_order ~= "newest_first" and inbox.sort_order ~= "oldest_first" then
      return nil, 'inbox.sort_order must be "newest_first" or "oldest_first"'
    end
    settings.sort_order = inbox.sort_order
  end
  if inbox.notification_duration_ms ~= nil then
    local ms = inbox.notification_duration_ms
    if type(ms) ~= "number" or ms <= 0 or ms ~= math.floor(ms) then
      return nil, "inbox.notification_duration_ms must be a positive whole number"
    end
    settings.notification_duration_ms = ms
  end
  if inbox.default_folder ~= nil then
    local folder = type(inbox.default_folder) == "string" and relative_path(inbox.default_folder)
    if not folder then
      return nil, ("inbox.default_folder %s must be a folder relative to notes_root"):format(
        vim.inspect(inbox.default_folder)
      )
    end
    settings.default_folder = folder
  end

  local list = raw.repositories or {}
  if type(list) ~= "table" or not vim.islist(list) then
    return nil, "repositories must be a JSON array"
  end
  local repositories, seen = {}, {}
  for i, entry in ipairs(list) do
    local repo
    repo, err = validate_repo(entry, i, seen)
    if not repo then
      return nil, err
    end
    repositories[#repositories + 1] = repo
  end
  return { inbox = settings, repositories = repositories }
end

--- Reads the inbox configuration.
--- @return table|nil cfg  nil when the file is missing or invalid
--- @return string|nil err  nil when the file is simply missing (inbox off)
function M.load(path)
  if not vim.uv.fs_stat(path) then
    return nil, nil
  end
  local file, open_err = io.open(path, "r")
  if not file then
    return nil, ("Cannot read %s: %s"):format(path, open_err)
  end
  local content = file:read("*a")
  file:close()
  local ok, raw = pcall(vim.json.decode, content or "", { luanil = { object = true, array = true } })
  if not ok then
    return nil, ("Invalid JSON in %s: %s"):format(path, tostring(raw))
  end
  local cfg, err = M.validate(raw)
  if not cfg then
    return nil, ("Invalid inbox config in %s: %s"):format(path, M.redact(err))
  end
  return cfg
end

local function realpath(path)
  local full = vim.fn.fnamemodify(vim.fs.normalize(path), ":p"):gsub("/+$", "")
  return vim.uv.fs_realpath(full)
end

--- Marks each repository's role for the active notes root (A1.5):
--- `active`, `disabled`, or `other_root` (with `root_missing` when its
--- notes_root does not exist). Sets repo.root to the resolved notes root.
function M.classify(cfg, root)
  local active_root = root and realpath(root)
  for _, repo in ipairs(cfg.repositories) do
    repo.root = realpath(repo.notes_root)
    if not repo.enabled then
      repo.role = "disabled"
    elseif repo.root and active_root and repo.root == active_root then
      repo.role = "active"
    else
      repo.role = "other_root"
      repo.root_missing = repo.root == nil
    end
  end
  return cfg
end

return M
