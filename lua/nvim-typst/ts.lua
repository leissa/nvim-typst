--- Tree-sitter helpers.
---
--- Everything structural in this plugin is driven from the `typst` parse
--- tree (https://github.com/uben0/tree-sitter-typst, the grammar
--- nvim-treesitter installs) rather than from regular expressions or syntax
--- groups.
local config = require('nvim-typst.config')
local util = require('nvim-typst.util')

local M = {}

--- `= Heading` and everything up to the next heading of the same level. The
--- parser nests them, so a `==` section is a child of its `=` section.
M.SECTION = { section = true }

--- `$ ... $`, inline or displayed.
M.MATH = { math = true }

--- `#...` and everything else in code mode.
M.CODE = { code = true }

--- Raw text, as `` `x` `` or in a fenced block.
M.RAW = { raw_span = true, raw_blck = true }

--- `// ...` and `/* ... */`.
M.COMMENT = { comment = true }

local warned = {}

--- Get the Typst parser for `bufnr`, or nil when it is unavailable.
---@param bufnr integer|nil
---@return vim.treesitter.LanguageTree|nil
function M.parser(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not config.get('treesitter', 'enabled') then
    return nil
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'typst')
  if not ok or not parser then
    if config.get('treesitter', 'warn_missing_parser') and not warned[bufnr] then
      warned[bufnr] = true
      util.warn("the 'typst' tree-sitter parser is not available; run :TSInstall typst")
    end
    return nil
  end
  return parser
end

---@param bufnr integer|nil
---@return TSNode|nil
function M.root(bufnr)
  local parser = M.parser(bufnr)
  if not parser then
    return nil
  end
  local trees = parser:parse()
  return trees and trees[1] and trees[1]:root() or nil
end

--- The smallest named node covering the cursor.
---
--- `vim.treesitter.get_node` needs an already parsed tree, which is not
--- guaranteed right after a buffer is created, so the root is fetched (and
--- thereby parsed) explicitly here.
---@param bufnr integer|nil
---@param pos integer[]|nil `{ row (1-indexed), col (0-indexed) }`
---@return TSNode|nil
function M.node_at_cursor(bufnr, pos)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local root = M.root(bufnr)
  if not root then
    return nil
  end

  pos = pos or vim.api.nvim_win_get_cursor(0)
  local row = math.max(0, pos[1] - 1)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local col = math.max(0, math.min(pos[2], math.max(0, #line - 1)))

  return root:named_descendant_for_range(row, col, row, col)
end

--- Walk up from `node` to the first ancestor (inclusive) matching `types`.
---@param node TSNode|nil
---@param types table<string, boolean>|fun(node: TSNode): boolean
---@param predicate fun(node: TSNode): boolean|nil extra filter
---@return TSNode|nil
function M.ancestor(node, types, predicate)
  local matches = type(types) == 'function' and types or function(n)
    return types[n:type()] == true
  end
  while node do
    if matches(node) and (not predicate or predicate(node)) then
      return node
    end
    node = node:parent()
  end
  return nil
end

--- Collect every node matching `types`, in document order.
---@param bufnr integer|nil
---@param types table<string, boolean>|fun(node: TSNode): boolean
---@return TSNode[]
function M.collect(bufnr, types)
  local root = M.root(bufnr)
  if not root then
    return {}
  end
  local matches = type(types) == 'function' and types or function(n)
    return types[n:type()] == true
  end

  local out = {}
  local function walk(node)
    if matches(node) then
      out[#out + 1] = node
    end
    for child in node:iter_children() do
      if child:named() then
        walk(child)
      end
    end
  end
  walk(root)
  return out
end

--- Is the cursor (or `pos`) inside math?
---@param bufnr integer|nil
---@param pos integer[]|nil
---@return boolean
function M.in_math(bufnr, pos)
  return M.ancestor(M.node_at_cursor(bufnr, pos), M.MATH) ~= nil
end

--- The level of a section: 1 for `=`, 2 for `==`, ...
---@param section TSNode
---@param bufnr integer|nil
---@return integer
function M.section_level(section, bufnr)
  local heading = section:named_child(0)
  if not heading or heading:type() ~= 'heading' then
    return 0
  end
  local text = vim.treesitter.get_node_text(heading, bufnr or 0)
  return #(text:match('^%s*(=+)') or '')
end

return M
