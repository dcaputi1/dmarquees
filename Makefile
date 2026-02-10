# IvarArcade Parent Makefile
# Builds both dmarquees and analyze_games executables
#
# MAKEFILE_VERSION = 2026-02-10T14:10

.PHONY: all dmarquees analyze_games install install-force clean help sync-back

# Install directory
INSTALL_DIR ?= $(HOME)/marquees

# Set the shell configuration specifically for rsync-back AI generated script
SHELL := /bin/bash
.ONESHELL:
SHELLFLAGS := -eu -o pipefail -c

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
	@echo "  uninstall     - Remove installed files (untested)"
	@echo "  sync-back     - Copies lr-mame/MAME config from /opt/ to ./Backup_RetroPie"
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
	@echo "Syncing back updated config from lr-mame/MAME to project..."

	@ROOT="$$(pwd)"
	@SRC="/opt/retropie"
	@DST="$$ROOT/Backup_RetroPie/opt/retropie"
	@MAME_DIR="$$SRC/emulators/mame"

	@if [[ ! -d "$$SRC" ]]; then
		echo "ERROR: $$SRC not found"
		exit 1
	fi

	# 1) Preflight: XinMo swap sanity check (currently disabled)
	# if [[ -x "$$HOME/scripts/xinmo-swapcheck.py" || -f "$$HOME/scripts/xinmo-swapcheck.py" ]]; then
	# 	"$$HOME/scripts/xinmo-swapcheck.py" || { echo "ERROR: xinmo-swapcheck.py failed. Aborting."; exit 1; }
	# else
	# 	echo "ERROR: $$HOME/scripts/xinmo-swapcheck.py not found. Aborting."
	# 	exit 1
	# fi

	# 2) Preflight: cfg_ra and cfg_sa must both exist under MAME, and cfg must NOT exist
	@if [[ ! -d "$$MAME_DIR/cfg_ra" ]]; then
		echo "ERROR: Missing required folder: $$MAME_DIR/cfg_ra"
		exit 1
	fi
	@if [[ ! -d "$$MAME_DIR/cfg_sa" ]]; then
		echo "ERROR: Missing required folder: $$MAME_DIR/cfg_sa"
		exit 1
	fi
	@if [[ -d "$$MAME_DIR/cfg" ]]; then
		echo "ERROR: Forbidden folder exists: $$MAME_DIR/cfg"
		echo "       (cfg_ra and cfg_sa must exist, and cfg must not.)"
		exit 1
	fi

	# 3) Preflight: detect cfg nesting bug (cfg_ra/cfg or cfg_sa/cfg) under MAME
	@bad_cfg="$$(find "$$MAME_DIR" -type d \( -path "*/cfg_ra/cfg" -o -path "*/cfg_sa/cfg" \) -print -quit)"
	@if [[ -n "$$bad_cfg" ]]; then
		echo "ERROR: Detected nested cfg folder bug: $$bad_cfg"
		echo "       Fix/move it first; refusing to sync-back."
		exit 1
	fi

	@mkdir -p "$$DST"
	@echo "Syncing updated + new files, but ONLY into dirs that already exist in the project..."

	@is_useful_ini_change() {
		local src="$$1"
		local dst="$$2"

		local IGNORE_RE='^(#|;|$$)|\r$$|^(play|plays|play_count|playcount|last_play|lastplay|play_time|playtime|time_played|times_played|credits|coin|coins|highscore|hiscore|score|scores|nvram|autofire|cheat|cheats|ui_.*|ui|state|history|bookkeeping)[[:space:]]*='
		local IGNORE_SOUND_RE='^(sound|samples|samplerate|audio_latency|volume|attenuation|speaker_report|mixer|slider|bgm|music|snd|panning|compressor|equalizer)[[:space:]]*='

		local ALLOW_RE='^(ctrlr|joystick|mouse|lightgun|trackball|paddle|dial|adstick|pedal|positional|multikeyboard|multimouse|steadykey|joystick_contradictory|joystick_deadzone|joystick_saturation|joystick_map|input|coin_lockout)[[:space:]]*='
		local ALLOW_VIDEO_RE='^(numscreens|screen0|aspect|resolution|view|rotate|ror|rol|flipx|flipy|refresh|switchres|prescale|keepaspect|unevenstretch|intoverscan|intscalex|intscaley|video|monitorprovider)[[:space:]]*='

		local t1="$$(mktemp)"
		local t2="$$(mktemp)"
		trap 'rm -f "$$t1" "$$t2"' RETURN

		grep -vE "$$IGNORE_RE" "$$src" 2>/dev/null | grep -vE "$$IGNORE_SOUND_RE" | sed 's/\r$$//' > "$$t1" || true
		if [[ -f "$$dst" ]]; then
			grep -vE "$$IGNORE_RE" "$$dst" 2>/dev/null | grep -vE "$$IGNORE_SOUND_RE" | sed 's/\r$$//' > "$$t2" || true
		else
			: > "$$t2"
		fi

		if diff -q "$$t1" "$$t2" >/dev/null 2>&1; then
			return 1
		fi

		local changed
		changed="$$(diff -u "$$t2" "$$t1" \
			| grep -E '^[+-]' \
			| grep -vE '^[+-]{3} ' \
			| sed 's/^[+-]//')"

		[[ -n "$$changed" ]] || return 1

		echo "$$changed" | grep -Eq "$$ALLOW_RE|$$ALLOW_VIDEO_RE"
	}

	@is_mixer_only_cfg() {
		local src="$$1"
		local remainder
		remainder="$$(sed -e 's/\r$$//' \
			-e '/^<\?xml[[:space:]]/d' \
			-e '/^[[:space:]]*<!--/d' \
			-e '/^[[:space:]]*$$/d' \
			-e ':a; /<mixer[>[:space:]]/{N; /<\/mixer>/!ba; s/<mixer[>[:space:]][^>]*>.*<\/mixer>//s;}' \
			"$$src" 2>/dev/null \
			| sed -E 's/<mameconfig[^>]*>//g; s/<\/mameconfig>//g; s/<system[^>]*>//g; s/<\/system>//g' \
			| tr -d '[:space:]')"
		[[ -z "$$remainder" ]]
	}

	@is_useful_xml_cfg_change() {
		local src="$$1"
		local dst="$$2"

		normalize_cfg() {
			sed -e 's/\r$$//' \
				-e '/^<\?xml[[:space:]]/d' \
				-e '/^[[:space:]]*<!--/d' \
				-e '/^[[:space:]]*$$/d' \
				-e ':a; /<mixer[>[:space:]]/{N; /<\/mixer>/!ba; s/<mixer[>[:space:]][^>]*>.*<\/mixer>//s;}' \
				"$$1" 2>/dev/null \
			| tr -d '[:space:]'
		}

		local a b
		a="$$(normalize_cfg "$$src")"
		if [[ -f "$$dst" ]]; then
			b="$$(normalize_cfg "$$dst")"
		else
			b=""
		fi

		[[ "$$a" != "$$b" ]]
	}

	@cd "$$SRC"

	@SKIP_FOLDERS=(autoconfig-presets)

	# Log skip folders once (only if present in SRC)
	@for d in "$${SKIP_FOLDERS[@]}"; do \
		if [[ -d "$$SRC/$$d" ]]; then \
			echo "[skip] $$d/ (pruned)" >&2; \
		fi; \
	done

	@declare -A SKIPPED_DIRS

	@find_cmd=(find .)
	@if ((${#SKIP_FOLDERS[@]})); then \
		find_cmd+=('\('); \
		first=1; \
		for d in "$${SKIP_FOLDERS[@]}"; do \
			if (( first == 0 )); then find_cmd+=(-o); fi; \
			# Match both the folder itself and everything underneath it
			find_cmd+=(-path "./$$d" -o -path "./$$d/*"); \
			first=0; \
		done; \
		find_cmd+=('\)' -prune -o); \
	fi; \
	find_cmd+=(-type f -print0); \
	"$${find_cmd[@]}" \
	| while IFS= read -r -d '' f; do
		# Only copy into dirs that already exist in the destination tree
		if [[ ! -d "$$DST/$$(dirname "$$f")" ]]; then
			rel_dir="$$(dirname "$${f#./}")"
			if [[ -z "$${SKIPPED_DIRS[$$rel_dir]+x}" ]]; then
				SKIPPED_DIRS[$$rel_dir]=1
				echo "[skip] new-dir (would create): $$rel_dir/" >&2
			fi
			continue
		fi

		# Skip the MAME binary explicitly (SRC is /opt/retropie now)
		if [[ "$$f" == "./emulators/mame/mame" ]]; then
			continue
		fi

		# INI policy: only copy if useful/intentional
		if [[ "$$f" == *.ini ]]; then
			srcp="$$SRC/$${f#./}"
			dstp="$$DST/$${f#./}"
			if ! is_useful_ini_change "$$srcp" "$$dstp"; then
				echo "[skip] ini (noise/unknown): $${f#./}" >&2
				continue
			fi
		fi

		# CFG policy:
		# - XML-ish cfg:
		#     - skip mixer-only
		#     - if existing: copy only if meaningful change ignoring <mixer>
		#     - if new: copy only if it contains <input>
		# - non-XML cfg (retroarch.cfg etc): keep (no XML filtering)
		if [[ "$$f" == *.cfg ]]; then
			srcp="$$SRC/$${f#./}"
			dstp="$$DST/$${f#./}"

			if head -n 5 "$$srcp" 2>/dev/null | grep -qiE '^\s*<\?xml|<mameconfig\b|^\s*<'; then
				if is_mixer_only_cfg "$$srcp"; then
					echo "[skip] cfg (mixer-only): $${f#./}" >&2
					continue
				fi

				if [[ -f "$$dstp" ]]; then
					if ! is_useful_xml_cfg_change "$$srcp" "$$dstp"; then
						echo "[skip] cfg (only mixer/whitespace changes): $${f#./}" >&2
						continue
					fi
				else
					if ! grep -qi '<[[:space:]]*input[[:space:]>]' "$$srcp"; then
						echo "[skip] cfg (new XML cfg without <input>): $${f#./}" >&2
						continue
					fi
				fi
			fi
		fi

		printf '%s\0' "$$f"
	done \
	| rsync -ai --update --from0 --files-from=- --no-implied-dirs \
		--exclude='/emulators/mame/mame' \
		--no-perms --no-owner --no-group --omit-dir-times \
		"$$SRC/" "$$DST/"

	@echo "Back-synced: $$SRC/ -> $$DST/"
	@echo "Sync-back complete!"
