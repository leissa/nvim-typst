local H = require('tests.helpers')
local compiler = require('nvim-typst.compiler')
local config = require('nvim-typst.config')
local preview = require('nvim-typst.preview')
local qf = require('nvim-typst.qf')
local snacks = require('nvim-typst.viewer.snacks')
local typst = require('nvim-typst.compiler.typst')
local viewer = require('nvim-typst.viewer')

--- A stand-in for snacks.nvim's image module.
---@param supported boolean the terminal can show images
---@param placeholders boolean|nil it has unicode placeholders
---@return table state `{ placed = table|nil }`
local function fake_snacks(supported, placeholders)
  local state = {}
  package.loaded.snacks = {
    image = {
      config = { enabled = true, doc = { max_width = 30, max_height = 10 } },
      supports_terminal = function()
        return supported
      end,
      terminal = {
        env = function()
          return { placeholders = placeholders }
        end,
      },
      placement = {
        new = function(buf, src, opts)
          local placed = {
            buf = buf,
            src = src,
            opts = opts,
            -- What ImageMagick reports for a PNG without a resolution.
            img = { info = { dpi = { width = 72, height = 72 } } },
            close = function() end,
          }
          placed.state = function()
            return { loc = { 1, 0, width = 12, height = 5 } }
          end
          state.placed = placed
          return placed
        end,
      },
    },
  }
  return state
end

--- The width and height of a PNG, from its header.
---@param path string
---@return integer, integer
local function png_size(path)
  local file = assert(io.open(path, 'rb'))
  local header = file:read(24)
  file:close()
  local function int(at)
    local a, b, c, d = header:byte(at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return int(17), int(21)
end

describe('fragment preview', function()
  local dir

  before_each(function()
    dir = H.tmpdir()
    config.setup({
      lsp = { enabled = false },
      compiler = { silent = true },
      cache_root = dir .. '/cache',
      view = { general = { executable = 'true', args = {} } },
    })
  end)

  after_each(function()
    snacks.close()
    package.loaded.snacks = nil
    H.cleanup()
  end)

  describe('fragment_at_cursor', function()
    before_each(H.need_parser)

    --- The text of the fragment at `needle`.
    local function at(lines, needle)
      local bufnr = H.buf(lines)
      H.cursor_at(needle)
      local node = preview.fragment_at_cursor(bufnr)
      return node and vim.treesitter.get_node_text(node, bufnr)
    end

    it('takes the math around the cursor', function()
      T.eq('$x + y$', at({ 'Let $x + y$ be.' }, 'y'))
    end)

    it('takes the outermost math', function()
      T.eq('$ f(#box[$z$]) $', at({ '$ f(#box[$z$]) $' }, 'z'))
    end)

    it('takes embedded code, with its #', function()
      T.eq(
        '#figure(\n  table(1, 2),\n  caption: [C],\n)',
        at({ '#figure(', '  table(1, 2),', '  caption: [C],', ')' }, 'C')
      )
    end)

    it('prefers math inside code', function()
      T.eq('$ y $', at({ '#figure($ y $, caption: [C])' }, 'y'))
    end)

    it('has nothing in prose or in a definition', function()
      T.eq(nil, at({ 'Just text.' }, 'text'))
      T.eq(nil, at({ '#let f(x) = x + 1' }, '+'))
    end)
  end)

  describe('definitions', function()
    before_each(H.need_parser)

    it('collects the top-level definitions before the fragment', function()
      local bufnr = H.buf({
        '= Section',
        '#import "lib.typ": *',
        '#show: conf.with(',
        '  title: [T],',
        ')',
        '#let N = $bb(N)$',
        'Some text.',
        '#show heading: set text(red)',
        '$ N $',
        '#let late = 1',
      })
      T.eq({
        { first = 2, lines = { '#import "lib.typ": *' } },
        { first = 6, lines = { '#let N = $bb(N)$' } },
        { first = 8, lines = { '#show heading: set text(red)' } },
      }, preview.definitions(bufnr, 8))
    end)
  end)

  describe('preamble without templates', function()
    before_each(H.need_parser)

    it('blanks out a #show: template, keeping the line numbers', function()
      local lines =
        { '#import "tpl.typ": conf', '#show: conf.with(', '  title: "T",', ')', '#show heading: strong', 'x' }
      T.eq(
        { '#import "tpl.typ": conf', '', '', '', '#show heading: strong' },
        typst.preamble(lines, dir .. '/main.typ', dir, dir, true)
      )
    end)
  end)

  describe('snacks', function()
    --- A compiled fragment named `preview` in `dir`.
    local function fragment()
      H.write(dir .. '/preview.png', 'PNG')
      return H.project(dir .. '/preview.typ', { format = 'png', ppi = 192 })
    end

    it('shows a fragment in virtual lines below the anchor', function()
      config.setup({ view = { snacks = { scale = 2 } } })
      local state = fake_snacks(true, true)
      local f = fragment()
      local buf = H.buf({ '$', '  x', '$', 'after' })
      viewer.show_fragment(f, snacks.anchor(buf, 2))
      local placed = state.placed
      T.ok(placed)
      T.eq(buf, placed.buf)
      T.eq(true, placed.opts.inline)
      T.matches('/preview%-%d+%.png$', placed.src)
      T.eq(1, vim.fn.filereadable(placed.src))
      T.eq(30, placed.opts.max_width)

      -- The anchor follows edits above it, and the image gets the
      -- resolution it was rendered at, less the magnification.
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'new' })
      placed.opts.on_update_pre(placed)
      T.eq({ 4, 0 }, placed.opts.pos)
      T.eq({ 4, 0, 4, 1 }, placed.opts.range)
      T.eq(96, placed.img.info.dpi.width)

      vim.cmd('TypstPreviewClose')
      T.eq(0, vim.fn.filereadable(placed.src))
      T.eq({}, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
    end)

    it('shows a fragment in a float without placeholders', function()
      local state = fake_snacks(true, false)
      local buf = H.buf({ 'a', 'b', 'c' })
      viewer.show_fragment(fragment(), snacks.anchor(buf, 1))
      local placed = state.placed
      T.ok(placed.buf ~= buf)

      local before = #vim.api.nvim_list_wins()
      placed.opts.on_update_pre(placed)
      local wins = vim.api.nvim_list_wins()
      T.eq(before + 1, #wins)
      local win = wins[#wins]
      T.eq(12, vim.api.nvim_win_get_width(win))
      T.eq({ 1, 0 }, vim.api.nvim_win_get_config(win).bufpos)

      snacks.close()
      T.eq(false, vim.api.nvim_win_is_valid(win))
    end)

    it('is not available without image support, or with view.snacks off', function()
      T.eq(false, snacks.available())
      fake_snacks(false)
      T.eq(false, snacks.available())
      fake_snacks(true, true)
      T.eq(true, snacks.available())
      config.setup({ view = { snacks = { enabled = false } } })
      T.eq(false, snacks.available())
    end)

    it('renders at 96 ppi times the scale', function()
      config.setup({ view = { snacks = { scale = 1.5 } } })
      T.eq(144, snacks.ppi())
    end)

    it('makes typst write the first page as a PNG', function()
      local cmd = typst.build_cmd(H.project(dir .. '/f.typ', { format = 'png', ppi = 192 }))
      T.eq({ '--format', 'png', '--ppi', '192', '--pages', '1' }, vim.list_slice(cmd, #cmd - 7, #cmd - 2))
      T.eq(dir .. '/f.png', cmd[#cmd])
    end)
  end)

  describe('with typst', function()
    local view

    before_each(function()
      H.need_parser()
      H.need_typst()
      view = viewer.view
    end)

    after_each(function()
      viewer.view = view
    end)

    ---@param fragment table
    local function wait(fragment)
      H.wait(function()
        return not compiler.is_running(fragment) and fragment.last_status ~= 'running'
      end, 20000, 'the compilation')
    end

    it('renders the math under the cursor cropped, and shows it below', function()
      local state = fake_snacks(true, true)
      local main = H.write(dir .. '/main.typ', {
        '#let conf(doc) = { [Title block]; doc }',
        '#show: conf',
        '#let N = $bb(N)$',
        'Text.',
        '$ N subset.eq RR $',
        'More.',
      })
      local project = H.project(main)
      H.buf(vim.fn.readfile(main), { name = main })
      H.cursor_at('subset')
      preview.preview(project)
      local fragment = project.fragments.preview
      wait(fragment)
      T.eq('success', fragment.last_status)
      T.ok(state.placed, 'shown with snacks')
      local width, height = png_size(state.placed.src)
      -- A formula, not a page with a title block on it.
      T.ok(width < 300 and height < 100, ('%dx%d'):format(width, height))
      -- Below the formula.
      state.placed.opts.on_update_pre(state.placed)
      T.eq({ 5, 0 }, state.placed.opts.pos)
      T.eq(vim.fn.glob(dir .. '/.*.typ', true, true), {})
    end)

    it('opens the PDF in the viewer without snacks', function()
      local viewed
      viewer.view = function(f, opts)
        viewed = { f, opts }
      end
      local main = H.write(dir .. '/main.typ', { '#figure(rect(), caption: [C])' })
      local project = H.project(main)
      H.buf(vim.fn.readfile(main), { name = main })
      H.cursor_at('rect')
      preview.preview(project)
      local fragment = project.fragments.preview
      wait(fragment)
      T.eq('success', fragment.last_status)
      T.eq(fragment, viewed[1])
      T.eq({ pdf = true }, viewed[2])
      T.ok(vim.uv.fs_stat(fragment.out_dir .. '/preview.pdf'))
    end)

    it('points errors in the fragment and its definitions back at the buffer', function()
      viewer.view = function() end
      local main = H.write(dir .. '/main.typ', { '= Title', '#let ff = nope', 'Text', '$ ff + 1 $' })
      local project = H.project(main)
      H.buf(vim.fn.readfile(main), { name = main })
      H.cursor_at('+')
      preview.preview(project)
      local fragment = project.fragments.preview
      wait(fragment)
      T.eq('failed', fragment.last_status)
      local items = qf.collect(fragment)
      T.ok(#items > 0)
      T.eq(main, items[1].filename)
      T.eq(2, items[1].lnum)
    end)
  end)
end)
