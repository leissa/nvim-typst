NVIM ?= nvim

# One spec instead of the whole suite: `make test SPEC=qf`, `SPEC='qf project'`.
SPEC ?=

# Pinned so a parser rebuild does not silently change what the tests exercise.
# This is the revision nvim-treesitter installs. The repository ships the
# generated parser.c (ABI 14, understood by every Neovim from 0.10 on), so
# building it needs a C compiler but not the tree-sitter CLI.
TS_TYPST_REV ?= 46cf4ded12ee974a70bf8457263b67ad7ee0379d

DEPS := .deps
PARSER := $(DEPS)/parser/typst.so

.PHONY: test fmt fmt-check doc parser clean

## Run the whole suite, or a single file with `make test SPEC=qf`. Specs that
## need the `typst` parser or compiler skip when it is missing; `make parser`
## builds the parser into .deps.
test:
	SPEC="$(SPEC)" $(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "lua require('tests.runner').main()"

## Reformat the tree.
fmt:
	stylua lua plugin tests

## What CI enforces.
fmt-check:
	stylua --check lua plugin tests

## Regenerate doc/tags.
doc:
	$(NVIM) --headless --clean -c 'helptags doc' -c q

## Build the `typst` tree-sitter parser into .deps/parser, which
## tests/minimal_init.lua loads.
parser: $(PARSER)

$(PARSER):
	rm -rf $(DEPS)/tree-sitter-typst
	git clone --filter=blob:none https://github.com/uben0/tree-sitter-typst \
		$(DEPS)/tree-sitter-typst
	git -C $(DEPS)/tree-sitter-typst checkout --quiet $(TS_TYPST_REV)
	mkdir -p $(DEPS)/parser
	$(CC) -O2 -fPIC -shared -I $(DEPS)/tree-sitter-typst/src -o $@ \
		$(DEPS)/tree-sitter-typst/src/parser.c $(DEPS)/tree-sitter-typst/src/scanner.c

clean:
	rm -rf $(DEPS) doc/tags
