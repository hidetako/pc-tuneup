# =====================================================================
#  レジストリ・エラー (registry)
#  方針: 「存在しないファイルを指している登録」だけを対象にし、
#        削除前に必ず reg export でバックアップを取る。
# =====================================================================

function Global:Get-RunKeyPaths {
    @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
    )
}

Register-Check @{
    Id = 'registry.run-orphans'; Group = 'registry'
    Name = '存在しないプログラムの自動起動エントリ'
    Description = 'Run / RunOnce に登録されているが、実行ファイルが既に無い項目'
    FixLabel = '削除'
    Notes = 'アンインストール後に残った登録です。削除前に .reg ファイルへバックアップします。'
    Scan = {
        $found = @()
        foreach ($key in (Get-RunKeyPaths)) {
            foreach ($v in (Get-RegValues -Path $key)) {
                $exe = Get-ExecutablePath ([string]$v.Value)
                if ($exe -and -not (Test-Path -LiteralPath $exe)) {
                    $found += [pscustomobject]@{ Key = $key; Name = $v.Name; Value = [string]$v.Value; Exe = $exe }
                }
            }
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '問題ありません') }
        New-ScanResult -Status issue -Count $found.Count -Summary "$($found.Count) 件の無効なエントリ" `
            -Items @($found | ForEach-Object { '{0}\{1}  →  {2}' -f $_.Key, $_.Name, $_.Exe }) -Data @{ Entries = $found }
    }
    Fix = {
        param($ScanResult)
        $n = 0
        foreach ($e in $ScanResult.Data.Entries) {
            Backup-RegistryKey -PSPath $e.Key -Tag ('run-' + $e.Name) | Out-Null
            Remove-ItemProperty -LiteralPath $e.Key -Name $e.Name -ErrorAction Stop
            Write-Log "  削除: $($e.Key)\$($e.Name)"; $n++
        }
        New-FixResult -Success $true -Message "$n 件のエントリを削除しました (バックアップ: $(Join-Path $Global:PCTuneUp.DataDir 'backup'))"
    }
}

Register-Check @{
    Id = 'registry.uninstall-orphans'; Group = 'registry'
    Name = 'アンインストール済みアプリの残留エントリ'
    Description = '「インストールされているアプリ」に載るが、アンインストーラーも本体も無い項目'
    FixLabel = '削除'
    Notes = 'Windows Installer (msiexec) 管理の項目は対象外です。'
    Scan = {
        $found = @()
        foreach ($p in (Get-InstalledPrograms)) {
            if ($p.SystemComponent -or -not $p.Name -or -not $p.UninstallString) { continue }
            if ($p.WindowsInstaller -or $p.UninstallString -match 'msiexec') { continue }
            $exe = Get-ExecutablePath $p.UninstallString
            if (-not $exe -or (Test-Path -LiteralPath $exe)) { continue }
            if ($p.InstallLocation -and (Test-Path -LiteralPath $p.InstallLocation)) { continue }
            $found += $p
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '問題ありません') }
        New-ScanResult -Status issue -Count $found.Count -Summary "$($found.Count) 件の残留エントリ" `
            -Items @($found | ForEach-Object { '{0}  →  {1}' -f $_.Name, $_.UninstallString }) -Data @{ Keys = @($found | ForEach-Object { $_.KeyPath }) }
    }
    Fix = {
        param($ScanResult)
        $n = 0
        foreach ($k in $ScanResult.Data.Keys) {
            Backup-RegistryKey -PSPath $k -Tag ('uninstall-' + (Split-Path $k -Leaf)) | Out-Null
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
            Write-Log "  削除: $k"; $n++
        }
        New-FixResult -Success $true -Message "$n 件のエントリを削除しました"
    }
}

Register-Check @{
    Id = 'registry.app-paths'; Group = 'registry'
    Name = '無効なアプリケーション パス'
    Description = 'App Paths に登録されているが実行ファイルが無い項目'
    FixLabel = '削除'
    Scan = {
        $roots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths'
        )
        $found = @()
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $def = [string](Get-RegValue -Path $k.PSPath -Name '(default)')
                if (-not $def) { continue }
                $exe = Get-ExecutablePath $def
                if ($exe -and -not (Test-Path -LiteralPath $exe)) {
                    $found += [pscustomobject]@{ Key = $k.PSPath; Name = $k.PSChildName; Exe = $exe }
                }
            }
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '問題ありません') }
        New-ScanResult -Status issue -Count $found.Count -Summary "$($found.Count) 件の無効なパス" `
            -Items @($found | ForEach-Object { '{0}  →  {1}' -f $_.Name, $_.Exe }) -Data @{ Keys = @($found | ForEach-Object { $_.Key }) }
    }
    Fix = {
        param($ScanResult)
        $n = 0
        foreach ($k in $ScanResult.Data.Keys) {
            Backup-RegistryKey -PSPath $k -Tag ('apppath-' + (Split-Path $k -Leaf)) | Out-Null
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
            Write-Log "  削除: $k"; $n++
        }
        New-FixResult -Success $true -Message "$n 件のエントリを削除しました"
    }
}

Register-Check @{
    Id = 'registry.shared-dlls'; Group = 'registry'
    Name = '存在しない共有 DLL の参照'
    Description = 'SharedDLLs に登録されているが、ファイルが無い項目'
    RequiresAdmin = $true; FixLabel = '削除'
    Scan = {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedDLLs'
        $found = @()
        foreach ($v in (Get-RegValues -Path $key)) {
            $path = [Environment]::ExpandEnvironmentVariables($v.Name)
            if ((Test-IsRootedPath $path) -and -not (Test-Path -LiteralPath $path)) { $found += $v.Name }
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '問題ありません') }
        New-ScanResult -Status issue -Count $found.Count -Summary "$($found.Count) 件の無効な参照" -Items $found -Data @{ Key = $key; Names = $found }
    }
    Fix = {
        param($ScanResult)
        Backup-RegistryKey -PSPath $ScanResult.Data.Key -Tag 'shareddlls' | Out-Null
        $n = 0
        foreach ($name in $ScanResult.Data.Names) {
            Remove-ItemProperty -LiteralPath $ScanResult.Data.Key -Name $name -ErrorAction Stop; $n++
        }
        New-FixResult -Success $true -Message "$n 件の参照を削除しました"
    }
}

Register-Check @{
    Id = 'registry.service-orphans'; Group = 'registry'
    Name = '実行ファイルが無いサービス／ドライバー'
    Description = '削除済みソフトが残したサービス登録。起動時にエラーログを出す原因になります'
    RequiresAdmin = $true; Risk = 'medium'; FixLabel = '削除'
    Notes = 'ImagePath の実体が無いものだけを対象にします。取り外し中の外付け機器のドライバーが該当することもあるため、一覧を確認してから実行してください。'
    Scan = {
        $root = 'HKLM:\SYSTEM\CurrentControlSet\Services'
        $found = @()
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $img = [string](Get-RegValue -Path $k.PSPath -Name 'ImagePath')
            if (-not $img) { continue }
            if ($img -match 'svchost\.exe|dllhost\.exe|lsass\.exe') { continue }
            $exe = Get-ExecutablePath $img
            if (-not $exe -or (Test-Path -LiteralPath $exe)) { continue }
            $type = [int](Get-RegValue -Path $k.PSPath -Name 'Type')
            $desc = [string](Get-RegValue -Path $k.PSPath -Name 'DisplayName')
            $found += [pscustomobject]@{ Name = $k.PSChildName; Key = $k.PSPath; Exe = $exe; Type = $type; Display = $desc }
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '問題ありません') }
        New-ScanResult -Status issue -Count $found.Count -Summary "$($found.Count) 件の無効なサービス登録" `
            -Items @($found | ForEach-Object { '{0}  →  {1}' -f $_.Name, $_.Exe }) -Data @{ Entries = $found }
    }
    Fix = {
        param($ScanResult)
        $n = 0; $errors = @()
        foreach ($e in $ScanResult.Data.Entries) {
            try {
                Backup-RegistryKey -PSPath $e.Key -Tag ('service-' + $e.Name) | Out-Null
                $r = Invoke-Exe -File 'sc.exe' -Arguments 'delete', $e.Name -Quiet
                if ($r.ExitCode -ne 0) { throw ($r.Lines -join ' ') }
                Write-Log "  削除: サービス $($e.Name)"; $n++
            } catch { $errors += "$($e.Name): $($_.Exception.Message)" }
        }
        $msg = "$n 件のサービス登録を削除しました"
        if ($errors.Count) { $msg += ' / 失敗: ' + ($errors -join '; ') }
        New-FixResult -Success ($errors.Count -eq 0) -Message $msg -RebootRequired ($n -gt 0)
    }
}

# =====================================================================
#  レジストリ・エラー (追加のチェック)
#  いずれも「実体が無い / 既定から外れている」ものだけを対象にし、
#  変更前に必ず .reg へバックアップする。
# =====================================================================

function Global:Get-ClsidServerPath {
    # CLSID から実体の DLL / EXE を求める (64 ビットと 32 ビットの両方のビューを見る)
    param([Parameter(Mandatory)][string]$Clsid)
    foreach ($root in 'Registry::HKEY_CLASSES_ROOT\CLSID', 'Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID') {
        foreach ($server in 'InprocServer32', 'LocalServer32') {
            $key = "$root\$Clsid\$server"
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $raw = [string](Get-RegValue -Path $key -Name '(default)')
            if (-not $raw) { continue }
            return [pscustomobject]@{ Key = $key; Raw = $raw; Path = (Get-ExecutablePath $raw) }
        }
    }
    return $null
}

function Global:Get-ShellExtensionHandlers {
    <#
      エクスプローラーが読み込むシェル拡張 (右クリックメニュー・アイコンオーバーレイ) を列挙する。
      DLL が無い拡張は毎回読み込みに失敗し、フォルダーを開く動作を遅くする原因になる。
    #>
    $roots = @(
        'Registry::HKEY_CLASSES_ROOT\*\shellex\ContextMenuHandlers',
        'Registry::HKEY_CLASSES_ROOT\Directory\shellex\ContextMenuHandlers',
        'Registry::HKEY_CLASSES_ROOT\Directory\Background\shellex\ContextMenuHandlers',
        'Registry::HKEY_CLASSES_ROOT\Folder\shellex\ContextMenuHandlers',
        'Registry::HKEY_CLASSES_ROOT\AllFilesystemObjects\shellex\ContextMenuHandlers',
        'Registry::HKEY_CLASSES_ROOT\Drive\shellex\ContextMenuHandlers',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $def = [string](Get-RegValue -Path $k.PSPath -Name '(default)')
            # CLSID は既定値か、キー名そのものに入っている
            $clsid = $null
            if ($def -match '^\{[0-9A-Fa-f\-]{36}\}$') { $clsid = $def }
            elseif ($k.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') { $clsid = $k.PSChildName }
            if (-not $clsid) { continue }
            [pscustomobject]@{
                Name   = $k.PSChildName
                Key    = $k.PSPath
                Root   = $root
                Clsid  = $clsid
                Server = (Get-ClsidServerPath -Clsid $clsid)
            }
        }
    }
}

Register-Check @{
    Id = 'registry.shell-extensions'; Group = 'registry'
    Name = '読み込めないシェル拡張'
    Description = '右クリックメニューやアイコン表示を担う拡張のうち、DLL が既に無いもの'
    RequiresAdmin = $true; FixLabel = '削除'
    Notes = 'アンインストールしたソフトが残した登録です。エクスプローラーが毎回読み込みに失敗するため、フォルダーを開く動作が遅くなります。'
    Scan = {
        $found = @()
        foreach ($h in (Get-ShellExtensionHandlers)) {
            if (-not $h.Server) { continue }              # CLSID 自体が無い場合は他の項目に任せる
            if (-not $h.Server.Path) { continue }         # パスを特定できないものは触らない
            if (Test-Path -LiteralPath $h.Server.Path) { continue }
            $found += $h
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '問題ありません') }
        New-ScanResult -Status issue -Count $found.Count -Summary "$($found.Count) 件の壊れたシェル拡張" `
            -Items @($found | ForEach-Object { '{0}  →  {1}' -f $_.Name, $_.Server.Path }) `
            -Data @{ Keys = @($found | ForEach-Object { $_.Key }); Names = @($found | ForEach-Object { $_.Name }) }
    }
    Fix = {
        param($ScanResult)
        $n = 0
        for ($i = 0; $i -lt $ScanResult.Data.Keys.Count; $i++) {
            $k = $ScanResult.Data.Keys[$i]
            Backup-RegistryKey -PSPath $k -Tag ('shellex-' + $ScanResult.Data.Names[$i]) | Out-Null
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
            Write-Log "  削除: $k"; $n++
        }
        New-FixResult -Success $true -Message "$n 件のシェル拡張登録を削除しました (エクスプローラーの再起動後に反映)"
    }
}

Register-Check @{
    Id = 'registry.file-assoc'; Group = 'registry'
    Name = '開けないファイルの関連付け'
    Description = 'ファイルの種類に登録された「開く」コマンドが、既に無いプログラムを指している'
    ActionLabel = '既定のアプリを開く'
    Notes = '関連付けを勝手に消すとそのファイルが開けなくなるため、検出のみ行います。「既定のアプリ」で開くプログラムを選び直してください。'
    Scan = {
        $extRoot = 'Registry::HKEY_CLASSES_ROOT'
        if (-not (Test-Path -LiteralPath $extRoot)) { return (New-ScanResult -Status na -Summary 'この環境では確認できません') }
        $found = @(); $seen = @{}
        foreach ($k in (Get-ChildItem -LiteralPath $extRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName.StartsWith('.') })) {
            $progId = [string](Get-RegValue -Path $k.PSPath -Name '(default)')
            if (-not $progId -or $seen.ContainsKey($progId)) { continue }
            $seen[$progId] = $true
            $cmdKey = "$extRoot\$progId\shell\open\command"
            if (-not (Test-Path -LiteralPath $cmdKey)) { continue }
            $cmd = [string](Get-RegValue -Path $cmdKey -Name '(default)')
            $exe = Get-ExecutablePath $cmd
            if ($exe -and -not (Test-Path -LiteralPath $exe)) {
                $found += ('{0} ({1})  →  {2}' -f $k.PSChildName, $progId, $exe)
            }
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '問題ありません') }
        New-ScanResult -Status issue -Count $found.Count -Summary "$($found.Count) 種類のファイルが開けない状態です" -Items $found
    }
    Action = { Start-Tool 'ms-settings:defaultapps' }
}

function Global:Get-PathEntryStatus {
    # PATH の文字列を項目に分け、フォルダーが実在するかを調べる (%SystemRoot% などは展開して判定)
    param([string]$RawPath)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($e in ([string]$RawPath -split ';')) {
        $t = $e.Trim()
        if (-not $t) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($t)
        $exists = $false
        try { $exists = [bool](Test-Path -LiteralPath $expanded -PathType Container) } catch { }
        $entries.Add([pscustomobject]@{ Raw = $t; Expanded = $expanded; Exists = $exists })
    }
    # 呼び出し側は必ず @() で受ける (1 件のときにスカラーへ落ちるのを防ぐため)
    return $entries.ToArray()
}

function Global:Get-PathRegistryValue {
    # PATH を「展開せずに」読む。展開して書き戻すと %SystemRoot% が固定パスになってしまうため
    param([ValidateSet('Machine', 'User')][string]$Scope)
    if ($Scope -eq 'Machine') {
        $base = [Microsoft.Win32.Registry]::LocalMachine
        $sub = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $psPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    } else {
        $base = [Microsoft.Win32.Registry]::CurrentUser
        $sub = 'Environment'
        $psPath = 'HKCU:\Environment'
    }
    if (-not $base) { return $null }          # レジストリを扱えない環境 (Windows 以外) では対象外
    $key = $base.OpenSubKey($sub, $false)
    if (-not $key) { return $null }
    try {
        $names = @($key.GetValueNames())
        if ($names -notcontains 'Path') { return $null }
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $key.GetValueKind('Path')
    } finally { $key.Close() }
    [pscustomobject]@{ Scope = $Scope; SubKey = $sub; PSPath = $psPath; Raw = $raw; Kind = $kind }
}

function Global:Set-PathRegistryValue {
    param([ValidateSet('Machine', 'User')][string]$Scope, [Parameter(Mandatory)][string]$Value, $Kind)
    if ($Scope -eq 'Machine') {
        $base = [Microsoft.Win32.Registry]::LocalMachine
        $sub = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    } else {
        $base = [Microsoft.Win32.Registry]::CurrentUser
        $sub = 'Environment'
    }
    if (-not $base) { throw 'この環境ではレジストリを変更できません' }
    $key = $base.OpenSubKey($sub, $true)
    if (-not $key) { throw "$Scope の環境変数キーを開けません" }
    try { $key.SetValue('Path', $Value, $Kind) } finally { $key.Close() }
}

Register-Check @{
    Id = 'registry.path'; Group = 'registry'
    Name = '存在しないフォルダーを指す PATH'
    Description = 'PATH に残った実在しないフォルダー。コマンドを実行するたびに無駄な検索が発生します'
    Risk = 'medium'; FixLabel = '除去'
    FixConfirm = 'PATH から実在しないフォルダーを取り除きます (取り外し中の外付けドライブやネットワークドライブのパスも対象になります)'
    Notes = '外付けドライブを接続すれば戻るパスも「存在しない」と判定されます。一覧を確認してから実行してください。'
    Scan = {
        $items = @(); $missing = 0; $data = @()
        foreach ($scope in 'Machine', 'User') {
            $v = Get-PathRegistryValue -Scope $scope
            if (-not $v) { continue }
            $entries = @(Get-PathEntryStatus -RawPath $v.Raw)
            $bad = @($entries | Where-Object { -not $_.Exists })
            $label = $(if ($scope -eq 'Machine') { 'システム' } else { 'ユーザー' })
            $items += '{0}: {1} 件中 {2} 件が存在しません' -f $label, $entries.Count, $bad.Count
            foreach ($b in $bad) { $items += ('  ' + $b.Raw) }
            $missing += $bad.Count
            if ($bad.Count -gt 0) { $data += [pscustomobject]@{ Scope = $scope; Kind = $v.Kind; Keep = @($entries | Where-Object { $_.Exists } | ForEach-Object { $_.Raw }) } }
        }
        if ($items.Count -eq 0) { return (New-ScanResult -Status na -Summary 'PATH を読み取れません') }
        if ($missing -eq 0) { return (New-ScanResult -Status ok -Summary 'すべてのフォルダーが存在します' -Items $items) }
        New-ScanResult -Status issue -Count $missing -Summary "$missing 件の存在しないフォルダーが PATH にあります" -Items $items -Data @{ Targets = $data }
    }
    Fix = {
        param($ScanResult)
        $n = 0
        foreach ($t in $ScanResult.Data.Targets) {
            $v = Get-PathRegistryValue -Scope $t.Scope
            Backup-RegistryKey -PSPath $v.PSPath -Tag ('path-' + $t.Scope) | Out-Null
            Set-PathRegistryValue -Scope $t.Scope -Value ($t.Keep -join ';') -Kind $t.Kind
            Write-Log "  $($t.Scope) の PATH を更新しました ($($t.Keep.Count) 件を維持)"
            $n++
        }
        New-FixResult -Success $true -Message "$n 箇所の PATH を整理しました (新しく開くアプリから反映されます)" 
    }
}

Register-Check @{
    Id = 'registry.winlogon'; Group = 'registry'
    Name = 'サインイン時に起動するプログラム (Winlogon)'
    Description = 'Userinit と Shell が Windows の既定から書き換えられていないか'
    RequiresAdmin = $true; Risk = 'medium'; FixLabel = '既定に戻す'
    FixConfirm = 'Userinit と Shell を Windows の既定値に戻します (サインインの動作に関わるため、心当たりのない書き換えがある場合のみ実行してください)'
    Notes = 'ここはマルウェアの常駐先として使われることがあります。企業向けの設定で意図的に変更されている場合もあるため、値を確認してから判断してください。'
    Scan = {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if (-not (Test-Path -LiteralPath $k)) { return (New-ScanResult -Status na -Summary 'この環境では確認できません') }
        $userinit = [string](Get-RegValue -Path $k -Name 'Userinit')
        $shell = [string](Get-RegValue -Path $k -Name 'Shell')
        $items = @("Userinit: $userinit", "Shell: $shell")
        $bad = @()
        foreach ($part in ($userinit -split ',')) {
            $t = $part.Trim()
            if (-not $t) { continue }
            $exe = Get-ExecutablePath $t
            if (-not $exe -or (Split-Path $exe -Leaf) -ne 'userinit.exe') { $bad += "Userinit に想定外の項目: $t" }
        }
        $shellExe = Get-ExecutablePath $shell
        if (-not $shell) { $bad += 'Shell が設定されていません' }
        elseif (-not $shellExe -or (Split-Path $shellExe -Leaf) -ne 'explorer.exe') { $bad += "Shell が explorer.exe ではありません: $shell" }
        $userShell = Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'Shell'
        if ($userShell) { $bad += "ユーザー側にも Shell が設定されています: $userShell"; $items += "HKCU Shell: $userShell" }
        if ($bad.Count -eq 0) { return (New-ScanResult -Status ok -Summary '既定のままです' -Items $items) }
        New-ScanResult -Status issue -Count $bad.Count -Summary '既定から書き換えられています' -Items ($items + $bad)
    }
    Fix = {
        param($ScanResult)
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Backup-RegistryKey -PSPath $k -Tag 'winlogon' | Out-Null
        $userinitDefault = (Join-EnvPath $env:SystemRoot 'system32\userinit.exe') + ','
        Set-RegValue -Path $k -Name 'Userinit' -Value $userinitDefault -Type String
        Set-RegValue -Path $k -Name 'Shell' -Value 'explorer.exe' -Type String
        $userKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if ($null -ne (Get-RegValue -Path $userKey -Name 'Shell')) {
            Backup-RegistryKey -PSPath $userKey -Tag 'winlogon-user' | Out-Null
            Remove-ItemProperty -LiteralPath $userKey -Name 'Shell' -ErrorAction SilentlyContinue
        }
        New-FixResult -Success $true -Message 'Userinit と Shell を既定値に戻しました (次回のサインインから反映)'
    }
}
