-- Plugin options and .lattice.json loading.
local M = {}

M.filename = ".lattice.json"

local DEFAULT_KEYMAPS = {
  open = "<leader>ll",
  add_todo = "<leader>lt",
  add_waiting = "<leader>ld",
  refresh = "<leader>lr",
}

-- Options passed to setup(). `root` has no default: it must be set explicitly.
M.options = {
  root = nil,
  keymaps = vim.deepcopy(DEFAULT_KEYMAPS),
}

function M.defaults()
  return {
    version = 1,
    scan = { include = { "**/*.md" }, exclude = { "Archives/**", ".git/**" } },
    headings = { todo = "To Do", waiting = "Waiting On" },
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

function M.setup(opts)
  opts = opts or {}
  M.options.root = M.normalize_root(opts.root)
  if opts.keymaps == false then
    M.options.keymaps = false
  elseif type(opts.keymaps) == "table" then
    M.options.keymaps = vim.tbl_extend("force", DEFAULT_KEYMAPS, opts.keymaps)
  else
    M.options.keymaps = vim.deepcopy(DEFAULT_KEYMAPS)
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
  for _, key in ipairs({ "scan", "headings", "inbox" }) do
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

  for _, key in ipairs({ "todo", "waiting" }) do
    if headings[key] ~= nil then
      local value = headings[key]
      if type(value) ~= "string" or vim.trim(value) == "" then
        return nil, ("headings.%s must be a non-empty string"):format(key)
      end
      cfg.headings[key] = vim.trim(value)
    end
  end
  if cfg.headings.todo == cfg.headings.waiting then
    return nil, "headings.todo and headings.waiting must be different"
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
  return cfg
end

--- Reads `<root>/.lattice.json`.
--- @return table|nil cfg  nil when the file is malformed
--- @return string|nil notice  nonfatal status (file missing)
--- @return string|nil err  actionable error (file malformed)
function M.load(root)
  local path = root .. "/" .. M.filename
  if not vim.uv.fs_stat(path) then
    return M.defaults(), ("No %s in %s; using defaults."):format(M.filename, vim.fn.fnamemodify(root, ":~"))
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
  local cfg, err = validate(raw)
  if not cfg then
    return nil, nil, ("Invalid config in %s: %s\nFix the file, then refresh."):format(path, err)
  end
  return cfg
end

return M
