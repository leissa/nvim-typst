--- Show a compiled fragment right in the buffer it comes from, below the
--- line it ends on, with snacks.nvim's image support. Terminals with unicode
--- placeholders (kitty, ghostty) get the image as virtual lines that move
--- with the text; others a floating window anchored to that line. The image
--- stays until the next fragment replaces it or `:TypstPreviewClose`.
---
--- typst renders the fragment as a PNG itself, so unlike nvim-tex's PDFs
--- nothing needs converting. Not a `view.method` backend: it has no forward
--- search, and suits cropped fragments rather than whole documents.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local util = require('nvim-typst.util')

local M = {}

--- snacks.nvim's image module, when `view.snacks.enabled` is on, snacks'
--- image support is enabled and the terminal can show images.
---@return table|nil
function M.image()
  if not config.get('view', 'snacks', 'enabled') then
    return nil
  end
  local ok, snacks = pcall(require, 'snacks')
  local image = ok and type(snacks) == 'table' and snacks.image or nil
  if not image or not image.config or image.config.enabled ~= true or not image.supports_terminal() then
    return nil
  end
  return image
end

--- Is there somewhere to show a fragment in the buffer?
---@return boolean
function M.available()
  return M.image() ~= nil
end

--- The resolution a fragment is rendered at: `view.snacks.scale` times its
--- printed size, on a screen of 96 pixels per inch.
---@return integer
function M.ppi()
  return math.floor(96 * (config.get('view', 'snacks', 'scale') or 1) + 0.5)
end

--- Where to show a fragment: below the line of extmark `mark` in `buf`.
---@class NvimTypstAnchor
---@field buf integer
---@field mark integer

--- The fragment on display.
---@type { buf: integer, mark: integer, placement: table, png: string, win: integer|nil, float_buf: integer|nil }|nil
local shown

local ns = vim.api.nvim_create_namespace('nvim-typst.viewer.snacks')
local augroup = vim.api.nvim_create_augroup('nvim-typst.viewer.snacks', { clear = true })

--- The anchor of the fragment being compiled.
---@type NvimTypstAnchor|nil
local pending

--- Mark line `row` (0-based) of `buf` to show the next fragment below, in
--- place of the previous mark not shown yet.
---@param buf integer
---@param row integer
---@return NvimTypstAnchor
function M.anchor(buf, row)
  if pending and vim.api.nvim_buf_is_valid(pending.buf) then
    vim.api.nvim_buf_del_extmark(pending.buf, ns, pending.mark)
  end
  row = math.max(0, math.min(row, vim.api.nvim_buf_line_count(buf) - 1))
  pending = { buf = buf, mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {}) }
  return pending
end

--- Remove the image, and the file made for it.
function M.close()
  vim.api.nvim_clear_autocmds({ group = augroup })
  if not shown then
    return
  end
  local s = shown
  shown = nil
  s.placement:close()
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_close(s.win, true)
  end
  if s.float_buf and vim.api.nvim_buf_is_valid(s.float_buf) then
    vim.api.nvim_buf_delete(s.float_buf, { force = true })
  end
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_del_extmark(s.buf, ns, s.mark)
  end
  vim.fn.delete(s.png)
end

vim.api.nvim_create_autocmd('VimLeavePre', { callback = M.close })

--- Show the PNG of `fragment` below `anchor`, by default the cursor line.
---@param fragment table
---@param anchor NvimTypstAnchor|nil
---@return boolean shown
function M.show(fragment, anchor)
  local image = M.image()
  if not image then
    return false
  end
  if
    not anchor
    or not vim.api.nvim_buf_is_valid(anchor.buf)
    or #vim.api.nvim_buf_get_extmark_by_id(anchor.buf, ns, anchor.mark, {}) == 0
  then
    anchor = M.anchor(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1] - 1)
  end
  M.close()
  -- snacks caches an image by its path: give every compilation its own, a
  -- hard link or else a copy.
  local png = project_mod.output_file(fragment, 'png')
  local stat = vim.uv.fs_stat(png)
  if not stat then
    return false
  end
  local copy = util.join(fragment.out_dir, ('%s-%d%09d.png'):format(fragment.name, stat.mtime.sec, stat.mtime.nsec))
  vim.fn.delete(copy)
  if not vim.uv.fs_link(png, copy) and not vim.uv.fs_copyfile(png, copy) then
    util.error('could not copy ' .. png)
    return false
  end

  local buf = anchor.buf
  local inline = image.terminal.env().placeholders == true
  local s = { buf = buf, png = copy, mark = anchor.mark }
  if not inline then
    s.float_buf = vim.api.nvim_create_buf(false, true)
  end
  local doc = image.config.doc or {}

  --- The anchor line, 1-based, where edits have moved it.
  ---@return integer
  local function line()
    return vim.api.nvim_buf_get_extmark_by_id(buf, ns, s.mark, {})[1] + 1
  end

  --- Put the image below the anchor line, once snacks knows its size.
  ---@type fun(placement: table)
  local place
  if inline then
    place = function(placement)
      -- The whole line as the range, so snacks puts the image in virtual
      -- lines below it, flush left.
      local l = line()
      local text = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ''
      placement.opts.pos = { l, 0 }
      placement.opts.range = { l, 0, l, #text }
    end
  else
    place = function(placement)
      if s.win then
        return
      end
      local win = vim.fn.bufwinid(buf)
      if win == -1 then
        return
      end
      local loc = placement:state().loc
      s.win = vim.api.nvim_open_win(s.float_buf, false, {
        relative = 'win',
        win = win,
        bufpos = { line() - 1, 0 },
        row = 1,
        col = 0,
        width = loc.width,
        height = loc.height,
        style = 'minimal',
        focusable = false,
      })
      vim.wo[s.win].wrap = false
    end
  end

  if anchor == pending then
    pending = nil
  end
  shown = s
  s.placement = image.placement.new(s.float_buf or buf, copy, {
    inline = inline,
    pos = inline and { line(), 0 } or nil,
    max_width = doc.max_width,
    max_height = doc.max_height,
    on_update_pre = function(placement)
      if shown ~= s then
        return
      end
      -- snacks sizes an image by its pixels over its resolution, which
      -- typst's PNGs do not record (ImageMagick then assumes 72). They are
      -- rendered at 96 ppi times the magnification (`M.ppi`), so 96 shows
      -- them magnified.
      local info = placement.img and placement.img.info
      if info then
        info.dpi = { width = 96, height = 96 }
      end
      place(placement)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = augroup,
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })
  return true
end

return M
