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
  {
    'TypstCite',
    function(opts)
      require('nvim-typst.cite').cite(project(), opts.args)
    end,
    { nargs = '*', desc = 'Search online for a paper, add it to the bibliography and cite it' },
  },
  {
    'TypstContextMenu',
    function()
      require('nvim-typst.context').menu(project())
    end,
    { desc = 'Act on the reference, citation, include or import under the cursor' },
  },
  {
    'TypstDocPackage',
    function()
      require('nvim-typst.context').doc_package(project())
    end,
    { desc = 'Open the documentation of the imported package under the cursor' },
  },
  {
    'TypstEnvSurround',
    function(opts)
      require('nvim-typst.surround').env_surround_lines(opts.line1, opts.line2, opts.args ~= '' and opts.args or nil)
    end,
    { range = true, nargs = '?', desc = 'Wrap the range in the content block of a call' },
  },
  {
    'TypstPreviewFragment',
    function(opts)
      local preview = require('nvim-typst.preview')
      if opts.range > 0 then
        preview.preview_lines(project(), vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false), opts.line1)
      else
        preview.preview(project())
      end
    end,
    { range = true, desc = 'Compile the math or code under the cursor, or the range, on its own and show it' },
  },
  {
    'TypstPreviewClose',
    function()
      require('nvim-typst.viewer.snacks').close()
    end,
    { desc = 'Remove the fragment preview from the buffer' },
  },
  {
    'TypstImaps',
    function()
      require('nvim-typst.imaps').list()
    end,
    { desc = 'List the insert mode math mappings' },
  },
  {
    'TypstForwardSearch',
    function()
      viewer.forward_search(project())
    end,
    { desc = 'Scroll the tinymist preview to the cursor (starting it if needed)' },
  },
  {
    'TypstViewClose',
    function()
      viewer.close(project())
    end,
    { desc = 'Close the viewer, or stop the tinymist preview' },
  },
  {
    'TypstCompileSelected',
    function(opts)
      local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
      compiler.compile_selected(project(), lines, { first = opts.line1 })
    end,
    { range = '%', desc = 'Compile the lines in range as a standalone document' },
  },
  {
    'TypstCountWords',
    function(opts)
      require('nvim-typst.count').count(project(), {
        detailed = opts.bang,
        first = opts.range > 0 and opts.line1 or nil,
        last = opts.range > 0 and opts.line2 or nil,
      })
    end,
    { bang = true, range = true, desc = 'Count the words of the document or range (! for a report)' },
  },
  {
    'TypstCountLetters',
    function(opts)
      require('nvim-typst.count').count(project(), {
        letters = true,
        detailed = opts.bang,
        first = opts.range > 0 and opts.line1 or nil,
        last = opts.range > 0 and opts.line2 or nil,
      })
    end,
    { bang = true, range = true, desc = 'Count the letters of the document or range (! for a report)' },
  },
  {
    'TypstToc',
    function()
      require('nvim-typst.toc').open(project())
    end,
    { desc = 'Open the table of contents' },
  },
  {
    'TypstTocToggle',
    function()
      require('nvim-typst.toc').toggle(project())
    end,
    { desc = 'Toggle the table of contents' },
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
