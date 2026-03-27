# IvarArcade Parent Makefile
# Builds both dmarquees and analyze_games executables

# MAKEFILE_VERSION = 2026-02-10T14:10

# Set the shell configuration specifically for sync-back (policy script)
SHELL := /bin/bash
.ONESHELL:
SHELLFLAGS := -eu -o pipefail -c

.PHONY: all dmarquees analyze_games install install-force install-pi3 clean help sync-back

# Install directory (fixed to arcade user path so sudo/non-sudo behave the same)
INSTALL_DIR ?= /home/danc/marquees

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
	@mkdir -p $(INSTALL_DIR)/bin
	
	@# Install executables
	@if [ ! -f $(INSTALL_DIR)/bin/dmarquees ] || [ dmarquees/dmarquees -nt $(INSTALL_DIR)/bin/dmarquees ]; then \
		cp -p dmarquees/dmarquees $(INSTALL_DIR)/bin/ && echo "Updated: $(INSTALL_DIR)/bin/dmarquees"; \
	else \
		echo "Skipped: $(INSTALL_DIR)/bin/dmarquees (up to date)"; \
	fi
	
	@# Install runtime resources (images directory)
	@if [ -d images ]; then \
		if [ ! -d $(INSTALL_DIR)/images ]; then \
			cp -a images $(INSTALL_DIR)/ && echo "Updated: $(INSTALL_DIR)/images"; \
		else \
			echo "Skipped: $(INSTALL_DIR)/images (already exists)"; \
		fi; \
	fi

	@# Install panel label mappings
	@if [ -d labels ]; then \
		mkdir -p $(INSTALL_DIR)/labels; \
		rsync -a --update labels/ $(INSTALL_DIR)/labels/ && echo "Updated: $(INSTALL_DIR)/labels"; \
	fi
	
	@# Install plugins to local directory
	@if [ -d plugins ]; then \
		if [ ! -d $(INSTALL_DIR)/plugins ]; then \
			cp -a plugins $(INSTALL_DIR)/ && echo "Updated: $(INSTALL_DIR)/plugins"; \
		else \
			echo "Skipped: $(INSTALL_DIR)/plugins (already exists)"; \
		fi; \
	fi
	
	@# Sync McAtariPi5 contents to system (only newer files)
	@# This handles plugins, scripts, configs, and all other system files
	@if [ ! -d McAtariPi5 ]; then \
		echo "Error: McAtariPi5 source directory missing"; \
	else \
		echo "Syncing /opt directory (newer files only)..."; \
		rsync -a --update --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS McAtariPi5/opt/ /opt/; \
		echo "Syncing /home directory (newer files only)..."; \
		rsync -a --update --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS McAtariPi5/home/ /home/; \
	fi
	
	@echo "Installation complete!"

# Install with forced overwrite of all files
install-force: all
	@echo "Installing IvarArcade components (forcing overwrites)..."
	@mkdir -p $(INSTALL_DIR)/bin
	
	@# Force install executables
	@cp -fp dmarquees/dmarquees $(INSTALL_DIR)/bin/ && echo "Installed: $(INSTALL_DIR)/bin/dmarquees"
	
	@# Force install runtime resources (images directory)
	@if [ -d images ]; then \
		cp -af images $(INSTALL_DIR)/ && echo "Installed: $(INSTALL_DIR)/images"; \
	fi

	@# Force install panel label mappings
	@if [ -d labels ]; then \
		cp -af labels $(INSTALL_DIR)/ && echo "Installed: $(INSTALL_DIR)/labels"; \
	fi
	
	@# Force sync McAtariPi5 contents to system (overwrite all files)
	@if [ ! -d McAtariPi5 ]; then \
		echo "Error: McAtariPi5 source directory missing"; \
	else \
		echo "Syncing /opt directory (forcing overwrites)..."; \
		rsync -a --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS McAtariPi5/opt/ /opt/; \
		echo "Syncing /home directory (forcing overwrites)..."; \
		rsync -a --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS McAtariPi5/home/ /home/; \
	fi
	
	@echo "Force installation complete!"

# Pi3-focused deploy target: installs binaries + service assets and enables services.
# Usage (on Pi3): sudo make install-pi3
install-pi3: all
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Error: install-pi3 must run as root"; \
		echo "Run: sudo make install-pi3"; \
		exit 1; \
	fi
	@echo "Installing Pi3 marquee stack..."
	@mkdir -p /home/danc/scripts

	@# Stop running services before replacing binaries to avoid "Text file busy"
	@systemctl stop dmarquees-daemon.service dmarquees-netbridge.service dmarquees-mount.service 2>/dev/null || true

	@# Runtime binary + assets under /home/danc/marquees
	@$(MAKE) install INSTALL_DIR=/home/danc/marquees

	@# Stage Pi3 service scripts and assets
	@rsync -a --exclude '__pycache__/' McAtariPi5/home/danc/scripts/ /home/danc/scripts/
	@chmod 0755 /home/danc/scripts/install-dmarquees-mount-service.sh /home/danc/scripts/install-dmarquees-daemon-service.sh /home/danc/scripts/install-dmarquees-netbridge-service.sh /home/danc/scripts/dmarquees-send.sh || true
	@chown -R danc:danc /home/danc/scripts /home/danc/marquees || true

	@# Install and enable services
	@/home/danc/scripts/install-dmarquees-mount-service.sh
	@/home/danc/scripts/install-dmarquees-daemon-service.sh
	@/home/danc/scripts/install-dmarquees-netbridge-service.sh

	@# Pi3-safe defaults
	@printf '%s\n' \
		'DMARQUEES_USER=danc' \
		'DMARQUEES_ZIP=/home/danc/MAME_0.256_EXTRAs/marquees.zip' \
		'DMARQUEES_MNT=/home/danc/mnt/marquees' \
		>/etc/default/dmarquees-mount
	@printf '%s\n' \
		'DMARQUEES_USER=danc' \
		'DMARQUEES_FRONTEND=NA' \
		'DMARQUEES_DRM_DEVICE=/dev/dri/card0' \
		>/etc/default/dmarquees-daemon

	@systemctl daemon-reload
	@systemctl restart dmarquees-mount.service dmarquees-daemon.service dmarquees-netbridge.service
	@systemctl --no-pager --full status dmarquees-mount.service dmarquees-daemon.service dmarquees-netbridge.service || true
	@echo "Pi3 install complete."

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
	@rm -f $(INSTALL_DIR)/bin/dmarquees
	@rm -rf $(INSTALL_DIR)/images
	@rm -rf $(INSTALL_DIR)/plugins
	@rmdir --ignore-fail-on-non-empty $(INSTALL_DIR)/bin || true
	@rmdir --ignore-fail-on-non-empty $(INSTALL_DIR) || true
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
	@echo "  install-pi3   - One-command Pi3 deploy (services + defaults)"
	@echo "  clean         - Remove all build artifacts"
	@echo "  uninstall     - Remove installed files (untested)"
	@echo "  sync-back     - Copies lr-mame/MAME config from /opt/ to ./McAtariPi5"
	@echo "  help          - Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  INSTALL_DIR   - Installation directory (default: $(HOME)/marquees)"
	@echo ""
	@echo "Examples:"
	@echo "  make"
	@echo "  make install"
	@echo "  make install INSTALL_DIR=/usr/local/ivararcade"
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

	[[ -d "$$MAME_DIR/cfg_ra" ]] || { echo "ERROR: Missing required folder: $$MAME_DIR/cfg_ra"; exit 1; }
	[[ -d "$$MAME_DIR/cfg_sa" ]] || { echo "ERROR: Missing required folder: $$MAME_DIR/cfg_sa"; exit 1; }
	if [[ -d "$$MAME_DIR/cfg" ]]; then
		echo "ERROR: Forbidden folder exists: $$MAME_DIR/cfg"
		echo "       (cfg_ra and cfg_sa must exist, and cfg must not.)"
		exit 1
	fi
	bad_cfg="$$(find "$$MAME_DIR" -type d \( -path "*/cfg_ra/cfg" -o -path "*/cfg_sa/cfg" \) -print -quit)"
	if [[ -n "$$bad_cfg" ]]; then
		echo "ERROR: Detected nested cfg folder bug: $$bad_cfg"
		echo "       Fix/move it first; refusing to sync-back."
		exit 1
	fi

	# --- config knobs you maintain ---
	# 1) Where NEW files are allowed to be created (relative to $$MAME_DIR)
	NEW_FILE_DIRS=(cfg_ra cfg_sa)
	# 2) Useful sections for XML .cfg files
	USEFUL_CFG_SECTIONS=(input video)

	# Return 0 if: XML-ish .cfg AND it contains NONE of the useful sections.
	is_default_only_cfg() {
		local f="$$1"
		# Only apply rule to XML-ish cfg files; non-XML cfg files are always allowed.
		if ! head -n 5 "$$f" 2>/dev/null | grep -qiE '^\s*<\?xml|<mameconfig\b|^\s*<'; then
			return 1
		fi
		local tag_re=""
		local t
		for t in "$${USEFUL_CFG_SECTIONS[@]}"; do
			tag_re+="<\\s*$$t\\b|"
		done
		tag_re="$${tag_re%|}"
		# If we find ANY useful section tag, it is NOT default-only.
		grep -qiE "$$tag_re" "$$f" && return 1
		return 0
	}

	# --- Phase A: sync only MODIFIED files that ALREADY EXIST in the target tree ---
	# NOTE: --existing prevents new files from being created in the target tree.
	rsync -ai --existing --update \
		--no-perms --no-owner --no-group --omit-dir-times \
		"$$SRC/" "$$DST/"


	# --- Phase B: copy NEW files from approved folders (subject to cfg rules) ---
	for d in "$${NEW_FILE_DIRS[@]}"; do
		src_dir="$$MAME_DIR/$$d"
		dst_dir="$$DST/emulators/mame/$$d"
		[[ -d "$$src_dir" ]] || { echo "ERROR: Missing new-file source folder: $$src_dir"; exit 1; }
		[[ -d "$$dst_dir" ]] || { echo "ERROR: Missing target folder (must already exist): $$dst_dir"; exit 1; }

		cd "$$src_dir"
		find . -type f -print0 \
		| while IFS= read -r -d '' f; do
			rel="$${f#./}"
			# Only include if destination file does NOT exist.
			if [[ ! -f "$$dst_dir/$$rel" ]]; then
				# Special rule: skip default-only XML cfg files.
				if [[ "$$rel" == *.cfg ]] && is_default_only_cfg "$$src_dir/$$rel"; then
					continue
				fi
				printf '%s\0' "$$f"
			fi
		done \
		| rsync -ai --ignore-existing --from0 --files-from=- --no-implied-dirs \
			--no-perms --no-owner --no-group --omit-dir-times \
			"$$src_dir/" "$$dst_dir/"
	done

	@echo "sync-back: $$SRC/ -> $$DST/ ... complete!"
