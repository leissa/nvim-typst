--- tinymist integration.
---
--- The server is started per project root with `vim.lsp.start`, which reuses
--- an existing client when one already matches. If you configure tinymist
--- yourself (nvim-lspconfig, `vim.lsp.enable`, ...), set `lsp.enabled = false`
--- or simply let the duplicate check below back off.
---
--- tinymist checks a file on its own unless it is told which file is the
--- main one; a chapter then reports every label and variable it takes from
--- the rest of the document as undefined. With `lsp.pin_main` the main file
--- of the current buffer's project is pinned whenever it changes.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local util = require('nvim-typst.util')

local M = {}

--- commands already reported as missing
---@type table<string, boolean>
local warned = {}

--- client id -> the main file pinned in that client
---@type table<integer, string>
local pinned = {}

--- `client:request` from 0.11 on, `client.request` before.
---@param client vim.lsp.Client
---@param method string
---@param params table
---@param handler function|nil
---@param bufnr integer|nil
local function request(client, method, params, handler, bufnr)
  if vim.fn.has('nvim-0.11') == 1 then
    return client:request(method, params, handler, bufnr)
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  return client.request(method, params, handler, bufnr)
end
M.request = request

--- Is a client with this name already attached to `bufnr`?
---@param bufnr integer
---@param name string
---@return boolean
local function already_attached(bufnr, name)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name == name then
      return true
    end
  end
  return false
end

--- The `vim.lsp.start` configuration for `project`.
---@param project table
---@return table
function M.client_config(project)
  local opts = config.get('lsp')
  return vim.tbl_deep_extend('force', {
    name = opts.name,
    cmd = opts.cmd,
    root_dir = project.root,
    -- tinymist reads its settings from the initialization options and from
    -- `workspace/didChangeConfiguration` alike.
    settings = vim.tbl_extend('force', { rootPath = project.root }, opts.settings or {}),
    init_options = vim.tbl_extend('force', { rootPath = project.root }, opts.settings or {}),
  }, opts.config or {})
end

--- Start (or reuse) tinymist for `bufnr`.
---@param bufnr integer
---@return integer|nil client_id
function M.attach(bufnr)
  local opts = config.get('lsp')
  if not opts.enabled then
    return nil
  end
  if already_attached(bufnr, opts.name) then
    M.pin_main(bufnr)
    return nil
  end

  local cmd = opts.cmd
  if not util.executable(cmd[1]) then
    if not warned[cmd[1]] then
      warned[cmd[1]] = true
      util.warn(("'%s' not found; LSP features are unavailable"):format(cmd[1]))
    end
    return nil
  end

  local project = project_mod.get(bufnr)
  local ok, client_id = pcall(vim.lsp.start, M.client_config(project), { bufnr = bufnr })
  if not ok then
    util.error('failed to start ' .. opts.name .. ': ' .. tostring(client_id))
    return nil
  end
  return client_id
end

--- The tinymist client attached to `bufnr`, if any.
---@param bufnr integer|nil
---@return vim.lsp.Client|nil
function M.client(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name == config.get('lsp', 'name') then
      return client
    end
  end
  return nil
end

--- Run a tinymist workspace command.
---@param command string
---@param arguments table|nil
---@param bufnr integer|nil
---@param handler fun(err: table|nil, result: any, client: vim.lsp.Client)|nil called with the response
---@return boolean sent
function M.execute(command, arguments, bufnr, handler)
  local client = M.client(bufnr)
  if not client then
    return false
  end
  request(client, 'workspace/executeCommand', { command = command, arguments = arguments or {} }, function(err, result)
    if handler then
      handler(err, result, client)
    end
  end, bufnr)
  return true
end

--- Pin the main file of `bufnr`'s project in tinymist, unless it already is.
---@param bufnr integer|nil
---@param force boolean|nil pin even if nothing changed
function M.pin_main(bufnr, force)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not config.get('lsp', 'pin_main') then
    return
  end
  local client = M.client(bufnr)
  if not client then
    return
  end
  local main = project_mod.get(bufnr).main
  if main == '' or (pinned[client.id] == main and not force) then
    return
  end
  if M.execute('tinymist.pinMain', { main }, bufnr) then
    pinned[client.id] = main
  end
end

--- The main file pinned in the client attached to `bufnr`, if any.
---@param bufnr integer|nil
---@return string|nil
function M.pinned(bufnr)
  local client = M.client(bufnr)
  return client and pinned[client.id] or nil
end

local augroup = vim.api.nvim_create_augroup('nvim-typst-lsp', { clear = true })

--- Keep the pinned main file in step with the buffer being edited.
function M.setup()
  vim.api.nvim_create_autocmd('LspAttach', {
    group = augroup,
    desc = 'nvim-typst: pin the main file in tinymist',
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == config.get('lsp', 'name') then
        M.pin_main(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    desc = 'nvim-typst: pin the main file of the current project',
    callback = function(args)
      if vim.tbl_contains(config.get('filetypes'), vim.bo[args.buf].filetype) then
        M.pin_main(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('LspDetach', {
    group = augroup,
    callback = function(args)
      pinned[args.data.client_id] = nil
    end,
  })
end

return M
