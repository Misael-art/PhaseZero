#Requires AutoHotkey v2.0

ResolveBootstrapHome() {
    userProfile := EnvGet("USERPROFILE")
    if (userProfile != "")
        return userProfile

    home := EnvGet("HOME")
    if (home != "")
        return home

    homeDrive := EnvGet("HOMEDRIVE")
    homePath := EnvGet("HOMEPATH")
    if (homeDrive != "" && homePath != "")
        return homeDrive homePath

    localAppData := EnvGet("LOCALAPPDATA")
    if (localAppData != "")
        return localAppData

    tempPath := EnvGet("TEMP")
    if (tempPath != "")
        return tempPath

    return A_WorkingDir
}

bootstrapHome := ResolveBootstrapHome()
bootstrapRoot := bootstrapHome "\.bootstrap-tools\steamdeck\automation"
systemRoot := EnvGet("SystemRoot")
powershellExe := (systemRoot != "" ? systemRoot "\System32\WindowsPowerShell\v1.0\powershell.exe" : "powershell.exe")
settingsPath := bootstrapHome "\.bootstrap-tools\steamdeck-settings.json"

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
^!F6::RunBootstrapScript("Start-DevSession.ps1")
