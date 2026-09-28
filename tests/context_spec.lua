local H = require('tests.helpers')
local context = require('nvim-typst.context')

describe('context', function()
  local dir, project

  --- Write `lines` to the main file and show it in a buffer.
  ---@param lines string[]
  local function main(lines)
    H.write(project.main, lines)
    return H.buf(lines, { name = project.main })
  end

  ---@return string
  local function current_file()
    return vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  end

  before_each(function()
    H.need_parser()
    dir = H.tmpdir()
    project = H.project(dir .. '/main.typ')
    H.write(dir .. '/refs.bib', { '@book{knuth,', '  title = {TAOCP},', '}', '@misc{intro,', '}' })
    H.write(dir .. '/chap/intro.typ', { 'See #ref(<intro>).', '', '= Introduction <intro>' })
  end)

  after_each(function()
    H.cleanup()
    -- The files the menu opened.
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr):find(dir, 1, true) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  describe('find_label', function()
    it('finds where a label is attached, not where it is referred to', function()
      H.need_parser()
      T.eq({ 3, 15 }, { context.find_label({ 'See #ref(<a>).', '', '= Introduction <a>' }, 'a') })
      T.eq({ 1, 13 }, { context.find_label({ '#figure([x]) <fig:a>' }, 'fig:a') })
      T.eq({ nil }, { context.find_label({ '#cite(<a>)' }, 'a') })
    end)
  end)

  it('jumps from a reference to its label in an included file', function()
    main({ '#include "chap/intro.typ"', 'As @intro shows.', '#bibliography("refs.bib")' })
    H.cursor_at('intro shows')
    context.menu(project)
    T.eq(dir .. '/chap/intro.typ', current_file())
    T.eq({ 3, 15 }, vim.api.nvim_win_get_cursor(0))
  end)

  it('jumps from a reference without a label to the bibliography entry', function()
    main({ 'By @knuth[p. 3].', '#bibliography("refs.bib")' })
    H.cursor_at('p. 3')
    context.menu(project)
    T.eq(dir .. '/refs.bib', current_file())
    T.eq(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('prefers the bibliography entry for #cite', function()
    main({ '#include "chap/intro.typ"', '#cite(<intro>)', '#bibliography("refs.bib")' })
    H.cursor_at('intro>')
    context.menu(project)
    T.eq(dir .. '/refs.bib', current_file())
    T.eq(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('follows #cite(label("..."))', function()
    main({ '#cite(label("knuth"))', '#bibliography("refs.bib")' })
    H.cursor_at('knuth')
    context.menu(project)
    T.eq(dir .. '/refs.bib', current_file())
  end)

  it('finds an entry of a Hayagriva file', function()
    H.write(dir .. '/refs.yml', { 'other:', '  type: book', 'knuth:', '  type: book' })
    main({ '@knuth', '#bibliography(("refs.yml", "refs.bib"))' })
    context.menu(project)
    T.eq(dir .. '/refs.yml', current_file())
    T.eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('reports a key that is nowhere', function()
    main({ '@nothing', '#bibliography("refs.bib")' })
    context.menu(project)
    T.ok(H.notified('no label or bibliography entry nothing'))
    T.eq(project.main, current_file())
  end)

  it('opens an included file, from anywhere on the line', function()
    main({ '#include "chap/intro.typ"' })
    H.cursor_at('include')
    context.menu(project)
    T.eq(dir .. '/chap/intro.typ', current_file())
  end)

  it('opens the bibliography', function()
    main({ '#bibliography(("refs.bib",))' })
    H.cursor_at('refs')
    context.menu(project)
    T.eq(dir .. '/refs.bib', current_file())
  end)

  describe('packages', function()
    local cache

    before_each(function()
      cache = vim.env.TYPST_PACKAGE_CACHE_PATH
      vim.env.TYPST_PACKAGE_CACHE_PATH = dir .. '/cache'
    end)

    after_each(function()
      vim.env.TYPST_PACKAGE_CACHE_PATH = cache
    end)

    it('opens the entry point of an imported package', function()
      H.write(dir .. '/cache/preview/cetz/0.3.1/typst.toml', { '[package]', 'entrypoint = "src/lib.typ"' })
      H.write(dir .. '/cache/preview/cetz/0.3.1/src/lib.typ', { '// cetz' })
      main({ '#import "@preview/cetz:0.3.1": canvas' })
      H.cursor_at('cetz')
      context.menu(project)
      T.eq(dir .. '/cache/preview/cetz/0.3.1/src/lib.typ', current_file())
    end)

    it('says when a package is not downloaded yet', function()
      main({ '#import "@preview/cetz:0.3.1": canvas' })
      context.menu(project)
      T.ok(H.notified('@preview/cetz:0.3.1 is not downloaded yet'))
    end)
  end)

  it('has nothing to do in plain text without an LSP', function()
    main({ 'Just text.' })
    context.menu(project)
    T.ok(H.notified('nothing to do here'))
  end)
end)
