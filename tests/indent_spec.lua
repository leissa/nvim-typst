local H = require('tests.helpers')
local config = require('nvim-typst.config')
local indent = require('nvim-typst.indent')

--- Reindent `lines` from scratch (every line flush left first) with `=`.
---@param lines string[]
---@return string[]
local function reindent(lines)
  local flat = vim.tbl_map(function(line)
    return (line:gsub('^%s+', ''))
  end, lines)
  local bufnr = H.buf(flat)
  vim.bo[bufnr].shiftwidth = 2
  vim.bo[bufnr].expandtab = true
  indent.attach(bufnr)
  vim.cmd('silent normal! gg=G')
  return H.lines(bufnr)
end

--- The indent `indentexpr` computes for the (empty) line `lnum` of `lines`,
--- as after `o` on the line above.
---@param lines string[]
---@param lnum integer
---@return integer
local function indent_at(lines, lnum)
  local bufnr = H.buf(lines)
  vim.bo[bufnr].shiftwidth = 2
  return indent.get(lnum, bufnr)
end

describe('indent', function()
  before_each(H.need_parser)
  after_each(H.cleanup)

  it('indents multi-line arguments, content and code blocks', function()
    local doc = {
      '#figure(',
      '  image("a.png"),',
      '  caption: [',
      '    A caption',
      '  ],',
      ')',
      '#let f(x) = {',
      '  if x > 0 {',
      '    x',
      '  } else {',
      '    -x',
      '  }',
      '}',
    }
    T.eq(doc, reindent(doc))
  end)

  it('indents display math', function()
    local doc = { 'Text', '$', '  x + y', '$', '$ a', '  = b $' }
    T.eq(doc, reindent(doc))
  end)

  it('aligns a closing delimiter with the line that opened it', function()
    local doc = { '#box(width: 1cm)[', '  x', ']', '#set text(', '  size: 10pt)' }
    T.eq(doc, reindent(doc))
  end)

  it('ignores brackets in markup, strings and comments', function()
    local doc = { 'A [bracket and (paren', 'text', '#let s = "(["', '// {', 'more' }
    T.eq(doc, reindent(doc))
  end)

  it('leaves the structure of lists as it is', function()
    local doc = {
      '- one',
      '  continued',
      '  - nested',
      '    also nested',
      '  - second nested',
      '- two',
      '+ enum',
      '/ Term: description',
      '  more description',
      'A paragraph after the list.',
    }
    local bufnr = H.buf(doc)
    vim.bo[bufnr].shiftwidth = 2
    -- 0.10 rewrites a kept indent, which would turn the spaces into a tab.
    vim.bo[bufnr].expandtab = true
    indent.attach(bufnr)
    vim.cmd('silent normal! gg=G')
    T.eq(doc, H.lines(bufnr))
  end)

  it('keeps raw blocks as they are', function()
    local doc = { '#block[', '  ```py', 'def f():', '        return 1', '  ```', ']' }
    local bufnr = H.buf(doc)
    vim.bo[bufnr].shiftwidth = 2
    -- 0.10 rewrites a kept indent, which would turn the spaces into a tab.
    vim.bo[bufnr].expandtab = true
    indent.attach(bufnr)
    vim.cmd('silent normal! gg=G')
    T.eq(doc, H.lines(bufnr))
  end)

  it('indents after an unfinished opening delimiter', function()
    T.eq(2, indent_at({ '#figure(', '' }, 2))
    T.eq(2, indent_at({ '#let x = {', '' }, 2))
    T.eq(2, indent_at({ '#block[', '  text', '', '' }, 4))
  end)

  it('starts a new item after an item', function()
    T.eq(0, indent_at({ '- one', '' }, 2))
    T.eq(2, indent_at({ '- one', '  - nested', '' }, 3))
    T.eq(0, indent_at({ '- one', '  continued', '' }, 3))
    T.eq(0, indent_at({ '- one', '  - nested', '', '' }, 4))
  end)

  it('is installed when the buffer is attached', function()
    config.setup({})
    local bufnr = H.buf({ '= A' })
    require('nvim-typst').attach(bufnr)
    T.matches('nvim%-typst%.indent', vim.bo[bufnr].indentexpr)
  end)

  it('is left to indent/typst.vim when disabled', function()
    config.setup({ indent = { enabled = false } })
    local bufnr = H.buf({ '= A' })
    require('nvim-typst').attach(bufnr)
    T.ok(not vim.bo[bufnr].indentexpr:match('nvim%-typst'))
    config.setup({})
  end)
end)
