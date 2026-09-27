local H = require('tests.helpers')
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')

--- A buffer for `path`, with the file's contents.
---@param path string
---@return integer
local function open(path)
  return H.buf(vim.fn.readfile(path), { name = path })
end

describe('project', function()
  local dir

  before_each(function()
    dir = H.tmpdir()
  end)

  after_each(H.cleanup)

  describe('dependencies', function()
    it('finds #include and #import, relative to the file', function()
      local deps = project_mod.dependencies({
        '#include "chapters/intro.typ"',
        '#import "lib.typ": *',
        '#import "@preview/cetz:0.3.1"',
        '// #include "commented.typ"',
        '#link("https://typst.app")[x] #include "after-url.typ"',
      }, dir .. '/main.typ', dir)
      T.eq({ dir .. '/chapters/intro.typ', dir .. '/lib.typ', dir .. '/after-url.typ' }, deps)
    end)

    it('resolves an absolute path against the project root', function()
      local deps = project_mod.dependencies({ '#include "/common/a.typ"' }, dir .. '/sub/main.typ', dir)
      T.eq({ dir .. '/common/a.typ' }, deps)
    end)

    it('finds an include in code mode, without a hash', function()
      local deps = project_mod.dependencies({ '#{ include "a.typ" }' }, dir .. '/main.typ', dir)
      T.eq({ dir .. '/a.typ' }, deps)
    end)
  end)

  describe('find_root', function()
    it('stops at the nearest root marker', function()
      H.write(dir .. '/typst.toml', '')
      vim.fn.mkdir(dir .. '/a/b', 'p')
      T.eq(dir, project_mod.find_root(dir .. '/a/b'))
    end)

    it('falls back to the directory itself', function()
      config.setup({ root_markers = { 'no-such-marker' } })
      T.eq(dir, project_mod.find_root(dir))
    end)
  end)

  describe('detect_main', function()
    it('makes a file nothing includes its own main file', function()
      local main = H.write(dir .. '/alone.typ', '= Hello')
      T.eq(main, project_mod.detect_main(open(main)))
    end)

    it('finds the file including this one', function()
      local main = H.write(dir .. '/main.typ', '#include "chapters/intro.typ"')
      local intro = H.write(dir .. '/chapters/intro.typ', '= Intro')
      T.eq(main, project_mod.detect_main(open(intro)))
    end)

    it('follows a chain of includes to the top', function()
      local main = H.write(dir .. '/thesis.typ', '#include "parts/one.typ"')
      H.write(dir .. '/parts/one.typ', '#include "one/chapter.typ"')
      local chapter = H.write(dir .. '/parts/one/chapter.typ', '= Chapter')
      T.eq(main, project_mod.detect_main(open(chapter)))
    end)

    it('does not loop on files including each other', function()
      local a = H.write(dir .. '/a.typ', '#import "b.typ"')
      H.write(dir .. '/b.typ', '#import "a.typ"')
      local main = project_mod.detect_main(open(a))
      T.ok(main == a or main == dir .. '/b.typ')
    end)

    it('honours a // !TYPST main directive', function()
      H.write(dir .. '/book.typ', '= Book')
      local chapter = H.write(dir .. '/chapter.typ', { '// !TYPST main = book', '= Chapter' })
      T.eq(dir .. '/book.typ', project_mod.detect_main(open(chapter)))
    end)

    it('prefers b:typst_main and then main_file', function()
      local file = H.write(dir .. '/x.typ', '// !TYPST main = y.typ')
      local bufnr = open(file)
      config.setup({ main_file = dir .. '/configured.typ' })
      T.eq(dir .. '/configured.typ', project_mod.detect_main(bufnr))
      vim.b[bufnr].typst_main = dir .. '/override.typ'
      T.eq(dir .. '/override.typ', project_mod.detect_main(bufnr))
    end)

    it('takes main_file as a function', function()
      local bufnr = open(H.write(dir .. '/x.typ', ''))
      config.setup({
        main_file = function(b)
          return b == bufnr and dir .. '/fn.typ' or nil
        end,
      })
      T.eq(dir .. '/fn.typ', project_mod.detect_main(bufnr))
    end)

    it('prefers an open project including the file', function()
      local main = H.write(dir .. '/elsewhere/main.typ', '#include "../shared.typ"')
      local shared = H.write(dir .. '/shared.typ', 'shared')
      project_mod.get(open(main))
      T.eq(main, project_mod.detect_main(open(shared)))
    end)
  end)

  describe('get', function()
    it('shares one project between the buffers of a document', function()
      local main = H.write(dir .. '/main.typ', '#include "ch.typ"')
      local ch = H.write(dir .. '/ch.typ', 'x')
      local a = project_mod.get(open(main))
      local b = project_mod.get(open(ch))
      T.ok(a == b)
      T.eq(2, #project_mod.buffers(a))
    end)

    it('fills in the directories', function()
      H.write(dir .. '/typst.toml', '')
      local main = H.write(dir .. '/src/main.typ', '')
      local project = project_mod.get(open(main))
      T.eq(dir, project.root)
      T.eq(dir .. '/src', project.dir)
      T.eq(dir .. '/src', project.out_dir)
      T.eq(dir .. '/src/main.pdf', project_mod.output_file(project))
    end)

    it('puts the PDF into out_dir, relative to the main file', function()
      config.setup({ compiler = { typst = { out_dir = 'build' } } })
      local project = project_mod.get(open(H.write(dir .. '/main.typ', '')))
      T.eq(dir .. '/build', project.out_dir)
      T.ok(project.out_dir_set)
    end)

    it('redetects after invalidate and forget', function()
      local file = H.write(dir .. '/x.typ', '')
      local bufnr = open(file)
      local project = project_mod.get(bufnr)
      vim.b[bufnr].typst_main = dir .. '/other.typ'
      T.eq(file, project_mod.get(bufnr).main)
      project_mod.invalidate(bufnr)
      T.eq(dir .. '/other.typ', project_mod.get(bufnr).main)
      project_mod.forget(project)
      T.eq(nil, project_mod.projects[file])
    end)
  end)
end)
