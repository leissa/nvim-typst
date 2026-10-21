--- CeTZ canvases, nvim-tex's TikZ pictures for Typst.
---
--- A canvas is a call of a function in `cetz.functions`, by its last name:
--- `cetz.canvas(...)`, `canvas(...)` after `#import "@preview/cetz:…": canvas`,
--- or `c.canvas(...)` with the package imported `as c`. It need not be
--- embedded in markup: the canvas of `#figure(cetz.canvas(...))` and of
--- `#let pic = cetz.canvas(...)` count too. A canvas in the body of a
--- function does not, since its parameters only have values in a call.
local config = require('nvim-typst.config')
local util = require('nvim-typst.util')

local M = {}

--- Is `node` a call of one of `cetz.functions`?
---@param node TSNode
---@param bufnr integer
---@return boolean
function M.is_canvas(node, bufnr)
  if node:type() ~= 'call' then
    return false
  end
  local callee = node:field('item')[1]
  if callee and callee:type() == 'field' then
    callee = callee:field('field')[1]
  end
  if not callee or callee:type() ~= 'ident' then
    return false
  end
  return vim.tbl_contains(config.get('cetz', 'functions') or {}, vim.treesitter.get_node_text(callee, bufnr))
end

--- Does `node` start the body of a function: `(x) => ...`, `#let f(x) = ...`?
---@param node TSNode
---@return boolean
local function is_function(node)
  if node:type() == 'lambda' then
    return true
  end
  local pattern = node:type() == 'let' and node:field('pattern')[1] or nil
  return pattern ~= nil and pattern:type() == 'call'
end

--- The outermost canvas around `node`, outside function bodies.
---@param node TSNode|nil
---@param bufnr integer
---@return TSNode|nil
function M.canvas(node, bufnr)
  local outer
  while node do
    if M.is_canvas(node, bufnr) then
      outer = node
    elseif is_function(node) then
      outer = nil
    end
    node = node:parent()
  end
  return outer
end

--- `:TypstCetzPreview`: compile the canvas under the cursor on its own and
--- show it, as `:TypstPreviewFragment` does.
---@param project table
function M.preview(project)
  local preview = require('nvim-typst.preview')
  local bufnr = vim.api.nvim_get_current_buf()
  local canvas = M.canvas(require('nvim-typst.ts').node_at_cursor(bufnr), bufnr)
  if not canvas then
    util.warn('not in a CeTZ canvas')
    return
  end
  preview.preview_node(project, canvas)
end

return M
