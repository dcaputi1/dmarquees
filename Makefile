# IvarArcade Parent Makefile
# Builds both dmarquees and analyze_games executables

# MAKEFILE_VERSION = 2026-02-10T14:10

# Set the shell configuration specifically for sync-back (policy script)
SHELL := /bin/bash
.ONESHELL:
SHELLFLAGS := -eu -o pipefail -c

.PHONY: all dmarquees analyze_games install install-force clean help sync-back

# Binary install directory for dmarquees daemon
DMARQUEES_BIN_DIR ?= /home/danc/marquees/bin

# NOTE: images and labels are referenced directly from ~/IvarArcade/ - no install needed

all: dmarquees analyze_games

# Build dmarquees
dmarquees:
	@echo "Building dmarquees..."
	@$(MAKE) -C dmarquees

# Build analyze_games
analyze_games:
	@echo "Building analyze_games..."
	@$(MAKE) -C analyze_games

# Install both executables and resources
install: all
	@echo "Installing IvarArcade components..."
	@mkdir -p $(DMARQUEES_BIN_DIR)

	@# Ask dmarquees to exit cleanly via FIFO before updating binaries
	@if pgrep -x dmarquees >/dev/null 2>&1; then \
		echo "Stopping running dmarquees via /tmp/dmarquees_cmd..."; \
		echo "EXIT" > /tmp/dmarquees_cmd || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do \
			if ! pgrep -x dmarquees >/dev/null 2>&1; then \
				break; \
			fi; \
			sleep 0.1; \
		done; \
		if pgrep -x dmarquees >/dev/null 2>&1; then \
			echo "dmarquees still running after EXIT; forcing stop..."; \
			pkill -9 -x dmarquees || true; \
			if pgrep -x dmarquees >/dev/null 2>&1; then \
				echo "Warning: unable to stop dmarquees; install may hit text file busy."; \
			fi; \
		fi; \
	else \
		echo "No running dmarquees process found."; \
	fi
	
	@# Install dmarquees binary
	@if [ ! -f $(DMARQUEES_BIN_DIR)/dmarquees ] || [ dmarquees/dmarquees -nt $(DMARQUEES_BIN_DIR)/dmarquees ]; then \
		cp -p dmarquees/dmarquees $(DMARQUEES_BIN_DIR)/ && echo "Updated: $(DMARQUEES_BIN_DIR)/dmarquees"; \
	else \
		echo "Skipped: $(DMARQUEES_BIN_DIR)/dmarquees (up to date)"; \
	fi
	
	@# Sync McAtariPi5 contents to system (only newer files)
	@# This handles plugins, scripts, configs, and all other system files
	@if [ ! -d McAtariPi5 ]; then \
		echo "Error: McAtariPi5 source directory missing"; \
	else \
		echo "Syncing /opt directory (newer files only)..."; \
			rsync -a --update --no-perms --no-owner --no-group --omit-dir-times --info=NAME --exclude='__pycache__' McAtariPi5/opt/ /opt/; \
			echo "Syncing /home directory (newer files only)..."; \
			rsync -a --update --no-perms --no-owner --no-group --omit-dir-times --info=NAME --exclude='__pycache__' McAtariPi5/home/ /home/; \
		# Ensure all scripts in ~/scripts are executable
		if [ -d "$$HOME/scripts" ]; then \
			chmod +x $$HOME/scripts/*; \
			echo "Set executable: $$HOME/scripts/*"; \
		fi; \
		# Ensure autostart.sh is executable
		if [ -f "/opt/retropie/configs/all/autostart.sh" ]; then \
			chmod +x /opt/retropie/configs/all/autostart.sh; \
			echo "Set executable: /opt/retropie/configs/all/autostart.sh"; \
		fi; \
	fi
	
	@echo "Installation complete!"

# Install with forced overwrite of all files
install-force: all
	@echo "Installing IvarArcade components (forcing overwrites)..."
	@mkdir -p $(DMARQUEES_BIN_DIR)

	@# Ask dmarquees to exit cleanly via FIFO before updating binaries
	@if pgrep -x dmarquees >/dev/null 2>&1; then \
		echo "Stopping running dmarquees via /tmp/dmarquees_cmd..."; \
		echo "EXIT" > /tmp/dmarquees_cmd || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do \
			if ! pgrep -x dmarquees >/dev/null 2>&1; then \
				break; \
			fi; \
			sleep 0.1; \
		done; \
		if pgrep -x dmarquees >/dev/null 2>&1; then \
			echo "dmarquees still running after EXIT; forcing stop..."; \
			pkill -9 -x dmarquees || true; \
			if pgrep -x dmarquees >/dev/null 2>&1; then \
				echo "Warning: unable to stop dmarquees; install may hit text file busy."; \
			fi; \
		fi; \
	else \
		echo "No running dmarquees process found."; \
	fi
	
	@# Force install dmarquees binary
	@cp -fp dmarquees/dmarquees $(DMARQUEES_BIN_DIR)/ && echo "Installed: $(DMARQUEES_BIN_DIR)/dmarquees"

	@# Force sync McAtariPi5 contents to system (overwrite all files)
	@if [ ! -d McAtariPi5 ]; then \
		echo "Error: McAtariPi5 source directory missing"; \
	else \
		echo "Syncing /opt directory (forcing overwrites)..."; \
			rsync -a --no-perms --no-owner --no-group --omit-dir-times --info=NAME --exclude='__pycache__' McAtariPi5/opt/ /opt/; \
			echo "Syncing /home directory (forcing overwrites)..."; \
			rsync -a --no-perms --no-owner --no-group --omit-dir-times --info=NAME --exclude='__pycache__' McAtariPi5/home/ /home/; \
		# Ensure autostart.sh is executable
		if [ -f "/opt/retropie/configs/all/autostart.sh" ]; then \
			chmod +x /opt/retropie/configs/all/autostart.sh; \
			echo "Set executable: /opt/retropie/configs/all/autostart.sh"; \
		fi; \
	fi
	
	@echo "Force installation complete!"


# Clean all build artifacts
clean:
	@echo "Cleaning all build artifacts..."
	@$(MAKE) -C dmarquees clean
	@$(MAKE) -C analyze_games clean
	@rm -f build.log
	@echo "Clean complete."

# Uninstall
uninstall:
	@echo "Removing installed files..."
	@rm -f $(DMARQUEES_BIN_DIR)/dmarquees
	@rmdir --ignore-fail-on-non-empty $(DMARQUEES_BIN_DIR) || true
	@echo "Uninstall complete."

# Help
help:
	@echo "IvarArcade Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  all           - Build both dmarquees and analyze_games (default)"
	@echo "  dmarquees     - Build only dmarquees executable"
	@echo "  analyze_games - Build only analyze_games executable"
	@echo "  install       - Build and install all components (skip existing)"
	@echo "  install-force - Build and install all components (overwrite all)"

	@echo "  clean         - Remove all build artifacts"
	@echo "  uninstall     - Remove installed files (untested)"
	@echo "  sync-back     - Syncs deployed /opt/retropie MAME ctrlr updates back to ./McAtariPi5"
	@echo "  help          - Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  DMARQUEES_BIN_DIR - dmarquees binary install dir (default: /home/danc/marquees/bin)"
	@echo ""
	@echo "Note: images and labels are read directly from ~/IvarArcade/ - no install required"
	@echo ""
	@echo "Examples:"
	@echo "  make"
	@echo "  make install"
	@echo "  make clean"

sync-back:
	@echo "Syncing back updated config from /opt/retropie to project..."

	ROOT="$$(pwd)"
	SRC="/opt/retropie"
	DST="$$ROOT/McAtariPi5/opt/retropie"
	MAME_DIR="$$SRC/emulators/mame"

	# --- safety checks ---
	[[ -d "$$SRC" ]] || { echo "ERROR: $$SRC not found"; exit 1; }
	[[ -d "$$DST" ]] || { echo "ERROR: destination tree not found: $$DST"; exit 1; }

	# The temporary cfg directory is optional and may be absent after merges.
	# sync-back only needs to pull updated controller profiles from the deployment tree.
	if [[ -d "$$MAME_DIR/cfg_ra" ]] || [[ -d "$$MAME_DIR/cfg_sa" ]]; then
		echo "ERROR: Legacy folders detected under $$MAME_DIR (cfg_ra / cfg_sa)."
		echo "       Remove them from the Pi before running sync-back."
		exit 1
	fi

	# --- config knobs you maintain ---
	# 1) Controller profiles in the repo copy that may be updated from the deployment tree.
	#    Only files already present in the repo copy are considered.
	# 2) Useful sections for XML .cfg files
	USEFUL_CFG_SECTIONS=(input video)

	# Return 0 if: XML-ish .cfg AND it contains NONE of the useful sections.
	is_default_only_cfg() {
		local f="$$1"
		# Only apply rule to XML-ish cfg files; non-XML cfg files are always allowed.
		if ! head -n 5 "$${f}" 2>/dev/null | grep -qiE '^\s*<\?xml|<mameconfig\b|^\s*<'; then
			return 1
		fi
		local tag_re=""
		local t
		for t in "$${USEFUL_CFG_SECTIONS[@]}"; do
			tag_re+="<\\s*$$t\\b|"
		done
		tag_re="$${tag_re%|}"
		# If we find ANY useful section tag, it is NOT default-only.
		grep -qiE "$${tag_re}" "$${f}" && return 1
		return 0
	}

	# --- Phase A: sync only MODIFIED controller profiles that ALREADY EXIST in the target tree ---
	d="ctrlr"
	src_dir="$$MAME_DIR/$$d"
	dst_dir="$$DST/emulators/mame/$$d"
	[[ -d "$${src_dir}" ]] || { echo "WARNING: Missing deployment folder: $$src_dir; skipping ctrlr sync."; exit 0; }
	[[ -d "$${dst_dir}" ]] || { echo "ERROR: Missing target folder (must already exist): $$dst_dir"; exit 1; }

	find "$${dst_dir}" -maxdepth 1 -type f -print0 \
	| while IFS= read -r -d '' f; do
		rel="$${f#$$dst_dir/}"
		src_file="$$src_dir/$$rel"
		if [[ -f "$${src_file}" ]]; then
			rsync -ai --existing --update \
				--no-perms --no-owner --no-group --omit-dir-times --exclude='__pycache__' \
				"$$src_file" "$${f}"
		fi
	  done

	@echo "sync-back: $$SRC/ -> $$DST/ ... complete!"
