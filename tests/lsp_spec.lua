local H = require('tests.helpers')
local config = require('nvim-typst.config')
local lsp = require('nvim-typst.lsp')
local project_mod = require('nvim-typst.project')

--- An in-process language server that records the commands it is sent.
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
          callback(nil, { capabilities = { executeCommandProvider = { commands = { 'tinymist.pinMain' } } } })
        elseif method == 'workspace/executeCommand' then
          commands[#commands + 1] = { params.command, params.arguments }
          callback(nil, vim.NIL)
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

describe('lsp', function()
  local dir

  before_each(function()
    dir = H.tmpdir()
  end)

  after_each(function()
    for _, client in ipairs(vim.lsp.get_clients({ name = 'tinymist' })) do
      client:stop(true)
    end
    H.cleanup()
  end)

  describe('client_config', function()
    it('roots the client in the project and fills in rootPath', function()
      local project = H.project(dir .. '/main.typ')
      local cfg = lsp.client_config(project)
      T.eq('tinymist', cfg.name)
      T.eq({ 'tinymist' }, cfg.cmd)
      T.eq(dir, cfg.root_dir)
      T.eq(dir, cfg.settings.rootPath)
      T.eq('never', cfg.settings.exportPdf)
      T.eq(dir, cfg.init_options.rootPath)
    end)

    it('merges lsp.settings and lsp.config', function()
      config.setup({ lsp = { settings = { formatterMode = 'disable' }, config = { autostart = false } } })
      local cfg = lsp.client_config(H.project(dir .. '/main.typ'))
      T.eq('disable', cfg.settings.formatterMode)
      T.eq('never', cfg.settings.exportPdf)
      T.eq(false, cfg.autostart)
    end)

    it('passes indent.width on as formatterIndentSize unless lsp.settings has one', function()
      local project = H.project(dir .. '/main.typ')
      T.eq(nil, lsp.client_config(project).settings.formatterIndentSize)
      config.setup({ indent = { width = 4 } })
      T.eq(4, lsp.client_config(project).settings.formatterIndentSize)
      T.eq(4, lsp.client_config(project).init_options.formatterIndentSize)
      config.setup({ indent = { width = 4 }, lsp = { settings = { formatterIndentSize = 3 } } })
      T.eq(3, lsp.client_config(project).settings.formatterIndentSize)
      config.setup({})
    end)
  end)

  describe('attach', function()
    it('warns once when tinymist is missing', function()
      config.setup({ lsp = { cmd = { 'no-such-tinymist' } } })
      local bufnr = H.buf({ '= A' }, { name = dir .. '/a.typ' })
      T.eq(nil, lsp.attach(bufnr))
      T.ok(H.notified("'no%-such%-tinymist' not found"))
    end)

    it('does nothing when disabled', function()
      config.setup({ lsp = { enabled = false, cmd = { 'no-such-tinymist' } } })
      local bufnr = H.buf({ '= A' }, { name = dir .. '/b.typ' })
      H.notifications = {}
      T.eq(nil, lsp.attach(bufnr))
      T.falsy(H.notified('not found'))
    end)

    it('does nothing for a document with // !TYPST lsp = off', function()
      config.setup({ lsp = { cmd = { 'no-such-tinymist-off' } } })
      local file = H.write(dir .. '/off.typ', '// !TYPST lsp = off')
      H.notifications = {}
      local bufnr = H.buf(vim.fn.readfile(file), { name = file })
      T.eq(nil, lsp.attach(bufnr))
      T.falsy(H.notified('not found'))
    end)
  end)

  describe('pin_main', function()
    it('pins the main file of an included buffer, once', function()
      local commands = {}
      local main = H.write(dir .. '/main.typ', '#include "ch.typ"')
      local ch = H.write(dir .. '/ch.typ', '= Chapter')
      local bufnr = H.buf(vim.fn.readfile(ch), { name = ch, filetype = 'text' })

      local cfg = lsp.client_config(project_mod.get(bufnr))
      cfg.cmd = fake_server(commands)
      local client_id = vim.lsp.start(cfg, { bufnr = bufnr })
      T.ok(client_id)
      H.wait(function()
        return #commands > 0
      end, 5000, 'the pin request')

      T.eq({ { 'tinymist.pinMain', { main } } }, commands)
      T.eq(main, lsp.pinned(bufnr))

      lsp.pin_main(bufnr)
      vim.wait(50)
      T.eq(1, #commands)
    end)

    it('is skipped with pin_main = false', function()
      config.setup({ lsp = { pin_main = false } })
      local commands = {}
      local file = H.write(dir .. '/solo.typ', '= Solo')
      local bufnr = H.buf(vim.fn.readfile(file), { name = file, filetype = 'text' })
      local cfg = lsp.client_config(project_mod.get(bufnr))
      cfg.cmd = fake_server(commands)
      vim.lsp.start(cfg, { bufnr = bufnr })
      vim.wait(200)
      T.eq({}, commands)
    end)

    it('is skipped for a document with // !TYPST lsp = off', function()
      local commands = {}
      local file = H.write(dir .. '/off.typ', { '= Off', '// !TYPST lsp = off' })
      local bufnr = H.buf(vim.fn.readfile(file), { name = file, filetype = 'text' })
      local cfg = lsp.client_config(project_mod.get(bufnr))
      cfg.cmd = fake_server(commands)
      vim.lsp.start(cfg, { bufnr = bufnr })
      vim.wait(200)
      T.eq({}, commands)
    end)

    it('detaches and stops a tinymist started elsewhere for a document with // !TYPST lsp = off', function()
      local commands = {}
      local file = H.write(dir .. '/off.typ', { '= Off', '// !TYPST lsp = off' })
      local bufnr = H.buf(vim.fn.readfile(file), { name = file, filetype = 'typst' })
      local cfg = lsp.client_config(project_mod.get(bufnr))
      cfg.cmd = fake_server(commands)
      local id = vim.lsp.start(cfg, { bufnr = bufnr })
      H.wait(function()
        return not vim.lsp.buf_is_attached(bufnr, id) and vim.lsp.get_client_by_id(id) == nil
      end, nil, 'the client to stop')
      T.eq({}, commands)
    end)

    it('leaves a tinymist alone that still serves another buffer', function()
      local on = H.write(dir .. '/on.typ', '= On')
      local off = H.write(dir .. '/off.typ', { '= Off', '// !TYPST lsp = off' })
      local on_buf = H.buf(vim.fn.readfile(on), { name = on, filetype = 'text' })
      local cfg = lsp.client_config(project_mod.get(on_buf))
      cfg.cmd = fake_server({})
      local id = vim.lsp.start(cfg, { bufnr = on_buf })
      local off_buf = H.buf(vim.fn.readfile(off), { name = off, filetype = 'typst' })
      vim.lsp.buf_attach_client(off_buf, id)
      H.wait(function()
        return not vim.lsp.buf_is_attached(off_buf, id)
      end, nil, 'the client to detach')
      T.ok(vim.lsp.buf_is_attached(on_buf, id))
      T.ok(vim.lsp.get_client_by_id(id) ~= nil)
    end)
  end)
end)
