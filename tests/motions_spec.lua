local H = require('tests.helpers')
local motions = require('nvim-typst.motions')

local DOC = {
  '= One', -- 1
  'Some prose with $a + b$ in it.', -- 2
  '#emph[x] and #figure(image("a.png"))[body]', -- 3
  '', -- 4
  '== Sub', -- 5
  '// a comment', -- 6
  '$', -- 7
  '  x = y', -- 8
  '$', -- 9
  '', -- 10
  '= Two', -- 11
  '/* block', -- 12
  '   comment */', -- 13
  'end', -- 14
}

--- The cursor after running `fn` from `(row, col)`.
---@param row integer
---@param col integer
---@param fn function
---@return integer[]
local function jump_from(row, col, fn)
  H.cursor(row, col)
  fn()
  return vim.api.nvim_win_get_cursor(0)
end

describe('motions', function()
  before_each(function()
    H.need_parser()
    H.buf(DOC)
  end)

  after_each(H.cleanup)

  describe('sections', function()
    it(']] goes to the next heading, nested or not', function()
      T.eq({ 5, 0 }, jump_from(1, 0, motions.map[']]']))
      T.eq({ 11, 0 }, jump_from(5, 0, motions.map[']]']))
    end)

    it('[[ goes to the previous heading', function()
      T.eq({ 5, 0 }, jump_from(8, 2, motions.map['[[']))
      T.eq({ 1, 0 }, jump_from(5, 0, motions.map['[[']))
    end)

    it('stays put when there is no next heading', function()
      T.eq({ 11, 0 }, jump_from(11, 0, motions.map[']]']))
    end)

    it('][ goes to the end of a section, before the blank lines', function()
      -- `== Sub` ends at the closing `$`; `= One` contains it and ends there too.
      T.eq({ 9, 0 }, jump_from(5, 0, motions.map['][']))
      T.eq({ 14, 2 }, jump_from(11, 0, motions.map['][']))
    end)

    it('[] goes to the end of the previous section', function()
      T.eq({ 9, 0 }, jump_from(12, 0, motions.map['[]']))
    end)

    it('honours a count', function()
      -- Driven through the real mapping, because `v:count1` is only set for
      -- a keypress.
      H.cursor(1, 0)
      vim.api.nvim_feedkeys('2]]', 'x', false)
      T.eq(11, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('works as an operator target', function()
      H.cursor(11, 0)
      vim.api.nvim_feedkeys('d[[', 'x', false)
      T.eq('= Two', H.lines()[5])
    end)
  end)

  describe('math', function()
    it(']n and [n go to the opening $', function()
      T.eq({ 2, 16 }, jump_from(1, 0, motions.map[']n']))
      T.eq({ 7, 0 }, jump_from(2, 16, motions.map[']n']))
      T.eq({ 2, 16 }, jump_from(7, 0, motions.map['[n']))
    end)

    it(']N and [N go to the closing $', function()
      T.eq({ 2, 22 }, jump_from(1, 0, motions.map[']N']))
      T.eq({ 9, 0 }, jump_from(2, 22, motions.map[']N']))
      T.eq({ 2, 22 }, jump_from(8, 0, motions.map['[N']))
    end)
  end)

  describe('calls', function()
    it(']m and [m go to the # of a call in markup', function()
      T.eq({ 3, 0 }, jump_from(2, 0, motions.map[']m']))
      T.eq({ 3, 13 }, jump_from(3, 0, motions.map[']m']))
      T.eq({ 3, 0 }, jump_from(3, 13, motions.map['[m']))
    end)

    it(']M goes to the end of the whole call', function()
      T.eq({ 3, 7 }, jump_from(3, 0, motions.map[']M']))
      T.eq({ 3, 41 }, jump_from(3, 7, motions.map[']M']))
    end)

    it('ignores #let and #set', function()
      H.buf({ '#let x = 1', '#set page(width: 1cm)', '#f(x)' })
      T.eq({ 3, 0 }, jump_from(1, 0, motions.map[']m']))
    end)
  end)

  describe('comments', function()
    it(']/ and [/ go to the start of a comment', function()
      T.eq({ 6, 0 }, jump_from(1, 0, motions.map[']/']))
      T.eq({ 12, 0 }, jump_from(6, 0, motions.map[']/']))
      T.eq({ 6, 0 }, jump_from(12, 0, motions.map['[/']))
    end)

    it(']* goes to the end of a comment', function()
      T.eq({ 6, 11 }, jump_from(1, 0, motions.map[']*']))
      T.eq({ 13, 12 }, jump_from(7, 0, motions.map[']*']))
    end)
  end)

  describe('%', function()
    it('jumps between the $ of math', function()
      T.eq({ 2, 22 }, jump_from(2, 16, motions.map['%']))
      T.eq({ 2, 16 }, jump_from(2, 22, motions.map['%']))
      T.eq({ 9, 0 }, jump_from(7, 0, motions.map['%']))
    end)

    it('jumps between the markers of strong and emphasis', function()
      H.buf({ 'a *bold* and _emph_' })
      T.eq({ 1, 7 }, jump_from(1, 2, motions.map['%']))
      T.eq({ 1, 13 }, jump_from(1, 18, motions.map['%']))
    end)

    it('falls back to the built-in % for brackets', function()
      T.eq({ 3, 35 }, jump_from(3, 20, motions.map['%']))
    end)

    it('is inclusive as an operator target', function()
      H.buf({ 'a $x + y$ b' })
      H.cursor(1, 2)
      vim.api.nvim_feedkeys('d%', 'x', false)
      T.eq('a  b', H.lines()[1])
    end)

    it('does nothing as an operator target without a match', function()
      H.buf({ 'plain text' })
      H.cursor(1, 2)
      vim.api.nvim_feedkeys('d%', 'x', false)
      T.eq('plain text', H.lines()[1])
    end)
  end)
end)
