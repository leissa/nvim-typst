--- typst backend: `typst watch` in continuous mode, `typst compile` otherwise.
---
--- Typst writes nothing but the PDF -- no log, no auxiliary files -- so the
--- diagnostics are read from the compiler output, which `--diagnostic-format
--- short` turns into one `file:line:col: severity: message` line each.
---
--- A watch cycle is framed by two lines: `[12:00:00] compiling ...` when it
--- starts and `[12:00:00] compiled successfully in 3 ms` (or `with warnings`,
--- `with errors`) when it is done. The diagnostics come after the second one.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local ts = require('nvim-typst.ts')
local util = require('nvim-typst.util')

local M = {
  name = 'typst',
  install_hint = 'Install typst: https://github.com/typst/typst#installation',
}

---@param project table
---@param opts table|nil `{ continuous = boolean, target = string }`
---@return string[] cmd
function M.build_cmd(project, opts)
  opts = opts or {}
  local typst = config.get('compiler', 'typst')
  local target = opts.target or project.main

  local cmd = util.as_cmd(typst.executable)
  cmd[#cmd + 1] = opts.continuous and 'watch' or 'compile'
  vim.list_extend(cmd, { '--root', project.root, '--diagnostic-format', 'short' })
  vim.list_extend(cmd, typst.options or {})

  -- A fragment shown in the buffer is rendered as an image, of its first
  -- page: a PNG holds only one.
  if project.format == 'png' then
    vim.list_extend(cmd, { '--format', 'png', '--ppi', tostring(project.ppi), '--pages', '1' })
  end

  -- Typst refuses to write into a directory that is missing.
  util.mkdir(project.out_dir)
  vim.list_extend(cmd, { target, project_mod.output_file(project) })
  return cmd
end

--- The preamble of a document, for compiling a fragment of it: the lines
--- before its first content, as long as they hold nothing but `#set`,
--- `#show`, `#import` and `#let` statements and comments. A `#show:
--- template.with(...)` is part of it, so the fragment gets the template.
---
--- Relative `#import` paths are rewritten against the project root, as the
--- fragment may be compiled from another directory than `file`'s.
---
--- With `drop_templates`, a `#show: template` is blanked out: a template
--- typesets a title block and the like, which a cropped preview of one
--- formula can do without.
---@param lines string[] the main file
---@param file string its path
---@param root string the project root
---@param dir string the directory the fragment is compiled in
---@param drop_templates boolean|nil
---@return string[]|nil preamble, one line per line of `lines`; nil without a parser
function M.preamble(lines, file, root, dir, drop_templates)
  local source = table.concat(lines, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'typst')
  if not ok or not parser then
    return nil
  end
  local tree_root = parser:parse()[1]:root()

  local rows = #lines
  local rewrites = {}
  local blanks = {}
  for node in tree_root:iter_children() do
    if node:named() then
      local kind = node:type()
      local statement = ts.definition(node)
      if statement then
        local path = statement:type() == 'import' and statement:named_child(0)
        if path and path:type() == 'string' then
          rewrites[#rewrites + 1] = path
        end
        if drop_templates and ts.is_template(statement) then
          blanks[#blanks + 1] = node
        end
      elseif kind ~= 'comment' and kind ~= 'parbreak' then
        rows = node:start()
        break
      end
    end
  end

  local out = vim.list_slice(lines, 1, rows)
  for _, node in ipairs(blanks) do
    local sr, _, er = node:range()
    for row = sr + 1, er + 1 do
      out[row] = ''
    end
  end
  if dir == vim.fs.dirname(file) then
    return out
  end
  -- Right to left, so that the columns of the earlier strings stay valid.
  for i = #rewrites, 1, -1 do
    local row, scol, _, ecol = rewrites[i]:range()
    local line = out[row + 1]
    if line then
      local value = line:sub(scol + 2, ecol - 1)
      local resolved = project_mod.resolve(value, file, root)
      if resolved and not value:match('^/') and vim.startswith(resolved, root .. '/') then
        out[row + 1] = line:sub(1, scol) .. '"' .. resolved:sub(#root + 1) .. '"' .. line:sub(ecol + 1)
      end
    end
  end
  return out
end

--- The `#set page(...)` of a fragment shown on its own: as tall as its
--- content, and with `crop` as wide too, without the header, footer and page
--- number the template may set.
---@param crop boolean
---@return string
function M.fragment_page(crop)
  return ('#set page(%sheight: auto, margin: %s, header: none, footer: none, numbering: none)'):format(
    crop and 'width: auto, ' or '',
    config.get('preview', 'border') or '2pt'
  )
end

--- Typst leaves nothing behind but the PDF.
---@param project table
---@param full boolean also remove the PDF
---@return string[]
function M.clean_files(project, full)
  local pdf = project_mod.output_file(project)
  if full and util.is_file(pdf) then
    return { pdf }
  end
  return {}
end

--- Does a new watch cycle start on this line?
---@param line string
---@return boolean
function M.is_start_line(line)
  return line:match('^%[[%d:]+%] compiling') ~= nil
end

--- Is a watch cycle done? Its diagnostics are still to come.
---@param line string
---@return boolean
function M.is_finished_line(line)
  return line:match('^%[[%d:]+%] compiled') ~= nil
end

--- Did typst report a failure on this line?
---@param line string
---@return boolean
function M.is_failure_line(line)
  return line:match('^%[[%d:]+%] compiled with errors') ~= nil
    or line:match('^error: ') ~= nil
    or line:match('^%S.-:%d+:%d+: error: ') ~= nil
end

return M
