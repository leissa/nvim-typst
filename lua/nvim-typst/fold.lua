--- Typst folding.
---
--- Neovim's `vim.treesitter.foldexpr()` already does the hard part -- it
--- computes fold levels asynchronously and updates them incrementally as the
--- tree changes -- but it needs a `folds` query, and Neovim ships none for
--- Typst. nvim-typst installs its own with `vim.treesitter.query.set`, which
--- also takes precedence over the one nvim-treesitter may provide.
---
--- The query itself is fixed; what it folds is decided by predicates that
--- read the `fold` options when the tree is matched. Neovim 0.10 memoizes
--- `query.get`, so a query rebuilt from changed options would never be seen,
--- and this way a change needs no more than a refold.
---
--- A section already runs up to the next heading in the tree, blank lines
--- included, so it folds as it is. A run of `//` line comments is not a
--- single node, though, and gets its range from a directive.
local config = require('nvim-typst.config')
local util = require('nvim-typst.util')

local M = {}

--- Handlers see every node of a capture (`all`), and replace any earlier
--- registration of the same name (`force`), so a reload works.
local HANDLER_OPTS = { force = true, all = true }

--- The node captured as `id` in a predicate or directive's `match`. With
--- `all = true` that is a list of nodes; the last one is what we want.
---@param match table
---@param id integer
---@return TSNode|nil
local function captured(match, id)
  local node = match[id]
  if type(node) == 'table' then
    node = node[#node]
  end
  return node
end

---@param metadata table
---@param id integer
---@param range integer[]
local function set_range(metadata, id, range)
  metadata[id] = metadata[id] or {}
  metadata[id].range = range
end

---@param node TSNode|nil
---@param source integer|string
---@return boolean
local function is_line_comment(node, source)
  return node ~= nil and node:type() == 'comment' and vim.startswith(vim.treesitter.get_node_text(node, source), '//')
end

local registered = false

local function register()
  if registered then
    return
  end
  registered = true

  -- `(#nvim-typst-fold? "sections")`: is this kind of fold switched on?
  vim.treesitter.query.add_predicate('nvim-typst-fold?', function(_, _, _, predicate)
    return config.get('fold', predicate[2]) == true
  end, HANDLER_OPTS)

  -- `(#nvim-typst-delimited? @fold)`: is this `[ ... ]` rather than the body
  -- of a section, which is a `content` node too?
  vim.treesitter.query.add_predicate('nvim-typst-delimited?', function(match, _, _, predicate)
    local node = captured(match, predicate[2])
    local parent = node and node:parent()
    return node ~= nil and not (parent and parent:type() == 'section')
  end, HANDLER_OPTS)

  -- `(#nvim-typst-comment-run? @fold)`: is this `//` comment the first of a
  -- run of them on consecutive lines? Only that one folds, over the run.
  vim.treesitter.query.add_predicate('nvim-typst-comment-run?', function(match, _, source, predicate)
    local node = captured(match, predicate[2])
    if not is_line_comment(node, source) then
      return false
    end
    ---@cast node TSNode
    local prev = node:prev_named_sibling()
    return not (is_line_comment(prev, source) and prev:end_() == node:start() - 1)
  end, HANDLER_OPTS)

  vim.treesitter.query.add_directive('nvim-typst-comment-run!', function(match, _, source, predicate, metadata)
    local id = predicate[2]
    local node = captured(match, id)
    if not node then
      return
    end
    local last = node
    local next_node = last:next_named_sibling()
    while is_line_comment(next_node, source) and next_node:start() == last:end_() + 1 do
      last = next_node
      next_node = last:next_named_sibling()
    end
    local srow, scol = node:start()
    local erow, ecol = last:end_()
    set_range(metadata, id, { srow, scol, erow, ecol })
  end, HANDLER_OPTS)
end

--- The `folds` query.
---@return string
function M.query_source()
  return table.concat({
    '((section) @fold (#nvim-typst-fold? "sections"))',
    '([(block) (group) (content)] @fold (#nvim-typst-fold? "code") (#nvim-typst-delimited? @fold))',
    '((math) @fold (#nvim-typst-fold? "math"))',
    '((raw_blck) @fold (#nvim-typst-fold? "raw"))',
    '((comment) @fold (#nvim-typst-fold? "comments") (#lua-match? @fold "^/%*"))',
    '((comment) @fold (#nvim-typst-fold? "comments") (#nvim-typst-comment-run? @fold)'
      .. ' (#nvim-typst-comment-run! @fold))',
  }, '\n')
end

local installed = false

--- Install the `folds` query, once.
---@return boolean ok
function M.install()
  if installed then
    return true
  end
  register()
  local ok, err = pcall(vim.treesitter.query.set, 'typst', 'folds', M.query_source())
  if not ok then
    util.error('could not install the fold query: ' .. tostring(err))
    return false
  end
  installed = true
  return true
end

--- Fold `bufnr` in the window showing it. 'foldmethod' and 'foldexpr' are
--- window-local; Neovim carries them over to windows that open the buffer
--- later.
---@param bufnr integer
function M.attach(bufnr)
  if not M.install() then
    return
  end
  vim.api.nvim_buf_call(bufnr, function()
    vim.opt_local.foldmethod = 'expr'
    vim.opt_local.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
  end)
end

return M
