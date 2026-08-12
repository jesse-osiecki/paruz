# SPDX-License-Identifier: GPL-3.0-or-later
# paruz — build/install/test targets.
#
# paruz is pure Bash, so "build" means "validate" (syntax + optional lint),
# not compile. Install layout is PREFIX-relative and DESTDIR-aware so it works
# both for `sudo make install` and inside a PKGBUILD's package() step.

PREFIX      ?= /usr
BINDIR      ?= $(PREFIX)/bin
LIBDIR      ?= $(PREFIX)/lib/paruz/lib
SHAREDIR    ?= $(PREFIX)/share/paruz
SYSCONFDIR  ?= /etc/paruz
BASHCOMPDIR ?= $(PREFIX)/share/bash-completion/completions
ZSHCOMPDIR  ?= $(PREFIX)/share/zsh/site-functions
LICENSEDIR  ?= $(PREFIX)/share/licenses/paruz
DOCDIR      ?= $(PREFIX)/share/doc/paruz

INSTALL         := install
INSTALL_PROGRAM := $(INSTALL) -Dm755
INSTALL_DATA    := $(INSTALL) -Dm644

BIN_SCRIPTS  := bin/paruz bin/paruz-setup
LIB_SCRIPTS  := $(wildcard lib/*.sh)

.PHONY: all build check test lint install uninstall clean help

all: build

## build: validate every script parses (bash -n) — the "compile" step for Bash
build:
	@echo "==> syntax-checking scripts"
	@for f in $(BIN_SCRIPTS) $(LIB_SCRIPTS) tests/run.sh; do \
		bash -n "$$f" && echo "    ok  $$f" || exit 1; \
	done
	@echo "==> build ok (pure Bash: nothing to compile)"

## lint: run shellcheck if available (no-op with a note if it isn't)
lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "==> shellcheck"; \
		shellcheck -x $(BIN_SCRIPTS) tests/run.sh; \
		echo "    shellcheck clean"; \
	else \
		echo "==> shellcheck not installed — skipping lint (install 'shellcheck' to enable)"; \
	fi

## test: run the fast, non-privileged acceptance tier (tests/run.sh)
## For the live tier (real chroot builds/installs) use the VM rig: testrig/run.sh
test: build lint
	@echo "==> fast test tier"
	@./tests/run.sh

## check: alias for test
check: test

## install: place all files under $(DESTDIR)$(PREFIX) (DESTDIR-aware for packaging)
install:
	@echo "==> installing to $(DESTDIR)$(PREFIX)"
	$(INSTALL_PROGRAM) bin/paruz        $(DESTDIR)$(BINDIR)/paruz
	$(INSTALL_PROGRAM) bin/paruz-setup  $(DESTDIR)$(BINDIR)/paruz-setup
	@for f in $(LIB_SCRIPTS); do \
		echo "    $(INSTALL_DATA) $$f -> $(DESTDIR)$(LIBDIR)/$$(basename $$f)"; \
		$(INSTALL_DATA) "$$f" "$(DESTDIR)$(LIBDIR)/$$(basename $$f)"; \
	done
	$(INSTALL_DATA) share/known-bad-packages.txt $(DESTDIR)$(SHAREDIR)/known-bad-packages.txt
	$(INSTALL_DATA) etc/paruz.conf      $(DESTDIR)$(SYSCONFDIR)/paruz.conf
	$(INSTALL_DATA) completions/paruz.bash $(DESTDIR)$(BASHCOMPDIR)/paruz
	$(INSTALL_DATA) completions/_paruz  $(DESTDIR)$(ZSHCOMPDIR)/_paruz
	$(INSTALL_DATA) LICENSE             $(DESTDIR)$(LICENSEDIR)/LICENSE
	$(INSTALL_DATA) README.md           $(DESTDIR)$(DOCDIR)/README.md
	$(INSTALL_DATA) PLAN.md             $(DESTDIR)$(DOCDIR)/PLAN.md
	@echo "==> installed. Run 'paruz-setup' next to configure the build chroot / local repo / pacman.conf."

## uninstall: remove installed files (mirror of install; not for pacman-managed installs)
uninstall:
	@echo "==> removing installed files from $(DESTDIR)$(PREFIX)"
	rm -f  $(DESTDIR)$(BINDIR)/paruz $(DESTDIR)$(BINDIR)/paruz-setup
	rm -rf $(DESTDIR)$(PREFIX)/lib/paruz
	rm -rf $(DESTDIR)$(SHAREDIR)
	rm -f  $(DESTDIR)$(BASHCOMPDIR)/paruz $(DESTDIR)$(ZSHCOMPDIR)/_paruz
	rm -rf $(DESTDIR)$(LICENSEDIR) $(DESTDIR)$(DOCDIR)
	@echo "note: $(SYSCONFDIR)/paruz.conf left in place (may hold local edits); remove by hand if desired."
	@echo "note: this does NOT undo 'paruz-setup' system state — run 'paruz-setup --uninstall' for that."

## clean: nothing to clean (no build artifacts), present for convention
clean:
	@echo "nothing to clean (pure Bash, no build artifacts)"

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
