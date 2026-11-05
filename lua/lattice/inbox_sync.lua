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

local function changed()
  for _, fn in ipairs(M.listeners) do
    fn()
  end
end

--- The key of a capture in `state.removals`: its repository and ID (or its
--- file name when it has no ID).
function M.key(capture)
  return capture.repo .. "\0" .. (capture.id or capture.file)
end

local function removals()
  return M.state.removals
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
    reason = "the repository refused the push"
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
  if repo.op then
    -- An error in a callback ends the locked operation instead of leaving
    -- its lock held (see with_lock).
    local inner = done
    done = function(result)
      local ok, err = xpcall(inner, debug.traceback, result)
      if not ok then
        repo.op.fail(err)
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

-- Operations on a cache folder run one at a time (a fetch and a removal
-- must not share a working tree). `fn(release, op)` calls release() when it
-- is done. A Lua error in `fn`, or in a git callback of a repository bound
-- to `op` (M.bind), is reported, calls `on_error(err)` and releases the
-- lock, so one bug cannot block the repository for the session.
local locks = {}
local function with_lock(dir, fn, on_error)
  local function run(release_next)
    local released, failed = false, false
    local function release()
      if not released then
        released = true
        release_next()
      end
    end
    local op = {}
    function op.fail(err)
      if failed then
        return
      end
      failed = true
      notify("Lattice Inbox: internal error: " .. tostring(err), vim.log.levels.ERROR, { title = "Lattice Inbox" })
      release()
      if on_error then
        pcall(on_error, err)
      end
    end
    local ok, err = xpcall(fn, debug.traceback, release, op)
    if not ok then
      op.fail(err)
    end
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
    if (entry.new_files or {})[capture.file] and not removals()[M.key(capture)] then
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
          M.state.running = false
          M.recover(active)
          summary(mode, active)
          M.retry_removals()
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
      end, function(err)
        entry.status, entry.error = "error", "internal error: " .. vim.split(tostring(err), "\n")[1]
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
        return done({ code = 0 })
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
  local record = removals()[k]
  if record and record.status == "removing" then
    return
  end
  record = record or {}
  record.repo, record.id, record.file, record.kind = capture.repo, capture.id, capture.file, kind
  record.note = note or record.note
  record.status, record.error = "removing", nil
  removals()[k] = record
  changed()

  local entry = M.state.repos[capture.repo]
  local function failed(message)
    if kind == "dismissed" then
      removals()[k] = nil
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
      local function finish()
        local current = M.state.repos[capture.repo] or entry
        local had = file_set(current.captures or {})
        current.captures, current.skipped = M.list_captures(repo, dir)
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
          removals()[k] = nil
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
      -- Undo the local commit so the cache matches the remote again.
      git(repo, { "reset", "-q", "--hard", "refs/remotes/origin/" .. repo.branch }, dir, finish)
    end)
  end, function(err)
    failed("internal error: " .. vim.split(tostring(err), "\n")[1])
  end)
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
      if capture.id and not removals()[k] and not M.state.checked[k] then
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
  local result = require("lattice.scanner").collect(root)
  if result.error then
    return
  end
  for k in pairs(wanted) do
    M.state.checked[k] = true
  end
  for _, heading in ipairs(result.outlines or {}) do
    local capture = heading.capture_id
      and heading.capture_repo
      and wanted[heading.capture_repo .. "\0" .. heading.capture_id]
    if capture and process.file_has_capture_id(heading.path, capture.id, capture.repo, result.cfg) then
      wanted[M.key(capture)] = nil
      removals()[M.key(capture)] = {
        repo = capture.repo,
        id = capture.id,
        file = capture.file,
        kind = "filed",
        note = heading.path,
        status = "pending",
      }
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
  for k, record in pairs(removals()) do
    local entry = M.state.repos[record.repo]
    if record.status == "pending" then
      if not (entry and entry.role == "active") then
        removals()[k] = nil
        M.state.checked[k] = nil
      elseif entry.status == "ok" then
        if listed[k] then
          M.remove(listed[k], "filed", record.note, { retry = true })
        else
          removals()[k] = nil
        end
      end
    end
  end
end

--- Removals for a repository, sorted by file.
function M.removals_for(name)
  local out = {}
  for _, record in pairs(removals()) do
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
