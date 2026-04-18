# IVAR ARCADE COMPLETE BUTTON MAPPING DOCUMENTATION
# End-to-End Controller Mapping System

Generated: December 31, 2025
Updated: January 4, 2026 - Device order now consistent across both frontends
System: IvarArcade - RetroPie on Raspberry Pi

## IMPORTANT UPDATE (January 4, 2026):
Device order has been unified across both standalone MAME (via allctrlrs.cfg) 
and libretro MAME (via RetroArch port bindings). The new order matches the 
native hardware physical order:
  1. JOYCODE_1 = js0 (Trooper V2)
  2. JOYCODE_2 = js1 (Xinmotek Player 1)
  3. JOYCODE_3 = js2 (Xinmotek Player 2)
  4. JOYCODE_4 = js3 (Ultrastik)
  5. JOYCODE_5 = js4 (Racing Wheel)

This provides consistent controller mappings across all MAME frontends.

================================================================================
## DOCUMENTATION FILES OVERVIEW
================================================================================

This documentation suite provides complete end-to-end button mapping from
physical controllers through all software layers to MAME game controls.

### Primary Documentation Files:

1. **hardware_controllers.txt**
   - Physical hardware detection and specifications
   - All 5 joystick devices (js0-js4) with vendor/product IDs
   - Physical button layouts and labels
   - Player assignments and usage patterns

2. **mapping_retroarch_path.txt**
   - Complete RetroArch (cfg_ra) mapping chain
   - Physical Button → Joystick → RetroPad → MAME
   - All 5 controllers fully documented
   - RetroPad layer translation explained

3. **mapping_standalone_path.txt**
   - Complete Standalone MAME (cfg_sa) mapping chain
   - Physical Button → Joystick → MAME Direct
   - No RetroPad layer (direct hardware access)
   - Differences from RetroArch path highlighted

4. **complete_button_mapping.csv**
   - Spreadsheet format for Excel/LibreOffice
   - Side-by-side comparison of cfg_ra vs cfg_sa
   - All controllers, all buttons in single table
   - Includes notes on mapping differences

5. **custom_game_mappings.txt**
   - Game-specific MAME configurations
   - Q*bert (diagonal movement)
   - Spy Hunter (analog controls)
   - Indianapolis Tempest (multi-controller)
   - Custom overrides explained

6. **button_mappings_comparison.csv** (original)
   - Simple comparison of default.cfg between cfg_ra and cfg_sa
   - MAME control mappings only

================================================================================
## SYSTEM ARCHITECTURE
================================================================================

### Controller Input Flow:

┌─────────────────────┐
│  Physical Buttons   │  What you press on the arcade cabinet
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Linux Input Layer  │  /dev/input/js0-js4, kernel joystick driver
└──────────┬──────────┘
           │
           ├─────────────────┬────────────────┐
           │                 │                │
           ▼                 ▼                ▼
    ┌─────────────┐   ┌─────────────┐   ┌──────────┐
    │  RetroArch  │   │ Standalone  │   │  Other   │
    │   (cfg_ra)  │   │    MAME     │   │  Emus    │
    └──────┬──────┘   │  (cfg_sa)   │   └──────────┘
           │          └──────┬───────┘
           │                 │
           ▼                 │
    ┌─────────────┐          │
    │  RetroPad   │          │
    │   Layer     │          │
    └──────┬──────┘          │
           │                 │
           └────────┬────────┘
                    │
                    ▼
           ┌─────────────────┐
           │   MAME Core     │  Game emulation
           └─────────────────┘

### Two Paths to MAME:

**RetroArch Path (cfg_ra):**
Physical → js Device → RetroPad → MAME Core → Game
- Uses retropad standard mapping
- Easier to reconfigure via RetroArch UI
- Consistent across different emulators
- Good for general arcade gaming

**Standalone Path (cfg_sa):**
Physical → js Device → MAME Direct → Game
- Direct hardware access, no middleware
- Game-specific configs easier to manage
- Better for advanced MAME features
- Required for some specialty controls

================================================================================
## CONTROLLER SUMMARY
================================================================================

### js0 - Trooper V2 (Player 1)
- 6 buttons: A, B, LB, RB, SEL, START
- Joystick with axes
- cfg_ra: JOYCODE_1
- cfg_sa: JOYCODE_1
- Best for: Simple 6-button fighting games

### js1 - Xinmotek Controller Player 1 (Player 1)
- 6 action buttons: Y, A, B, L, R, X
- START button (Player 1 specific)
- COIN button
- Part of dual-stick fight stick panel
- cfg_ra: JOYCODE_2
- cfg_sa: JOYCODE_2
- Best for: Neo Geo, Street Fighter, fighting games

### js2 - Xinmotek Controller Player 2 (Player 2)
- 6 action buttons: Y, A, B, L, R, X
- START button (Player 2 specific)
- COIN button
- Part of dual-stick fight stick panel
- cfg_ra: JOYCODE_3
- cfg_sa: JOYCODE_3
- Best for: 2-player fighting games

### js3 - Ultimarc Ultra-Stik Custom Panel (Player 1 + P2 Start)
- 4 action buttons: A, B, X, Y
- START 1 (Player 1)
- START 2 (Player 2) - Special cross-player feature!
- COIN button
- Ultimarc analog joystick
- cfg_ra: JOYCODE_4
- cfg_sa: JOYCODE_4
- Best for: Classic arcade games, general use

### js4 - Hori MarioKart Pro Racing Wheel (Player 1)
- Racing wheel (analog steering)
- Pedals (gas, brake) on analog axes
- Multiple buttons and paddles
- D-pad for menu navigation
- Device marketed for Nintendo Switch (generic USB controller)
- cfg_ra: JOYCODE_5
- cfg_sa: JOYCODE_5
- Best for: Racing games, driving simulations

================================================================================
## QUICK REFERENCE - JOYCODE ASSIGNMENTS
================================================================================

Device | cfg_ra    | cfg_sa    | Player | Notes
-------|-----------|-----------|--------|--------------------------------
js0    | JOYCODE_1 | JOYCODE_1 | P1     | Trooper V2
js1    | JOYCODE_2 | JOYCODE_2 | P1     | Xinmotek P1 side
js2    | JOYCODE_3 | JOYCODE_3 | P2     | Xinmotek P2 side
js3    | JOYCODE_4 | JOYCODE_4 | P1+P2  | Ultrastik, has P2 START
js4    | JOYCODE_5 | JOYCODE_5 | P1     | Racing wheel

Note: JOYCODE numbers don't match js device numbers!

================================================================================
## KEY MAPPING DIFFERENCES: cfg_ra vs cfg_sa
================================================================================

### Button Number Mapping:
Many buttons map to different JOYCODE_X_BUTTONY numbers between cfg_ra and cfg_sa

Example - Xinmotek js1:
- Physical Button 3 (L):
  - cfg_ra: JOYCODE_2_BUTTON5
  - cfg_sa: JOYCODE_2_BUTTON11  ← Different!

### Axis Types:
- cfg_ra prefers: HAT inputs (HAT1UP, HAT1DOWN, HAT1LEFT, HAT1RIGHT)
- cfg_sa prefers: AXIS inputs (XAXIS_LEFT_SWITCH, YAXIS_UP_SWITCH)

### START/SELECT vs BUTTON IDs:
- cfg_ra: Uses START and SELECT codes
- cfg_sa: Uses specific BUTTON numbers for START/SELECT

### UI Controls:
- cfg_ra: Minimal UI mapping (usually JOYCODE_1)
- cfg_sa: Comprehensive UI mapping across all devices + keyboard

================================================================================
## COMMON MAME CONTROLS (What Games See)
================================================================================

Player 1 Controls:
- P1_JOYSTICK_UP/DOWN/LEFT/RIGHT - Directional movement
- P1_BUTTON1 through P1_BUTTON6 - Action buttons
- P1_START - Start game
- P1_SELECT - Select/Coin
- P1_PEDAL, P1_PEDAL2 - Analog pedals (racing games)
- P1_PADDLE - Steering/spinner control

Player 2 Controls:
- P2_JOYSTICK_UP/DOWN/LEFT/RIGHT - Directional movement
- P2_BUTTON1 through P2_BUTTON6 - Action buttons
- P2_START - Start game (can be on P1 controller!)
- P2_SELECT - Select/Coin

System Controls:
- START1, START2 - Credit start buttons
- COIN1, COIN2 - Insert coin
- UI_SELECT, UI_BACK, UI_CANCEL - MAME menu navigation

================================================================================
## SPECIAL FEATURES & NOTES
================================================================================

### Multi-Device Input (OR Logic):
Many MAME controls accept input from multiple controllers simultaneously:
- COIN1: Can be triggered by js0, js1, js2, js3, or js4
- START1: Can be triggered by multiple controllers
- Allows flexibility in cabinet design

### Cross-Device Mappings:
- js3 Button 6 (START 2) triggers Player 2 start
- Allows single control panel to handle 2-player games
- cfg_sa uses JOYCODE_1_BUTTON7 reference even though JOYCODE_1 not in default

### Analog Controls:
- Racing wheel (js4) uses analog axes for steering and pedals
- Pedals share JOYCODE_2 axes (Xinmotek's axes)
- Both digital and analog inputs available

### Game-Specific Overrides:
- Q*bert: Diagonal movement (AND logic for simultaneous directions)
- Spy Hunter: Analog steering + multiple weapon buttons
- Indianapolis Tempest: Multi-controller input
- Override only what's different from default.cfg

================================================================================
## TROUBLESHOOTING GUIDE
================================================================================

### Button Not Working:
1. Check physical button in hardware_controllers.txt
2. Verify js device number and button ID
3. Check JOYCODE assignment in cfg file
4. Confirm MAME control mapping
5. Test in jstest: jstest /dev/input/jsX

### Wrong Button Response:
1. Compare cfg_ra vs cfg_sa mappings
2. Check if game has custom .cfg override
3. Verify RetroPad layer (cfg_ra only)
4. Look for button number differences

### Controller Not Recognized:
1. Check /proc/bus/input/devices for device
2. Verify /dev/input/jsX exists
3. Check permissions on js device
4. Ensure controller has power/USB connection

### Directional Controls Inverted:
1. Check HAT vs AXIS usage
2. Game might expect different joystick orientation
3. Q*bert-style games need diagonal mapping
4. May need custom game .cfg file

================================================================================
## MAINTENANCE & UPDATES
================================================================================

### Adding New Controller:
1. Connect and detect in /proc/bus/input/devices
2. Test with jstest to get button/axis IDs
3. Add to hardware_controllers.txt
4. Create RetroArch autoconfig if using cfg_ra
5. Update default.cfg in cfg_sa if needed
6. Document in mapping files

### Creating Game-Specific Config:
1. Start with working default.cfg
2. Launch game and use MAME's Tab menu
3. Configure controls as needed
4. MAME auto-saves to /gamename/.cfg
5. Copy to cfg_ra/ or cfg_sa/ directory
6. Document special requirements

### Backing Up Configurations:
Important files to backup:
- /opt/retropie/emulators/mame/cfg_ra/*.cfg
- /opt/retropie/emulators/mame/cfg_sa/*.cfg
- /opt/retropie/configs/all/retroarch/autoconfig/*.cfg
- /opt/retropie/configs/all/retroarch.cfg
- This documentation directory!

================================================================================
## ADDITIONAL RESOURCES
================================================================================

### Files in This Documentation:
- hardware_controllers.txt - Hardware specs
- mapping_retroarch_path.txt - RetroArch mappings  
- mapping_standalone_path.txt - Standalone mappings
- complete_button_mapping.csv - Comparison table (Excel)
- custom_game_mappings.txt - Game-specific configs
- button_mappings_comparison.csv - cfg_ra vs cfg_sa default
- README.txt (this file) - Complete overview

### External Resources:
- MAME Documentation: https://docs.mamedev.org/
- RetroPie Wiki: https://retropie.org.uk/docs/
- Ultimarc Support: https://www.ultimarc.com/support/
- RetroArch Docs: https://docs.libretro.com/

### Tools Used:
- jstest - Joystick testing
- /proc/bus/input/devices - Hardware detection
- MAME's Tab menu - In-game configuration
- RetroArch RGUI - RetroPad configuration

================================================================================
## CONCLUSION
================================================================================

This documentation provides complete end-to-end mapping for the IvarArcade
system, covering all 5 controllers through both RetroArch and Standalone MAME
paths. 

Use the CSV files for quick reference, the text files for detailed technical
information, and this README for overall understanding of the system.

The dual-path approach (cfg_ra and cfg_sa) provides maximum flexibility:
- Use cfg_ra for ease of use and consistent behavior
- Use cfg_sa for advanced features and game-specific optimizations

All physical controllers are mapped to work simultaneously, allowing game
selection to determine which controller is best suited for each game.

For questions or updates, refer to the individual documentation files for
specific technical details.
