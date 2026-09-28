--- Informational commands: `:TypstInfo`, `:TypstStatus`, reloading and the
--- main file toggle.
local compiler = require('nvim-typst.compiler')
local config = require('nvim-typst.config')
local lsp = require('nvim-typst.lsp')
local project_mod = require('nvim-typst.project')
local qf = require('nvim-typst.qf')
local ts = require('nvim-typst.ts')
local util = require('nvim-typst.util')
local viewer = require('nvim-typst.viewer')

local M = {}

---@param project table
---@param full boolean
---@return string[]
local function info_lines(project, full)
  local lines = {
    'nvim-typst',
    '',
    'project',
    '  main file:   ' .. vim.fn.fnamemodify(project.main, ':~'),
    '  root:        ' .. vim.fn.fnamemodify(project.root, ':~'),
    '  out dir:     ' .. vim.fn.fnamemodify(project.out_dir, ':~'),
    '  pdf:         ' .. vim.fn.fnamemodify(project_mod.output_file(project), ':~'),
    '',
    'compiler',
    '  method:      ' .. tostring(config.get('compiler', 'method')),
    '  state:       ' .. compiler.status_line(project):gsub('^.-: ', ''),
  }

  if project.qf_errors or project.qf_warnings then
    lines[#lines + 1] = ('  diagnostics: %d errors, %d warnings (level: %s)'):format(
      project.qf_errors or 0,
      project.qf_warnings or 0,
      qf.level()
    )
  end
  if project.compiler then
    lines[#lines + 1] = '  command:     ' .. table.concat(project.compiler.cmd, ' ')
  end

  local client = lsp.client()
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'lsp'
  lines[#lines + 1] = '  client:      ' .. (client and (client.name .. ' (id ' .. client.id .. ')') or 'not attached')
  if client then
    lines[#lines + 1] = '  root:        ' .. vim.fn.fnamemodify(client.root_dir or '', ':~')
    local pinned = lsp.pinned()
    lines[#lines + 1] = '  pinned main: ' .. (pinned and vim.fn.fnamemodify(pinned, ':~') or 'none')
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = 'treesitter'
  lines[#lines + 1] = '  parser:      ' .. (ts.parser(0) and 'typst (active)' or 'unavailable')

  lines[#lines + 1] = ''
  lines[#lines + 1] = 'viewer'
  lines[#lines + 1] = '  method:      ' .. tostring(config.get('view', 'method'))
  local running = 'no'
  if viewer.is_running(project) then
    local v = project.viewer
    running = v.backend .. (v.url and (' at ' .. v.url) or v.pid and (' (pid ' .. v.pid .. ')') or '')
  end
  lines[#lines + 1] = '  running:     ' .. running

  if full then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'documents'
    local seen = {}
    local function walk(file, depth)
      if seen[file] or depth > 8 then
        return
      end
      seen[file] = true
      lines[#lines + 1] = '  ' .. string.rep('  ', depth) .. vim.fn.fnamemodify(file, ':~:.')
      for _, dep in ipairs(project_mod.dependencies(util.readlines(file), file, project.root)) do
        if dep:match('%.typ$') and util.is_file(dep) then
          walk(dep, depth + 1)
        end
      end
    end
    walk(project.main, 0)

    lines[#lines + 1] = ''
    lines[#lines + 1] = 'configuration'
    for _, chunk in ipairs(vim.split(vim.inspect(config.get()), '\n', { plain = true })) do
      lines[#lines + 1] = '  ' .. chunk
    end
  end

  return lines
end

---@param project table
---@param full boolean|nil
function M.info(project, full)
  util.scratch('nvim-typst://info', info_lines(project, full or false), { height = full and 25 or 20 })
end

---@param project table
function M.status(project)
  util.info(compiler.status_line(project))
end

function M.status_all()
  local lines = {}
  for _, project in pairs(project_mod.projects) do
    lines[#lines + 1] = compiler.status_line(project)
  end
  if #lines == 0 then
    util.info('no projects')
    return
  end
  table.sort(lines)
  util.scratch('nvim-typst://status', lines, { height = math.min(#lines + 1, 12) })
end

--- Reload the plugin's Lua modules, keeping the user configuration.
function M.reload()
  local options = vim.deepcopy(config.get())
  for name, _ in pairs(package.loaded) do
    if name:match('^nvim%-typst') then
      package.loaded[name] = nil
    end
  end
  require('nvim-typst').setup(options)
  util.info('reloaded')
end

--- Drop all cached project state and redetect.
function M.reload_state()
  for _, project in pairs(vim.deepcopy(project_mod.projects)) do
    local live = project_mod.projects[project.main]
    if live then
      project_mod.forget(live)
    end
  end
  util.info('project state cleared')
end

--- Cycle the main file between the detected one and the current buffer.
---@param bufnr integer
function M.toggle_main(bufnr)
  local current = vim.api.nvim_buf_get_name(bufnr)
  local ok, existing = pcall(vim.api.nvim_buf_get_var, bufnr, 'typst_main')
  if ok and existing and existing ~= '' then
    vim.api.nvim_buf_del_var(bufnr, 'typst_main')
    project_mod.invalidate(bufnr)
    util.info('main file: ' .. vim.fn.fnamemodify(project_mod.get(bufnr).main, ':~:.') .. ' (detected)')
  else
    vim.api.nvim_buf_set_var(bufnr, 'typst_main', current)
    project_mod.invalidate(bufnr)
    util.info('main file: ' .. vim.fn.fnamemodify(current, ':~:.') .. ' (this buffer)')
  end
  lsp.pin_main(bufnr)
end

return M
