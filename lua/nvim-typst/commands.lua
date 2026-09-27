--- User commands. Every command acts on the project of the current buffer.
---
--- The names are nvim-tex's with `Tex` replaced by `Typst`.
local compiler = require('nvim-typst.compiler')
local info = require('nvim-typst.info')
local project_mod = require('nvim-typst.project')
local qf = require('nvim-typst.qf')
local viewer = require('nvim-typst.viewer')

local M = {}

---@return table
local function project()
  return project_mod.get(0)
end

--- All commands, as `{ name, fn, opts }`.
local COMMANDS = {
  {
    'TypstCompile',
    function()
      compiler.compile(project())
    end,
    { desc = 'Start or stop compilation' },
  },
  {
    'TypstCompileSS',
    function()
      compiler.compile_single_shot(project())
    end,
    { desc = 'Compile once' },
  },
  {
    'TypstCompileOutput',
    function()
      compiler.show_output(project())
    end,
    { desc = 'Show the raw compiler output' },
  },
  {
    'TypstStop',
    function()
      compiler.stop(project())
    end,
    { desc = 'Stop the compilation of this project' },
  },
  {
    'TypstStopAll',
    function()
      compiler.stop_all()
    end,
    { desc = 'Stop all compilations' },
  },
  {
    'TypstClean',
    function(opts)
      compiler.clean(project(), opts.bang)
    end,
    { bang = true, desc = 'Remove generated files (! also removes the PDF)' },
  },
  {
    'TypstView',
    function()
      viewer.view(project())
    end,
    { desc = 'Open the PDF viewer' },
  },
  {
    'TypstErrors',
    function()
      qf.update(project(), { force_open = true, silent = false })
    end,
    { desc = 'Open the quickfix list with errors and warnings' },
  },
  {
    'TypstQfLevel',
    function(opts)
      if opts.args ~= '' then
        qf.set_level(opts.args)
      else
        qf.cycle_level()
      end
      qf.update(project(), { force_open = true })
    end,
    {
      nargs = '?',
      complete = function()
        return qf.levels()
      end,
      desc = 'Set or cycle the lowest severity shown in the quickfix list',
    },
  },
  {
    'TypstStatus',
    function()
      info.status(project())
    end,
    { desc = 'Report the compilation status of this project' },
  },
  {
    'TypstStatusAll',
    function()
      info.status_all()
    end,
    { desc = 'Report the compilation status of all projects' },
  },
  {
    'TypstInfo',
    function(opts)
      info.info(project(), opts.bang)
    end,
    { bang = true, desc = 'Show project information (! for the full dump)' },
  },
  {
    'TypstReload',
    function()
      info.reload()
    end,
    { desc = 'Reload nvim-typst' },
  },
  {
    'TypstReloadState',
    function()
      info.reload_state()
    end,
    { desc = 'Forget all cached project state' },
  },
  {
    'TypstToggleMain',
    function()
      info.toggle_main(vim.api.nvim_get_current_buf())
    end,
    { desc = 'Toggle the main file between detected and current buffer' },
  },
}

--- The names of all commands.
---@return string[]
function M.names()
  return vim.tbl_map(function(spec)
    return spec[1]
  end, COMMANDS)
end

function M.setup()
  for _, spec in ipairs(COMMANDS) do
    vim.api.nvim_create_user_command(spec[1], spec[2], spec[3])
  end
end

return M
