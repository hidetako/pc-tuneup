# =====================================================================
#  Windows の設定 (settings)
# =====================================================================

function Global:Get-StartupItems {
    # Run キーとスタートアップフォルダーの項目を、有効／無効の判定付きで列挙
    $items = @()
    $approvedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $sources = @(
        @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKCU:\$approvedRoot\Run" },
        @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKLM:\$approvedRoot\Run" },
        @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approvedRoot\Run32" }
    )
    foreach ($s in $sources) {
        foreach ($v in (Get-RegValues -Path $s.Key)) {
            $flag = Get-RegValue -Path $s.Approved -Name $v.Name
            $enabled = -not ($flag -and $flag.Length -gt 0 -and ($flag[0] -band 1) -eq 1)
            $items += [pscustomobject]@{ Name = $v.Name; Command = [string]$v.Value; Source = $s.Key; Enabled = $enabled }
        }
    }
    $folders = @(
        @{ Path = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup';     Approved = "HKCU:\$approvedRoot\StartupFolder" },
        @{ Path = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'; Approved = "HKLM:\$approvedRoot\StartupFolder" }
    )
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f.Path)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $flag = Get-RegValue -Path $f.Approved -Name $file.Name
            $enabled = -not ($flag -and $flag.Length -gt 0 -and ($flag[0] -band 1) -eq 1)
            $items += [pscustomobject]@{ Name = $file.BaseName; Command = $file.FullName; Source = $f.Path; Enabled = $enabled }
        }
    }
    return $items
}

Register-Check @{
    Id = 'settings.startup'; Group = 'settings'
    Name = 'スタートアップ アプリの数'
    Description = 'サインイン時に自動起動するアプリが多いと起動が遅くなります'
    ActionLabel = 'スタートアップ設定を開く'
    Notes = 'どれを止めるかは利用状況によるため、Windows の設定画面で個別に無効化してください。'
    Scan = {
        $items = @(Get-StartupItems)
        $enabled = @($items | Where-Object { $_.Enabled })
        $list = @($enabled | Sort-Object Name | ForEach-Object { '{0}  →  {1}' -f $_.Name, $_.Command })
        $disabledCount = $items.Count - $enabled.Count
        $summary = '有効 {0} 件 / 無効 {1} 件' -f $enabled.Count, $disabledCount
        $status = if ($enabled.Count -ge 10) { 'recommend' } else { 'ok' }
        if ($status -eq 'recommend') { $summary += ' — 使っていないものを無効化すると起動が速くなります' }
        New-ScanResult -Status $status -Count $enabled.Count -Summary $summary -Items $list
    }
    Action = { Start-Tool 'ms-settings:startupapps' }
}

Register-Check @{
    Id = 'settings.storage-sense'; Group = 'settings'
    Name = 'ストレージ センサー'
    Description = '一時ファイルやごみ箱を Windows が自動で整理する機能'
    FixLabel = '有効にする'
    Scan = {
        $v = Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -Name '01'
        if ($v -eq 1) { New-ScanResult -Status ok -Summary '有効' }
        else { New-ScanResult -Status recommend -Count 1 -Summary '無効です。有効にすると不要ファイルが自動で整理されます' }
    }
    Fix = {
        param($ScanResult)
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        Set-RegValue -Path $k -Name '01' -Value 1
        if ($null -eq (Get-RegValue -Path $k -Name '2048')) { Set-RegValue -Path $k -Name '2048' -Value 0 }   # 空き容量が少ないときに実行
        New-FixResult -Success $true -Message 'ストレージ センサーを有効にしました'
    }
}

Register-Check @{
    Id = 'settings.free-space'; Group = 'settings'
    Name = 'ドライブの空き容量'
    Description = '空き容量が 10% を切ると更新の失敗や動作の遅延が起きやすくなります'
    ActionLabel = 'ストレージ設定を開く'
    Scan = {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
        $items = @(); $low = 0
        foreach ($d in $disks) {
            if (-not $d.Size) { continue }
            $pct = [math]::Round($d.FreeSpace * 100 / $d.Size, 1)
            $items += '{0}  空き {1} / {2} ({3}%)' -f $d.DeviceID, (Format-Bytes $d.FreeSpace), (Format-Bytes $d.Size), $pct
            if ($pct -lt 10 -or $d.FreeSpace -lt 10GB) { $low++ }
        }
        if ($low -gt 0) { New-ScanResult -Status issue -Count $low -Summary "$low 台のドライブで空き容量が不足しています" -Items $items }
        else { New-ScanResult -Status ok -Summary '空き容量は十分です' -Items $items }
    }
    Action = { Start-Tool 'ms-settings:storagesense' }
}

Register-Check @{
    Id = 'settings.trim'; Group = 'settings'
    Name = 'SSD の TRIM'
    Description = 'SSD の寿命と速度を保つ TRIM が有効かどうか'
    RequiresAdmin = $true; FixLabel = '有効にする'
    Scan = {
        $ssd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.MediaType -eq 'SSD' })
        if ($ssd.Count -eq 0) { return (New-ScanResult -Status na -Summary 'SSD が検出されないため対象外') }
        $r = Invoke-Exe -File 'fsutil.exe' -Arguments 'behavior', 'query', 'DisableDeleteNotify' -Quiet
        $line = $r.Lines | Where-Object { $_ -match 'NTFS\s+DisableDeleteNotify\s*=\s*(\d)' } | Select-Object -First 1
        if (-not $line) { $line = $r.Lines | Where-Object { $_ -match 'DisableDeleteNotify\s*=\s*(\d)' } | Select-Object -First 1 }
        if (-not $line) { throw 'fsutil の出力を解釈できません' }
        $null = $line -match 'DisableDeleteNotify\s*=\s*(\d)'
        if ($Matches[1] -eq '0') { New-ScanResult -Status ok -Summary 'TRIM は有効です' -Items $r.Lines }
        else { New-ScanResult -Status issue -Count 1 -Summary 'TRIM が無効です' -Items $r.Lines }
    }
    Fix = {
        param($ScanResult)
        $r = Invoke-Exe -File 'fsutil.exe' -Arguments 'behavior', 'set', 'DisableDeleteNotify', 'NTFS', '0' -Quiet
        if ($r.ExitCode -ne 0) { $r = Invoke-Exe -File 'fsutil.exe' -Arguments 'behavior', 'set', 'DisableDeleteNotify', '0' -Quiet }
        if ($r.ExitCode -eq 0) { New-FixResult -Success $true -Message 'TRIM を有効にしました' }
        else { New-FixResult -Success $false -Message ('fsutil が失敗しました: ' + ($r.Lines -join ' ')) }
    }
}

Register-Check @{
    Id = 'settings.defrag-task'; Group = 'settings'
    Name = 'ドライブの最適化 (スケジュール)'
    Description = 'Windows が週 1 回ドライブを最適化 (SSD は TRIM、HDD はデフラグ) するタスク'
    RequiresAdmin = $true; FixLabel = '有効にする'
    Scan = {
        $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -InputObject $t -ErrorAction SilentlyContinue
        $last = if ($info -and $info.LastRunTime -gt (Get-Date '2000-01-01')) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { '不明' }
        if ($t.State -eq 'Disabled') { New-ScanResult -Status issue -Count 1 -Summary "無効になっています (最終実行: $last)" }
        else { New-ScanResult -Status ok -Summary "有効 (状態: $($t.State) / 最終実行: $last)" }
    }
    Fix = {
        param($ScanResult)
        Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null
        New-FixResult -Success $true -Message 'ドライブの最適化スケジュールを有効にしました'
    }
}

Register-Check @{
    Id = 'settings.time-sync'; Group = 'settings'
    Name = '時刻の自動同期'
    Description = '時計がずれると Web サイトの証明書エラーやサインイン失敗の原因になります'
    RequiresAdmin = $true; FixLabel = '有効にする'
    Scan = {
        $svc = Get-Service -Name W32Time -ErrorAction Stop
        $type = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name 'Type'
        $server = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name 'NtpServer'
        $items = @("サービス: $($svc.Status) / 開始の種類: $($svc.StartType)", "同期方式: $type", "NTP サーバー: $server")
        if ($type -eq 'NoSync' -or $svc.StartType -eq 'Disabled') {
            New-ScanResult -Status issue -Count 1 -Summary '時刻の自動同期が無効です' -Items $items
        } else {
            New-ScanResult -Status ok -Summary "自動同期は有効です ($type)" -Items $items
        }
    }
    Fix = {
        param($ScanResult)
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
        if ((Get-RegValue -Path $k -Name 'Type') -eq 'NoSync') {
            Set-RegValue -Path $k -Name 'Type' -Value 'NTP' -Type String
            if (-not (Get-RegValue -Path $k -Name 'NtpServer')) { Set-RegValue -Path $k -Name 'NtpServer' -Value 'time.windows.com,0x9' -Type String }
        }
        Set-Service -Name W32Time -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name W32Time -ErrorAction SilentlyContinue
        Invoke-Exe -File 'w32tm.exe' -Arguments '/config', '/update' -Quiet | Out-Null
        Invoke-Exe -File 'w32tm.exe' -Arguments '/resync', '/nowait' -Quiet | Out-Null
        New-FixResult -Success $true -Message '時刻の自動同期を有効にし、同期を開始しました'
    }
}

Register-Check @{
    Id = 'settings.pagefile'; Group = 'settings'
    Name = '仮想メモリ (ページファイル)'
    Description = 'ページファイルが無いとメモリ不足時にアプリが落ちやすくなります'
    RequiresAdmin = $true; Risk = 'medium'; FixLabel = '自動管理にする'
    Scan = {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $pf = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue)
        $items = @($pf | ForEach-Object { '{0}: 割り当て {1:N0} MB / 使用中 {2:N0} MB' -f $_.Name, $_.AllocatedBaseSize, $_.CurrentUsage })
        if ($cs.AutomaticManagedPagefile) { return (New-ScanResult -Status ok -Summary 'Windows が自動管理しています' -Items $items) }
        if ($pf.Count -eq 0) { return (New-ScanResult -Status issue -Count 1 -Summary 'ページファイルがありません' -Items $items) }
        New-ScanResult -Status info -Summary 'サイズが手動で設定されています (意図した設定ならそのままで構いません)' -Items $items
    }
    Fix = {
        param($ScanResult)
        Get-CimInstance -ClassName Win32_ComputerSystem | Set-CimInstance -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
        New-FixResult -Success $true -Message 'ページファイルを自動管理に戻しました (再起動後に反映)' -RebootRequired $true
    }
}
