local H = require('tests.helpers')
local config = require('nvim-typst.config')
local nvim_typst = require('nvim-typst')

--- Every command `nvim-typst.commands` is meant to register: nvim-tex's,
--- as far as Typst has them.
local COMMANDS = {
  'TypstCite',
  'TypstClean',
  'TypstCompile',
  'TypstCompileOutput',
  'TypstCompileSS',
  'TypstCompileSelected',
  'TypstContextMenu',
  'TypstCountLetters',
  'TypstCountWords',
  'TypstErrors',
  'TypstForwardSearch',
  'TypstInfo',
  'TypstQfLevel',
  'TypstReload',
  'TypstReloadState',
  'TypstStatus',
  'TypstStatusAll',
  'TypstStop',
  'TypstStopAll',
  'TypstToc',
  'TypstTocToggle',
  'TypstToggleMain',
  'TypstView',
  'TypstViewClose',
}

--- The leader keys, which are nvim-tex's.
local LEADER_KEYS =
  { 'l', 'L', 'S', 'k', 'K', 'v', 'e', 'E', 'o', 'c', 'C', 't', 'T', 'g', 'G', 'i', 'I', 'a', 'b', 's', 'x', 'X' }

---@param bufnr integer
---@return string[]
local function normal_lhss(bufnr)
  return vim.tbl_map(function(map)
    return map.lhs
  end, vim.api.nvim_buf_get_keymap(bufnr, 'n'))
end

describe('plugin', function()
  before_each(function()
    -- No tinymist in the test environment, and no warning about it either.
    config.setup({ lsp = { enabled = false } })
  end)

  after_each(H.cleanup)

  describe('highlighting', function()
    before_each(H.need_parser)

    it('keeps the regex syntax when there is no highlight query', function()
      local get = vim.treesitter.query.get
      vim.treesitter.query.get = function(lang, name)
        if name == 'highlights' then
          return nil
        end
        return get(lang, name)
      end
      local ok, err = pcall(function()
        local bufnr = H.buf({ '= A' })
        nvim_typst.attach(bufnr)
        T.falsy(vim.treesitter.highlighter.active[bufnr])
        T.eq('typst', vim.bo[bufnr].syntax)
      end)
      vim.treesitter.query.get = get
      assert(ok, err)
    end)

    it('starts tree-sitter highlighting when there is one', function()
      local get = vim.treesitter.query.get
      vim.treesitter.query.get = function(lang, name)
        if name == 'highlights' then
          return vim.treesitter.query.parse('typst', '(text) @spell')
        end
        return get(lang, name)
      end
      local ok, err = pcall(function()
        local bufnr = H.buf({ '= A' })
        nvim_typst.attach(bufnr)
        T.ok(vim.treesitter.highlighter.active[bufnr])
        vim.treesitter.stop(bufnr)
      end)
      vim.treesitter.query.get = get
      assert(ok, err)
    end)

    it('leaves highlighting alone with highlight = false', function()
      config.setup({ lsp = { enabled = false }, treesitter = { highlight = false } })
      local bufnr = H.buf({ '= A' })
      T.falsy(vim.treesitter.highlighter.active[bufnr])
    end)
  end)

  describe('commands', function()
    it('are all registered by the bootstrap', function()
      local registered = vim.api.nvim_get_commands({})
      for _, name in ipairs(COMMANDS) do
        T.ok(registered[name], ('missing command :%s'):format(name))
      end
      local names = require('nvim-typst.commands').names()
      table.sort(names)
      T.eq(COMMANDS, names)
    end)

    it('all carry a description', function()
      local registered = vim.api.nvim_get_commands({})
      for _, name in ipairs(COMMANDS) do
        -- Up to Neovim 0.12 the description of a Lua command is reported as
        -- its `definition`; 0.13 reports it separately as `desc` and leaves
        -- `definition` empty.
        local command = registered[name]
        local description = command and (command.desc or command.definition)
        T.ok(description ~= nil and description ~= '', name)
      end
    end)

    it(':TypstQfLevel cycles the quickfix level', function()
      local qf = require('nvim-typst.qf')
      H.buf({ '= A' }, { name = H.tmpdir() .. '/a.typ' })
      qf.set_level('error')
      vim.cmd('TypstQfLevel')
      T.eq('warning', qf.level())
      vim.cmd('TypstQfLevel error')
      T.eq('error', qf.level())
    end)

    it(':TypstToggleMain switches between the detected main and the buffer', function()
      local dir = H.tmpdir()
      local main = H.write(dir .. '/main.typ', '#include "ch.typ"')
      local ch = H.write(dir .. '/ch.typ', 'x')
      local bufnr = H.buf(vim.fn.readfile(ch), { name = ch })
      local project_mod = require('nvim-typst.project')
      T.eq(main, project_mod.get(bufnr).main)
      vim.cmd('TypstToggleMain')
      T.eq(ch, project_mod.get(bufnr).main)
      vim.cmd('TypstToggleMain')
      T.eq(main, project_mod.get(bufnr).main)
    end)
  end)

  describe('attaching', function()
    it("sets nvim-tex's leader mappings on a typst buffer", function()
      local bufnr = H.buf({ '= A' })
      local lhss = normal_lhss(bufnr)
      local leader = vim.g.maplocalleader
      for _, key in ipairs(LEADER_KEYS) do
        T.contains(lhss, leader .. key)
      end
    end)

    it('fires the NvimTypstAttach autocmd', function()
      local seen = nil
      vim.api.nvim_create_autocmd('User', {
        pattern = 'NvimTypstAttach',
        once = true,
        callback = function(args)
          seen = args.data.bufnr
        end,
      })
      local bufnr = H.buf({ 'text' })
      T.eq(bufnr, seen)
    end)

    it('leaves a buffer of another filetype alone', function()
      local bufnr = H.buf({ 'print("hi")' }, { filetype = 'lua' })
      T.excludes(normal_lhss(bufnr), vim.g.maplocalleader .. 'l')
    end)

    it('sets no mappings with mappings.enabled = false', function()
      config.setup({ lsp = { enabled = false }, mappings = { enabled = false } })
      local bufnr = H.buf({ 'text' })
      T.excludes(normal_lhss(bufnr), vim.g.maplocalleader .. 'l')
    end)

    it('maps ]] in insert mode only with mappings.insert_close', function()
      local function insert_lhss(bufnr)
        return vim.tbl_map(function(map)
          return map.lhs
        end, vim.api.nvim_buf_get_keymap(bufnr, 'i'))
      end
      config.setup({ lsp = { enabled = false } })
      T.excludes(insert_lhss(H.buf({ 'text' })), ']]')
      config.setup({ lsp = { enabled = false }, mappings = { insert_close = true } })
      T.contains(insert_lhss(H.buf({ 'text' })), ']]')
    end)

    it('honours mappings.prefix', function()
      config.setup({ lsp = { enabled = false }, mappings = { prefix = '<leader>t' } })
      local bufnr = H.buf({ 'text' })
      T.contains(normal_lhss(bufnr), vim.g.mapleader .. 'tl')
    end)

    it('compiles on save with build_on_save', function()
      H.need_typst()
      config.setup({ lsp = { enabled = false }, compiler = { build_on_save = true, silent = true } })
      local dir = H.tmpdir()
      local bufnr = H.buf({ '= Saved' }, { name = dir .. '/saved.typ' })
      vim.cmd('silent write')
      local project = require('nvim-typst.project').get(bufnr)
      H.wait(function()
        return project.last_status == 'success'
      end, 20000, 'the compilation')
      T.ok(vim.uv.fs_stat(dir .. '/saved.pdf'))
    end)
  end)

  describe('setup', function()
    it('applies the options and stays callable twice', function()
      nvim_typst.setup({ qf = { height = 12 } })
      T.eq(12, config.get('qf', 'height'))
      nvim_typst.setup({})
      T.eq(8, config.get('qf', 'height'))
    end)

    it('attaches to the filetypes it is given', function()
      nvim_typst.setup({ filetypes = { 'typst', 'typstx' }, lsp = { enabled = false } })
      local bufnr = H.buf({ '= A' }, { filetype = 'typstx' })
      T.contains(normal_lhss(bufnr), vim.g.maplocalleader .. 'l')
    end)
  end)

  describe('health', function()
    it('runs through without raising', function()
      local checked = {}
      local health = vim.health
      -- `vim.health.*` only works inside a real `:checkhealth` buffer.
      vim.health = setmetatable({}, {
        __index = function(_, key)
          return function(...)
            checked[#checked + 1] = { key, ... }
          end
        end,
      })
      local ok, err = pcall(require('nvim-typst.health').check)
      vim.health = health
      T.ok(ok, tostring(err))
      T.ok(#checked > 0)
    end)
  end)

  describe('info', function()
    it(':TypstInfo! lists the documents and the configuration', function()
      local dir = H.tmpdir()
      H.write(dir .. '/ch.typ', 'x')
      local main = H.write(dir .. '/main.typ', '#include "ch.typ"')
      H.buf(vim.fn.readfile(main), { name = main })
      vim.cmd('TypstInfo!')
      local text = H.text()
      T.matches('main file:', text)
      T.matches('ch%.typ', text)
      T.matches('configuration', text)
    end)
  end)
end)
