-- Looking up global normal-mode mappings for keymap conflict detection
-- (LATTICE_KEYBINDINGS_SPEC A1.2).
local M = {}

-- The global normal-mode mapping for `lhs`, ignoring buffer-local ones:
-- maparg() prefers the current buffer's mappings, so ask from a scratch
-- buffer that has none.
function M.global_mapping(lhs)
  local scratch = vim.api.nvim_create_buf(false, true)
  local found = vim.api.nvim_buf_call(scratch, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
  vim.api.nvim_buf_delete(scratch, { force = true })
  return not vim.tbl_isempty(found) and found or nil
end

function M.is_lattice(mapping)
  return mapping ~= nil and (mapping.desc or ""):match("^Lattice: ") ~= nil
end

-- The bytes Neovim matches for `lhs`, with <Leader> and <LocalLeader>
-- expanded as :map does (backslash when unset).
function M.raw(lhs)
  local function leader(name)
    local value = vim.g[name]
    return (type(value) == "string" and value ~= "") and value or "\\"
  end
  local expanded = lhs:gsub("<[Ll][Oo][Cc][Aa][Ll][Ll][Ee][Aa][Dd][Ee][Rr]>", function()
    return leader("maplocalleader")
  end)
  expanded = expanded:gsub("<[Ll][Ee][Aa][Dd][Ee][Rr]>", function()
    return leader("mapleader")
  end)
  return vim.api.nvim_replace_termcodes(expanded, true, true, true)
end

-- Other global normal-mode mappings that are a proper prefix of `lhs`, or
-- that `lhs` is a proper prefix of. Either way one of the two keys waits
-- for 'timeoutlen' before it runs. Lattice's own mappings are ignored.
function M.overlaps(lhs)
  local mine = M.raw(lhs)
  local found = {}
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if not M.is_lattice(map) then
      local theirs = map.lhsraw or M.raw(map.lhs)
      if theirs ~= mine and theirs ~= "" then
        local shorter, longer = theirs, mine
        if #shorter > #longer then
          shorter, longer = longer, shorter
        end
        if longer:sub(1, #shorter) == shorter then
          found[#found + 1] = { lhs = map.lhs, desc = map.desc, prefix = #theirs < #mine }
        end
      end
    end
  end
  table.sort(found, function(a, b)
    return a.lhs < b.lhs
  end)
  return found
end

return M
