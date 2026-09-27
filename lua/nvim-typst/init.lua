--- nvim-typst: a Neovim-only Typst plugin built on LSP and tree-sitter.
---
--- Usage:
---   require('nvim-typst').setup({ ... })
--- Calling `setup` is optional; the defaults apply as soon as the plugin is
--- loaded. See `:help nvim-typst`.
local config = require('nvim-typst.config')

local M = {}

local augroup = vim.api.nvim_create_augroup('nvim-typst', { clear = true })
local initialised = false
local attached = {}

--- Buffer-local options on top of Neovim's own `ftplugin/typst.vim`, which
--- already sets 'commentstring', 'comments' and 'suffixesadd'.
---@param bufnr integer
local function buffer_options(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    -- `[i`, `[d` and friends should follow `#include "foo.typ"`.
    vim.opt_local.include = [[\v<(include|import)\s*"\zs[^"]+\ze"]]
  end)
end

--- Is there a `highlights` query for the `typst` parser?
---@return boolean
function M.has_highlights()
  local ok, query = pcall(vim.treesitter.query.get, 'typst', 'highlights')
  return ok and query ~= nil
end

---@param bufnr integer
local function treesitter_setup(bufnr)
  local opts = config.get('treesitter')
  if not opts.enabled then
    return
  end

  local ts = require('nvim-typst.ts')
  if not ts.parser(bufnr) then
    return
  end

  -- Neovim ships no highlight query for Typst; nvim-treesitter does. Starting
  -- the highlighter without one would turn the regex syntax off and leave the
  -- buffer with no highlighting at all, so `syntax/typst.vim` stays in charge
  -- then.
  if opts.highlight and M.has_highlights() then
    pcall(vim.treesitter.start, bufnr, 'typst')
  end
end

--- Attach the plugin to `bufnr`.
---@param bufnr integer|nil
function M.attach(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not config.get('enabled') or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  buffer_options(bufnr)
  treesitter_setup(bufnr)
  require('nvim-typst.lsp').attach(bufnr)
  require('nvim-typst.keymaps').attach(bufnr)

  if attached[bufnr] then
    return
  end
  attached[bufnr] = true

  vim.api.nvim_create_autocmd('BufWritePost', {
    group = augroup,
    buffer = bufnr,
    desc = 'nvim-typst: compile on save',
    callback = function()
      if not config.get('compiler', 'build_on_save') then
        return
      end
      local compiler = require('nvim-typst.compiler')
      local project = require('nvim-typst.project').get(bufnr)
      if not compiler.is_running(project) then
        compiler.compile_single_shot(project)
      end
    end,
  })

  vim.api.nvim_create_autocmd('BufDelete', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      attached[bufnr] = nil
      require('nvim-typst.project').invalidate(bufnr)
    end,
  })

  vim.api.nvim_exec_autocmds('User', { pattern = 'NvimTypstAttach', data = { bufnr = bufnr } })
end

--- Neovim maps the `typst` filetype to the `typst` parser already; this only
--- matters when `filetypes` names others.
local function register_language()
  vim.treesitter.language.register('typst', config.get('filetypes'))
end

--- The FileType hook, recreated when `setup` changes `filetypes`.
local filetype_autocmd = nil

local function filetype_hook()
  if filetype_autocmd then
    pcall(vim.api.nvim_del_autocmd, filetype_autocmd)
  end
  filetype_autocmd = vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = config.get('filetypes'),
    desc = 'nvim-typst: attach to Typst buffers',
    callback = function(args)
      M.attach(args.buf)
    end,
  })
end

--- Register commands and the FileType hook. Safe to call repeatedly.
function M.init()
  if initialised then
    return
  end
  initialised = true

  register_language()
  require('nvim-typst.commands').setup()
  require('nvim-typst.lsp').setup()
  filetype_hook()

  -- Stop every compilation when Neovim exits, so no `typst watch` is left
  -- running in the background.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    desc = 'nvim-typst: stop compilations on exit',
    callback = function()
      local project_mod = require('nvim-typst.project')
      local compiler = require('nvim-typst.compiler')
      for _, project in pairs(project_mod.projects) do
        if compiler.is_running(project) then
          project.compiler.stopping = true
          project.compiler.handle:kill('sigterm')
        end
      end
    end,
  })
end

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  M.init()
  register_language()
  filetype_hook()

  -- Re-attach buffers that were already open when `setup` ran.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains(config.get('filetypes'), vim.bo[bufnr].filetype) then
      M.attach(bufnr)
    end
  end
end

return M
