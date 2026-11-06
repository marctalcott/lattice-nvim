-- Fetches captures from the GitHub inbox repositories and removes processed
-- ones (LATTICE_INBOX_SPEC A1.5, A1.6, A1.11, A1.12). Each active repository
-- is mirrored in a shallow, sparse Git clone under stdpath("cache"); that
-- clone is the local cache. Everything runs asynchronously through `git`
-- and never prompts.
local config = require("lattice.config")
local inbox_config = require("lattice.inbox_config")
local keywords = require("lattice.keywords")
local process = require("lattice.inbox_process")

local M = {}

-- Overridable for tests.
M.cache_root = vim.fn.stdpath("cache") .. "/lattice/inbox"
M.timeout_ms = 30000
M.max_parallel = 4
M.max_capture_bytes = 1024 * 1024
M.max_push_attempts = 3

-- Session state. `repos` maps a repository name to
-- { name, role, url, status = "ok"|"error"|"fetching"|"pending", error,
--   last_success, captures, skipped, new_files }.
-- `removals` maps M.key(capture) to a removal in progress or pending:
-- { repo, id, file, kind = "filed"|"dismissed", note = path of the filed
--   note, status = "removing"|"pending", error }.
-- `warned` holds retried removal failures already reported, by
-- "<repo>\0<reason>". `checked` holds the keys of captures recovery has
-- already looked up this session.
function M.new_state()
  return {
    running = false,
    repos = {},
    order = {},
    config_error = nil,
    configured = false,
    removals = {},
    warned = {},
    checked = {},
  }
end
M.state = M.new_state()

local queued_rerun = false
local startup_done = false

-- Functions called when a fetch starts or finishes (the inbox view
-- repaints).
M.listeners = {}

-- Listener errors are reported here, so they are never mistaken for a
-- failed fetch or removal.
local function changed()
  for _, fn in ipairs(M.listeners) do
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
      vim.notify("Lattice Inbox: could not update the view: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

--- The key of a capture in `state.removals`: its repository and ID (or its
--- file name when it has no ID).
function M.key(capture)
  return capture.repo .. "\0" .. (capture.id or capture.file)
end

--- The removal in progress or pending for a capture, or nil.
function M.removal(capture)
  return M.state.removals[M.key(capture)]
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
  local rejected = lower:find("[remote rejected]", 1, true) or lower:find("[rejected]", 1, true)
  if rejected then
    -- Show what the server said (a protected branch, a missing permission).
    local said = {}
    for line in stderr:gmatch("[^\r\n]+") do
      local text = vim.trim(line:match("^remote:(.*)$") or "")
      if text ~= "" then
        said[#said + 1] = text
      end
    end
    last = #said > 0 and table.concat(said, " ") or vim.trim(stderr:match("[^\n]*rejected%][^\n]*") or last or "")
    if lower:find("fetch first", 1, true) or lower:find("non-fast-forward", 1, true) then
      reason = ("the branch kept changing during %d attempts; the next fetch retries"):format(M.max_push_attempts)
    else
      reason = "the repository refused the push"
    end
  elseif lower:find("please tell me who you are", 1, true) or lower:find("unable to auto-detect email", 1, true) then
    reason = "Git has no identity for the removal commit; set user.name and user.email with git config --global"
  elseif lower:find("host key verification failed", 1, true) then
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

--- The folder git must not search above: the cache root, as a real path.
function M.ceiling()
  return vim.uv.fs_realpath(M.cache_root) or M.cache_root
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
  local op = repo.op
  if op then
    -- The lock is held while any git process of the operation runs. After
    -- a failure, remaining callbacks only release it; an error in a
    -- callback ends the operation (see with_lock).
    op.running = op.running + 1
    if op.lock then
      -- Still alive: keep the cross-session lock fresh.
      local now = os.time()
      vim.uv.fs_utime(op.lock, now, now)
    end
    local inner = done
    done = function(result)
      op.running = op.running - 1
      if op.failed then
        if op.running == 0 then
          op.release()
        end
        return
      end
      local ok, err = xpcall(inner, debug.traceback, result)
      if not ok then
        op.fail(err)
      end
    end
  end
  local ok, err = pcall(vim.system, cmd, {
    cwd = cwd,
    -- Git must never find a repository above the cache folder (such as a
    -- home directory kept in Git) and act on it.
    env = { GIT_TERMINAL_PROMPT = "0", GIT_CEILING_DIRECTORIES = M.ceiling() },
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

-- Cross-process lock: a `<cache dir>.lock` folder holding the owner's PID,
-- since every Neovim session shares the cache. The owner refreshes its
-- time whenever it starts a git process. A lock is stale when its process
-- is gone, when it is this process (which never holds one between
-- operations), or when it has not been refreshed for lock_stale_s (its PID
-- may since belong to an unrelated program, after a reboot).
M.lock_wait_ms = 120000
M.lock_retry_ms = 200
M.lock_stale_s = 600

local function process_alive(pid)
  if pid == vim.fn.getpid() then
    return false
  end
  local ok, err = vim.uv.kill(pid, 0)
  return ok == 0 or (type(err) == "string" and err:find("EPERM", 1, true) ~= nil)
end

local function lock_is_stale(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return false
  end
  local age = os.time() - stat.mtime.sec
  if age >= M.lock_stale_s then
    return true
  end
  local file = io.open(path .. "/pid", "r")
  local pid = file and tonumber(file:read("*a"))
  if file then
    file:close()
  end
  if not pid then
    -- A lock without a PID yet may be being created right now.
    return age >= 10
  end
  return not process_alive(pid)
end

local function take_file_lock(dir)
  local path = dir .. ".lock"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  if vim.uv.fs_mkdir(path, tonumber("700", 8)) then
    local file = io.open(path .. "/pid", "w")
    if file then
      file:write(tostring(vim.fn.getpid()))
      file:close()
    end
    return true
  end
  if not lock_is_stale(path) then
    return false
  end
  -- Breaking a stale lock is itself locked, and staleness is checked again
  -- inside, so two sessions never both break it (one would delete the
  -- lock the other just took). The caller retries afterwards.
  local breaker = path .. ".break"
  if not vim.uv.fs_mkdir(breaker, tonumber("700", 8)) then
    local stat = vim.uv.fs_stat(breaker)
    if stat and os.time() - stat.mtime.sec >= 10 then
      vim.fn.delete(breaker, "rf") -- left by a crash mid-break
    end
    return false
  end
  if lock_is_stale(path) then
    vim.fn.delete(path, "rf")
  end
  vim.fn.delete(breaker, "rf")
  return false
end

local function drop_file_lock(dir)
  vim.fn.delete(dir .. ".lock", "rf")
end

-- Operations on a cache folder run one at a time (a fetch and a removal
-- must not share a working tree), within this session and across Neovim
-- sessions. `fn(release, op)` calls release() when it is done.
-- `on_error(message)` is called when the operation cannot run or fails
-- with a Lua error, in `fn` or in a git callback of a repository bound to
-- `op` (see bind): the error is reported, and the lock is released once no
-- git process of the operation is still running, so one bug cannot block
-- the repository.
local locks = {}
local function with_lock(dir, fn, on_error)
  local function run(release_next)
    local released = false
    local op = { running = 0, failed = false, lock = dir .. ".lock" }
    local function release()
      if not released then
        released = true
        drop_file_lock(dir)
        release_next()
      end
    end
    op.release = release
    function op.fail(err)
      if op.failed then
        return
      end
      op.failed = true
      notify("Lattice Inbox: internal error: " .. tostring(err), vim.log.levels.ERROR, { title = "Lattice Inbox" })
      if op.running == 0 then
        release()
      end
      if on_error then
        pcall(on_error, "internal error: " .. vim.split(tostring(err), "\n")[1])
      end
    end
    local deadline = vim.uv.now() + M.lock_wait_ms
    local function start()
      if not take_file_lock(dir) then
        if vim.uv.now() < deadline then
          return vim.defer_fn(start, M.lock_retry_ms)
        end
        released = true
        release_next()
        if on_error then
          pcall(on_error, "another Neovim session is using this repository's cache; try :LatticeInboxRefresh later")
        end
        return
      end
      local ok, err = xpcall(fn, debug.traceback, release, op)
      if not ok then
        op.fail(err)
      end
    end
    start()
  end
  if locks[dir] then
    table.insert(locks[dir], run)
    return
  end
  locks[dir] = {}
  local function release_next()
    local next_run = table.remove(locks[dir], 1)
    if next_run then
      next_run(release_next)
    else
      locks[dir] = nil
    end
  end
  run(release_next)
end

-- A view of `repo` whose git callbacks report errors to `op`.
local function bind(repo, op)
  return setmetatable({ op = op }, { __index = repo })
end

-- For tests only.
M._internal = { with_lock = with_lock, bind = bind, git = git, take_file_lock = take_file_lock }

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
local function sync_repo(repo, entry, done, release)
  local dir = M.cache_dir(repo)
  local had_cache = vim.uv.fs_stat(dir .. "/.git/HEAD") ~= nil
  local before = had_cache and file_set((M.list_captures(repo, dir))) or {}
  if not had_cache and entry.discarded then
    -- The cache was discarded this session (a failed undo): what it listed
    -- is not new.
    before = file_set(entry.captures or {})
  end
  entry.discarded = nil
  -- Captures a removal's retry fetched have not been announced yet.
  for file in pairs(entry.unannounced or {}) do
    before[file] = nil
  end

  local function finish(result)
    entry.captures, entry.skipped = M.list_captures(repo, dir)
    entry.new_files = {}
    if result.code == 0 then
      entry.status, entry.error, entry.last_success = "ok", nil, os.time()
      entry.unannounced = {}
      for _, capture in ipairs(entry.captures) do
        if not before[capture.file] then
          entry.new_files[capture.file] = true
        end
      end
    else
      entry.status, entry.error = "error", M.explain(result, repo)
    end
    release()
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

-- New captures in a fetched repository, not counting ones already filed.
local function new_count(entry)
  local count = 0
  for _, capture in ipairs(entry.captures or {}) do
    if (entry.new_files or {})[capture.file] and not M.state.removals[M.key(capture)] then
      count = count + 1
    end
  end
  return count
end

local function summary(mode, repos)
  local new, failed = 0, {}
  for _, entry in ipairs(repos) do
    entry.new = new_count(entry)
    new = new + entry.new
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
    entry.new_files = {}
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
      local function on_repo_done()
        running, finished = running - 1, finished + 1
        if finished == #active then
          -- Completion runs on its own, not inside the last repository's
          -- git callback, so an error here is not blamed on that
          -- repository and does not skip the rest.
          vim.schedule(function()
            M.state.running = false
            local ok, err = xpcall(M.recover, debug.traceback, active)
            if not ok then
              notify("Lattice Inbox: recovery failed: " .. tostring(err), vim.log.levels.ERROR, { title = "Lattice Inbox" })
            end
            summary(mode, active)
            M.retry_removals()
            changed()
            if queued_rerun then
              queued_rerun = false
              M.fetch("manual")
            end
            if on_done then
              on_done()
            end
          end)
        else
          launch()
        end
      end
      local repo_done = false
      local function once()
        if not repo_done then
          repo_done = true
          on_repo_done()
        end
      end
      with_lock(M.cache_dir(entry.repo), function(release, op)
        sync_repo(bind(entry.repo, op), entry, once, release)
      end, function(message)
        entry.status, entry.error = "error", message
        once()
      end)
    end
  end
  launch()
  return true
end

-- Removal (A1.6, §12) -------------------------------------------------------------

local function non_fast_forward(result)
  local stderr = result.stderr or ""
  return stderr:find("non%-fast%-forward") or stderr:find("fetch first") or stderr:find("stale info")
end

-- Deletes one capture file from the repository: git rm, commit, push. A push
-- rejected as non-fast-forward is retried after a fresh fetch, up to
-- max_push_attempts. A file that is already gone counts as removed.
-- `done(result)` gets code 0 on success.
local function remove_file(repo, dir, file, done)
  local rel = repo.directory ~= "" and (repo.directory .. "/" .. file) or file
  local attempt = 0
  local function try()
    attempt = attempt + 1
    git(repo, { "ls-files", "--error-unmatch", "--", rel }, dir, function(listed)
      if listed.code ~= 0 then
        -- Already gone only if git says so; a lock or a damaged index is a
        -- failure, not a removal.
        local gone = (listed.stderr or ""):find("did not match any file", 1, true)
        return done(gone and { code = 0 } or listed)
      end
      chain(repo, {
        { "rm", "-q", "--", rel },
        -- Signing could need a passphrase prompt, which a detached git
        -- cannot show.
        { "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "Lattice: remove processed capture " .. file },
        { "push", "-q", "--no-verify", "origin", "HEAD:refs/heads/" .. repo.branch },
      }, dir, function(result)
        if result.code == 0 or not non_fast_forward(result) or attempt >= M.max_push_attempts then
          return done(result)
        end
        fetch_into(repo, dir, function(fetched)
          if fetched.code ~= 0 then
            return done(fetched)
          end
          try()
        end)
      end)
    end)
  end
  if not vim.uv.fs_stat(dir .. "/.git/HEAD") then
    return done({ code = -1, stderr = "the capture cache is missing; run :LatticeInboxRefresh" })
  end
  try()
end

--- Deletes a processed capture from its repository (§12). `kind` is "filed"
--- (after the user saved the note at `note`) or "dismissed" (after
--- confirmation). Until it succeeds the capture is listed as filed, removal
--- pending; a filed capture whose removal fails stays so and is retried by
--- the next fetch, a dismissed one returns to the inbox (§12.4).
--- `opts.retry` marks an automatic retry: its failure is reported once per
--- session for each repository and reason, not every time.
function M.remove(capture, kind, note, opts)
  opts = opts or {}
  local k = M.key(capture)
  local record = M.state.removals[k]
  if record and record.status == "removing" then
    return
  end
  record = record or {}
  record.repo, record.id, record.file, record.kind = capture.repo, capture.id, capture.file, kind
  record.note = note or record.note
  record.status, record.error = "removing", nil
  M.state.removals[k] = record
  changed()

  local entry = M.state.repos[capture.repo]
  local function failed(message)
    if kind == "dismissed" then
      M.state.removals[k] = nil
      notify(
        ("Lattice Inbox: could not dismiss %s from %s: %s. It stays in the inbox."):format(capture.file, capture.repo, message),
        vim.log.levels.WARN,
        { title = "Lattice Inbox" }
      )
    else
      record.status, record.error = "pending", message
      local warned = M.state.warned
      local warned_key = capture.repo .. "\0" .. message
      if not opts.retry then
        notify(
          ("Lattice Inbox: %s is filed, but removing it from %s failed: %s. The next fetch (:LatticeInboxRefresh) retries."):format(
            capture.file,
            capture.repo,
            message
          ),
          vim.log.levels.WARN,
          { title = "Lattice Inbox" }
        )
        warned[warned_key] = true
      elseif not warned[warned_key] then
        warned[warned_key] = true
        notify(
          ("Lattice Inbox: removing filed captures from %s failed: %s. They stay filed, removal pending (:LatticeInboxStatus)."):format(
            capture.repo,
            message
          ),
          vim.log.levels.WARN,
          { title = "Lattice Inbox" }
        )
      end
    end
    changed()
  end
  if not (entry and entry.role == "active" and entry.repo) then
    return failed("the repository is not active in this session")
  end
  local dir = M.cache_dir(entry.repo)
  with_lock(dir, function(release, op)
    local repo = bind(entry.repo, op)
    remove_file(repo, dir, capture.file, function(result)
      local function finish(discarded)
        local current = M.state.repos[capture.repo] or entry
        local had = file_set(current.captures or {})
        if discarded then
          -- Keep showing what the cache listed until the next fetch clones
          -- it afresh.
          current.discarded = true
        else
          current.captures, current.skipped = M.list_captures(repo, dir)
        end
        -- A retry fetches; captures it brought in count as new at the next
        -- fetch.
        current.unannounced = current.unannounced or {}
        for _, listed_capture in ipairs(current.captures) do
          if not had[listed_capture.file] then
            current.unannounced[listed_capture.file] = true
          end
        end
        release()
        if result.code == 0 then
          M.state.removals[k] = nil
          -- If the capture comes back (a re-upload, a reverted commit),
          -- recovery looks it up again.
          M.state.checked[k] = nil
          if kind == "dismissed" then
            notify(("Lattice Inbox: dismissed %s"):format(capture.file), nil, { title = "Lattice Inbox" })
          end
          changed()
        else
          failed(M.explain(result, repo))
        end
      end
      if result.code == 0 or not vim.uv.fs_stat(dir .. "/.git/HEAD") then
        return finish()
      end
      -- Undo the local commit so the cache matches the remote again. If
      -- that fails too, the cache is discarded: the next fetch clones it
      -- afresh, and until then the capture is not wrongly shown as gone.
      git(repo, { "reset", "-q", "--hard", "refs/remotes/origin/" .. repo.branch }, dir, function(reset)
        if reset.code ~= 0 then
          vim.fn.delete(dir, "rf")
        end
        finish(reset.code ~= 0)
      end)
    end)
  end, failed)
end

--- Recovery (A1.12): a listed capture whose ID is already in a saved note
--- under the notes root was filed earlier (a crash, a failed removal, or a
--- second filing). It is marked filed, removal pending, so it is not offered
--- again. Each capture is looked up once per session, so the notes are
--- scanned only when a fetch lists a capture not seen before. A note matches only if its drawer has the capture's ID and
--- repository (:CAPTURE_REPO:). The note is found with the normal scan and
--- confirmed on disk, so an unsaved buffer never counts.
function M.recover(entries)
  local wanted = {}
  for _, entry in ipairs(entries) do
    for _, capture in ipairs(entry.captures or {}) do
      local k = M.key(capture)
      if capture.id and not M.state.removals[k] and not M.state.checked[k] then
        wanted[k] = capture
      end
    end
  end
  local root = config.options.root
  if next(wanted) == nil or not root then
    return
  end
  -- One scan per fetch with captures not looked up yet this session; a
  -- capture filed later in the session is recorded by the save itself.
  local scanner = require("lattice.scanner")
  local result = scanner.collect(root)
  if result.error then
    return
  end
  local unsaved = scanner.modified_buffers()
  -- Captures whose note is open with unsaved changes that disagree with
  -- the disk are looked up again at the next fetch.
  local unconfirmed = {}
  for _, heading in ipairs(result.outlines or {}) do
    local capture = heading.capture_id
      and heading.capture_repo
      and wanted[M.key({ repo = heading.capture_repo, id = heading.capture_id })]
    -- The scan read unsaved buffers; only those need checking on disk.
    local confirmed = capture
      and (
        not unsaved[vim.uv.fs_realpath(heading.path) or heading.path]
        or process.file_has_capture_id(heading.path, capture.id, capture.repo, result.cfg)
      )
    if capture and not confirmed then
      unconfirmed[M.key(capture)] = true
    end
    if confirmed then
      wanted[M.key(capture)] = nil
      M.state.checked[M.key(capture)] = true
      M.state.removals[M.key(capture)] = {
        repo = capture.repo,
        id = capture.id,
        file = capture.file,
        kind = "filed",
        note = heading.path,
        status = "pending",
      }
    end
  end
  -- The scan saw unsaved buffers, not their files: a capture ID still
  -- found on disk under such a buffer is left for the next fetch too.
  for path in pairs(unsaved) do
    local file = io.open(path, "r")
    local text = file and file:read("*a")
    if file then
      file:close()
    end
    if text then
      for k, capture in pairs(wanted) do
        if text:find(capture.id, 1, true) then
          unconfirmed[k] = true
        end
      end
    end
  end
  for k in pairs(wanted) do
    if not unconfirmed[k] then
      M.state.checked[k] = true
    end
  end
end

--- Starts removal of every filed capture whose removal is pending, in the
--- active repositories. Records for captures no longer listed, or for
--- repositories no longer active, are dropped: the note is the record, so
--- recovery finds them again if the capture comes back.
function M.retry_removals()
  local listed = {}
  for _, name in ipairs(M.state.order) do
    local entry = M.state.repos[name]
    if entry.role == "active" and entry.status == "ok" then
      for _, capture in ipairs(entry.captures or {}) do
        listed[M.key(capture)] = capture
      end
    end
  end
  for k, record in pairs(M.state.removals) do
    local entry = M.state.repos[record.repo]
    if record.status == "pending" then
      if not (entry and entry.role == "active") then
        M.state.removals[k] = nil
        M.state.checked[k] = nil
      elseif entry.status == "ok" then
        if listed[k] then
          M.remove(listed[k], "filed", record.note, { retry = true })
        else
          M.state.removals[k] = nil
          M.state.checked[k] = nil
        end
      end
    end
  end
end

--- Rereads a repository's captures from its cache without fetching. Every
--- Neovim session shares the cache, so another session may have removed
--- captures from it (or fetched new ones, which count as new at the next
--- fetch).
function M.relist(name)
  local entry = M.state.repos[name]
  if not (entry and entry.role == "active" and entry.repo) or entry.discarded then
    return
  end
  local had = file_set(entry.captures or {})
  entry.captures, entry.skipped = M.list_captures(entry.repo, M.cache_dir(entry.repo))
  entry.unannounced = entry.unannounced or {}
  for _, capture in ipairs(entry.captures) do
    if not had[capture.file] then
      entry.unannounced[capture.file] = true
    end
  end
  changed()
end

--- Whether a listed capture's file is still in the cache.
function M.present(capture)
  return capture.path ~= nil and vim.uv.fs_stat(capture.path) ~= nil
end

--- Removals for a repository, sorted by file.
function M.removals_for(name)
  local out = {}
  for _, record in pairs(M.state.removals) do
    if record.repo == name then
      out[#out + 1] = record
    end
  end
  table.sort(out, function(a, b)
    return a.file < b.file
  end)
  return out
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
      for _, record in ipairs(M.removals_for(name)) do
        if record.status == "removing" then
          line = line .. ("\n    removing %s"):format(record.file)
        else
          line = line .. ("\n    removal pending %s%s"):format(record.file, record.error and (": " .. record.error) or "")
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
