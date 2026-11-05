-- Fixtures for inbox tests: local bare Git repositories stand in for GitHub.
local H = require("helpers")
local write, notes = H.write, H.notes
local config = H.config
local sync = require("lattice.inbox_sync")

local IH = {}

-- Removal commits use the user's Git identity; tests use a fixed one and
-- ignore the developer's global Git configuration (hooks, signing).
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_AUTHOR_NAME, vim.env.GIT_AUTHOR_EMAIL = "Lattice Test", "test@example.com"
vim.env.GIT_COMMITTER_NAME, vim.env.GIT_COMMITTER_EMAIL = "Lattice Test", "test@example.com"
function IH.run(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
  return result
end

local IDENTITY = { "git", "-c", "user.name=Lattice Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false" }

-- A bare "GitHub" repository and a working clone used to add captures.
function IH.remote()
  local base = notes()
  IH.run({ "git", "init", "-q", "--bare", "-b", "main", base .. "/remote.git" })
  IH.run({ "git", "init", "-q", "-b", "main", base .. "/work" })
  IH.run({ "git", "remote", "add", "origin", base .. "/remote.git" }, base .. "/work")
  local r = { url = base .. "/remote.git", work = base .. "/work" }
  -- Files on the remote's main branch.
  function r.files()
    local out = IH.run({ "git", "ls-tree", "-r", "--name-only", "main" }, r.url).stdout
    return vim.split(out, "\n", { trimempty = true })
  end
  function r.last_message()
    return vim.trim(IH.run({ "git", "log", "-1", "--format=%s", "main" }, r.url).stdout)
  end
  -- Makes the remote refuse every push (like branch protection), or allow
  -- them again.
  function r.protect(on)
    local hook = r.url .. "/hooks/pre-receive"
    if on then
      write(r.url, "hooks/pre-receive", "#!/bin/sh\necho 'protected branch' >&2\nexit 1\n")
      vim.uv.fs_chmod(hook, tonumber("755", 8))
    else
      vim.fn.delete(hook)
    end
  end

  function r.push(files, remove)
    -- Start from the remote's current state (Lattice may have pushed).
    if vim.trim(IH.run({ "git", "ls-remote", "origin", "main" }, r.work).stdout) ~= "" then
      IH.run({ "git", "fetch", "-q", "origin", "main" }, r.work)
      IH.run({ "git", "reset", "-q", "--hard", "FETCH_HEAD" }, r.work)
    end
    for rel, content in pairs(files or {}) do
      write(r.work, rel, content)
    end
    for _, rel in ipairs(remove or {}) do
      IH.run({ "git", "rm", "-q", rel }, r.work)
    end
    IH.run({ "git", "add", "-A" }, r.work)
    IH.run(vim.list_extend(vim.deepcopy(IDENTITY), { "commit", "-q", "--allow-empty", "-m", "captures" }), r.work)
    IH.run({ "git", "push", "-q", "origin", "main" }, r.work)
  end
  return r
end

function IH.capture(id, text)
  return ('---\nid: "%s"\ncreated: "2026-11-05T07:45:00-05:00"\nsource: "drafts"\ndestination: "personal"\n---\n%s\n'):format(id, text or "Etna lava dome idea")
end

-- Points Lattice at a notes root and an inbox.json listing `repos`.
function IH.setup_inbox(root, repos, inbox)
  local dir = notes()
  write(dir, "inbox.json", vim.json.encode({ inbox = inbox or vim.empty_dict(), repositories = repos }))
  config.options.root = root
  config.options.inbox_sync = { config = dir .. "/inbox.json" }
  sync.cache_root = notes() .. "/cache"
  sync.state = sync.new_state()
end

-- Waits until no removal is in progress.
function IH.wait_removals()
  assert(vim.wait(20000, function()
    for _, record in pairs(sync.state.removals) do
      if record.status == "removing" then
        return false
      end
    end
    return true
  end, 20), "removal did not finish")
end

function IH.fetch(mode)
  local done = false
  local started = sync.fetch(mode, function()
    done = true
  end)
  if started then
    assert(vim.wait(20000, function()
      return done
    end, 20), "fetch did not finish")
  end
  return started
end

function IH.files(name)
  return vim.tbl_map(function(c)
    return c.file
  end, sync.captures()[name] or {})
end

return IH
