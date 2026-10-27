<#
.SYNOPSIS
  Sends UFC Undisputed 3 Recompiled to an Xbox in Developer Mode without
  installing an .msix: copies the app as loose files to the console's
  developer share, registers it, and launches it. Only changed files are
  copied, so after the first run an update is just the new ufc3.exe.

  Run through deploy-xbox.bat (double-click), after build-xbox.bat.
  get-xbox-log.bat runs this with -GetLog to download the app's log.txt.

  The first run asks for the Xbox's address and the Device Portal user name
  and password, and saves them in deploy-xbox.settings.xml next to this
  script (the password is encrypted for your Windows account).
#>
[CmdletBinding()]
param(
  [switch]$GetLog,      # only download LocalState\log.txt to this folder
  [switch]$Options,     # pick extra game settings (args.txt) and restart the game
  [switch]$NoLaunch,    # deploy without starting the app
  [switch]$ResetSettings
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$SettingsPath = Join-Path $Root 'deploy-xbox.settings.xml'
$StatePath = Join-Path $Root 'deploy-xbox.state'
$ArgsPath = Join-Path $Root 'xbox-args.txt'
$Layout = Join-Path $Root 'UFC3ReX\out\build\uwp-amd64-release\uwp\ufc3\Release\layout'
# The extracted game files: the folder named in game-folder.txt.
$GameFolderFile = Join-Path $Root 'game-folder.txt'
$GameFiles = if (Test-Path $GameFolderFile) {
  ((Get-Content -LiteralPath $GameFolderFile | Where-Object { $_.Trim() }) | Select-Object -First 1).Trim().Trim('"')
} else { '' }
$LooseFolderName = 'ufc3'
$PackageName = 'ReXGlue.UFC3'
$Curl = if ($env:RB2X_CURL) { $env:RB2X_CURL } else { 'curl.exe' }
$PortalPort = if ($env:RB2X_PORTAL_PORT) { $env:RB2X_PORTAL_PORT } else { '11443' }

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

function ConvertTo-Base64Param([string]$Text) {
  [Uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)))
}

function Get-Settings {
  if ($ResetSettings -and (Test-Path $SettingsPath)) { Remove-Item $SettingsPath }
  if (Test-Path $SettingsPath) { return Import-Clixml $SettingsPath }
  Write-Host 'First-time setup. You can find these in Dev Home on the Xbox:'
  Write-Host '  - the address under Remote Access, for example 192.168.1.50'
  Write-Host '  - the Device Portal user name and password you set'
  $address = (Read-Host 'Xbox address (just the numbers, no https:// or :11443)').Trim()
  $address = $address -replace '^https?://', '' -replace ':\d+/?$', '' -replace '/$', ''
  $user = (Read-Host 'Device Portal user name').Trim()
  $password = Read-Host 'Device Portal password' -AsSecureString
  $settings = [pscustomobject]@{
    Address    = $address
    Credential = New-Object System.Management.Automation.PSCredential($user, $password)
  }
  $settings | Export-Clixml $SettingsPath
  return $settings
}

# Calls the Device Portal REST API. Returns @{ Code = <HTTP status>; Body = <text> }.
# The "auto-" user name prefix is the Device Portal's documented way for
# command-line clients to skip its browser CSRF check.
function Invoke-Portal([string]$Method, [string]$PathAndQuery, [string]$OutFile) {
  $url = "https://$($Settings.Address):$PortalPort$PathAndQuery"
  $user = 'auto-' + $Settings.Credential.UserName
  $password = $Settings.Credential.GetNetworkCredential().Password
  $bodyFile = if ($OutFile) { $OutFile } else { [IO.Path]::GetTempFileName() }
  try {
    $code = & $Curl -s -k --max-time 300 -u "${user}:${password}" -X $Method `
      -H 'Content-Length: 0' -o $bodyFile -w '%{http_code}' $url
    if ($LASTEXITCODE -ne 0) {
      throw "Couldn't reach the Device Portal at https://$($Settings.Address):$PortalPort (curl error $LASTEXITCODE). Check the address, that the Xbox is on and in Dev Mode, and that Device Portal is enabled."
    }
    $body = if ($OutFile) { '' } else { [IO.File]::ReadAllText($bodyFile) }
    $result = @{ Code = [int]$code; Body = $body }
    if ($result.Code -eq 401) {
      throw "The Device Portal rejected the user name or password. Run deploy-xbox.bat again after deleting deploy-xbox.settings.xml to re-enter them."
    }
    return $result
  } finally {
    if (-not $OutFile) { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
  }
}

function Get-Packages {
  $r = Invoke-Portal 'GET' '/api/app/packagemanager/packages'
  if ($r.Code -ne 200) { throw "Listing the Xbox's apps failed (HTTP $($r.Code)): $($r.Body)" }
  $json = $r.Body | ConvertFrom-Json
  if ($json.InstalledPackages) { return @($json.InstalledPackages) }
  return @()
}

function Find-Rb2Package {
  Get-Packages | Where-Object { $_.PackageFullName -like "$PackageName`_*" } | Select-Object -First 1
}

function Remove-InstalledPackage($Package) {
  # Unlike most Device Portal calls, uninstall takes the plain (not base64)
  # package name.
  $r = Invoke-Portal 'DELETE' ("/api/app/packagemanager/package?package=" + [Uri]::EscapeDataString($Package.PackageFullName))
  if ($r.Code -ge 300) { throw "Uninstalling $($Package.PackageFullName) failed (HTTP $($r.Code)): $($r.Body)" }
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    if (-not (Find-Rb2Package)) { return }
  }
  throw "The old installation is still listed after 2 minutes. Uninstall it in the Device Portal, then run this again."
}

function Get-ShareCredentials {
  $r = Invoke-Portal 'GET' '/ext/smb/developerfolder'
  if ($r.Code -ne 200) { throw "Getting the developer share login failed (HTTP $($r.Code)): $($r.Body)" }
  $json = $r.Body | ConvertFrom-Json
  if ($json.Credentials) { $json = $json.Credentials }
  if (-not $json.Username) { throw "Unexpected developer share reply: $($r.Body)" }
  # The console may report its own local path (for example
  # D:\DevelopmentFiles) rather than the network path; the share is named
  # after the folder.
  $shareName = 'DevelopmentFiles'
  if ($json.Path) {
    $reported = $json.Path.TrimEnd('\')
    if ($reported.StartsWith('\\')) {
      $path = $reported
    } else {
      $leaf = ($reported -split '[\\/]')[-1]
      if ($leaf) { $shareName = $leaf }
      $path = "\\$($Settings.Address)\$shareName"
    }
  } else {
    $path = "\\$($Settings.Address)\$shareName"
  }
  return [pscustomobject]@{ Path = $path; Username = $json.Username; Password = $json.Password }
}

# Disconnects from a share, ignoring "not connected" messages. In Windows
# PowerShell, redirecting a native command's error output while
# $ErrorActionPreference is 'Stop' turns any message into a fatal error.
function Disconnect-Share([string]$Path) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & net use $Path /delete /y 2>&1 | Out-Null
  } catch {
  } finally {
    $ErrorActionPreference = $previous
  }
}

function Copy-ToShare([string]$Source, [string]$Destination) {
  & robocopy $Source $Destination /E /R:2 /W:2 /NP /NFL /NDL /NJH | Out-Host
  if ($LASTEXITCODE -ge 8) { throw "Copying $Source to the Xbox failed (robocopy code $LASTEXITCODE)." }
}

# The app needs Microsoft's C++ runtime package (Microsoft.VCLibs) on the
# Xbox. It comes with Visual Studio; this sends it to the Xbox when it isn't
# in the Xbox's app list (installing it again when it's there does no harm).
function Install-VCLibs {
  $appx = Join-Path ${env:ProgramFiles(x86)} ('Microsoft SDKs\Windows Kits\10\ExtensionSDKs\' +
    'Microsoft.VCLibs\14.0\Appx\Retail\x64\Microsoft.VCLibs.x64.14.00.appx')
  if (-not (Test-Path $appx)) {
    Write-Host ("Microsoft.VCLibs.x64.14.00.appx isn't on this PC ($appx). If registering " +
      "fails, add the Universal Windows Platform tools in the Visual Studio Installer.") -ForegroundColor Yellow
    return
  }
  Write-Step 'Installing the C++ runtime package (Microsoft.VCLibs) on the Xbox'
  $url = "https://$($Settings.Address):$PortalPort/api/app/packagemanager/package?package=Microsoft.VCLibs.x64.14.00.appx"
  $user = 'auto-' + $Settings.Credential.UserName
  $password = $Settings.Credential.GetNetworkCredential().Password
  $code = & $Curl -s -k --max-time 600 -u "${user}:${password}" -X POST `
    -F "file=@$appx;filename=Microsoft.VCLibs.x64.14.00.appx" -o NUL -w '%{http_code}' $url
  if ($LASTEXITCODE -ne 0 -or [int]$code -ge 300) {
    Write-Host ("Sending Microsoft.VCLibs failed (HTTP $code). If registering fails next, install " +
      "$appx with the Device Portal (My games & apps, Add).") -ForegroundColor Yellow
    return
  }
  try { Wait-Deployment } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
  Write-Host 'Done.'
}

function Wait-Deployment {
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    $r = Invoke-Portal 'GET' '/api/app/packagemanager/state'
    if ($r.Code -eq 204) { continue }       # still deploying
    # 200: done. 404: no deployment in progress any more. Either way the
    # package list (checked next) shows whether it worked.
    if ($r.Code -eq 200 -or $r.Code -eq 404) { return }
    throw "Registering the app failed (HTTP $($r.Code)): $($r.Body)"
  }
  throw 'Registering the app is taking more than 3 minutes. Check My games & apps in the Device Portal.'
}

function Start-Rb2([object]$Package) {
  $relativeId = $Package.PackageRelativeId
  if (-not $relativeId) { $relativeId = "$($Package.PackageFamilyName)!App" }
  $r = Invoke-Portal 'POST' ("/api/taskmanager/app?appid=" + (ConvertTo-Base64Param $relativeId) +
    "&package=" + (ConvertTo-Base64Param $Package.PackageFullName))
  if ($r.Code -ge 300) { throw "Launching the app failed (HTTP $($r.Code)): $($r.Body)" }
}

function Stop-Rb2([object]$Package) {
  # Closing the game first, so its files can be replaced. Fails harmlessly
  # when it isn't running.
  $null = Invoke-Portal 'DELETE' ("/api/taskmanager/app?package=" + (ConvertTo-Base64Param $Package.PackageFullName))
}

function Get-ManifestHash {
  (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Layout 'AppxManifest.xml')).Hash
}

function Get-AppFileQuery([object]$Package, [string]$SubPath) {
  '&packagefullname=' + [Uri]::EscapeDataString($Package.PackageFullName) +
    '&path=' + [Uri]::EscapeDataString($SubPath)
}

# Puts xbox-args.txt (extra game settings, one per line) on the Xbox as
# LocalState\args.txt, or removes args.txt there when there's no xbox-args.txt.
function Sync-Args([object]$Package) {
  $query = '/api/filesystem/apps/file?knownfolderid=LocalAppData' + (Get-AppFileQuery $Package '\LocalState')
  if (Test-Path $ArgsPath) {
    $url = "https://$($Settings.Address):$PortalPort$query"
    $user = 'auto-' + $Settings.Credential.UserName
    $password = $Settings.Credential.GetNetworkCredential().Password
    $code = & $Curl -s -k --max-time 60 -u "${user}:${password}" -X POST `
      -F "file=@$ArgsPath;filename=args.txt" -o NUL -w '%{http_code}' $url
    if ($LASTEXITCODE -ne 0 -or [int]$code -ge 300) {
      throw "Sending the game settings (xbox-args.txt) to the Xbox failed (HTTP $code)."
    }
    Write-Host 'Game settings sent: ' -NoNewline
    Write-Host ((Get-Content $ArgsPath | Where-Object { $_ -and $_ -notmatch '^\s*#' }) -join ' ')
  } else {
    $null = Invoke-Portal 'DELETE' ($query + '&filename=args.txt')
  }
}

# Lists the game's LocalState folder on the Xbox (saves, log, settings) into
# xbox-files.txt.
function Save-FileList([object]$Package) {
  $lines = New-Object System.Collections.Generic.List[string]
  $pending = New-Object System.Collections.Generic.Queue[object]
  $pending.Enqueue(@('\LocalState', 0))
  while ($pending.Count) {
    $item = $pending.Dequeue()
    $r = Invoke-Portal 'GET' ('/api/filesystem/apps/files?knownfolderid=LocalAppData' + (Get-AppFileQuery $Package $item[0]))
    if ($r.Code -ne 200) { $lines.Add("$($item[0]): HTTP $($r.Code)"); continue }
    foreach ($entry in @(($r.Body | ConvertFrom-Json).Items)) {
      $isDir = ($entry.Type -band 16) -ne 0
      $path = "$($item[0])\$($entry.Name)"
      if ($isDir) {
        $lines.Add("$path\")
        if ($item[1] -lt 6) { $pending.Enqueue(@($path, $item[1] + 1)) }
      } else {
        $lines.Add("$path  ($($entry.FileSize) bytes)")
      }
    }
  }
  [IO.File]::WriteAllLines((Join-Path $Root 'xbox-files.txt'), $lines)
}

# Deletes the game's stored shaders and pipelines (LocalState\ufc3\cache\shaders).
function Clear-ShaderCache([object]$Package) {
  $removed = 0
  $pending = New-Object System.Collections.Generic.Queue[string]
  $pending.Enqueue('\LocalState\ufc3\cache\shaders')
  while ($pending.Count) {
    $dir = $pending.Dequeue()
    $r = Invoke-Portal 'GET' ('/api/filesystem/apps/files?knownfolderid=LocalAppData' + (Get-AppFileQuery $Package $dir))
    if ($r.Code -ne 200) { continue }
    foreach ($entry in @(($r.Body | ConvertFrom-Json).Items)) {
      if (($entry.Type -band 16) -ne 0) {
        $pending.Enqueue("$dir\$($entry.Name)")
      } else {
        $d = Invoke-Portal 'DELETE' ('/api/filesystem/apps/file?knownfolderid=LocalAppData' +
          (Get-AppFileQuery $Package $dir) + '&filename=' + [Uri]::EscapeDataString($entry.Name))
        if ($d.Code -lt 300) { $removed++ } else { Write-Host "Couldn't delete $dir\$($entry.Name) (HTTP $($d.Code))" }
      }
    }
  }
  return $removed
}

function Invoke-Options {
  $package = Find-Rb2Package
  if (-not $package) { throw 'UFC Undisputed 3 Recompiled is not installed on the Xbox. Run deploy-xbox.bat first.' }
  $choices = @(
    @{ Name = 'Normal settings (use this unless something is wrong)'; Args = @() },
    @{ Name = 'Clear the shader cache (if the game crashes at startup)'; Args = $null; Clear = $true },
    @{ Name = 'Undo the changes made in the in-game Start+Share menu (if the game crashes at startup after using it)'; Args = $null; ResetConfig = $true }
  )
  Write-Host ''
  Write-Host 'Extra settings for the game (no rebuild needed):'
  for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host ("  {0}. {1}" -f $i, $choices[$i].Name) }
  $answer = (Read-Host 'Type a number and press Enter').Trim()
  $index = 0
  if (-not [int]::TryParse($answer, [ref]$index) -or $index -lt 0 -or $index -ge $choices.Count) {
    throw "'$answer' isn't one of the numbers."
  }
  $choice = $choices[$index]
  if ($choice.ResetConfig) {
    Write-Step 'Removing the settings saved by the in-game menu'
    Stop-Rb2 $package
    Start-Sleep -Seconds 2
    $query = '/api/filesystem/apps/file?knownfolderid=LocalAppData' +
      (Get-AppFileQuery $package '\LocalState') + '&filename=ufc3.toml'
    $r = Invoke-Portal 'GET' $query (Join-Path $Root 'xbox-config-old.txt')
    if ($r.Code -eq 200) { Write-Host 'Saved a copy of the old settings to xbox-config-old.txt.' }
    $null = Invoke-Portal 'DELETE' $query
    Start-Rb2 $package
    Write-Host 'Settings reset. Started the game.'
    return
  }
  if ($choice.Clear -and $choice.Args -and $choice.Args.Count) {
    [IO.File]::WriteAllLines($ArgsPath, [string[]](@("# $($choice.Name)") + $choice.Args))
    Write-Step 'Clearing the shader cache and restarting the game with these settings'
    Stop-Rb2 $package
    Start-Sleep -Seconds 2
    $removed = Clear-ShaderCache $package
    Write-Host "Removed $removed cache files."
    Sync-Args $package
    Start-Rb2 $package
    Write-Host "Started with: $($choice.Name)"
    return
  }
  if ($choice.Clear) {
    Write-Step 'Clearing the shader cache on the Xbox'
    Stop-Rb2 $package
    Start-Sleep -Seconds 2
    $removed = Clear-ShaderCache $package
    Write-Host "Removed $removed cache files."
    Start-Rb2 $package
    Write-Host 'Started the game.'
    return
  }
  if ($choice.Args.Count) {
    [IO.File]::WriteAllLines($ArgsPath, [string[]](@("# $($choice.Name)") + $choice.Args))
  } elseif (Test-Path $ArgsPath) {
    Remove-Item $ArgsPath
  }
  Write-Step 'Restarting the game on the Xbox with these settings'
  Stop-Rb2 $package
  Start-Sleep -Seconds 2
  Sync-Args $package
  Start-Rb2 $package
  Write-Host "Started with: $($choice.Name)"
}

function Save-Log {
  $package = Find-Rb2Package
  if (-not $package) { throw 'UFC Undisputed 3 Recompiled is not installed on the Xbox.' }
  $target = Join-Path $Root 'xbox-log.txt'
  $query = '/api/filesystem/apps/file?knownfolderid=LocalAppData&filename=log.txt' +
    '&packagefullname=' + [Uri]::EscapeDataString($package.PackageFullName) +
    '&path=' + [Uri]::EscapeDataString('\LocalState')
  $r = Invoke-Portal 'GET' $query $target
  try { Save-FileList $package } catch { }
  try {
    $configQuery = '/api/filesystem/apps/file?knownfolderid=LocalAppData&filename=ufc3.toml' +
      '&packagefullname=' + [Uri]::EscapeDataString($package.PackageFullName) +
      '&path=' + [Uri]::EscapeDataString('\LocalState')
    $configTarget = Join-Path $Root 'xbox-config.txt'
    $c = Invoke-Portal 'GET' $configQuery $configTarget
    if ($c.Code -ne 200) { Remove-Item $configTarget -ErrorAction SilentlyContinue }
  } catch { }
  if ($r.Code -ne 200) {
    Remove-Item $target -ErrorAction SilentlyContinue
    Save-LogDiagnostics $package $r.Code
    throw ("Downloading log.txt failed (HTTP $($r.Code)). Saved what the Xbox reported to " +
      "xbox-log-diagnostics.txt - attach it to an issue on the GitHub page if you need help.")
  }
  Write-Host "Saved the Xbox log to $target"
}

# When log.txt can't be downloaded: records what the Xbox has in the app's
# folders and whether the game is running, in xbox-log-diagnostics.txt.
function Save-LogDiagnostics([object]$Package, [int]$LogCode) {
  $report = New-Object System.Collections.Generic.List[string]
  $report.Add("Time: $(Get-Date -Format o)")
  $report.Add("Package: $($Package.PackageFullName)")
  $report.Add("Family: $($Package.PackageFamilyName)")
  $report.Add("log.txt download: HTTP $LogCode")
  $pkg = [Uri]::EscapeDataString($Package.PackageFullName)
  $requests = @(
    '/api/filesystem/apps/knownfolders',
    "/api/filesystem/apps/files?knownfolderid=LocalAppData&packagefullname=$pkg",
    ("/api/filesystem/apps/files?knownfolderid=LocalAppData&packagefullname=$pkg&path=" +
      [Uri]::EscapeDataString('\LocalState')),
    '/api/resourcemanager/processes'
  )
  foreach ($request in $requests) {
    $report.Add('')
    $report.Add("GET $request")
    try {
      $r = Invoke-Portal 'GET' $request
      $report.Add("HTTP $($r.Code)")
      $body = $r.Body
      if ($request -like '/api/resourcemanager/processes*' -and $r.Code -eq 200) {
        # Only the game's process, not the whole list.
        try {
          $found = @(($body | ConvertFrom-Json).Processes | Where-Object {
            $_.ImageName -like 'ufc3*' -or $_.PackageFullName -like "$PackageName`_*" })
          $body = if ($found.Count) { ($found | ConvertTo-Json -Depth 3) } else { 'ufc3 is not running' }
        } catch { }
      }
      if ($body.Length -gt 20000) { $body = $body.Substring(0, 20000) + ' ...' }
      $report.Add($body)
    } catch {
      $report.Add("failed: $($_.Exception.Message)")
    }
  }
  $path = Join-Path $Root 'xbox-log-diagnostics.txt'
  [IO.File]::WriteAllLines($path, $report)
}

function Invoke-Main {
  $script:Settings = Get-Settings

  if ($GetLog) { Save-Log; return }
  if ($Options) { Invoke-Options; return }

  Write-Step 'Checking the build'
  foreach ($required in @('AppxManifest.xml', 'ufc3.exe')) {
    if (-not (Test-Path (Join-Path $Layout $required))) {
      throw "The build output is missing $required. Run build-xbox.bat first."
    }
  }
  if (-not (Test-Path (Join-Path $GameFiles 'default.xex'))) {
    throw "The game folder in game-folder.txt ($GameFiles) has no default.xex."
  }

  Write-Step 'Checking what is installed on the Xbox'
  $installed = Find-Rb2Package
  $looseDeployed = Test-Path $StatePath
  if ($installed -and -not $looseDeployed) {
    Write-Host "Found the .msix installation ($($installed.PackageFullName))."
    Write-Host 'It has to be removed once so the quick-update version can take its place.'
    Write-Host 'This deletes its LocalState (log.txt and any saves).'
    $answer = Read-Host 'Remove it now? (y/n)'
    if ($answer -notmatch '^[Yy]') { throw 'Stopped without changing anything.' }
    Remove-InstalledPackage $installed
    Write-Host 'Removed.'
  }

  if ($installed -and $looseDeployed) {
    Write-Step 'Closing the game on the Xbox if it is running'
    Stop-Rb2 $installed
    Start-Sleep -Seconds 2
  }

  Write-Step 'Connecting to the Xbox developer share'
  $share = Get-ShareCredentials
  Disconnect-Share $share.Path
  & net use $share.Path /user:$($share.Username) $share.Password | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Connecting to $($share.Path) failed." }
  try {
    $destination = Join-Path $share.Path "LooseApps\$LooseFolderName"
    Write-Step 'Copying the app (only changed files)'
    Copy-ToShare $Layout $destination
    Write-Step 'Copying the game files (only the first time takes long)'
    Copy-ToShare $GameFiles (Join-Path $destination 'assets')
  } finally {
    Disconnect-Share $share.Path
  }

  # Registering again resets the game's LocalState folder on the Xbox (saves
  # and settings), so it's only done when needed: the first time, or when the
  # app's manifest changed. Otherwise the copied files are used as they are.
  $manifestHash = Get-ManifestHash
  $state = if ($looseDeployed) { (Get-Content $StatePath -Raw).Trim() } else { '' }
  $package = Find-Rb2Package
  if ($package -and $state -eq "loose $manifestHash") {
    Write-Host "Already registered ($($package.PackageFullName)) - your saves are kept."
  } else {
    if ($package) {
      Write-Host 'The app has to be registered again. This can reset its saves.' -ForegroundColor Yellow
    }
    # The app needs Microsoft's C++ runtime package. It came with the .msix
    # install, but removing that install can remove it too.
    $vclibs = Get-Packages | Where-Object { $_.PackageFullName -like 'Microsoft.VCLibs.140.00_*x64*' -and $_.PackageFullName -notlike '*.Debug*' }
    if (-not $vclibs) { Install-VCLibs }

    Write-Step 'Registering the app on the Xbox'
    $r = Invoke-Portal 'POST' ("/api/app/packagemanager/register?folder=" + (ConvertTo-Base64Param $LooseFolderName))
    if ($r.Code -ge 300) { throw "Registering the app failed (HTTP $($r.Code)): $($r.Body)" }
    Wait-Deployment
    Set-Content -Path $StatePath -Value "loose $manifestHash"
    $package = Find-Rb2Package
    if (-not $package) { throw 'The app was registered but is not listed. Check My games & apps in the Device Portal.' }
    Write-Host "Registered $($package.PackageFullName)."
  }

  if (-not $looseDeployed) {
    Write-Host ''
    Write-Host 'FIRST TIME ONLY: in Dev Home on the Xbox, set this app''s type to Game' -ForegroundColor Yellow
    Write-Host '(highlight it, press Menu, View details, App type: Game).' -ForegroundColor Yellow
    Read-Host 'Press Enter when done'
  }

  Sync-Args $package

  if (-not $NoLaunch) {
    Write-Step 'Launching on the Xbox'
    Start-Rb2 $package
    Write-Host 'Started. If it closes, run get-xbox-log.bat to download log.txt.'
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  try {
    Invoke-Main
    exit 0
  } catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
  }
}
