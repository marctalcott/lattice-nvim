-- Markdown block structure from Neovim's Tree-sitter Markdown parser
-- (LATTICE_SYNTAX_SPEC §13.1): headings with their section ranges, list
-- items with their nesting and task markers, and the front matter. Code
-- blocks produce nothing, so text inside them is never a heading or item.
--
-- Lines are 1-based and ranges inclusive. Nothing here knows about TODO
-- keywords or metadata; see tasks.lua.
local M = {}

local HEADING_LEVEL = {
  atx_h1_marker = 1,
  atx_h2_marker = 2,
  atx_h3_marker = 3,
  atx_h4_marker = 4,
  atx_h5_marker = 5,
  atx_h6_marker = 6,
}

local CHECKBOX = {
  task_list_marker_unchecked = " ",
  task_list_marker_checked = "x",
}

--- True when Neovim can load a Markdown parser.
function M.available()
  return (pcall(vim.treesitter.language.add, "markdown"))
end

-- Last line (1-based, inclusive) covered by a node. A node ending at
-- column 0 stops at the end of the previous line.
local function last_line(node)
  local _, _, er, ec = node:range()
  return ec == 0 and er or er + 1
end

local function heading_text(raw)
  raw = vim.trim(raw or "")
  raw = raw:gsub("^#+$", "")
  raw = raw:gsub("[ \t]+#+$", "")
  return vim.trim(raw)
end

--- @class lattice.Heading
--- @field line integer
--- @field level integer   1-6
--- @field text string     heading text without markers or closing #s
--- @field stop integer    last line of the heading's section (subtree)
--- @field parent integer|nil  index of the enclosing heading

--- @class lattice.Item
--- @field line integer        line of the list marker
--- @field stop integer        last line of the item, children included
--- @field col integer         0-based byte column of the marker
--- @field marker string       "-", "*", "+", "1." or "1)"
--- @field ordered boolean
--- @field checkbox string|nil " " or "x"/"X"; nil without a task marker
--- @field text string         first line of the item's text
--- @field text_col integer    0-based byte column where `text` starts
--- @field parent integer|nil  index of the enclosing item
--- @field heading integer|nil index of the enclosing heading

--- Parses `lines` (a list of strings without newlines).
--- @return { headings: lattice.Heading[], items: lattice.Item[], front_matter: integer }|nil
--- @return string|nil err
function M.parse(lines)
  if not M.available() then
    return nil, "Neovim has no Markdown Tree-sitter parser (run :checkhealth vim.treesitter)"
  end
  local text = table.concat(lines, "\n") .. "\n"
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown")
  if not ok then
    return nil, "could not start the Markdown parser: " .. tostring(parser)
  end
  local root = parser:parse()[1]:root()

  local result = { headings = {}, items = {}, front_matter = 0 }

  local function node_text(node)
    return vim.treesitter.get_node_text(node, text)
  end

  local function visit(node, heading, item)
    local kind = node:type()
    if kind == "minus_metadata" then
      result.front_matter = last_line(node)
      return
    elseif kind == "fenced_code_block" or kind == "indented_code_block" or kind == "html_block" then
      return
    elseif kind == "section" then
      local first = node:named_child(0)
      if first and first:type() == "atx_heading" then
        local marker = first:named_child(0)
        local inline = first:field("heading_content")[1]
        if not inline then
          for child in first:iter_children() do
            if child:type() == "inline" then
              inline = child
            end
          end
        end
        local sr = first:range()
        result.headings[#result.headings + 1] = {
          line = sr + 1,
          level = HEADING_LEVEL[marker and marker:type()] or 1,
          text = heading_text(inline and node_text(inline)),
          stop = last_line(node),
          parent = heading,
        }
        heading = #result.headings
      end
    elseif kind == "list_item" then
      local sr, sc = node:range()
      local entry = { line = sr + 1, stop = last_line(node), col = sc, parent = item, heading = heading }
      local text_node
      for child in node:iter_children() do
        local child_kind = child:type()
        if child_kind:match("^list_marker_") then
          entry.marker = vim.trim(node_text(child))
          entry.ordered = child_kind == "list_marker_dot" or child_kind == "list_marker_parenthesis"
        elseif CHECKBOX[child_kind] then
          entry.checkbox = node_text(child):sub(2, 2)
        elseif child_kind == "paragraph" and not text_node then
          text_node = child
        end
      end
      local line = lines[sr + 1] or ""
      if text_node and text_node:range() == sr then
        local _, tc = text_node:range()
        entry.text_col = tc
        entry.text = vim.trim(line:sub(tc + 1))
      else
        entry.text_col = #line
        entry.text = ""
      end
      result.items[#result.items + 1] = entry
      item = #result.items
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child, heading, item)
      end
    end
  end

  visit(root, nil, nil)
  return result
end

return M
