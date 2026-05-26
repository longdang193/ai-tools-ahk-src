; UI.ahk - User interface (menus, GUI, tray)
; Part of ai-tools-ahk - https://github.com/ecornell/ai-tools-ahk

;# Globals (shared with main script)
global _iMenu := ""
global _iMenuItemParms := Map()
global _displayResponse := false

;# Read prompt section names in popup_menu order (excluding separators/comments)
GetPopupMenuPromptNames() {
    global SETTINGS_FILE
    names := []

    try {
        menu_items := IniRead(SETTINGS_FILE, "popup_menu")
    } catch {
        return names
    }

    loop parse menu_items, "`n" {
        promptName := Trim(A_LoopField, " `t`r")
        if (promptName == "" || SubStr(promptName, 1, 1) == "#" || promptName == "-")
            continue
        names.Push(promptName)
    }

    return names
}

;# Strip AHK menu accelerator markers from a label (single &, keep literal && as &)
StripMenuAccelerators(label) {
    if (label == "")
        return label

    placeholder := Chr(0xE000)  ; private-use marker unlikely to appear
    label := StrReplace(label, "&&", placeholder)
    label := StrReplace(label, "&", "")
    label := StrReplace(label, placeholder, "&")
    return label
}

;# Review prompt + selected text before sending to API
; Returns Map with keys: cancelled, promptName, templateText, selectedText, extraContext
ShowReviewBeforeSend(initialPromptName, selectedText) {
    items := []        ; array of {promptName, label}
    labels := []       ; drop-down display labels

    for _, promptName in GetPopupMenuPromptNames() {
        menuText := StripMenuAccelerators(GetSetting(promptName, "menu_text", promptName))
        items.Push(Map("promptName", promptName, "label", menuText))
        labels.Push(menuText)
    }

    ; Fallback: ensure at least initial prompt exists
    if (items.Length == 0) {
        items.Push(Map("promptName", initialPromptName, "label", initialPromptName))
        labels.Push(initialPromptName)
    }

    ; Pick initial index
    initialIndex := 1
    for idx, item in items {
        if (item["promptName"] == initialPromptName) {
            initialIndex := idx
            break
        }
    }

    result := Map("cancelled", true)

    ; Use relative layout (no hard-coded y math) so row-count changes never overlap.
    reviewGui := Gui("", "Review Before Send")
    reviewGui.MarginX := 12
    reviewGui.MarginY := 12
    reviewGui.SetFont("s9", "Segoe UI")

    txtHint := reviewGui.Add("Text", "w720", "Edits not saved to settings.ini")

    reviewGui.Add("Text", "xm w720", "Template")
    ddl := reviewGui.Add("DropDownList", "xm w720 Choose" initialIndex, labels)

    reviewGui.Add("Text", "xm w720", "Template text")
    editTemplate := reviewGui.Add("Edit", "xm w720 r5 -Wrap", "")

    reviewGui.Add("Text", "xm w720", "Selected text")
    editSelected := reviewGui.Add("Edit", "xm w720 r5 -Wrap", selectedText)

    reviewGui.Add("Text", "xm w720", "Extra context")
    editExtra := reviewGui.Add("Edit", "xm w720 r5 -Wrap", "")

    btnSend := reviewGui.Add("Button", "xm w110 Default", "Send")
    btnCopy := reviewGui.Add("Button", "x+10 w110", "Copy")
    btnCancel := reviewGui.Add("Button", "x+10 w110", "Cancel")

    LoadTemplate(idx) {
        promptName := items[idx]["promptName"]
        editTemplate.Value := GetSetting(promptName, "prompt", "")
    }

    ddl.OnEvent("Change", (*) => LoadTemplate(ddl.Value))

    btnSend.OnEvent("Click", (*) => (
        result["cancelled"] := false,
        result["promptName"] := items[ddl.Value]["promptName"],
        result["templateText"] := editTemplate.Value,
        result["selectedText"] := editSelected.Value,
        result["extraContext"] := editExtra.Value,
        reviewGui.Destroy()
    ))

    btnCopy.OnEvent("Click", (*) => (
        A_Clipboard := (
            editTemplate.Value
            . editSelected.Value
            . (editExtra.Value != "" ? "`n`nExtra context:`n" editExtra.Value : "")
            . GetSetting(items[ddl.Value]["promptName"], "prompt_end", "")
        ),
        ToolTip("Copied"),
        SetTimer(() => ToolTip(), -1000)
    ))

    CancelNow(*) {
        result["cancelled"] := true
        reviewGui.Destroy()
    }

    btnCancel.OnEvent("Click", CancelNow)
    reviewGui.OnEvent("Escape", CancelNow)
    reviewGui.OnEvent("Close", CancelNow)

    ; Initial load
    LoadTemplate(initialIndex)

    reviewGui.Show("AutoSize Center")
    ; Block until user closes window (Send/Cancel destroys GUI)
    try {
        WinWaitClose("ahk_id " reviewGui.Hwnd)
    } catch {
        ; ignore
    }
    return result
}

;# Show popup menu at cursor
ShowPopupMenu() {
    global _iMenu
    _iMenu.Show()
}

;# Initialize popup menu from settings
InitPopupMenu() {
    global _iMenu, _displayResponse, _iMenuItemParms, SETTINGS_FILE
    _iMenu := Menu()
    _iMenuItemParms := Map()

    _iMenu.add "&`` - Display response in new window", MenuNewWindowCheckHandler
    _iMenu.Add  ; Add a separator line.

    try {
        menu_items := IniRead(SETTINGS_FILE, "popup_menu")
    } catch as e {
        LogDebug "Warning: popup_menu section not found in settings.ini: " e.Message
        return
    }

    id := 1
    loop parse menu_items, "`n" {
        v_promptName := A_LoopField
        if (v_promptName != "" and SubStr(v_promptName, 1, 1) != "#") {
            if (v_promptName = "-") {
                _iMenu.Add  ; Add a separator line.
            } else {
                menu_text := GetSetting(v_promptName, "menu_text", v_promptName)
                if (RegExMatch(menu_text, "^[^&]*&[^&]*$") == 0) {
                    if (id == 10)
                        keyboard_shortcut := "&0 - "
                    else if (id > 10)
                        keyboard_shortcut := "&" Chr(id + 86) " - "
                    else
                        keyboard_shortcut := "&" id " - "
                    menu_text := keyboard_shortcut menu_text
                    id++
                }

                _iMenu.Add menu_text, MenuItemHandler
                try {
                    item_count := DllCall("GetMenuItemCount", "ptr", _iMenu.Handle)
                    _iMenuItemParms[item_count] := v_promptName
                } catch as e {
                    LogDebug "Warning: Failed to get menu item count: " e.Message
                }
            }
        }
    }
}

;# Handle menu item selection
MenuItemHandler(ItemName, ItemPos, MyMenu) {
    global _iMenuItemParms
    PromptHandler(_iMenuItemParms[ItemPos])
}

;# Toggle display mode (popup vs paste)
MenuNewWindowCheckHandler(*) {
    global _iMenu, _displayResponse
    _iMenu.ToggleCheck "&`` - Display response in new window"
    _displayResponse := !_displayResponse
    _iMenu.Show()
}

;# Initialize system tray menu
InitTrayMenu() {
    tray := A_TrayMenu
    tray.add
    tray.add "Open settings", OpenSettings
    tray.add "Reload settings", ReloadSettings
    tray.add
    tray.add "Github readme", OpenGithub
    TrayAddStartWithWindows(tray)
}

;# Add "Start with Windows" option to tray menu
TrayAddStartWithWindows(tray) {
    tray.add "Start with Windows", StartWithWindowsAction
    SplitPath a_scriptFullPath, , , , &script_name
    _sww_shortcut := a_startup "/" script_name ".lnk"
    if FileExist(_sww_shortcut) {
        fileGetShortcut _sww_shortcut, &target  ;# update if script has moved
        if (target != a_scriptFullPath) {
            fileCreateShortcut a_scriptFullPath, _sww_shortcut
        }
        tray.Check("Start with Windows")
    } else {
        tray.Uncheck("Start with Windows")
    }
    StartWithWindowsAction(*) {
        if FileExist(_sww_shortcut) {
            fileDelete(_sww_shortcut)
            tray.Uncheck("Start with Windows")
            trayTip("Start With Windows", "Shortcut removed", TRAY_TIP_DURATION)
        } else {
            fileCreateShortcut(a_scriptFullPath, _sww_shortcut)
            tray.Check("Start with Windows")
            trayTip("Start With Windows", "Shortcut created", TRAY_TIP_DURATION)
        }
    }
}

;# Open GitHub readme in browser
OpenGithub(*) {
    Run "https://github.com/ecornell/ai-tools-ahk#usage"
}

;# Open settings.ini in default editor
OpenSettings(*) {
    Run A_ScriptDir . "/settings.ini"
}

;# Reload settings from file
ReloadSettings(*) {
    TrayTip("Reload Settings", "Reloading settings...", TRAY_TIP_DURATION)
    ReloadSettingsCache()
    InitPopupMenu()
}

;# Handle response window resize
ResponseGui_Size(thisGui, MinMax, Width, Height) {
    if MinMax = -1  ; The window has been minimized. No action needed.
        return
    ; Otherwise, the window has been resized or maximized. Resize the controls to match.
    try {
        ogcActiveXWBC := thisGui["IE"]
        xClose := ""
        ; Find the close button
        for ctrlName, ctrl in thisGui {
            if (ctrl.Type = "Button") {
                xClose := ctrl
                break
            }
        }
        if (ogcActiveXWBC)
            ogcActiveXWBC.Move(,, Width - RESPONSE_GUI_MARGIN_RIGHT, Height - RESPONSE_GUI_MARGIN_BOTTOM)
        if (xClose)
            xClose.Move(Width / 2 - RESPONSE_BUTTON_OFFSET, Height - RESPONSE_BUTTON_OFFSET,,)
    }
}
