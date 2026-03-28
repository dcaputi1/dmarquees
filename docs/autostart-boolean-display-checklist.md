# autostart.sh Boolean Display Refactor Checklist

This checklist guides the refactor of autostart.sh to replace legacy dual monitor and transport logic with two booleans: Pi5 dual display and Pi3 present.

## Step 1: Remove Old Logic
- [ ] Remove all code and functions related to dual monitor mode (ADVANCED_DUAL_MODE_FILE, get_dual_monitor_mode, set_dual_monitor_mode, etc.).
- [ ] Remove all code and functions related to transport mode (DMARQUEES_TRANSPORT, get_transport_mode, select_dmarquees_transport, etc.).
- [ ] Remove any menu items or UI elements that reference the old dual/transport logic.

## Step 2: Add New Booleans
- [ ] Add two new booleans:
    - `PI5_DUAL_DISPLAY` (true/false)
    - `PI3_PRESENT` (true/false)
- [ ] Set sensible defaults and allow configuration (e.g., via config file or menu).

## Step 3: Refactor Advanced Menu
- [ ] Replace dual/transport menu items with toggles for the two new booleans.
- [ ] Ensure toggles update the correct variables and persist if needed.

## Step 4: Update Daemon/Setup Logic
- [ ] Update all logic that previously depended on dual/transport to use the new booleans.
- [ ] Test all code paths (local, remote, dual, single, Pi3 present/absent).

## Step 5: Documentation
- [ ] Update README and in-code comments to reflect new logic.
- [ ] Remove references to old dual/transport logic.

---

Check off each item as you complete it. Test thoroughly after each step.