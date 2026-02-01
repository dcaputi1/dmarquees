# IvarArcade Parent Makefile
# Builds both dmarquees and analyze_games executables

.PHONY: all dmarquees analyze_games install install-force clean help

# Install directory
INSTALL_DIR ?= $(HOME)/marquees

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
	
	@# Install plugins to local directory
	@if [ -d plugins ]; then \
		if [ ! -d $(INSTALL_DIR)/plugins ]; then \
			cp -a plugins $(INSTALL_DIR)/ && echo "Updated: $(INSTALL_DIR)/plugins"; \
		else \
			echo "Skipped: $(INSTALL_DIR)/plugins (already exists)"; \
		fi; \
	fi
	
	@# Sync Backup_RetroPie contents to system (only newer files)
	@# This handles plugins, scripts, configs, and all other system files
	@if [ ! -d Backup_RetroPie ]; then \
		echo "Error: Backup_RetroPie source directory missing"; \
	else \
		echo "Syncing /opt directory (newer files only)..."; \
		rsync -a --update --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS Backup_RetroPie/opt/ /opt/; \
		echo "Syncing /home directory (newer files only)..."; \
		rsync -a --update --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS Backup_RetroPie/home/ /home/; \
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
	
	@# Force sync Backup_RetroPie contents to system (overwrite all files)
	@if [ ! -d Backup_RetroPie ]; then \
		echo "Error: Backup_RetroPie source directory missing"; \
	else \
		echo "Syncing /opt directory (forcing overwrites)..."; \
		rsync -a --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS Backup_RetroPie/opt/ /opt/; \
		echo "Syncing /home directory (forcing overwrites)..."; \
		rsync -a --no-perms --no-owner --no-group --omit-dir-times --info=NAME,STATS Backup_RetroPie/home/ /home/; \
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
	@echo "  clean         - Remove all build artifacts"
	@echo "  uninstall     - Remove installed files"
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

# Sync-back: Copy updated files from system location back to project
sync-back:
	@echo "Syncing back updated files from system to project..."
	@if [ ! -d /opt/retropie/emulators/mame ]; then \
		echo "Skipped: /opt/retropie/emulators/mame (not found in system location)"; \
	else \
		mkdir -p Backup_RetroPie/opt/retropie/emulators/mame; \
		echo "Syncing all emulators/mame directories back to project..."; \
		rsync -av --update --no-perms --no-owner --no-group --omit-dir-times /opt/retropie/emulators/mame/ Backup_RetroPie/opt/retropie/emulators/mame/ && echo "Back-synced: /opt/retropie/emulators/mame/"; \
	fi
	@echo "Sync-back complete!"
