--- tinymist's live preview, the Typst counterpart of a SyncTeX viewer.
---
--- The preview runs inside the tinymist language server: the
--- `tinymist.doStartPreview` command starts an HTTP server rendering the
--- main file, which the browser opens. It renders the editor's unsaved
--- buffers, so it needs no compilation at all.
---
--- Forward search is `tinymist.scrollPreview` with a `panelScrollTo` event
--- for the cursor position. Inverse search is pushed by the server: a click
--- in the preview makes tinymist send `window/showDocument`, which Neovim's
--- own handler answers by jumping to the clicked spot.
local config = require('nvim-typst.config')
local lsp = require('nvim-typst.lsp')
local util = require('nvim-typst.util')

local M = { name = 'tinymist' }

--- Needs no PDF: the preview renders the source.
M.needs_pdf = false

local counter = 0

function M.available()
  return lsp.client() ~= nil or util.executable(config.get('lsp', 'cmd')[1])
end

---@return table
local function opts()
  return config.get('view', 'tinymist') or {}
end

--- A fresh task id; tinymist reserves `primary`.
---@return string
function M.task_id()
  counter = counter + 1
  return ('nvim-typst-%d-%d'):format(vim.fn.getpid(), counter)
end

--- The arguments of `tinymist.doStartPreview`, those of `tinymist preview`.
---@param project table
---@param task_id string
---@return string[]
function M.start_args(project, task_id)
  local args = {
    '--task-id',
    task_id,
    -- A free port, so that several previews can run side by side.
    '--data-plane-host',
    '127.0.0.1:0',
    -- The browser is opened here, with `view.tinymist.executable`.
    '--no-open',
    '--root',
    project.root,
  }
  vim.list_extend(args, opts().options or {})
  args[#args + 1] = project.main
  return args
end

--- The `panelScrollTo` request for the cursor in the current window.
---
--- tinymist takes the column in characters (its fixme says UTF-16 code
--- units, but the server counts characters), not in bytes.
---@param bufnr integer|nil
---@param pos integer[]|nil `{ row (1-indexed), col (0-indexed bytes) }`
---@return table|nil
function M.scroll_request(bufnr, pos)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil
  end
  pos = pos or vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false)[1] or ''
  return {
    event = 'panelScrollTo',
    filepath = util.normalize(name),
    line = pos[1] - 1,
    character = vim.fn.strchars(line:sub(1, pos[2])),
  }
end

--- The client that runs the preview of `project`, if it is still alive.
---@param project table
---@return vim.lsp.Client|nil
local function preview_client(project)
  local viewer = project.viewer
  if not viewer or viewer.backend ~= M.name or not viewer.client_id then
    return nil
  end
  local client = vim.lsp.get_client_by_id(viewer.client_id)
  if not client or client:is_stopped() then
    return nil
  end
  return client
end

---@param project table
---@return boolean
function M.is_running(project)
  return preview_client(project) ~= nil
end

--- Open `url` with `view.tinymist.executable`, or just report it.
---@param url string
function M.open(url)
  local o = opts()
  if not o.executable then
    util.info('preview: ' .. url)
    return
  end
  local cmd = util.as_cmd(o.executable)
  vim.list_extend(cmd, util.expand_args(o.args or { '@url' }, { url = url }))
  local ok, err = pcall(vim.system, cmd, { detach = true })
  if not ok then
    util.error('could not open the preview: ' .. tostring(err))
  end
end

--- Scroll the preview of `project` to the cursor.
---@param project table
---@param bufnr integer|nil
---@return boolean sent
function M.forward_search(project, bufnr)
  local client = preview_client(project)
  local req = M.scroll_request(bufnr)
  if not client or not req or project.viewer.starting then
    return false
  end
  lsp.request(client, 'workspace/executeCommand', {
    command = 'tinymist.scrollPreview',
    arguments = { project.viewer.task_id, req },
  }, function() end, bufnr)
  return true
end

--- Start the preview of `project`, or scroll it to the cursor if it runs.
---@param project table
function M.view(project)
  if M.is_running(project) then
    if not project.viewer.starting then
      M.forward_search(project)
    end
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local client = lsp.client(bufnr)
  if not client then
    util.error("the tinymist preview needs tinymist's language server, which is not attached")
    return
  end

  local task_id = M.task_id()
  local viewer = { backend = M.name, task_id = task_id, client_id = client.id, starting = true }
  project.viewer = viewer
  lsp.execute('tinymist.doStartPreview', { M.start_args(project, task_id) }, bufnr, function(err, result)
    if project.viewer ~= viewer then
      return -- closed while starting
    end
    if err or type(result) ~= 'table' then
      project.viewer = nil
      util.error('tinymist could not start the preview: ' .. tostring(err and err.message or result))
      return
    end
    viewer.starting = nil
    viewer.url = 'http://' .. (result.staticServerAddr or ('127.0.0.1:' .. tostring(result.staticServerPort)))
    M.open(viewer.url)
  end)
end

--- Stop the preview of `project`.
---@param project table
function M.close(project)
  local client = preview_client(project)
  if client then
    lsp.request(client, 'workspace/executeCommand', {
      command = 'tinymist.doKillPreview',
      arguments = { project.viewer.task_id },
    }, function() end)
  end
  project.viewer = nil
end

local timer = nil

--- With `view.tinymist.follow_cursor`, scroll the preview along with the
--- cursor, debounced so that typing does not flood the server.
---@param bufnr integer
function M.cursor_moved(bufnr)
  if not opts().follow_cursor then
    return
  end
  local project = require('nvim-typst.project').get(bufnr)
  if not M.is_running(project) then
    return
  end
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(
    opts().follow_delay or 100,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_get_current_buf() == bufnr then
        M.forward_search(project, bufnr)
      end
    end)
  )
end

vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
  group = vim.api.nvim_create_augroup('nvim-typst-preview', { clear = true }),
  desc = 'nvim-typst: scroll the tinymist preview along with the cursor',
  callback = function(args)
    if opts().follow_cursor and vim.tbl_contains(config.get('filetypes'), vim.bo[args.buf].filetype) then
      M.cursor_moved(args.buf)
    end
  end,
})

return M
