-- Fetches captures from the GitHub inbox repositories (LATTICE_INBOX_SPEC
-- A1.5, A1.6, A1.11). Each active repository is mirrored in a shallow,
-- sparse Git clone under stdpath("cache"); that clone is the local cache.
-- Everything runs asynchronously through `git` and never prompts.
local config = require("lattice.config")
local inbox_config = require("lattice.inbox_config")
local keywords = require("lattice.keywords")

local M = {}

-- Overridable for tests.
M.cache_root = vim.fn.stdpath("cache") .. "/lattice/inbox"
M.timeout_ms = 30000
M.max_parallel = 4
M.max_capture_bytes = 1024 * 1024

-- Session state. `repos` maps a repository name to
-- { name, role, url, status = "ok"|"error"|"fetching"|"pending", error,
--   last_success, captures, skipped, new }.
M.state = { running = false, repos = {}, order = {}, config_error = nil, configured = false }

local queued_rerun = false
local startup_done = false

-- Functions called when a fetch starts or finishes (the inbox view
-- repaints).
M.listeners = {}

local function changed()
  for _, fn in ipairs(M.listeners) do
    fn()
  end
end

local function notify(message, level, opts)
  vim.notify(message, level or vim.log.levels.INFO, opts)
end

local function plural(n, word, words)
  return ("%d %s"):format(n, n == 1 and word or (words or word .. "s"))
end

--- The inbox configuration path: setup({ inbox_sync = { config = … } }) or
--- the default.
function M.config_path()
  local opts = config.options.inbox_sync or {}
  return opts.config or inbox_config.default_path()
end

--- The cache folder for a repository: its name plus a hash of what it
--- mirrors, so changing url, branch or directory starts a fresh clone.
function M.cache_dir(repo)
  local slug = repo.name:gsub("[^%w_-]", "_")
  local key = vim.fn.sha256(table.concat({ repo.url, repo.branch, repo.directory }, "\n"))
  return ("%s/%s-%s"):format(M.cache_root, slug, key:sub(1, 8))
end

-- Turns git's stderr into an actionable message. Credentials in URLs are
-- redacted.
function M.explain(result, repo)
  if result.code == 124 then
    return ("timed out after %d s; check the network and try :LatticeInboxRefresh"):format(M.timeout_ms / 1000)
  end
  local stderr = result.stderr or ""
  local last
  for line in stderr:gmatch("[^\r\n]+") do
    if vim.trim(line) ~= "" then
      last = vim.trim(line)
    end
  end
  local lower = stderr:lower()
  local reason
  if lower:find("host key verification failed", 1, true) then
    reason = "SSH host key not accepted yet; connect once from a terminal (for example ssh -T git@github.com)"
  elseif
    lower:find("authentication failed", 1, true)
    or lower:find("could not read username", 1, true)
    or lower:find("terminal prompts disabled", 1, true)
    or lower:find("permission denied", 1, true)
    or lower:find("returned error: 403", 1, true)
  then
    reason = "authentication failed; check the Git credentials or SSH key for this account"
  elseif lower:find("repository not found", 1, true) or lower:find("does not appear to be a git repository", 1, true) then
    reason = "repository not found, or these credentials cannot see it"
  elseif lower:find("couldn't find remote ref", 1, true) then
    reason = ("branch %q not found"):format(repo.branch)
  elseif
    lower:find("could not resolve host", 1, true)
    or lower:find("unable to access", 1, true)
    or lower:find("network is unreachable", 1, true)
    or lower:find("timed out", 1, true)
  then
    reason = "network error"
  else
    reason = ("git exited with code %d"):format(result.code or -1)
  end
  if last then
    reason = reason .. " (" .. last .. ")"
  end
  return inbox_config.redact(reason)
end

-- Runs git asynchronously; `done(result)` is called on the main loop.
-- The process is detached (no controlling terminal), so ssh cannot prompt
-- over Neovim's screen, and GIT_TERMINAL_PROMPT=0 stops git's own prompts.
local function git(repo, args, cwd, done)
  local cmd = { "git" }
  if repo.url:match("^[Hh][Tt][Tt][Pp][Ss]?://") then
    vim.list_extend(cmd, { "-c", "credential.useHttpPath=true" })
  end
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, {
    cwd = cwd,
    env = { GIT_TERMINAL_PROMPT = "0" },
    text = true,
    timeout = M.timeout_ms,
    detach = true,
  }, vim.schedule_wrap(done))
  if not ok then
    local missing = tostring(err):find("ENOENT", 1, true)
    vim.schedule(function()
      done({ code = -1, stderr = missing and "git is not installed or not on PATH" or tostring(err) })
    end)
  end
end

-- Runs git commands in order, stopping at the first failure.
local function chain(repo, steps, cwd, done)
  local i = 0
  local function step(result)
    if result and result.code ~= 0 then
      return done(result)
    end
    i = i + 1
    if i > #steps then
      return done({ code = 0 })
    end
    git(repo, steps[i], cwd, step)
  end
  step(nil)
end

-- Parsed captures by path, reused while the file's size and mtime match.
local parsed = {}

local function parse_capture(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local key = ("%d:%d:%d"):format(stat.size, stat.mtime.sec, stat.mtime.nsec)
  local hit = parsed[path]
  if hit and hit.key == key then
    return hit.capture
  end
  local capture = { path = path }
  if stat.size > M.max_capture_bytes then
    capture.error = "larger than 1 MB; not read"
  else
    local file = io.open(path, "r")
    local text = file and file:read("*a")
    if file then
      file:close()
    end
    if not text then
      capture.error = "cannot be read"
    else
      local lines = vim.split(text, "\n", { plain = true })
      local _, _, last = keywords.front_matter(lines)
      for _, field in ipairs({ "id", "created", "source", "destination" }) do
        capture[field] = keywords.front_matter_scalar(lines, field)
      end
      capture.body_line = last + 1
      if not capture.id then
        capture.error = "no id in its front matter"
      end
    end
  end
  parsed[path] = { key = key, capture = capture }
  return capture
end

--- Lists the captures in a repository's cache: regular files named
--- `[A-Za-z0-9._-]+.md` directly in the capture directory. Symlinks and
--- other Markdown names are skipped and reported; other files are ignored.
--- @return table[] captures, table[] skipped
function M.list_captures(repo, dir)
  local folder = repo.directory ~= "" and (dir .. "/" .. repo.directory) or dir
  local captures, skipped = {}, {}
  local handle = vim.uv.fs_scandir(folder)
  if not handle then
    return captures, skipped
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match("%.md$") or kind == "link" then
      if kind == "file" and name:match("^[%w._-]+%.md$") then
        local capture = parse_capture(folder .. "/" .. name)
        if capture then
          capture = vim.tbl_extend("force", {}, capture, { file = name, repo = repo.name })
          captures[#captures + 1] = capture
        end
      elseif name ~= ".git" then
        skipped[#skipped + 1] = {
          file = name,
          reason = kind == "link" and "symbolic link" or (kind ~= "file" and kind or "unsafe file name"),
        }
      end
    end
  end
  table.sort(captures, function(a, b)
    return a.file < b.file
  end)
  table.sort(skipped, function(a, b)
    return a.file < b.file
  end)
  return captures, skipped
end

local function file_set(captures)
  local set = {}
  for _, capture in ipairs(captures) do
    set[capture.file] = true
  end
  return set
end

-- Creates an empty clone with the remote and sparse checkout configured.
local function init_cache(repo, dir, done)
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  chain(repo, {
    { "init", "-q" },
    { "remote", "add", "origin", repo.url },
  }, dir, function(result)
    if result.code ~= 0 or repo.directory == "" then
      return done(result)
    end
    -- Only the capture directory is checked out.
    local file = io.open(dir .. "/.git/info/sparse-checkout", "w")
    if not file then
      return done({ code = -1, stderr = "cannot write the cache's sparse-checkout file" })
    end
    file:write("/" .. repo.directory .. "/\n")
    file:close()
    git(repo, { "config", "core.sparseCheckout", "true" }, dir, done)
  end)
end

local function fetch_into(repo, dir, done)
  local ref = "refs/remotes/origin/" .. repo.branch
  chain(repo, {
    { "fetch", "-q", "--depth", "1", "--no-tags", "origin", ("+refs/heads/%s:%s"):format(repo.branch, ref) },
    { "reset", "-q", "--hard", ref },
  }, dir, done)
end

-- Fetches one repository. The cache is rebuilt once if it is missing or
-- damaged (for example by an interrupted fetch). A failed fetch keeps the
-- captures already in the cache (§6.4).
local function sync_repo(repo, entry, done)
  local dir = M.cache_dir(repo)
  local had_cache = vim.uv.fs_stat(dir .. "/.git/HEAD") ~= nil
  local before = had_cache and file_set((M.list_captures(repo, dir))) or {}

  local function finish(result)
    entry.captures, entry.skipped = M.list_captures(repo, dir)
    if result.code == 0 then
      entry.status, entry.error, entry.last_success = "ok", nil, os.time()
      entry.new = 0
      for _, capture in ipairs(entry.captures) do
        if not before[capture.file] then
          entry.new = entry.new + 1
        end
      end
    else
      entry.status, entry.error, entry.new = "error", M.explain(result, repo), 0
    end
    done()
  end

  local function fresh_clone()
    init_cache(repo, dir, function(result)
      if result.code ~= 0 then
        return finish(result)
      end
      fetch_into(repo, dir, finish)
    end)
  end

  if not had_cache then
    return fresh_clone()
  end
  fetch_into(repo, dir, function(result)
    local stderr = result.stderr or ""
    local damaged = result.code ~= 0
      and (stderr:find("%.lock") or stderr:find("not a git repository") or stderr:find("corrupt"))
    if damaged then
      return fresh_clone()
    end
    finish(result)
  end)
end

local function summary(mode, repos)
  local new, failed = 0, {}
  for _, entry in ipairs(repos) do
    new = new + (entry.new or 0)
    if entry.status == "error" then
      failed[#failed + 1] = entry
    end
  end
  if mode == "startup" then
    local message = ("Lattice Inbox: %s"):format(plural(new, "new capture"))
    local level = vim.log.levels.INFO
    if #failed > 0 then
      message = ("%s (%s failed — :LatticeInboxStatus)"):format(message, plural(#failed, "repository", "repositories"))
      level = vim.log.levels.WARN
    end
    notify(message, level, { title = "Lattice Inbox", timeout = M.state.settings.notification_duration_ms })
  elseif #failed > 0 then
    local parts = vim.tbl_map(function(entry)
      return ("%s: %s"):format(entry.name, entry.error)
    end, failed)
    notify("Lattice Inbox: " .. table.concat(parts, "\n"), vim.log.levels.WARN, { title = "Lattice Inbox" })
  end
end

--- Fetches every active repository. `mode` is "startup" (one notification
--- with the count of new captures) or "manual" (silent unless something
--- fails). `on_done`, if given, runs when every repository has finished.
function M.fetch(mode, on_done)
  if M.state.running then
    if mode == "manual" then
      queued_rerun = true
    end
    return false
  end
  local path = M.config_path()
  local cfg, err = inbox_config.load(path)
  M.state.config_error = err
  M.state.configured = cfg ~= nil or err ~= nil
  if err then
    notify("Lattice Inbox: " .. err, vim.log.levels.ERROR, { title = "Lattice Inbox" })
    return false
  end
  if not cfg then
    M.state.repos, M.state.order = {}, {}
    if mode == "manual" then
      notify(("Lattice Inbox is off: no configuration at %s"):format(vim.fn.fnamemodify(path, ":~")))
    end
    return false
  end
  if mode == "startup" and not cfg.inbox.auto_fetch then
    return false
  end
  M.state.settings = cfg.inbox
  inbox_config.classify(cfg, config.options.root)

  local repos, active = {}, {}
  local order = {}
  for _, repo in ipairs(cfg.repositories) do
    local entry = M.state.repos[repo.name] or {}
    if entry.url ~= repo.url then
      entry = {}
    end
    entry.name, entry.url, entry.role, entry.root_missing = repo.name, repo.url, repo.role, repo.root_missing
    entry.notes_root, entry.repo = repo.notes_root, repo
    entry.new = 0
    if repo.role == "active" then
      entry.status = entry.status or "pending"
      active[#active + 1] = entry
    else
      entry.status, entry.error, entry.captures = nil, nil, nil
    end
    repos[repo.name] = entry
    order[#order + 1] = repo.name
  end
  M.state.repos, M.state.order = repos, order

  if #active == 0 then
    if mode == "manual" then
      notify("Lattice Inbox: no enabled repository uses this notes root; see :LatticeInboxStatus")
    end
    return false
  end

  M.state.running = true
  changed()
  local next_index, running, finished = 1, 0, 0
  local function launch()
    while running < M.max_parallel and next_index <= #active do
      local entry = active[next_index]
      next_index = next_index + 1
      running = running + 1
      entry.status = "fetching"
      sync_repo(entry.repo, entry, function()
        running, finished = running - 1, finished + 1
        if finished == #active then
          M.state.running = false
          summary(mode, active)
          changed()
          if on_done then
            on_done()
          end
          if queued_rerun then
            queued_rerun = false
            M.fetch("manual")
          end
        else
          launch()
        end
      end)
    end
  end
  launch()
  return true
end

--- :LatticeInboxRefresh
function M.refresh()
  M.fetch("manual")
end

--- Starts the startup fetch once per session, when a UI is attached (never
--- in headless or `nvim -l` sessions).
function M.on_startup()
  if startup_done then
    return
  end
  startup_done = true
  local function run()
    if #vim.api.nvim_list_uis() > 0 then
      M.fetch("startup")
    end
  end
  if #vim.api.nvim_list_uis() > 0 then
    vim.schedule(run)
  else
    vim.api.nvim_create_autocmd("UIEnter", { once = true, callback = vim.schedule_wrap(run) })
  end
end

--- Unprocessed captures of the active repositories, by repository name.
function M.captures()
  local out = {}
  for _, name in ipairs(M.state.order) do
    local entry = M.state.repos[name]
    if entry.role == "active" then
      out[name] = entry.captures or {}
    end
  end
  return out
end

--- Lines for :LatticeInboxStatus.
function M.status_lines()
  local path = vim.fn.fnamemodify(M.config_path(), ":~")
  if M.state.config_error then
    return { M.state.config_error }
  end
  if not M.state.configured then
    local cfg, err = inbox_config.load(M.config_path())
    if err then
      return { err }
    end
    if not cfg then
      return { ("Lattice Inbox is off: no configuration at %s"):format(path) }
    end
    return { ("Config: %s"):format(path), "Not fetched yet; run :LatticeInboxRefresh" }
  end
  local lines = { ("Config: %s"):format(path) }
  if #M.state.order == 0 then
    lines[#lines + 1] = "No repositories configured"
  end
  for _, name in ipairs(M.state.order) do
    local entry = M.state.repos[name]
    local line
    if entry.role == "disabled" then
      line = "disabled"
    elseif entry.role == "other_root" then
      line = entry.root_missing and ("notes_root %s does not exist"):format(entry.notes_root)
        or ("other notes root (%s)"):format(entry.notes_root)
    else
      local count = entry.captures and plural(#entry.captures, "capture") or "no captures fetched"
      local fetched = entry.last_success and ("last fetched %s"):format(os.date("%Y-%m-%d %H:%M", entry.last_success))
        or "never fetched"
      if entry.status == "error" then
        line = ("ERROR %s; %s, %s"):format(entry.error, count, fetched)
      elseif entry.status == "fetching" or entry.status == "pending" then
        line = ("fetching…; %s"):format(count)
      else
        line = ("ok; %s, %s"):format(count, fetched)
      end
      for _, skip in ipairs(entry.skipped or {}) do
        line = line .. ("\n    skipped %s: %s"):format(skip.file, skip.reason)
      end
      for _, capture in ipairs(entry.captures or {}) do
        if capture.error then
          line = line .. ("\n    %s: %s"):format(capture.file, capture.error)
        end
      end
    end
    lines[#lines + 1] = ("%s  %s"):format(name, line)
  end
  return lines
end

--- :LatticeInboxStatus
function M.status()
  local chunks = {}
  for _, line in ipairs(M.status_lines()) do
    chunks[#chunks + 1] = { line .. "\n" }
  end
  vim.api.nvim_echo(chunks, true, {})
end

--- Items for :checkhealth lattice.
function M.health_items()
  local items = {}
  local path = M.config_path()
  local cfg, err = inbox_config.load(path)
  if err then
    items[#items + 1] = { level = "error", message = err }
  elseif not cfg then
    items[#items + 1] = { level = "info", message = ("Off: no %s"):format(vim.fn.fnamemodify(path, ":~")) }
  else
    items[#items + 1] = {
      level = "ok",
      message = ("Config: %s (%s)"):format(vim.fn.fnamemodify(path, ":~"), plural(#cfg.repositories, "repository", "repositories")),
    }
    if vim.fn.executable("git") == 1 then
      items[#items + 1] = { level = "ok", message = "git found" }
    else
      items[#items + 1] = { level = "error", message = "git not found on PATH: the inbox cannot fetch" }
    end
  end
  return items
end

return M
