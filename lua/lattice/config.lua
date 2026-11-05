-- Plugin options and .lattice.json loading.
local keywords = require("lattice.keywords")

local M = {}

M.filename = ".lattice.json"

local DEFAULT_KEYMAPS = {
  open = "<leader>ll",
  add_todo = "<leader>lt",
  add_waiting = "<leader>ld",
  refresh = "<leader>lr",
  next_state = "<leader>ln",
  prev_state = "<leader>lp",
  set_state = "<leader>ls",
  toggle_checkbox = "<leader>lx",
  schedule = "<leader>lS",
  deadline = "<leader>lD",
  priority_up = "<leader>l+",
  priority_down = "<leader>l-",
  refile = "<leader>lw",
  archive = "<leader>lA",
  inbox = "<leader>li",
  inbox_refresh = "<leader>lR",
}

-- Options passed to setup(). `root` has no default: it must be set explicitly.
M.options = {
  root = nil,
  keymaps = vim.deepcopy(DEFAULT_KEYMAPS),
}

-- Keymaps setup() actually created, by name. Keys skipped because they
-- were already mapped are absent.
M.active_keymaps = {}

function M.defaults()
  local default = assert(keywords.build(keywords.DEFAULT))
  return {
    version = 1,
    scan = { include = { "**/*.md" }, exclude = { "Archives/**", ".git/**", "**/*_archive.md" } },
    -- Where :LatticeArchive moves a subtree; %s is the note's path relative
    -- to the root without ".md" (Org's "%s_archive" default).
    archive = { location = "%s_archive.md" },
    -- Workflows by name (LATTICE_SYNTAX_SPEC §4). `default` applies unless
    -- a task's :WORKFLOW: or project selects another. `keywords` is the
    -- default workflow, kept under its v0.1 name.
    workflows = { default = default },
    keywords = default,
    priorities = { values = { "A", "B", "C" }, default = "B" },
    inherit = { tags = true, properties = {} },
    deadlines = { warning_days = 14 },
    -- Org's org-log-done (nil) and org-log-repeat ('time) defaults.
    logging = { done = false, ["repeat"] = "time" },
    -- Org's org-enforce-todo-checkbox-dependencies / -todo-dependencies.
    enforce = { checkboxes = false, todo = false },
    -- Org's org-todo-repeat-to-state: nil returns a repeating task to the
    -- state it had before completion.
    repeat_to_state = nil,
    -- v0.1 legacy: bullets under this heading are read as WAITING.
    headings = { waiting = "Waiting On" },
    inbox = { path = "Inbox" },
  }
end

function M.normalize_root(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local path = vim.fn.fnamemodify(vim.fs.normalize(root), ":p")
  return (path:gsub("/+$", ""))
end

-- Merges user keymaps over the defaults. Unknown names and values other
-- than a key string or false are dropped with one error message, so a typo
-- cannot abort setup.
local function merge_keymaps(user)
  if user == false then
    return false
  end
  local keymaps = vim.deepcopy(DEFAULT_KEYMAPS)
  if user == nil then
    return keymaps
  end
  if type(user) ~= "table" then
    vim.notify("Lattice: keymaps must be a table or false; using the defaults", vim.log.levels.ERROR)
    return keymaps
  end
  local problems = {}
  for name, value in pairs(user) do
    if DEFAULT_KEYMAPS[name] == nil then
      problems[#problems + 1] = ("unknown keymaps.%s"):format(tostring(name))
    elseif value == false or (type(value) == "string" and value ~= "") then
      keymaps[name] = value
    else
      problems[#problems + 1] = ("keymaps.%s must be a key string or false, not %s"):format(name, vim.inspect(value))
      keymaps[name] = false
    end
  end
  if #problems > 0 then
    table.sort(problems)
    vim.notify("Lattice: " .. table.concat(problems, "; ") .. " (ignored)", vim.log.levels.ERROR)
  end
  return keymaps
end

function M.setup(opts)
  opts = opts or {}
  M.options.root = M.normalize_root(opts.root)
  M.options.keymaps = merge_keymaps(opts.keymaps)
  M.options.inbox_sync = {}
  local sync = opts.inbox_sync
  if sync ~= nil then
    if type(sync) ~= "table" or (sync.config ~= nil and (type(sync.config) ~= "string" or sync.config == "")) then
      vim.notify("Lattice: inbox_sync must be { config = \"<path>\" }; using the default path", vim.log.levels.ERROR)
    elseif sync.config then
      M.options.inbox_sync.config = vim.fn.fnamemodify(vim.fs.normalize(sync.config), ":p")
    end
  end
  return M.options
end

local function check_glob(field, glob)
  if type(glob) ~= "string" or glob == "" then
    return ("%s must contain only non-empty strings"):format(field)
  end
  if glob:sub(1, 1) == "/" or glob:sub(1, 1) == "~" or ("/" .. glob .. "/"):find("/../", 1, true) then
    return ("%s entry %q must stay relative to the notes root"):format(field, glob)
  end
  if not pcall(vim.glob.to_lpeg, glob) then
    return ("%s entry %q is not a valid glob"):format(field, glob)
  end
end

local function check_glob_list(field, list)
  if type(list) ~= "table" or not vim.islist(list) then
    return ("%s must be an array of glob strings"):format(field)
  end
  for _, glob in ipairs(list) do
    local err = check_glob(field, glob)
    if err then
      return err
    end
  end
end

local function validate(raw)
  if type(raw) ~= "table" then
    return nil, "the top level must be a JSON object"
  end
  if raw.version ~= nil and raw.version ~= 1 then
    return nil, ("unsupported version %s (expected 1)"):format(vim.inspect(raw.version))
  end
  for _, key in ipairs({ "scan", "headings", "inbox", "workflows", "priorities", "inherit", "deadlines", "logging", "enforce", "archive" }) do
    if raw[key] ~= nil and type(raw[key]) ~= "table" then
      return nil, key .. " must be a JSON object"
    end
  end

  local cfg = M.defaults()
  local scan, headings = raw.scan or {}, raw.headings or {}

  -- Lists replace the defaults, so `"exclude": []` removes Archives/**.
  for _, key in ipairs({ "include", "exclude" }) do
    if scan[key] ~= nil then
      local err = check_glob_list("scan." .. key, scan[key])
      if err then
        return nil, err
      end
      cfg.scan[key] = scan[key]
    end
  end

  if raw.todo ~= nil then
    local valid = type(raw.todo) == "string" or (type(raw.todo) == "table" and vim.islist(raw.todo))
    local built, err
    if valid then
      built, err = keywords.build(raw.todo)
    else
      err = "expected a sequence string or a list of them"
    end
    if not built then
      return nil, ("todo: %s"):format(err)
    end
    cfg.keywords = built
    cfg.workflows.default = built
  end

  if raw.workflows ~= nil then
    if next(raw.workflows) ~= nil and vim.islist(raw.workflows) then
      return nil, "workflows must be an object of named workflows"
    end
    -- Names are case-insensitive, so "Default" is the default workflow
    -- and "Bugs" and "bugs" would be the same one.
    local seen = {}
    for name in pairs(raw.workflows) do
      if type(name) ~= "string" or not name:match("^[%w_%-]+$") then
        return nil, ("workflow name %s must be a single word"):format(vim.inspect(name))
      end
      local key = name:lower()
      if key == "default" and raw.todo ~= nil then
        return nil, "set the default workflow in either todo or workflows.default, not both"
      end
      if seen[key] then
        return nil, ("workflows %q and %q differ only in case; names are case-insensitive"):format(seen[key], name)
      end
      seen[key] = name
    end
    for name, workflow in pairs(raw.workflows) do
      local built, err = keywords.from_workflow(workflow)
      if not built then
        return nil, ("workflows.%s: %s"):format(name, err)
      end
      cfg.workflows[name:lower()] = built
    end
    cfg.keywords = cfg.workflows.default
  end

  if raw.priorities ~= nil then
    local values, default = raw.priorities.values, raw.priorities.default
    if values ~= nil then
      if not vim.islist(values) or #values == 0 then
        return nil, "priorities.values must be a non-empty list of single letters or digits"
      end
      for _, value in ipairs(values) do
        if type(value) ~= "string" or not value:match("^%w$") then
          return nil, ("priorities.values: %s is not a single letter or digit"):format(vim.inspect(value))
        end
      end
      cfg.priorities.values = values
      if default == nil and not vim.tbl_contains(values, cfg.priorities.default) then
        cfg.priorities.default = values[math.ceil(#values / 2)]
      end
    end
    if default ~= nil then
      if not vim.tbl_contains(cfg.priorities.values, default) then
        return nil, ("priorities.default %s is not one of priorities.values"):format(vim.inspect(default))
      end
      cfg.priorities.default = default
    end
  end

  if raw.inherit ~= nil then
    local tags, properties = raw.inherit.tags, raw.inherit.properties
    if tags ~= nil then
      if type(tags) ~= "boolean" then
        return nil, "inherit.tags must be true or false"
      end
      cfg.inherit.tags = tags
    end
    if properties ~= nil then
      if properties == true then
        cfg.inherit.properties = true
      elseif type(properties) == "table" and vim.islist(properties) then
        cfg.inherit.properties = vim.tbl_map(function(name)
          return tostring(name):upper()
        end, properties)
      else
        return nil, "inherit.properties must be true or a list of property names"
      end
    end
  end

  if raw.logging ~= nil then
    for _, key in ipairs({ "done", "repeat" }) do
      local value = raw.logging[key]
      if value ~= nil then
        if value ~= false and value ~= "time" then
          return nil, ('logging.%s must be "time" or false'):format(key)
        end
        cfg.logging[key] = value
      end
    end
  end

  if raw.enforce ~= nil then
    for _, key in ipairs({ "checkboxes", "todo" }) do
      local value = raw.enforce[key]
      if value ~= nil then
        if type(value) ~= "boolean" then
          return nil, ("enforce.%s must be true or false"):format(key)
        end
        cfg.enforce[key] = value
      end
    end
  end

  local location = (raw.archive or {}).location
  if location ~= nil then
    if type(location) ~= "string" or not location:find("%s", 1, true) or not location:match("%.md$") then
      return nil, 'archive.location must be a path ending in .md containing %s, such as "%s_archive.md"'
    end
    if location:sub(1, 1) == "/" or location:sub(1, 1) == "~" or ("/" .. location .. "/"):find("/../", 1, true) then
      return nil, "archive.location must stay inside the notes root"
    end
    if location:gsub("^%./", "") == "%s.md" then
      return nil, "archive.location %s.md is the note itself; use a different name or folder, such as \"%s_archive.md\""
    end
    cfg.archive.location = location
  end

  if raw.repeat_to_state ~= nil then
    if type(raw.repeat_to_state) ~= "string" or vim.trim(raw.repeat_to_state) == "" then
      return nil, "repeat_to_state must be a state name"
    end
    cfg.repeat_to_state = vim.trim(raw.repeat_to_state)
  end

  if raw.deadlines ~= nil and raw.deadlines.warning_days ~= nil then
    local days = raw.deadlines.warning_days
    if type(days) ~= "number" or days < 0 or days % 1 ~= 0 then
      return nil, "deadlines.warning_days must be a whole number of days, 0 or more"
    end
    cfg.deadlines.warning_days = days
  end

  if headings.waiting ~= nil then
    if type(headings.waiting) ~= "string" or vim.trim(headings.waiting) == "" then
      return nil, "headings.waiting must be a non-empty string"
    end
    cfg.headings.waiting = vim.trim(headings.waiting)
  end
  -- Older configs named a To Do heading; tasks now use keywords instead.
  local notice
  if headings.todo ~= nil or headings.done ~= nil then
    notice = 'headings.todo and headings.done are no longer used and were ignored; mark items with keywords such as "- TODO ..." and set sequences with "todo".'
  end

  local inbox_path = (raw.inbox or {}).path
  if inbox_path ~= nil then
    if type(inbox_path) ~= "string" then
      return nil, "inbox.path must be a string"
    end
    inbox_path = vim.trim(inbox_path):gsub("/+$", "")
    local outside = inbox_path:sub(1, 1) == "/"
      or inbox_path:sub(1, 1) == "~"
      or ("/" .. inbox_path .. "/"):find("/../", 1, true)
    if inbox_path == "" or outside then
      return nil, ("inbox.path %q must be a folder inside the notes root"):format(inbox_path)
    end
    cfg.inbox.path = inbox_path
  end
  return cfg, nil, notice
end

--- Reads `<root>/.lattice.json`.
--- @return table|nil cfg  nil when the file is malformed
--- @return string|nil notice  nonfatal status (file missing)
--- @return string|nil err  actionable error (file malformed)
function M.load(root)
  local path = root .. "/" .. M.filename
  if not vim.uv.fs_stat(path) then
    local cfg = M.defaults()
    cfg.signature = ""
    return cfg, ("No %s in %s; using defaults."):format(M.filename, vim.fn.fnamemodify(root, ":~"))
  end

  local file, open_err = io.open(path, "r")
  if not file then
    return nil, nil, ("Cannot read %s: %s"):format(path, open_err)
  end
  local content = file:read("*a")
  file:close()

  local ok, raw = pcall(vim.json.decode, content or "", { luanil = { object = true, array = true } })
  if not ok then
    return nil, nil, ("Invalid JSON in %s: %s\nFix the file, then refresh."):format(path, tostring(raw))
  end
  local cfg, err, notice = validate(raw)
  if not cfg then
    return nil, nil, ("Invalid config in %s: %s\nFix the file, then refresh."):format(path, err)
  end
  -- Identifies this configuration, so cached parses are dropped when it
  -- changes (incremental refresh, milestone E).
  cfg.signature = content
  return cfg, notice
end

--- A path relative to the notes root, and the root (both real paths); for a
--- path outside the root, its file name and its folder.
function M.relative(path)
  local root = M.options.root
  local real_root = root and (vim.uv.fs_realpath(root) or root)
  local real = vim.uv.fs_realpath(path) or path
  if real_root and real:sub(1, #real_root + 1) == real_root .. "/" then
    return real:sub(#real_root + 2), real_root
  end
  return vim.fn.fnamemodify(real, ":t"), vim.fn.fnamemodify(real, ":h")
end

return M
