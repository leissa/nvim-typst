local H = require('tests.helpers')
local config = require('nvim-typst.config')
local lsp = require('nvim-typst.lsp')
local project_mod = require('nvim-typst.project')
local tinymist = require('nvim-typst.viewer.tinymist')
local viewer = require('nvim-typst.viewer')

--- Skip unless `tinymist` is installed.
local function need_tinymist()
  if vim.fn.executable('tinymist') == 0 then
    T.skip("'tinymist' is not installed")
  end
end

--- An in-process language server answering the preview commands the way
--- tinymist does, and recording them.
---@param commands table[] receives `{ command, arguments }`
---@return function cmd for `vim.lsp.start`
local function fake_server(commands)
  return function(dispatchers)
    local closing = false
    local id = 0
    return {
      request = function(method, params, callback)
        id = id + 1
        if method == 'initialize' then
          callback(nil, { capabilities = { executeCommandProvider = { commands = {} } } })
        elseif method == 'workspace/executeCommand' then
          commands[#commands + 1] = { params.command, params.arguments }
          if params.command == 'tinymist.doStartPreview' then
            callback(nil, { staticServerAddr = '127.0.0.1:4711', staticServerPort = 4711, isPrimary = true })
          else
            callback(nil, vim.NIL)
          end
        elseif method == 'shutdown' then
          callback(nil, vim.NIL)
        end
        return true, id
      end,
      notify = function(method)
        if method == 'exit' and not closing then
          closing = true
          dispatchers.on_exit(0, 15)
        end
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        if not closing then
          closing = true
          dispatchers.on_exit(0, 15)
        end
      end,
    }
  end
end

--- The commands sent so far, by name.
---@param commands table[]
---@param name string
---@return table[]
local function sent(commands, name)
  return vim.tbl_filter(function(c)
    return c[1] == name
  end, commands)
end

describe('preview', function()
  local dir

  before_each(function()
    dir = H.tmpdir()
    config.setup({ view = { method = 'tinymist', tinymist = { executable = false } }, lsp = { pin_main = false } })
  end)

  after_each(function()
    for _, client in ipairs(vim.lsp.get_clients({ name = 'tinymist' })) do
      client:stop(true)
    end
    -- Not `H.wait`: a teardown error would skip `H.cleanup` below.
    vim.wait(5000, function()
      return #vim.lsp.get_clients({ name = 'tinymist' }) == 0
    end, 20)
    H.cleanup()
  end)

  --- A buffer on `main.typ` with the fake server attached.
  ---@param lines string[]
  ---@return integer bufnr, table project, table[] commands
  local function fake_setup(lines)
    local commands = {}
    local main = H.write(dir .. '/main.typ', lines)
    local bufnr = H.buf(lines, { name = main, filetype = 'text' })
    local project = project_mod.get(bufnr)
    local cfg = lsp.client_config(project)
    cfg.cmd = fake_server(commands)
    vim.lsp.start(cfg, { bufnr = bufnr })
    H.wait(function()
      local client = lsp.client(bufnr)
      return client ~= nil and client.initialized == true
    end, 5000, 'the fake client')
    return bufnr, project, commands
  end

  describe('start_args', function()
    it('runs a task on a free port without opening a browser', function()
      config.setup({ view = { tinymist = { options = { '--invert-colors=auto' } } } })
      local project = H.project(dir .. '/main.typ', { root = dir })
      local args = tinymist.start_args(project, 'task')
      T.eq({
        '--task-id',
        'task',
        '--data-plane-host',
        '127.0.0.1:0',
        '--no-open',
        '--root',
        dir,
        '--invert-colors=auto',
        dir .. '/main.typ',
      }, args)
    end)

    it('never uses the reserved task id', function()
      T.ok(tinymist.task_id() ~= 'primary')
      T.ok(tinymist.task_id() ~= tinymist.task_id())
    end)
  end)

  describe('scroll_request', function()
    it('counts the column in characters and the line from 0', function()
      local file = dir .. '/a.typ'
      H.buf({ '= A', 'äöü x' }, { name = file, filetype = 'text' })
      H.cursor_at('x')
      T.eq({ event = 'panelScrollTo', filepath = file, line = 1, character = 4 }, tinymist.scroll_request())
    end)

    it('is nil for an unnamed buffer', function()
      H.buf({ 'x' }, { filetype = 'text' })
      T.eq(nil, tinymist.scroll_request())
    end)
  end)

  describe('view', function()
    it('starts the preview and reports its URL', function()
      local _, project, commands = fake_setup({ '= A' })
      viewer.view(project)
      H.wait(function()
        return project.viewer and project.viewer.url ~= nil
      end, 5000, 'the preview to start')

      local start = sent(commands, 'tinymist.doStartPreview')
      T.eq(1, #start)
      T.eq(project.main, start[1][2][1][#start[1][2][1]])
      T.eq('http://127.0.0.1:4711', project.viewer.url)
      T.ok(H.notified('preview: http://127%.0%.0%.1:4711'))
      T.ok(viewer.is_running(project))
    end)

    it('scrolls to the cursor once the preview runs', function()
      local _, project, commands = fake_setup({ '= A', '', 'text' })
      viewer.view(project)
      H.wait(function()
        return project.viewer and project.viewer.url ~= nil
      end, 5000, 'the preview to start')

      H.cursor(3, 2)
      viewer.view(project)
      H.wait(function()
        return #sent(commands, 'tinymist.scrollPreview') == 1
      end, 5000, 'the scroll request')
      local scroll = sent(commands, 'tinymist.scrollPreview')[1][2]
      T.eq(project.viewer.task_id, scroll[1])
      T.eq({ event = 'panelScrollTo', filepath = project.main, line = 2, character = 2 }, scroll[2])
      T.eq(1, #sent(commands, 'tinymist.doStartPreview'))
    end)

    it('follows the cursor with follow_cursor', function()
      config.setup({
        view = { method = 'tinymist', tinymist = { executable = false, follow_cursor = true, follow_delay = 10 } },
        lsp = { pin_main = false },
      })
      local bufnr, project, commands = fake_setup({ '= A', '', 'text' })
      vim.bo[bufnr].filetype = 'typst'
      viewer.view(project)
      H.wait(function()
        return project.viewer and project.viewer.url ~= nil
      end, 5000, 'the preview to start')

      H.cursor(3, 1)
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = bufnr })
      H.wait(function()
        return #sent(commands, 'tinymist.scrollPreview') > 0
      end, 5000, 'the scroll request')
    end)

    it('stops the preview with close', function()
      local _, project, commands = fake_setup({ '= A' })
      viewer.view(project)
      H.wait(function()
        return project.viewer and project.viewer.url ~= nil
      end, 5000, 'the preview to start')
      local task = project.viewer.task_id

      viewer.close(project)
      H.wait(function()
        return #sent(commands, 'tinymist.doKillPreview') == 1
      end, 5000, 'the kill request')
      T.eq({ task }, sent(commands, 'tinymist.doKillPreview')[1][2])
      T.falsy(viewer.is_running(project))
    end)

    it('needs the language server', function()
      -- An executable stand-in, so that it is the missing client that is reported.
      config.setup({ view = { method = 'tinymist', tinymist = { executable = false } }, lsp = { cmd = { 'true' } } })
      local main = H.write(dir .. '/main.typ', '= A')
      H.buf({ '= A' }, { name = main, filetype = 'text' })
      local project = project_mod.get(0)
      viewer.view(project)
      T.ok(H.notified('needs tinymist'))
      T.falsy(viewer.is_running(project))
    end)
  end)

  describe('forward_search', function()
    it('is not available for a PDF viewer', function()
      config.setup({ view = { method = 'general', general = { executable = 'true' } } })
      local main = H.write(dir .. '/main.typ', '= A')
      H.buf({ '= A' }, { name = main, filetype = 'text' })
      viewer.forward_search(project_mod.get(0))
      T.ok(H.notified('no forward search'))
    end)
  end)

  describe('view with pdf = true', function()
    it('opens the PDF with the general viewer instead of the preview', function()
      config.setup({ view = { method = 'tinymist', general = { executable = 'true' } } })
      local main = H.write(dir .. '/main.typ', '= A')
      H.write(dir .. '/main.pdf', '%PDF')
      local project = H.project(main)
      viewer.view(project, { pdf = true })
      T.eq('general', project.viewer.backend)
    end)
  end)

  describe('inverse search', function()
    it("lands on the clicked spot through Neovim's showDocument handler", function()
      local bufnr = fake_setup({ '= A', '', 'first', 'second line' })
      local other = H.buf({ 'x' }, { filetype = 'text' })
      T.ok(other ~= bufnr)
      -- What tinymist sends for a click, with `customizedShowDocument` off.
      local client = lsp.client(bufnr)
      vim.lsp.handlers['window/showDocument'](nil, {
        uri = vim.uri_from_bufnr(bufnr),
        takeFocus = true,
        selection = { start = { line = 3, character = 7 }, ['end'] = { line = 3, character = 7 } },
      }, { method = 'window/showDocument', client_id = client.id })
      T.eq(bufnr, vim.api.nvim_get_current_buf())
      T.eq({ 4, 7 }, vim.api.nvim_win_get_cursor(0))
    end)
  end)

  describe('with tinymist', function()
    it('serves the preview, scrolls it and stops it', function()
      need_tinymist()
      config.setup({ view = { method = 'tinymist', tinymist = { executable = false } } })
      local main = H.write(dir .. '/main.typ', { '= Hello', '', 'Some text.', '#pagebreak()', '= Two' })
      local bufnr = H.buf(vim.fn.readfile(main), { name = main })
      H.wait(function()
        local client = lsp.client(bufnr)
        return client ~= nil and client.initialized == true
      end, 15000, 'tinymist to start')

      local project = project_mod.get(bufnr)
      viewer.view(project)
      H.wait(function()
        return project.viewer and project.viewer.url ~= nil
      end, 15000, 'the preview to start')
      local url = project.viewer.url
      T.matches('^http://127%.0%.0%.1:%d+$', url)
      T.eq('200', vim.fn.system({ 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', url }))

      H.cursor(5, 2)
      T.ok(tinymist.forward_search(project))

      viewer.close(project)
      H.wait(function()
        return vim.fn.system({ 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', url }) == '000'
      end, 5000, 'the preview server to stop')
    end)
  end)
end)
