local H = require('tests.helpers')
local config = require('nvim-typst.config')
local toc = require('nvim-typst.toc')

---@param entries table[]
---@param key string|nil
---@return any[]
local function pluck(entries, key)
  return vim.tbl_map(function(entry)
    return entry[key or 'title']
  end, entries)
end

describe('toc', function()
  before_each(H.need_parser)
  after_each(function()
    local win = toc.window()
    if win and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    end
    config.setup({})
    H.cleanup()
  end)

  it('lists the headings with their levels', function()
    local dir = H.tmpdir()
    local main = H.write(dir .. '/main.typ', {
      '#set page(width: 10cm)',
      '= First',
      'text',
      '== One',
      '=== Deeper',
      '= Second',
    })
    local entries = toc.build(H.project(main))
    T.eq({ 'First', 'One', 'Deeper', 'Second' }, pluck(entries))
    T.eq({ 1, 2, 3, 1 }, pluck(entries, 'level'))
    T.eq({ 2, 4, 5, 6 }, pluck(entries, 'lnum'))
  end)

  it('strips markup and the label from a title', function()
    local dir = H.tmpdir()
    local main = H.write(dir .. '/main.typ', { '= A *bold* and _fancy_ `raw` title <intro>' })
    T.eq({ 'A bold and fancy `raw` title' }, pluck(toc.build(H.project(main))))
  end)

  it('follows #include into another file', function()
    local dir = H.tmpdir()
    H.write(dir .. '/chapters/intro.typ', { '== From the include' })
    local main = H.write(dir .. '/main.typ', {
      '= Main',
      '#include "chapters/intro.typ"',
      '= Back in the main file',
    })
    local entries = toc.build(H.project(main))
    T.eq({ 'Main', 'include: chapters/intro.typ', 'From the include', 'Back in the main file' }, pluck(entries))
    T.eq({ 1, 2, 2, 1 }, pluck(entries, 'level'))
    T.eq(dir .. '/chapters/intro.typ', entries[3].file)
  end)

  it('resolves an absolute include against the project root', function()
    local dir = H.tmpdir()
    H.write(dir .. '/parts/a.typ', { '= Part A' })
    local main = H.write(dir .. '/src/main.typ', { '#include "/parts/a.typ"' })
    local entries = toc.build(H.project(main, { root = dir }))
    T.eq({ 'include: /parts/a.typ', 'Part A' }, pluck(entries))
  end)

  it('does not loop on circular includes', function()
    local dir = H.tmpdir()
    H.write(dir .. '/a.typ', { '= A', '#include "main.typ"' })
    local main = H.write(dir .. '/main.typ', { '= Main', '#include "a.typ"' })
    config.setup({ toc = { show_includes = false } })
    T.eq({ 'Main', 'A' }, pluck(toc.build(H.project(main))))
  end)

  it('lists TODO comments, and labels on request', function()
    local dir = H.tmpdir()
    local main = H.write(dir .. '/main.typ', {
      '= A',
      '// TODO: write this',
      '#figure(rect()) <fig:x>',
      '/* FIXME: a block */',
      '// not a TODO',
      '/* TODO: block */',
    })
    T.eq({ 'A', 'TODO: write this', 'FIXME: a block', 'TODO: block' }, pluck(toc.build(H.project(main))))
    config.setup({ toc = { show_labels = true, show_todos = false } })
    T.eq({ 'A', 'label: fig:x' }, pluck(toc.build(H.project(main))))
  end)

  it('prefers the contents of a loaded buffer', function()
    local dir = H.tmpdir()
    local main = H.write(dir .. '/main.typ', { '= On disk' })
    H.buf({ '= In the buffer' }, { name = main })
    T.eq({ 'In the buffer' }, pluck(toc.build(H.project(main))))
  end)

  it('opens on the current heading and jumps to an entry', function()
    local dir = H.tmpdir()
    local main = H.write(dir .. '/main.typ', { '= One', 'x', '= Two', 'y', 'z' })
    vim.cmd('edit ' .. vim.fn.fnameescape(main))
    local source_win = vim.api.nvim_get_current_win()
    H.cursor(4)
    toc.open(H.project(main))
    local win = toc.window()
    T.eq(win, vim.api.nvim_get_current_win())
    T.eq({ 'One', 'Two' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    T.eq(2, vim.api.nvim_win_get_cursor(0)[1])

    H.cursor(1)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
    T.eq(source_win, vim.api.nvim_get_current_win())
    T.eq(1, vim.api.nvim_win_get_cursor(0)[1])
    T.eq(nil, toc.window())
    vim.cmd('bwipeout!')
  end)

  it('toggles', function()
    local dir = H.tmpdir()
    local main = H.write(dir .. '/main.typ', { '= One' })
    local project = H.project(main)
    toc.toggle(project)
    T.ok(toc.window())
    toc.toggle(project)
    T.eq(nil, toc.window())
  end)
end)
