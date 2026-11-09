# LLM Usage for Linux — build and run the tray app (Rust + gpui).
#
# `make` builds and (re)starts it. The app lives in the system tray and has no
# window until you click it, so `run` detaches and returns.

# rustup's default location, for shells whose PATH does not include it.
CARGO ?= $(or $(shell command -v cargo 2>/dev/null),$(HOME)/.cargo/bin/cargo)
BIN := target/release/llm-usage
DEBUG_BIN := target/debug/llm-usage
OUT ?= target/preview
FIXTURE ?= baseline
PREFIX ?= $(HOME)/.local
APPLICATIONS := $(PREFIX)/share/applications
AUTOSTART_DIR := $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/autostart
# Set AUTOSTART=0 to install without starting at login.
AUTOSTART ?= 1

.DEFAULT_GOAL := run
.PHONY: run build release stop probe demo icon test lint install uninstall clean help

## run: build, replace any running instance, and start detached
run: build stop
	@nohup "$(DEBUG_BIN)" >/dev/null 2>&1 & \
	sleep 1; \
	pid=$$(pgrep -xo llm-usage); \
	if [ -n "$$pid" ]; then echo "running  pid $$pid"; \
	else echo "failed to start" >&2; exit 1; fi

## build: compile the debug binary
build:
	@"$(CARGO)" build

## release: compile optimised and report the binary path
release:
	@"$(CARGO)" build --release
	@echo "$(BIN)"

## stop: terminate a running instance (daemon and panel), if any
stop:
	@pkill -x llm-usage 2>/dev/null && echo "stopped" || true

## probe: print every source's normalised usage, no GUI
probe: build
	@"$(DEBUG_BIN)" --probe

## demo: open the panel on fixed data (FIXTURE=baseline|states|severity)
demo: build
	@"$(DEBUG_BIN)" --demo "$(FIXTURE)"

## icon: render the tray artwork to PNGs in OUT
icon: build
	@mkdir -p "$(OUT)"
	@"$(DEBUG_BIN)" --icon "$(OUT)"

## test: run the unit tests (no real credentials or provider requests)
test:
	@"$(CARGO)" test

## lint: formatting and clippy, warnings as errors
lint:
	@"$(CARGO)" fmt --check
	@"$(CARGO)" clippy --all-targets -- -D warnings

## install: build optimised, install to PREFIX (~/.local), add a menu entry and autostart
install: release
	@$(MAKE) --no-print-directory stop
	@install -Dm755 "$(BIN)" "$(PREFIX)/bin/llm-usage"
	@mkdir -p "$(APPLICATIONS)"
	@sed 's|@BIN@|$(PREFIX)/bin/llm-usage|' packaging/llm-usage.desktop > "$(APPLICATIONS)/llm-usage.desktop"
	@if [ "$(AUTOSTART)" = 1 ]; then \
	  mkdir -p "$(AUTOSTART_DIR)"; \
	  cp "$(APPLICATIONS)/llm-usage.desktop" "$(AUTOSTART_DIR)/llm-usage.desktop"; \
	  echo "autostart $(AUTOSTART_DIR)/llm-usage.desktop"; \
	fi
	@nohup "$(PREFIX)/bin/llm-usage" >/dev/null 2>&1 &
	@echo "installed $(PREFIX)/bin/llm-usage"

## uninstall: remove the binary, menu entry and autostart entry
uninstall:
	@pkill -x llm-usage 2>/dev/null || true
	@rm -f "$(PREFIX)/bin/llm-usage" "$(APPLICATIONS)/llm-usage.desktop" "$(AUTOSTART_DIR)/llm-usage.desktop"
	@echo "removed  $(PREFIX)/bin/llm-usage"

## clean: remove build products
clean: stop
	@"$(CARGO)" clean

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
