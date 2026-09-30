--- `:TypstPreviewFragment`: compile the math or code under the cursor on its
--- own, nvim-tex's `:TexTikzPreview` for Typst.
---
--- The fragment is set in the document it belongs to, cut down to it:
---
---   - the preamble of the main file, as it is in its buffer, so the fonts,
---     imports and `#set`/`#show` rules are all there -- except a
---     `#show: template`, which would typeset a title block along;
---   - the top-level `#let`, `#set`, `#show` and `#import` statements of the
---     buffer before the fragment;
---   - `#set page(width: auto, height: auto, ...)`, which crops the page to
---     the fragment.
---
--- It is compiled like `:TypstCompileSelected`, and shown below its last line
--- with snacks.nvim (`view.snacks`), or else in the viewer, which is kept
--- between runs.
local compiler = require('nvim-typst.compiler')
local ts = require('nvim-typst.ts')
local util = require('nvim-typst.util')

local M = {}

--- What to preview at the cursor: the outermost math around it, or else the
--- outermost embedded code that is not a definition, `#figure(...)` or
--- `#table(...)`.
---@param bufnr integer
---@return TSNode|nil
function M.fragment_at_cursor(bufnr)
  local node = ts.node_at_cursor(bufnr)
  local outer_math, outer_code
  while node do
    if ts.MATH[node:type()] then
      outer_math = node
    elseif node:type() == 'code' then
      outer_code = ts.definition(node) == nil and node or nil
    end
    node = node:parent()
  end
  return outer_math or outer_code
end

--- The definitions at the top level of `bufnr` (sections count) before row
--- `stop` (0-based), a `#show: template` left out, as `{ first, lines }`
--- chunks.
---@param bufnr integer
---@param stop integer
---@return table[]
function M.definitions(bufnr, stop)
  local root = ts.root(bufnr)
  if not root then
    return {}
  end
  local out = {}
  -- The parser nests everything after a heading in the `content` of its
  -- section, so the top level goes on in there.
  local function walk(parent)
    for node in parent:iter_children() do
      local sr, _, er, ec = node:range()
      if sr >= stop then
        return
      end
      local statement = ts.definition(node)
      if statement and not ts.is_template(statement) and (er < stop or (er == stop and ec == 0)) then
        out[#out + 1] = {
          first = sr + 1,
          lines = vim.split(vim.treesitter.get_node_text(node, bufnr), '\n', { plain = true }),
        }
      elseif ts.SECTION[node:type()] or (node:type() == 'content' and ts.SECTION[parent:type()]) then
        walk(node)
      end
    end
  end
  walk(root)
  return out
end

--- Compile `lines` (from line `first` of the current buffer on) cropped, with
--- the definitions before them.
---@param project table
---@param lines string[]
---@param first integer
function M.preview_lines(project, lines, first)
  local bufnr = vim.api.nvim_get_current_buf()
  compiler.compile_fragment(project, 'preview', lines, {
    bufnr = bufnr,
    first = first,
    preview = true,
    definitions = M.definitions(bufnr, first - 1),
  })
end

--- Compile the fragment under the cursor and show it.
---@param project table
function M.preview(project)
  local bufnr = vim.api.nvim_get_current_buf()
  local fragment = M.fragment_at_cursor(bufnr)
  if not fragment then
    util.warn('no math or code under the cursor')
    return
  end
  local sr = fragment:range()
  local text = vim.treesitter.get_node_text(fragment, bufnr)
  -- Embedded code in markup keeps its `#`; in math it has none to begin with.
  M.preview_lines(project, vim.split(text, '\n', { plain = true }), sr + 1)
end

return M
