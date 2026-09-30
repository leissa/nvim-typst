local H = require('tests.helpers')
local config = require('nvim-typst.config')
local imaps = require('nvim-typst.imaps')

--- The typed sequences of the insert mappings `imaps` created in `bufnr`.
--- Filtered by description, because the plugin sets other insert mappings too.
---@param bufnr integer
---@return string[]
local function imap_lhss(bufnr)
  local out = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'i')) do
    if tostring(map.desc):match('^nvim%-typst: imap') then
      out[#out + 1] = map.lhs
    end
  end
  return out
end

--- Type `keys` in insert mode at the cursor and return the resulting line.
---@param keys string
---@return string
local function type_keys(keys)
  vim.api.nvim_feedkeys('i' .. keys, 'x', false)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
  return vim.api.nvim_get_current_line()
end

describe('imaps', function()
  before_each(function()
    config.setup({ lsp = { enabled = false } })
  end)

  after_each(H.cleanup)

  describe('lhs', function()
    it('prefixes the configured leader', function()
      T.eq('`a', imaps.lhs({ lhs = 'a', rhs = 'alpha' }))
    end)

    it('honours a per-entry leader', function()
      T.eq('@b', imaps.lhs({ leader = '@', lhs = 'b', style = 'bold' }))
    end)

    it('follows a changed leader', function()
      config.setup({ imaps = { leader = ';' } })
      T.eq(';a', imaps.lhs({ lhs = 'a', rhs = 'alpha' }))
    end)
  end)

  describe('rhs_label', function()
    it('shows the text of a plain entry', function()
      T.eq('alpha', imaps.rhs_label({ lhs = 'a', rhs = 'alpha' }))
    end)

    it('shows the shape of a style entry', function()
      T.eq('bold(<char>)', imaps.rhs_label({ lhs = 'b', style = 'bold' }))
    end)

    it('says so for a function', function()
      T.eq(
        '<function>',
        imaps.rhs_label({
          lhs = 'x',
          rhs = function()
            return 'x'
          end,
        })
      )
    end)
  end)

  describe('separate', function()
    it('keeps an expansion from running into a letter in front', function()
      T.eq(' alpha', imaps.separate('alpha', 'x', ''))
    end)

    it('keeps an expansion from running into a letter behind', function()
      T.eq('alpha ', imaps.separate('alpha', '', 'x'))
    end)

    it('leaves digits, spaces and brackets alone', function()
      T.eq('alpha', imaps.separate('alpha', '2', ')'))
      T.eq('alpha', imaps.separate('alpha', ' ', ' '))
      T.eq('bold(x)', imaps.separate('bold(x)', '(', 'y'))
    end)
  end)

  describe('entries', function()
    it('returns the configured list', function()
      config.setup({ imaps = { list = { { lhs = 'a', rhs = 'alpha' }, { lhs = 'b', rhs = 'beta' } } } })
      T.eq(2, #imaps.entries())
    end)

    it('takes a configured list verbatim rather than merging it into the default', function()
      config.setup({ imaps = { list = { { lhs = 'o', rhs = 'omicron' } } } })
      T.eq({ { lhs = 'o', rhs = 'omicron' } }, imaps.entries())
    end)

    it('leaves the disabled ones out', function()
      config.setup({
        imaps = {
          list = { { lhs = 'a', rhs = 'alpha' }, { lhs = 'b', rhs = 'beta' } },
          disabled = { 'a' },
        },
      })
      local entries = imaps.entries()
      T.eq(1, #entries)
      T.eq('b', entries[1].lhs)
    end)

    it('includes what add registered', function()
      config.setup({ imaps = { list = {} } })
      imaps.add({ lhs = 'oo', rhs = 'compose' })
      local entries = imaps.entries()
      T.eq(1, #entries)
      T.eq('compose', entries[1].rhs)
    end)

    it('has no duplicate lhs in the shipped list', function()
      local seen = {}
      for _, entry in ipairs(config.defaults.imaps.list) do
        local key = imaps.lhs(entry)
        T.falsy(seen[key], ('duplicate mapping %s'):format(key))
        seen[key] = true
      end
    end)

    it('ships only symbols the installed typst knows', function()
      local symbols = require('nvim-typst.conceal.symbols')
      for _, entry in ipairs(config.defaults.imaps.list) do
        local rhs = entry.rhs
        if entry.wrapper ~= 'trivial' and rhs and not vim.tbl_contains({ 'sqrt', 'bold' }, rhs) then
          T.ok(symbols.greek[rhs] or symbols.math[rhs], ('unknown symbol %s'):format(rhs))
        end
      end
    end)
  end)

  describe('wrappers', function()
    it("expands unconditionally for 'trivial'", function()
      T.eq(
        'x',
        imaps.wrappers.trivial('`t', function()
          return 'x'
        end)
      )
    end)

    it("expands only inside math for 'math'", function()
      H.need_parser()
      H.buf({ 'text $x$ text' })
      H.cursor(1, 6) -- inside the formula
      T.eq(
        'alpha',
        imaps.wrappers.math('`a', function()
          return 'alpha'
        end)
      )
      H.cursor(1, 1) -- in the prose
      T.eq(
        '`a',
        imaps.wrappers.math('`a', function()
          return 'alpha'
        end)
      )
    end)
  end)

  describe('attached mappings', function()
    before_each(function()
      config.setup({
        lsp = { enabled = false },
        imaps = {
          list = {
            { lhs = 'a', rhs = 'alpha' },
            { leader = '@', lhs = 'B', style = 'bb' },
            { lhs = '`', rhs = '``', wrapper = 'trivial' },
          },
        },
      })
    end)

    it('creates a buffer-local insert mapping per entry', function()
      local bufnr = H.buf({ 'text' })
      imaps.attach(bufnr)
      local lhss = imap_lhss(bufnr)
      table.sort(lhss)
      local expected = vim.tbl_map(function(entry)
        return imaps.lhs(entry)
      end, imaps.entries())
      table.sort(expected)
      T.eq(expected, lhss)
      T.contains(lhss, '`a')
      T.contains(lhss, '``')
    end)

    it('is set up when the plugin attaches to a buffer', function()
      local bufnr = H.buf({ 'text' })
      require('nvim-typst').attach(bufnr)
      T.contains(imap_lhss(bufnr), '`a')
    end)

    it('creates nothing when imaps are disabled', function()
      config.setup({ lsp = { enabled = false }, imaps = { enabled = false } })
      local bufnr = H.buf({ 'text' })
      imaps.attach(bufnr)
      T.eq(0, #imap_lhss(bufnr))
    end)

    it('expands inside a formula', function()
      H.need_parser()
      local bufnr = H.buf({ 'text $ $ text' })
      imaps.attach(bufnr)
      H.cursor(1, 6)
      T.eq('text $alpha $ text', type_keys('`a'))
    end)

    it('keeps the expansion apart from the letters around it', function()
      H.need_parser()
      local bufnr = H.buf({ '$xy$' })
      imaps.attach(bufnr)
      H.cursor(1, 2)
      T.eq('$x alpha y$', type_keys('`a'))
    end)

    it('wraps the next character for a style entry', function()
      H.need_parser()
      local bufnr = H.buf({ '$ = 1$' })
      imaps.attach(bufnr)
      H.cursor(1, 1)
      T.eq('$bb(R) = 1$', type_keys('@BR'))
    end)

    it('does not expand right after the closing dollar', function()
      H.need_parser()
      local bufnr = H.buf({ '$x$' })
      imaps.attach(bufnr)
      vim.api.nvim_feedkeys('A`a', 'x', false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
      T.eq('$x$`a', vim.api.nvim_get_current_line())
    end)

    it('expands in math that is not closed yet', function()
      H.need_parser()
      local bufnr = H.buf({ 'Let $x + ' })
      imaps.attach(bufnr)
      vim.api.nvim_feedkeys('A`a', 'x', false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
      T.eq('Let $x + alpha', vim.api.nvim_get_current_line())
    end)

    it('expands in unclosed math opened on an earlier line', function()
      H.need_parser()
      local bufnr = H.buf({ '$', '  x +' })
      imaps.attach(bufnr)
      H.cursor(2, 0)
      vim.api.nvim_feedkeys('A`a', 'x', false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
      T.eq('  x +alpha', vim.api.nvim_get_current_line())
    end)

    it('expands in unclosed math in a section, whatever errors are elsewhere', function()
      H.need_parser()
      local bufnr = H.buf({ '= Intro', '#let f(', '', 'Text.', '', '== More', 'Let $x + ' })
      imaps.attach(bufnr)
      H.cursor(7, 0)
      vim.api.nvim_feedkeys('A`a', 'x', false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
      T.eq('Let $x + alpha', vim.api.nvim_get_current_line())
    end)

    it('does not expand in prose after closed math in a document with errors', function()
      H.need_parser()
      local bufnr = H.buf({ '#let f(', '$x$ ' })
      imaps.attach(bufnr)
      H.cursor(2, 0)
      vim.api.nvim_feedkeys('A`a', 'x', false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
      T.eq('$x$ `a', vim.api.nvim_get_current_line())
    end)

    it('leaves the prose alone', function()
      H.need_parser()
      local bufnr = H.buf({ 'text  text' })
      imaps.attach(bufnr)
      H.cursor(1, 5)
      T.eq('text `a text', type_keys('`a'))
    end)

    it('inserts the leader typed twice as it is', function()
      H.need_parser()
      local bufnr = H.buf({ 'say  here' })
      imaps.attach(bufnr)
      H.cursor(1, 4)
      T.eq('say `` here', type_keys('``'))
    end)

    it('reaches buffers that were attached before the entry was added', function()
      local bufnr = H.buf({ 'text' })
      imaps.attach(bufnr)
      imaps.add({ lhs = 'oo', rhs = 'compose' })
      T.contains(imap_lhss(bufnr), '`oo')
    end)
  end)

  it(':TypstImaps lists the mappings', function()
    config.setup({ lsp = { enabled = false }, imaps = { list = { { lhs = 'a', rhs = 'alpha' } } } })
    H.buf({ 'text' })
    vim.cmd('TypstImaps')
    T.matches('^`a%s+%->%s+alpha%s+math$', vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
  end)
end)
