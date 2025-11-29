This workspace provides a VS Code task to run `make install` which will build the project and copy the binary to `~/marquees` (per the project's `Makefile`).

How to run the task now
- Open Command Palette (Ctrl+Shift+P)
- Type: Tasks: Run Task
- Choose: "Make: install"

Bind a hotkey to the task (user keybindings)
To add a keyboard shortcut that runs this task, add the following to your **user** keybindings (File → Preferences → Keyboard Shortcuts → Open Keyboard Shortcuts (JSON)):

```json
{
    "key": "ctrl+alt+m",
    "command": "workbench.action.tasks.runTask",
    "args": "Make: install"
}
```

Notes
- VS Code does not apply workspace keybindings automatically; the snippet above must be added to your user keybindings JSON.
- If that key is already taken you can change `"key"` to another shortcut.
- The task runs `make install` in the workspace root (`${workspaceFolder}`), so it will use the `install` target defined in the project's `Makefile`.

Troubleshooting
- If the task doesn't run, ensure `make` is installed and the Makefile has a working `install` target.
- You can view the task output in the Terminal panel.
