local H = require('tests.helpers')
local config = require('nvim-typst.config')
local fold = require('nvim-typst.fold')

--- The `foldexpr` value of every line of `lines`, with folding set up by
--- nvim-typst. `vim.treesitter.foldexpr` computes levels asynchronously in
--- newer Neovim versions, hence the wait.
---@param lines string[]
---@param opts table|nil `fold` configuration
---@return string[]
local function levels(lines, opts)
  config.setup({ fold = vim.tbl_extend('force', { enabled = true }, opts or {}) })
  local bufnr = H.buf(lines)
  fold.attach(bufnr)
  local function collect()
    local out = {}
    for lnum = 1, #lines do
      out[lnum] = tostring(vim.treesitter.foldexpr(lnum))
    end
    return out
  end
  collect()
  local out
  vim.wait(300, function()
    out = collect()
    return vim.iter(out):any(function(level)
      return level ~= '0'
    end)
  end, 10)
  return out
end

local DOC = {
  '#set page(width: 10cm)', --  1
  '= One', --  2
  'text', --  3
  '#figure(', --  4
  '  image("a.png"),', --  5
  ')', --  6
  '', --  7
  '== Sub', --  8
  '$', --  9
  '  x', -- 10
  '$', -- 11
  '', -- 12
  '= Two', -- 13
  'more', -- 14
}

describe('fold', function()
  before_each(H.need_parser)
  after_each(function()
    config.setup({})
    H.cleanup()
  end)

  it('folds sections, code and display math', function()
    T.eq({
      '0', -- #set does not fold
      '>1', -- = One
      '1',
      '>2', -- #figure(
      '2',
      '2',
      '1',
      '>2', -- == Sub, nested in the section
      '>3', -- $
      '3',
      '3',
      '2', -- the blank line folds with the subsection
      '>1', -- = Two, a fold of its own
      '1',
    }, levels(DOC))
  end)

  it('leaves out what is switched off', function()
    T.eq({
      '0',
      '0',
      '0',
      '0',
      '0',
      '0',
      '0',
      '0',
      '>1', -- only the math
      '1',
      '1',
      '0',
      '0',
      '0',
    }, levels(DOC, { sections = false, code = false }))
  end)

  it('folds raw blocks, block comments and runs of line comments', function()
    T.eq({
      '>1', -- ```py
      '1',
      '1',
      '>1', -- /*
      '1',
      '>1', -- first of three line comments
      '1',
      '1',
      '0',
      '0', -- a single line comment does not fold
    }, levels({ '```py', 'x = 1', '```', '/* a', ' b */', '// one', '// two', '// three', 'text', '// lone' }))
  end)

  it('does not fold the body of a section as content', function()
    T.eq({ '>1', '1', '1' }, levels({ '= A', 'x', 'y' }))
  end)

  it('sets the fold options of the window', function()
    config.setup({ fold = { enabled = true } })
    local bufnr = H.buf({ '= A', 'x' })
    fold.attach(bufnr)
    T.eq('expr', vim.wo.foldmethod)
    T.eq('v:lua.vim.treesitter.foldexpr()', vim.wo.foldexpr)
  end)
end)
