#!/bin/bash
 
# Find all .cfg files recursively from the current directory
# Filter only those whose path or filename contains "/cfg"
# Skip files with base name "___empty.cfg"
# Rename the rest by appending ".bak", removing any existing .bak first
 
find /home/danc -type f -name "*.cfg" | grep '/cfg' | while read -r file; do
    basename=$(basename "$file")
    if [[ "$basename" == "___empty.cfg" ]]; then
        echo "Skipping: $file"
        continue
    fi
 
    backup="${file}.bak"
    if [[ -f "$backup" ]]; then
        echo "Removing existing backup: $backup"
        rm -f "$backup"
    fi
 
    mv "$file" "$backup"
    echo "Renamed: $file -> ${basename}.bak"
done
 
# Special handling for es_input.cfg file
special_file="/opt/retropie/configs/all/emulationstation/es_input.cfg"
backup_file="${special_file}.bak"
 
if [[ -f "$special_file" ]]; then
    if [[ -f "$backup_file" ]]; then
        echo "Removing existing backup: $backup_file"
        rm -f "$backup_file"
    fi
    mv "$special_file" "$backup_file"
    echo "Renamed: $special_file -> $(basename "$backup_file")"
else
    echo "ES Input file not found: $special_file"
fi
