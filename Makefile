VIM ?= vim
VIM_TESTS := tests/vim/run.vim \
	tests/vim/config_types.vim \
	tests/vim/layout.vim \
	tests/vim/features.vim \
	tests/vim/daemon_protocol.vim \
	tests/vim/git_render.vim \
	tests/vim/tabline_memo.vim

.PHONY: check test rust-test vim-test install vim-core defcompile

check: rust-check vim-test defcompile vim-core

.PHONY: rust-check
rust-check:
	cargo fmt -- --check
	cargo clippy --locked --all-targets -- -D warnings
	cargo test --locked --all-targets

test: rust-test vim-test

rust-test:
	cargo test --locked --all-targets

vim-test:
	@for t in $(VIM_TESTS); do \
		echo "== $$t"; \
		$(VIM) -Nu NONE -n -i NONE -es -S $$t || exit 1; \
	done

install:
	./install.sh

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpleline/core.vim.
# ---------------------------------------------------------------------------

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
