local H = require('tests.helpers')
local config = require('nvim-typst.config')
local qf = require('nvim-typst.qf')

describe('qf', function()
  local root, main

  before_each(function()
    root = H.tmpdir()
    main = root .. '/main.typ'
  end)

  after_each(H.cleanup)

  describe('parse', function()
    it('reads the short diagnostic format', function()
      local items = qf.parse({
        'sub/ch.typ:1:9: error: unknown variable: oops',
        'main.typ:12:3: warning: unknown font family: nosuchfont',
      }, root, main)
      T.eq({
        { filename = root .. '/sub/ch.typ', lnum = 1, col = 9, type = 'E', text = 'unknown variable: oops' },
        { filename = main, lnum = 12, col = 3, type = 'W', text = 'unknown font family: nosuchfont' },
      }, items)
    end)

    it('turns the character column into a byte column', function()
      H.write(main, 'Leißa äöü #oops')
      local items = qf.parse({ 'main.typ:1:11: error: unknown variable: oops' }, root, main)
      T.eq(15, items[1].col)
    end)

    it('attributes a diagnostic without a location to the main file', function()
      local items = qf.parse({ 'error: failed to write PDF file (No such file or directory)' }, root, main)
      T.eq(
        { { filename = main, lnum = 0, type = 'E', text = 'failed to write PDF file (No such file or directory)' } },
        items
      )
    end)

    it('keeps an absolute path and resolves one outside the root', function()
      local items = qf.parse({ '/abs/x.typ:1:1: error: a', '../lib.typ:2:2: error: b' }, root, main)
      T.eq('/abs/x.typ', items[1].filename)
      T.eq(vim.fs.dirname(root) .. '/lib.typ', items[2].filename)
    end)

    it('resolves a package path into the package cache', function()
      local cache = H.tmpdir()
      local saved = vim.env.TYPST_PACKAGE_CACHE_PATH
      vim.env.TYPST_PACKAGE_CACHE_PATH = cache
      local items = qf.parse({ '@preview/cetz:0.3.1/src/draw.typ:4:2: error: boom' }, root, main)
      vim.env.TYPST_PACKAGE_CACHE_PATH = saved
      T.eq(cache .. '/preview/cetz/0.3.1/src/draw.typ', items[1].filename)
    end)

    it('skips the watcher chatter', function()
      local items = qf.parse({
        'watching main.typ',
        'writing to main.pdf',
        '',
        '[23:46:56] compiled with warnings in 5.3 ms',
        'hint: not a diagnostic of its own',
      }, root, main)
      T.eq({}, items)
    end)

    it('drops the messages matching ignore_filters', function()
      config.setup({ qf = { ignore_filters = { 'unknown font' } } })
      local items = qf.parse({ 'main.typ:1:1: warning: unknown font family: x', 'main.typ:2:1: error: y' }, root, main)
      T.eq(1, #items)
      T.eq('y', items[1].text)
    end)
  end)

  describe('update', function()
    local project

    before_each(function()
      project = H.project(main)
      project.last_output = {
        'main.typ:1:1: warning: first warning',
        'main.typ:2:1: error: an error',
        'main.typ:3:1: warning: second warning',
      }
    end)

    it('fills the quickfix list, errors first, and counts', function()
      local errors, warnings = qf.update(project, { silent = true })
      T.eq(1, errors)
      T.eq(2, warnings)
      local texts = vim.tbl_map(function(item)
        return item.text
      end, vim.fn.getqflist())
      T.eq({ 'an error', 'first warning', 'second warning' }, texts)
    end)

    it('hides warnings at level error, and tells so in the title', function()
      qf.set_level('error')
      qf.update(project, { silent = true })
      T.eq(1, #vim.fn.getqflist())
      T.matches('%(2 hidden%)', vim.fn.getqflist({ title = true }).title)
    end)

    it('opens the window on errors and closes it after a clean run', function()
      qf.update(project, { silent = true })
      T.ok(vim.fn.getqflist({ winid = true }).winid ~= 0)
      project.last_output = {}
      qf.update(project, { silent = true })
      T.eq(0, vim.fn.getqflist({ winid = true }).winid)
    end)

    it('does nothing when disabled', function()
      config.setup({ qf = { enabled = false } })
      T.eq(0, (qf.update(project)))
      T.eq({}, vim.fn.getqflist())
    end)
  end)

  describe('levels', function()
    it('cycles between error and warning', function()
      T.eq('warning', qf.level())
      T.eq('error', qf.cycle_level())
      T.eq('warning', qf.cycle_level())
    end)

    it('rejects an unknown level', function()
      qf.set_level('info')
      T.eq('warning', qf.level())
      T.ok(H.notified('unknown qf.level'))
    end)
  end)
end)
