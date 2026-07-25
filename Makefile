VIM ?= vim
VIM_TESTS := tests/vim/run.vim \
	tests/vim/config_types.vim \
	tests/vim/layout.vim \
	tests/vim/features.vim \
	tests/vim/daemon_protocol.vim \
	tests/vim/git_render.vim

.PHONY: check test rust-test vim-test install

check: rust-check vim-test

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
