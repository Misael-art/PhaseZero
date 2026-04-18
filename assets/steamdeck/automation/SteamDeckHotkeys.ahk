#Requires AutoHotkey v2.0

bootstrapRoot := EnvGet("USERPROFILE") "\.bootstrap-tools\steamdeck\automation"
powershellExe := EnvGet("SystemRoot") "\System32\WindowsPowerShell\v1.0\powershell.exe"
settingsPath := EnvGet("USERPROFILE") "\.bootstrap-tools\steamdeck-settings.json"

RunBootstrapScript(scriptName) {
    global bootstrapRoot
    global powershellExe
    global settingsPath

    scriptPath := bootstrapRoot "\" scriptName
    if !FileExist(scriptPath) {
        MsgBox("Script not found:`n" scriptPath, "SteamDeck Hotkeys", 48)
        return
    }

    Run('"' powershellExe '" -NoProfile -ExecutionPolicy Bypass -File "' scriptPath '" -SettingsPath "' settingsPath '"')
}

^!F1::RunBootstrapScript("Apply-Handheld.ps1")
^!F2::RunBootstrapScript("Apply-DockedMonitor.ps1")
^!F3::RunBootstrapScript("Apply-DockedTv.ps1")
^!F4::RunBootstrapScript("ModeWatcher.ps1")
^!F5::Run("SoundSwitch")
