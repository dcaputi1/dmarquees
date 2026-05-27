#!/usr/bin/env bash

# This file is part of The RetroPie Project
#
# The RetroPie Project is the legal property of its developers, whose names are
# too numerous to list here. Please refer to the COPYRIGHT.md file distributed with this source.
#
# See the LICENSE.md file at the top-level directory of this distribution and
# at https://raw.githubusercontent.com/RetroPie/RetroPie-Setup/master/LICENSE.md
#
# ============================================================================
# IvarArcade modification — mapdevice duplicate-ID fix
# Upstream: https://github.com/RetroPie/RetroPie-Setup/blob/master/scriptmodules/emulators/mame.sh
# Patch reference: IvarArcade/docs/mame-mapdevice-duplicate-id-fix.md
#
# Changes vs upstream:
#   1. sources_mame(): after gitPullOrClone, applies the two-line mapdevice fix
#      via sed, prints a summary, then pauses for your verification before the build.
#   2. install_mame(): after copying build artifacts, saves the two patched source
#      files to /home/danc/mame-src-patched/ for future reference.
#   3. __keep_sources=1: tells RetroPie-Setup NOT to delete the build directory
#      after install, leaving the full MAME source tree in place.
# ============================================================================

rp_module_id="mame"
rp_module_desc="MAME emulator"
rp_module_help="ROM Extensions: .zip .7z\n\nCopy your MAME roms to either $romdir/mame or\n$romdir/arcade"
rp_module_licence="GPL2 https://raw.githubusercontent.com/mamedev/mame/master/COPYING"
rp_module_repo="git https://github.com/mamedev/mame.git :_get_branch_mame"
rp_module_section="exp"
rp_module_flags="!mali !armv6 !:\$__gcc_version:-lt:7 nodistcc"

# IvarArcade: preserve the build directory after install so the patched source
# tree remains at ~/RetroPie-Setup/tmp/build/mame for inspection and re-use.
__keep_sources=1

function _get_branch_mame() {
    # starting with 0.265, GCC 10.3 or later is required for full C++17 support
    if compareVersions "$(gcc -dumpfullversion)" lt 10.3.0; then
        echo "mame0264"
        return
    fi
    download https://api.github.com/repos/mamedev/mame/releases/latest - | grep -m 1 tag_name | cut -d\" -f4
}

function depends_mame() {
    # Install required libraries required for compilation and running
    # Note: libxi-dev is required as of v0.210, because of flag changes for XInput
    local depends=(libfontconfig1-dev libsdl2-ttf-dev libflac-dev libxinerama-dev libxi-dev libpulse-dev)
    # build the MAME debugger only on X11 (desktop) platforms
    isPlatform "x11" && depends+=(qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools)

    getDepends "${depends[@]}"
}

function sources_mame() {
    gitPullOrClone
    # lzma assumes hardware crc support on arm which breaks when building on armv7
    isPlatform "armv7" && applyPatch "$md_data/lzma_armv7_crc.diff"

    # =====================================================================
    # IvarArcade: Apply mapdevice duplicate-ID fix
    # See: IvarArcade/docs/mame-mapdevice-duplicate-id-fix.md
    #
    # Two source files must be changed:
    #   src/emu/input.h   — change devicemap_table type from map to vector<pair>
    #   src/emu/ioport.cpp — change emplace() to emplace_back()
    # =====================================================================
    printHeading "IvarArcade: applying mapdevice duplicate-ID fix..."

    local patch_ok=1
    local devicemap_alias="using devicemap_table = std::vector<std::pair<std::string, std::string>>;"

    # -- Change 1: src/emu/input.h ----------------------------------------
    local input_h="$md_build/src/emu/input.h"
    if grep -qF "$devicemap_alias" "$input_h"; then
        echo "  [OK] src/emu/input.h: devicemap_table already uses std::vector<std::pair<std::string, std::string>>"
    elif grep -Eq '^[[:space:]]*using devicemap_table = .*;$' "$input_h"; then
        sed -E -i \
            's|^([[:space:]]*using devicemap_table = ).*;|\1std::vector<std::pair<std::string, std::string>>;|' \
            "$input_h"

        if ! grep -q '^#include <utility>$' "$input_h"; then
            sed -i '/^#include <string>$/a #include <utility>' "$input_h"
        fi

        if ! grep -q '^#include <vector>$' "$input_h"; then
            if grep -q '^#include <utility>$' "$input_h"; then
                sed -i '/^#include <utility>$/a #include <vector>' "$input_h"
            else
                sed -i '/^#include <string>$/a #include <vector>' "$input_h"
            fi
        fi

        if grep -qF "$devicemap_alias" "$input_h"; then
            echo "  [OK] src/emu/input.h: devicemap_table -> std::vector<std::pair<std::string, std::string>>"
        else
            echo "  [!!] src/emu/input.h: alias rewrite did not stick!"
            echo "       Expected alias: $devicemap_alias"
            echo "       Apply manually: $input_h"
            patch_ok=0
        fi
    else
        echo "  [!!] src/emu/input.h: PATTERN NOT FOUND — automatic patch skipped!"
        echo "       Expected alias: using devicemap_table = ...;"
        echo "       Apply manually: $input_h"
        patch_ok=0
    fi

    # -- Change 2: src/emu/ioport.cpp -------------------------------------
    local ioport_cpp="$md_build/src/emu/ioport.cpp"
    if grep -q "devicemap\.emplace(devicename, controllername)" "$ioport_cpp"; then
        sed -i \
            's/devicemap\.emplace(devicename, controllername);/devicemap.emplace_back(devicename, controllername);/' \
            "$ioport_cpp"
        echo "  [OK] src/emu/ioport.cpp: devicemap.emplace() -> emplace_back()"
    else
        echo "  [!!] src/emu/ioport.cpp: PATTERN NOT FOUND — automatic patch skipped!"
        echo "       Expected line:  devicemap.emplace(devicename, controllername);"
        echo "       Apply manually: $ioport_cpp"
        patch_ok=0
    fi

    echo ""
    echo "Source tree: $md_build"
    echo ""
    echo "Verify the applied changes:"
    echo "  grep -n 'devicemap_table' $input_h"
    echo "  grep -n 'emplace_back'    $ioport_cpp"
    echo ""

    if [[ "$patch_ok" -eq 0 ]]; then
        echo "*** WARNING: one or more patches were NOT applied automatically. ***"
        echo "    Apply them manually in $md_build/src/emu/ before continuing."
        echo "    See IvarArcade/docs/mame-mapdevice-duplicate-id-fix.md for the exact changes."
        echo ""
    fi

    read -rp "Press Enter to start the build, or Ctrl+C to abort and fix manually... "
}

function build_mame() {
    # More memory is required for 64bit platforms
    if isPlatform "64bit"; then
        rpSwap on 10240
    else
        rpSwap on 8192
    fi

    local params=(NOWERROR=1 ARCHOPTS="-U_FORTIFY_SOURCE -Wl,-s" PYTHON_EXECUTABLE=python3 OPTIMIZE=2 USE_SYSTEM_LIB_FLAC=1)
    isPlatform "x11" && params+=(USE_QTDEBUG=1) || params+=(USE_QTDEBUG=0)

    # array for storing ARCHOPTS_CXX parameters
    local arch_opts_cxx=()

    # when building on ARM enable 'fsigned-char' for compiled code, fixes crashes in a few drivers
    isPlatform "arm" || isPlatform "aarch64" && arch_opts_cxx+=(-fsigned-char)

    # workaround g++-12 compiler bug/compilation issue on 32bit arm userland with aarch64 kernel on
    # the rpi3 (cortex-a53). disabling -ftree-slp-vectorize works around the issue:
    #   {standard input}: Assembler messages:
    #   {standard input}:4045: Error: co-processor offset out of range
    #   make[2]: *** [skeleton.make:2727: obj/Release/src/mame/skeleton/scopus.o] Error 1
    if [[ "$__gcc_version" -eq 12 ]] && isPlatform "rpi3" && isPlatform "32bit" && [[ "$(uname -m)" == "aarch64" ]]; then
        arch_opts_cxx+=(-fno-tree-slp-vectorize)
    fi

    # if we have any arch opts set, add them
    if [[ ${#arch_opts_cxx[@]} -gt 0 ]]; then
        params+=(ARCHOPTS_CXX="${arch_opts_cxx[*]}")
    fi

    # force arm on arm platform - fixes building mame on when using 32bit arm userland with aarch64 kernel
    isPlatform "arm" && params+=(PLATFORM=arm)

    # workaround for linker crash on bullseye (use gold linker)
    if [[ "$__os_debian_ver" -eq 11 ]] && isPlatform "arm"; then
        LDFLAGS+=" -fuse-ld=gold -Wl,--long-plt" make "${params[@]}"
    else
        QT_SELECT=5 make "${params[@]}"
    fi

    rpSwap off
    md_ret_require="$md_build/mame"
}

function install_mame() {
    md_ret_files=(
        'artwork'
        'bgfx'
        'ctrlr'
        'docs'
        'hash'
        'hlsl'
        'ini'
        'language'
        'mame'
        'plugins'
        'roms'
        'samples'
        'uismall.bdf'
        'COPYING'
    )

    # =====================================================================
    # IvarArcade: save the two patched source files to a permanent location.
    # The full source tree is preserved in $md_build via __keep_sources=1,
    # but also explicitly copy the two changed files in case __keep_sources
    # behaviour differs across RetroPie-Setup versions.
    # =====================================================================
    local src_save="/home/danc/mame-src-patched"
    echo "IvarArcade: saving patched source files to $src_save ..."
    mkdir -p "$src_save/src/emu"
    cp "$md_build/src/emu/input.h"    "$src_save/src/emu/"
    cp "$md_build/src/emu/ioport.cpp" "$src_save/src/emu/"
    echo "  Saved: $src_save/src/emu/input.h"
    echo "  Saved: $src_save/src/emu/ioport.cpp"

    # Belt-and-suspenders: also set __keep_sources here (it was set at module
    # scope above, but set it again immediately before the framework cleanup check).
    __keep_sources=1
}

function configure_mame() {
    local system="mame"

    if [[ "$md_mode" == "install" ]]; then
        mkRomDir "arcade"
        mkRomDir "$system"

        # Create required MAME directories underneath the ROM directory
        local mame_sub_dir
        for mame_sub_dir in artwork cfg comments diff inp nvram samples scores snap sta; do
            mkRomDir "$system/$mame_sub_dir"
        done

        # Create a BIOS directory, where people will be able to store their BIOS files,
        # separate from ROMs
        mkUserDir "$biosdir/$system"

        # Create the configuration directory for the MAME ini files
        moveConfigDir "$home/.mame" "$md_conf_root/$system"

        # Create new INI files if they do not already exist

        # Create MAME config file
        local temp_ini_mame
        temp_ini_mame="$(mktemp)"
        iniConfig " " "" "$temp_ini_mame"
        iniSet "rompath"            "$romdir/$system;$romdir/arcade;$biosdir/$system"
        iniSet "hashpath"           "$md_inst/hash"
        iniSet "samplepath"         "$romdir/$system/samples;$romdir/arcade/samples"
        iniSet "artpath"            "$romdir/$system/artwork;$romdir/arcade/artwork"
        iniSet "ctrlrpath"          "$md_inst/ctrlr"
        iniSet "pluginspath"        "$md_inst/plugins"
        iniSet "languagepath"       "$md_inst/language"
        iniSet "cfg_directory"      "$romdir/$system/cfg"
        iniSet "nvram_directory"    "$romdir/$system/nvram"
        iniSet "input_directory"    "$romdir/$system/inp"
        iniSet "state_directory"    "$romdir/$system/sta"
        iniSet "snapshot_directory" "$romdir/$system/snap"
        iniSet "diff_directory"     "$romdir/$system/diff"
        iniSet "comment_directory"  "$romdir/$system/comments"
        iniSet "skip_gameinfo"      "1"
        iniSet "plugin"             "hiscore"
        iniSet "samplerate"         "44100"
        # Raspberry Pis show improved performance using accelerated mode which enables
        # SDL_RENDERER_TARGETTEXTURE. On RPI4 it uses OpenGL as a renderer, while on
        # earlier RPIs it uses OpenGLES2. Enabling accel also enables target texture on
        # X86 Ubuntu (and likely other X86 Linux platforms).
        iniSet "video"              "accel"
        copyDefaultConfig "$temp_ini_mame" "$md_conf_root/$system/mame.ini"
        rm "$temp_ini_mame"

        # Create MAME UI config file
        local temp_ini_ui
        temp_ini_ui="$(mktemp)"
        iniConfig " " "" "$temp_ini_ui"
        iniSet "scores_directory" "$romdir/$system/scores"
        copyDefaultConfig "$temp_ini_ui" "$md_conf_root/$system/ui.ini"
        rm "$temp_ini_ui"

        # Create MAME Plugin config file
        local temp_ini_plugin
        temp_ini_plugin="$(mktemp)"
        iniConfig " " "" "$temp_ini_plugin"
        iniSet "hiscore" "1"
        copyDefaultConfig "$temp_ini_plugin" "$md_conf_root/$system/plugin.ini"
        rm "$temp_ini_plugin"

        # Create MAME Hi Score config file
        local temp_ini_hiscore
        temp_ini_hiscore="$(mktemp)"
        iniConfig " " "" "$temp_ini_hiscore"
        iniSet "hi_path" "$romdir/$system/scores"
        copyDefaultConfig "$temp_ini_hiscore" "$md_conf_root/$system/hiscore.ini"
        rm "$temp_ini_hiscore"
    fi

    addEmulator 0 "$md_id" "arcade" "$md_inst/mame %BASENAME%"
    addEmulator 1 "$md_id" "$system" "$md_inst/mame %BASENAME%"

    addSystem "arcade"
    addSystem "$system"
}
