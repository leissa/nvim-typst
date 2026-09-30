# nvim-typst

[![CI](https://img.shields.io/github/actions/workflow/status/leissa/nvim-typst/ci.yml?branch=master&label=CI&logo=github&style=flat-square)](https://github.com/leissa/nvim-typst/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white&style=flat-square)](https://neovim.io)
[![Lua](https://img.shields.io/badge/made%20with-Lua-2C2D72?logo=lua&logoColor=white&style=flat-square)](https://www.lua.org)

A [Typst](https://typst.app) plugin for Neovim, the sibling of
[nvim-tex](https://github.com/leissa/nvim-tex): the same mappings, commands,
option names and events, with `Tex` replaced by `Typst`.

Two rules shape the design:

- **Neovim only.** No Vimscript, no Vim compatibility layer.
- **Structure from tree-sitter, language intelligence from the LSP.** The
  plugin ships no Typst parser and no syntax-group heuristics of its own.
  Structure comes from the `typst` parse tree; completion, diagnostics,
  references, rename and formatting come from
  [tinymist](https://github.com/Myriad-Dreamin/tinymist).

Motions, text objects, the `ds`/`cs`/`ts` edits, the table of contents,
indentation, folding and conceal read the parse tree. What is left is the part
neither of those covers: finding the main file of a multi-file document,
driving `typst watch` and `typst compile`, the quickfix list, and opening the
PDF or tinymist's live preview.

## Status

Continuous (`typst watch`) and single shot compilation, a quickfix list filled
after every watch cycle, main file and project root detection, tinymist with
the main file pinned, and tinymist's live preview with forward and inverse
search. On the editing side: nvim-tex's motions, text objects and
`ds`/`cs`/`ts` edits translated to Typst, a table of contents across
`#include`s, tree-sitter indentation, folding and conceal, word counts,
compiling a selection on its own, citing from DBLP, insert mode math
mappings (`` `a `` → `alpha`), `K` for a package's Typst Universe page, and a
preview of the formula or figure under the cursor, cropped and shown right in
the buffer with snacks.nvim. A test suite runs in
CI on Neovim 0.10, stable and nightly.

## Requirements

- Neovim 0.10+ (0.11+ recommended)
- [`typst`](https://github.com/typst/typst)
- The `typst` tree-sitter parser — `:TSInstall typst`

Optional: [`tinymist`](https://github.com/Myriad-Dreamin/tinymist) (also for
the live preview), a PDF viewer that reloads a changed file (zathura, sioyek,
okular, Skim), `curl` for `:TypstCite`, and
[snacks.nvim](https://github.com/folke/snacks.nvim) with its image support to
show previews in the buffer.

`:checkhealth nvim-typst` reports what is missing.

## Installation

nvim-typst works without calling `setup`: the defaults apply as soon as the
plugin loads. Call `require('nvim-typst').setup({...})` only to change them.

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'leissa/nvim-typst',
  ft = { 'typst' },
  opts = {},
}
```

`vim.pack` (built into Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/leissa/nvim-typst' })
```

Native packages (`:help packages`):

```sh
git clone https://github.com/leissa/nvim-typst \
  ~/.local/share/nvim/site/pack/plugins/start/nvim-typst
```

## Configuration

```lua
require('nvim-typst').setup({
  compiler = {
    typst = {
      continuous = true,   -- typst watch
      out_dir = 'build',
    },
  },
  view = { general = { executable = 'zathura' } },
  fold = { enabled = true },
})
```

To use tinymist's live preview in the browser instead of a PDF viewer, set
`view = { method = 'tinymist' }`; see [below](#the-preview).

`:TypstInfo!` prints the full effective configuration. The defaults live in
[`lua/nvim-typst/config.lua`](lua/nvim-typst/config.lua) and are documented in
`:help nvim-typst-configuration`.

## Mappings

The keys are nvim-tex's; those whose nvim-tex action has no Typst
counterpart are left unmapped.

| Key              | Action                                               |
| ---------------- | ---------------------------------------------------- |
| `<localleader>l` | start / stop compilation (`typst watch`)             |
| `<localleader>S` | compile once                                         |
| `<localleader>k` | stop — `K` stops all                                 |
| `<localleader>v` | view the PDF, or the preview (forward search)        |
| `<localleader>e` | quickfix list — `E` cycles the level, `o` raw output |
| `<localleader>c` | clean — `C` also removes the PDF                     |
| `<localleader>t` | table of contents — `T` toggles                      |
| `<localleader>i` | project info — `I` full                              |
| `<localleader>g` | status — `G` for all projects                        |
| `<localleader>a` | context menu (reference, citation, include, import)  |
| `<localleader>b` | search DBLP and cite (`:TypstCite`)                  |
| `<localleader>s` | toggle the main file                                 |
| `<localleader>L` | compile the selection as a standalone document       |
| `<localleader>x` | reload — `X` clears project state                    |

Motions (normal, visual, operator-pending, with a count):

| Key       | Motion                                 | Key       | Motion         |
| --------- | -------------------------------------- | --------- | -------------- |
| `]]` `[[` | heading                                | `][` `[]` | section end    |
| `]m` `[m` | function call (`#emph[…]`)             | `]M` `[M` | its end        |
| `]n` `[n` | math start                             | `]N` `[N` | math end       |
| `]/` `[/` | comment                                | `]*` `[*` | end of comment |
| `%`       | matching `$`, `*` or `_`               |           |                |

Text objects: `a$`/`i$` math, `ac`/`ic` function call, `ad`/`id`
delimiters, `am`/`im` list item, `aP`/`iP` section.

Editing: `ds$` `cs$` `ts$` (delete, re-layout, toggle inline/display math),
`dsc` `csc` (unwrap, rename a function call — `*x*` and `_x_` count as
`#strong[x]` and `#emph[x]`), `dsd` `csd` `tsd` (delete, change delimiters,
toggle `lr(…)`), `tsf` (`a/b` ↔ `frac(a, b)`), and `<F7>` to wrap the word or
selection in a call. nvim-tex's insert-mode `]]` is there as
`mappings.insert_close`, off by default since `]]` is ordinary Typst.

`:TypstCountWords` counts the words of the whole document, includes and all,
read off the parse tree; given a range it counts only that, and `!` shows a
per-file report. `:TypstCountLetters` does the same for letters.

`:TypstCite [query]` searches [DBLP](https://dblp.org) for a paper, lets you
pick one and edit its key, appends the BibTeX entry to the first `.bib` file a
`#bibliography(…)` names, and inserts `@key`. Needs `curl`; see
`:help nvim-typst-cite`.

Every mapping has a command behind it (`:TypstCompile`, `:TypstView`,
`:TypstToc`, …), so a different layout is just a matter of mapping those
instead. Groups can be disabled individually via `mappings.motions`,
`mappings.text_objects` and `mappings.surround`.

## The main file

Compilation always runs on the project's main file, never on the buffer you
happen to be in. It is found from `b:typst_main`, the `main_file` option, a
`// !TYPST main = …` directive, an open document that `#include`s or
`#import`s the buffer, or by following the chain of files including it up
the directory tree. A file nothing includes is its own main file.
`<localleader>s` toggles between the detected main file and the current
buffer.

The project root — Typst's `--root`, against which `/figures/a.svg` resolves —
is the nearest directory holding a `typst.toml` or `.git` (`root_markers`),
or else the main file's directory. The compiler runs there, and tinymist is
rooted there too.

## LSP

nvim-typst starts tinymist unless a tinymist client is already attached, and
pins the main file in it, so that an included chapter is checked as part of the
whole document instead of reporting every label it uses as undefined. It sets
`exportPdf = 'never'`, since nvim-typst does the compiling. See
`:help nvim-typst-lsp`.

## The preview

With `view = { method = 'tinymist' }`, `<localleader>v` opens tinymist's live
preview in the browser. It renders the buffers as you type, without
compiling. Once it runs, `<localleader>v` (`:TypstForwardSearch`) scrolls it to
the cursor, and a click in the preview jumps to the source in Neovim — the
Typst counterpart of SyncTeX. `view.tinymist.follow_cursor = true` keeps it
scrolled along. See `:help nvim-typst-preview`.

## Indentation, folding and conceal

nvim-typst sets a tree-sitter `indentexpr`: multi-line `(…)`, `[…]`, `{…}` and
`$…$` indent their contents, and list items keep the structure the parse tree
gives them. `fold = { enabled = true }` folds sections, multi-line code,
math, raw blocks and comments. With `conceallevel` set, `alpha` shows as α,
`RR` as ℝ, `arrow.r` as →, `x^2` as x², `bb(N)` as ℕ and `*bold*` as bold —
only in math where it is math, as the parse tree says. See
`:help nvim-typst-indent`, `nvim-typst-fold` and `nvim-typst-conceal`.

## Documentation

`:help nvim-typst`

## Tests

```sh
make test              # the whole suite
make test SPEC=qf      # one spec file
make fmt-check         # what CI enforces
make parser            # build the `typst` parser into .deps
```

The suite runs in a headless Neovim against `tests/minimal_init.lua` and
brings its own runner (`tests/runner.lua`), so there is nothing to install.
Specs that need the `typst` parser use the one `:TSInstall typst` left in
`stdpath('data')/site/parser`, or the one `make parser` builds into `.deps`,
and skip when there is neither; `NVIM_TYPST_PARSER` points at a specific
`typst.so`. Specs that run the compiler skip when `typst` is not installed.

CI runs the suite on Neovim 0.10, stable and nightly, with the parser built
from the revision of
[tree-sitter-typst](https://github.com/uben0/tree-sitter-typst) that
nvim-treesitter pins.

## Disclaimer

This plugin was mostly created with the help of AI.

## License

[MIT](LICENSE)
