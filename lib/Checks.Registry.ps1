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
