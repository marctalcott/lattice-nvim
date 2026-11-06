-- Run from anywhere: nvim -l tests/run.lua
local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(script, ":p:h:h")
package.path = table.concat({
  repo .. "/lua/?.lua",
  repo .. "/lua/?/init.lua",
  repo .. "/tests/?.lua",
  package.path,
}, ";")
-- Plugins are found on runtimepath (e.g. by :checkhealth), as in a real install.
vim.opt.runtimepath:prepend(repo)

local H = require("helpers")
for _, name in ipairs({ "parser_spec", "scanner_spec", "dashboard_spec", "insert_spec", "tasks_spec", "metadata_spec", "schedule_spec", "mutate_spec", "integration_spec", "review_fixes_spec", "review_fixes_0_2_1_spec", "review_fixes_0_2_2_spec", "inbox_spec" }) do
  dofile(repo .. "/tests/" .. name .. ".lua")
end

print(("%d passed, %d failed"):format(H.passed, H.failed))
os.exit(H.failed == 0 and 0 or 1)
