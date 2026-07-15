VIM ?= vim

.PHONY: check test rust-test vim-test install

check:
	cargo fmt -- --check
	cargo clippy --locked --all-targets -- -D warnings
	cargo test --locked --all-targets
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/run.vim
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/config_types.vim
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/layout.vim
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/daemon_protocol.vim

test: rust-test vim-test

rust-test:
	cargo test --locked --all-targets

vim-test:
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/run.vim
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/config_types.vim
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/layout.vim
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim/daemon_protocol.vim

install:
	./install.sh
