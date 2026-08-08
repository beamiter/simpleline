VIM ?= vim
VIM_TESTS := tests/vim/run.vim \
	tests/vim/config_types.vim \
	tests/vim/layout.vim \
	tests/vim/features.vim \
	tests/vim/daemon_protocol.vim \
	tests/vim/git_render.vim \
	tests/vim/tabline_memo.vim \
	tests/vim/render_cache.vim \
	tests/vim/git_files.vim \
	tests/vim/daemon_restart.vim

.PHONY: check test rust-test vim-test install vim-core defcompile core-verify

check: core-verify rust-check vim-test defcompile vim-core

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
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpleline/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
core-verify:
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
