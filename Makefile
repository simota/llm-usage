# LLM Usage — build and run the menu bar app.
#
# `make` builds and (re)starts it. The app is an accessory: it has no window and
# no Dock icon, so `run` detaches and returns rather than holding the terminal.

BIN := $(shell swift build --show-bin-path 2>/dev/null | tail -1)/LLMUsage
# Release artefacts ship universal so one zip covers both architectures; a local
# `make app` stays native, since doubling the build for your own machine is waste.
ARCHS ?=
RELEASE_FLAGS := -c release $(foreach a,$(ARCHS),--arch $(a))
# Lazy: resolving the release path costs a manifest load, and only these need it.
RELEASE_BIN = $(shell swift build $(RELEASE_FLAGS) --show-bin-path 2>/dev/null | tail -1)/LLMUsage
OUT ?= .build/preview

VERSION ?= 0.1.2
APP := .build/LLMUsage.app
DIST := .build/dist
# The zip holds LLMUsage-<version>/LLMUsage.app rather than a bare bundle:
# Homebrew descends into a single top-level directory, and if that directory is
# the .app itself the formula lands *inside* the bundle.
STAGE = $(DIST)/LLMUsage-$(VERSION)
ZIP = $(DIST)/LLMUsage-$(VERSION).zip
ICONSET := .build/LLMUsage.iconset
ICNS := .build/AppIcon.icns
# Match installed instances by the bundle-relative path, not by $(INSTALLED):
# a running process reports /private/var… where the prefix said /var…, so an
# absolute-path pkill silently misses and leaves the old copy running.
APP_PROC := LLMUsage.app/Contents/MacOS/LLMUsage
# /Applications is group-writable by admin on macOS, so this needs no sudo for
# the usual single-admin machine. Override with PREFIX= if it is not.
PREFIX ?= /Applications
INSTALLED := $(PREFIX)/LLMUsage.app

.DEFAULT_GOAL := run
.PHONY: run build stop restart release probe panel icon icns app dist install uninstall clean help

## run: build, replace any running instance, and start detached
run: build stop
	@nohup "$(BIN)" >/dev/null 2>&1 & \
	sleep 1; \
	pid=$$(pgrep -f "$(BIN)" | head -1); \
	if [ -n "$$pid" ]; then echo "running  pid $$pid"; \
	else echo "failed to start" >&2; exit 1; fi

## build: compile the debug binary
build:
	@swift build

## stop: terminate a running instance, if any
stop:
	@pkill -f "$(BIN)" 2>/dev/null && echo "stopped" || true

## restart: stop and run
restart: run

## release: compile optimised and report the binary path
release:
	@swift build $(RELEASE_FLAGS)
	@echo "$(RELEASE_BIN)"

## probe: print every source's normalised usage, no GUI
probe: build
	@"$(BIN)" --probe

## panel: render the panel to PNGs (light and dark) and open them
panel: build
	@mkdir -p "$(OUT)"
	@"$(BIN)" --panel "$(OUT)"
	@open "$(OUT)/panel-light.png" "$(OUT)/panel-dark.png"

## icon: render the menu bar artwork to PNGs and open them
icon: build
	@mkdir -p "$(OUT)"
	@"$(BIN)" --icon "$(OUT)"
	@open "$(OUT)"/menubar-*.png

## icns: draw the app icon at every size and pack it into an .icns
icns: build
	@rm -rf "$(ICONSET)"
	@"$(BIN)" --appicon "$(ICONSET)" >/dev/null
	@iconutil -c icns "$(ICONSET)" -o "$(ICNS)"
	@echo "built    $(ICNS)"

## app: assemble a release .app bundle in .build/ (ARCHS= for a universal one)
app: icns
	@swift build $(RELEASE_FLAGS)
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@sed 's/__VERSION__/$(VERSION)/g' packaging/Info.plist > "$(APP)/Contents/Info.plist"
	@cp "$(ICNS)" "$(APP)/Contents/Resources/AppIcon.icns"
	@cp "$(RELEASE_BIN)" "$(APP)/Contents/MacOS/LLMUsage"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@codesign --force --sign - "$(APP)" 2>/dev/null \
	  && echo "signed   ad-hoc" \
	  || echo "unsigned (codesign unavailable)"
	@echo "built    $(APP)  v$(VERSION)"

## dist: build a universal .app and zip it for a GitHub release
dist:
	@$(MAKE) --no-print-directory app ARCHS="arm64 x86_64"
	@rm -rf "$(DIST)"
	@mkdir -p "$(STAGE)"
# ditto, not cp or zip: it is what preserves the bundle's signature through the
# round trip, and an arm64 binary without one will not execute at all.
	@ditto "$(APP)" "$(STAGE)/LLMUsage.app"
	@ditto -c -k --sequesterRsrc --keepParent "$(STAGE)" "$(ZIP)"
	@echo "built    $(ZIP)"
	@echo "sha256   $$(shasum -a 256 "$(ZIP)" | cut -d' ' -f1)"
	@lipo -archs "$(APP)/Contents/MacOS/LLMUsage" | sed 's/^/archs    /'

## install: build the bundle, put it in /Applications (PREFIX=) and launch it
install: app
	@$(MAKE) --no-print-directory stop
	@pkill -f "$(APP_PROC)" 2>/dev/null || true
	@mkdir -p "$(PREFIX)" 2>/dev/null || true
	@if [ ! -w "$(PREFIX)" ]; then \
	  echo "$(PREFIX) is not writable — rerun with sudo, or PREFIX=$$HOME/Applications" >&2; \
	  exit 1; \
	fi
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP)" "$(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "installed $(INSTALLED)"
	@echo "note: macOS may ask for keychain access again after a rebuild — an"
	@echo "      ad-hoc signature changes every time and the ACL is bound to it."

## uninstall: remove the installed bundle
uninstall:
	@pkill -f "$(APP_PROC)" 2>/dev/null || true
	@rm -rf "$(INSTALLED)" && echo "removed  $(INSTALLED)"

## clean: remove build products
clean: stop
	@rm -rf .build

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
