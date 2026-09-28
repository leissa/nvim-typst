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

  -- Typst refuses to write into a directory that is missing.
  util.mkdir(project.out_dir)
  vim.list_extend(cmd, { target, project_mod.output_file(project) })
  return cmd
end

--- Top-level statements that configure the document rather than add to it.
local PREAMBLE = { set = true, show = true, import = true, let = true }

--- The preamble of a document, for compiling a fragment of it: the lines
--- before its first content, as long as they hold nothing but `#set`,
--- `#show`, `#import` and `#let` statements and comments. A `#show:
--- template.with(...)` is part of it, so the fragment gets the template.
---
--- Relative `#import` paths are rewritten against the project root, as the
--- fragment may be compiled from another directory than `file`'s.
---@param lines string[] the main file
---@param file string its path
---@param root string the project root
---@param dir string the directory the fragment is compiled in
---@return string[]|nil preamble, one line per line of `lines`; nil without a parser
function M.preamble(lines, file, root, dir)
  local source = table.concat(lines, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'typst')
  if not ok or not parser then
    return nil
  end
  local tree_root = parser:parse()[1]:root()

  local rows = #lines
  local rewrites = {}
  for node in tree_root:iter_children() do
    if node:named() then
      local kind = node:type()
      local statement = kind == 'code' and node:named_child_count() == 1 and node:named_child(0)
      if statement and PREAMBLE[statement:type()] then
        local path = statement:type() == 'import' and statement:named_child(0)
        if path and path:type() == 'string' then
          rewrites[#rewrites + 1] = path
        end
      elseif kind ~= 'comment' and kind ~= 'parbreak' then
        rows = node:start()
        break
      end
    end
  end

  local out = vim.list_slice(lines, 1, rows)
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
