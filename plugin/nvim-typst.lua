-- nvim-typst bootstrap: registers commands and the FileType hook with the
-- default configuration. `require('nvim-typst').setup{}` is optional and only
-- needed to override defaults.
if vim.g.loaded_nvim_typst then
  return
end
vim.g.loaded_nvim_typst = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('[nvim-typst] requires Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

require('nvim-typst').init()
