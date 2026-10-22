#!/usr/bin/env pwsh
# Fork installer: build-installer.ps1 with this fork's own identity, so it
# installs beside an official Plezy instead of over it, and shows as
# "Plezy Fork" in Apps & Features. The Start Menu entry is still "Plezy".
# installer\fork-installer.iss adds the look, the short wizard and the offer
# to remove the official Plezy; the wizard also asks "all users / me only".
# The same script is compiled a second time with ForkSilent defined: the silent
# installer (no pages, no questions, never removes the official Plezy; see
# fork-installer.iss).

param(
    [string]$OutputDir = ".",
    [Parameter(Mandatory)][string]$Version,
    [string]$X64BuildDir,
    [string]$InnoSetupPath = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    [string]$SevenZipPath = "$env:ProgramFiles\7-Zip\7z.exe",
    [switch]$EmitScriptOnly
)

$Identity = @{
    AppGuid                  = '1c3c86eb-f518-4002-b287-4cc21a29b477'
    AppTitle                 = 'Plezy Fork'
    InstallDirName           = 'PlezyFork'
    GroupName                = 'Plezy Fork'
    Publisher                = 'Plezy Fork'
    ReleasesUrl              = 'https://github.com/BakaDolev/plezy-bert/releases/latest'
    WizardStyle              = 'modern dynamic windows11'
    # The silent installer never asks "all users / me only": it installs per user.
    ExtraPrivilegesOverrides = '{#Defined(ForkSilent) ? "" : " dialog"}'
    IncludeScript            = 'windows\installer\fork-installer.iss'
    LaunchCheck              = ' and ForkLaunchAfterInstall'
    ExtraInstallers          = @{ 'plezy-windows-silent-installer' = @('/DForkSilent') }
}

$Forward = @{
    OutputDir     = $OutputDir
    Version       = $Version
    InnoSetupPath = $InnoSetupPath
    SevenZipPath  = $SevenZipPath
}
if ($X64BuildDir) { $Forward.X64BuildDir = $X64BuildDir }
if ($EmitScriptOnly) { $Forward.EmitScriptOnly = $true }

& "$PSScriptRoot\build-installer.ps1" @Identity @Forward
exit $LASTEXITCODE
