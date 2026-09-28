--- Buffer-local mappings.
---
--- The keys are nvim-tex's, which are VimTeX's without the extra `l` layer:
--- `<localleader>l` compiles, `<localleader>v` views, and so on. Keys whose
--- nvim-tex action has no Typst counterpart are left unmapped: `r` (the
--- tinymist preview pushes inverse search itself) and `q`, `m`.
local cite = require('nvim-typst.cite')
local compiler = require('nvim-typst.compiler')
local config = require('nvim-typst.config')
local context = require('nvim-typst.context')
local info = require('nvim-typst.info')
local motions = require('nvim-typst.motions')
local project_mod = require('nvim-typst.project')
local qf = require('nvim-typst.qf')
local surround = require('nvim-typst.surround')
local textobj = require('nvim-typst.textobj')
local toc = require('nvim-typst.toc')
local viewer = require('nvim-typst.viewer')

local M = {}

---@return table
local function project()
  return project_mod.get(0)
end

---@param bufnr integer
---@return fun(modes: string|string[], lhs: string, rhs: function|string, desc: string, extra: table|nil)
local function mapper(bufnr)
  return function(modes, lhs, rhs, desc, extra)
    vim.keymap.set(
      modes,
      lhs,
      rhs,
      vim.tbl_extend('force', {
        buffer = bufnr,
        silent = true,
        desc = 'nvim-typst: ' .. desc,
      }, extra or {})
    )
  end
end

--- The `<localleader>` group, as in nvim-tex.
---@param map function
---@param prefix string
local function leader_maps(map, prefix)
  map('n', prefix .. 'i', function()
    info.info(project(), false)
  end, 'info')
  map('n', prefix .. 'I', function()
    info.info(project(), true)
  end, 'info (full)')
  map('n', prefix .. 't', function()
    toc.open(project())
  end, 'open table of contents')
  map('n', prefix .. 'T', function()
    toc.toggle(project())
  end, 'toggle table of contents')
  map('n', prefix .. 'v', function()
    viewer.view(project())
  end, 'view (forward search with the tinymist preview)')
  map('n', prefix .. 'l', function()
    compiler.compile(project())
  end, 'start or stop compilation')
  map('n', prefix .. 'L', function()
    vim.o.operatorfunc = "v:lua.require'nvim-typst.keymaps'.op_compile_selected"
    return 'g@'
  end, 'compile the operated text', { expr = true })
  map('x', prefix .. 'L', function()
    vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
    local first, last = vim.fn.line("'<"), vim.fn.line("'>")
    compiler.compile_selected(project(), vim.api.nvim_buf_get_lines(0, first - 1, last, false), { first = first })
  end, 'compile the selection')
  map('n', prefix .. 'S', function()
    compiler.compile_single_shot(project())
  end, 'compile once')
  map('n', prefix .. 'k', function()
    compiler.stop(project())
  end, 'stop compilation')
  map('n', prefix .. 'K', function()
    compiler.stop_all()
  end, 'stop all compilations')
  map('n', prefix .. 'e', function()
    qf.update(project(), { force_open = true })
  end, 'show errors')
  map('n', prefix .. 'E', function()
    qf.cycle_level()
    qf.update(project(), { force_open = true })
  end, 'cycle the quickfix severity level')
  map('n', prefix .. 'o', function()
    compiler.show_output(project())
  end, 'show compiler output')
  map('n', prefix .. 'g', function()
    info.status(project())
  end, 'compilation status')
  map('n', prefix .. 'G', function()
    info.status_all()
  end, 'compilation status (all)')
  map('n', prefix .. 'c', function()
    compiler.clean(project(), false)
  end, 'clean generated files')
  map('n', prefix .. 'C', function()
    compiler.clean(project(), true)
  end, 'clean all output')
  map('n', prefix .. 'x', function()
    info.reload()
  end, 'reload nvim-typst')
  map('n', prefix .. 'X', function()
    info.reload_state()
  end, 'reload project state')
  map('n', prefix .. 's', function()
    info.toggle_main(vim.api.nvim_get_current_buf())
  end, 'toggle main file')
  map('n', prefix .. 'a', function()
    context.menu(project())
  end, 'context menu')
  map('n', prefix .. 'b', function()
    cite.cite(project())
  end, 'search online and cite')
end

--- `operatorfunc` for `<localleader>L` in normal mode.
---@param _ string
function M.op_compile_selected(_)
  local first, last = vim.fn.line("'["), vim.fn.line("']")
  compiler.compile_selected(project(), vim.api.nvim_buf_get_lines(0, first - 1, last, false), { first = first })
end

--- Math / call / delimiter editing, and the insert mode helpers. nvim-tex's
--- set minus environments, stars, line breaks and `\left`/`\right`.
---@param map function
local function surround_maps(map)
  map('n', 'ds$', surround.math_delete, 'delete surrounding math')
  map('n', 'dsc', surround.cmd_delete, 'delete surrounding function call')
  map('n', 'dsd', surround.delim_delete, 'delete surrounding delimiter')

  map('n', 'cs$', function()
    surround.math_change()
  end, 'change surrounding math')
  map('n', 'csc', function()
    surround.cmd_change()
  end, 'change surrounding function call')
  map('n', 'csd', function()
    surround.delim_change()
  end, 'change surrounding delimiter')

  map('n', 'tsf', function()
    surround.toggle_fraction(false)
  end, 'toggle fraction')
  map('x', 'tsf', function()
    surround.toggle_fraction(true)
  end, 'toggle fractions')
  map('n', 'ts$', surround.math_toggle, 'toggle inline/displayed math')
  map('n', 'tsd', surround.delim_toggle_lr, 'toggle lr(…) around delimiters')

  map('n', '<F7>', function()
    surround.cmd_create(false)
  end, 'wrap the word in a function call')
  map('x', '<F7>', function()
    surround.cmd_create(true)
  end, 'wrap the selection in a function call')
  map('i', '<F7>', surround.cmd_create_insert, 'turn the preceding word into a function call')
end

---@param bufnr integer
function M.attach(bufnr)
  local opts = config.get('mappings')
  if not opts.enabled then
    return
  end
  local map = mapper(bufnr)
  leader_maps(map, opts.prefix)
  if opts.motions then
    for lhs, fn in pairs(motions.map) do
      map({ 'n', 'x', 'o' }, lhs, fn, 'motion ' .. lhs)
    end
  end
  if opts.text_objects then
    for lhs, fn in pairs(textobj.map) do
      map({ 'x', 'o' }, lhs, fn, 'text object ' .. lhs)
    end
  end
  if opts.surround then
    surround_maps(map)
  end
  if opts.insert_close then
    map('i', ']]', surround.delim_close, 'close the current delimiter or math')
  end
end

return M
