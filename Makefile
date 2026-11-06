.PHONY: test lab lint package install clean

# Path to the Factorio binary (auto-detected from Steam install on macOS)
FACTORIO_BIN ?= $(HOME)/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio

VERSION := $(shell sed -n 's/.*"version": "\([^"]*\)".*/\1/p' info.json)
MOD_NAME := freight-stations-rats-fork
PACKAGE_DIR := $(MOD_NAME)_$(VERSION)
RELEASES_DIR := releases
PACKAGE_ZIP := $(RELEASES_DIR)/$(PACKAGE_DIR).zip

# Headless lab (scenario fs-test with the fs-test driver mod). Set up once:
#   make lab-setup LAB_DIR=../test-env
# then `make lab` re-syncs this repo into the lab and runs the full suite.
LAB_DIR ?= ../test-env
LAB_PORT ?= 34199

# Default Factorio mods dir per OS for `make install`
UNAME_S := $(shell uname -s 2>/dev/null)
ifeq ($(UNAME_S),Darwin)
	FACTORIO_MODS_DIR ?= $(HOME)/Library/Application Support/factorio/mods
else ifneq ($(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)),)
	FACTORIO_MODS_DIR ?= $(APPDATA)/Factorio/mods
else
	FACTORIO_MODS_DIR ?= $(HOME)/.factorio/mods
endif

# `make test` runs everything runnable without a display: the headless lab
# covers blueprint round-trips, flip pastes (iron/steel, raw/aligned) and the
# placement predicate; luacheck runs when installed.
test: lab lint

lab:
	FACTORIO_BIN="$(FACTORIO_BIN)" LAB_DIR="$(LAB_DIR)" LAB_PORT="$(LAB_PORT)" sh tests/run-lab.sh

lab-setup:
	@echo "Creates a headless lab at $(LAB_DIR):"
	@echo "  1. mkdir -p $(LAB_DIR)/mods && cp -R tests/lab/mods/. $(LAB_DIR)/mods/"
	@echo "  2. cp -R tests/lab/scenarios $(LAB_DIR)/"
	@echo "  3. cp tests/lab/test-env-config.ini $(LAB_DIR)/../  (adjust write-data)"
	@echo "See tests/run-lab.sh for the exact invocation."

lint:
	@command -v luacheck >/dev/null 2>&1 && luacheck . || \
		echo "luacheck not installed (brew install luacheck) - skipping"

package:
	@echo "Packaging $(MOD_NAME) $(VERSION)..."
	@rm -rf $(PACKAGE_DIR) $(RELEASES_DIR)
	@mkdir -p $(RELEASES_DIR)
	@mkdir -p $(PACKAGE_DIR)
# Files shipped in the zip: info.json + Lua are runtime requirements,
# changelog.txt is shown by the in-game mod list, thumbnail.png is read by
# the mod portal, and LICENSE must accompany MIT-licensed distributions.
# README.md, tests/, the Makefile and .luacheckrc are repo-only and stay out.
	@cp -r changelog.txt control.lua data.lua data-final-fixes.lua info.json LICENSE thumbnail.png $(PACKAGE_DIR)/
	@cp -R graphics locale prototypes scripts $(PACKAGE_DIR)/
	@zip -r $(PACKAGE_DIR).zip $(PACKAGE_DIR) >/dev/null
	@mv $(PACKAGE_DIR).zip $(RELEASES_DIR)/
	@rm -rf $(PACKAGE_DIR)
	@echo "Created $(PACKAGE_ZIP)"

install: package
	@mkdir -p "$(FACTORIO_MODS_DIR)"
	@if [ -f "$(FACTORIO_MODS_DIR)/freight-stations_0.12.9.zip" ]; then \
		echo "WARNING: the original freight-stations_0.12.9.zip is in $(FACTORIO_MODS_DIR)."; \
		echo "  The fork must replace it (same entity prototypes - never run both)."; \
		echo "  Move it away first, e.g.:"; \
		echo "    mv \"$(FACTORIO_MODS_DIR)/freight-stations_0.12.9.zip\" \"\$$HOME/freight-stations_0.12.9.zip.bak\""; \
	fi
	@if [ -d "$(FACTORIO_MODS_DIR)/$(PACKAGE_DIR)" ]; then \
		echo "Removing previous $(PACKAGE_DIR) folder install..."; \
		rm -rf "$(FACTORIO_MODS_DIR)/$(PACKAGE_DIR)"; \
	fi
	@cp "$(PACKAGE_ZIP)" "$(FACTORIO_MODS_DIR)/"
	@echo "Installed $(PACKAGE_DIR).zip to $(FACTORIO_MODS_DIR)"
	@echo "(Remove or rename any freight-stations_*.zip there before starting the game.)"

clean:
	@rm -rf $(RELEASES_DIR) $(PACKAGE_DIR)
