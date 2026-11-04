-- Shared test harness. Specs get helpers with: local H = require("helpers")
local H = {}

H.config = require("lattice.config")
H.dashboard = require("lattice.dashboard")
H.lattice = require("lattice")
H.parser = require("lattice.tasks")
H.timestamp = require("lattice.timestamp")
H.scanner = require("lattice.scanner")
H.insert = require("lattice.insert")
H.keywords = require("lattice.keywords")
H.health = require("lattice.health")

H.passed, H.failed = 0, 0
H.repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    H.passed = H.passed + 1
  else
    H.failed = H.failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end

local function eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local config, dashboard, parser = H.config, H.dashboard, H.parser
local HEADINGS = config.defaults()

local function parse(text)
  return assert(parser.parse(vim.split(text, "\n", { plain = true }), HEADINGS))
end

local function texts(result)
  return vim.tbl_map(function(task)
    return task.text
  end, result.tasks)
end

local function write(root, rel, content)
  local path = root .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
  return path
end

local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local function notes()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return vim.uv.fs_realpath(root)
end

local function reset(root)
  dashboard.close()
  vim.cmd("silent! %bwipeout!")
  config.options.root = root
end

-- Silence notifications, keeping the last one for assertions.
local last_notify
vim.notify = function(message, level)
  last_notify = { message = message, level = level }
end

local function dashboard_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function press_enter_on(text)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      dashboard.jump()
      return
    end
  end
  error("no dashboard line contains " .. text)
end
H.test = test
H.eq = eq
H.parse = parse
H.texts = texts
H.write = write
H.read = read
H.notes = notes
H.reset = reset
H.dashboard_text = dashboard_text
H.press_enter_on = press_enter_on
H.HEADINGS = HEADINGS
H.last_notify = function()
  return last_notify
end

return H
