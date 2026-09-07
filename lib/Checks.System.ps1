# =====================================================================
#  システム・エラー (system)
# =====================================================================

Register-Check @{
    Id = 'system.component-health'; Group = 'system'
    Name = 'システムイメージの健全性 (DISM)'
    Description = 'Windows のコンポーネントストアに破損の記録がないか'
    RequiresAdmin = $true; FixLabel = '修復 (DISM)'
    Notes = '修復には Windows Update から正常なファイルを取得するためインターネット接続が必要で、10〜30 分かかることがあります。'
    Scan = {
        $r = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
        $state = [string]$r.ImageHealthState
        if ($state -eq 'Healthy') { New-ScanResult -Status ok -Summary '破損は記録されていません' }
        else { New-ScanResult -Status issue -Count 1 -Summary "破損が記録されています: $state" }
    }
    Fix = {
        param($ScanResult)
        Write-Log '  Repair-WindowsImage -RestoreHealth を実行中 (時間がかかります)…'
        $r = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
        if ([string]$r.ImageHealthState -eq 'Healthy') {
            New-FixResult -Success $true -Message 'システムイメージを修復しました。続けて「システムファイルの整合性」も実行することをお勧めします' -RebootRequired $r.RestartNeeded
        } else {
            New-FixResult -Success $false -Message "修復後も状態が $($r.ImageHealthState) です。C:\Windows\Logs\DISM\dism.log を確認してください"
        }
    }
}

Register-Check @{
    Id = 'system.sfc'; Group = 'system'
    Name = 'システムファイルの整合性 (SFC)'
    Description = '保護されたシステムファイルの改変・破損を検査して修復'
    RequiresAdmin = $true; Long = $true; FixLabel = '検査と修復 (sfc /scannow)'
    Notes = 'sfc /scannow は 5〜15 分かかります。'
    Scan = {
        $log = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
        if (-not (Test-Path -LiteralPath $log)) { return (New-ScanResult -Status recommend -Count 1 -Summary '実行履歴がありません。一度実行することをお勧めします') }
        $tail = Get-Content -LiteralPath $log -Tail 60000 -ErrorAction Stop
        $lastVerify = $tail | Where-Object { $_ -match '\[SR\] Verify complete' } | Select-Object -Last 1
        if (-not $lastVerify) { return (New-ScanResult -Status recommend -Count 1 -Summary '最近の実行履歴がありません。一度実行することをお勧めします') }
        $date = $null
        if ($lastVerify -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { $date = [datetime]$Matches[1] }
        $idx = [array]::LastIndexOf($tail, $lastVerify)
        $after = if ($idx -ge 0) { $tail[$idx..($tail.Count - 1)] } else { @() }
        $cannot = @($after | Where-Object { $_ -match '\[SR\] Cannot repair' })
        $dateText = if ($date) { $date.ToString('yyyy-MM-dd HH:mm') } else { '不明' }
        if ($cannot.Count -gt 0) {
            New-ScanResult -Status issue -Count $cannot.Count -Summary "前回の検査 ($dateText) で修復できないファイルがありました" -Items @($cannot | Select-Object -First 20)
        } elseif ($date -and $date -gt (Get-Date).AddDays(-30)) {
            New-ScanResult -Status ok -Summary "最終検査: $dateText (問題なし)"
        } else {
            New-ScanResult -Status recommend -Count 1 -Summary "最終検査: $dateText — 30 日以上経過しています"
        }
    }
    Fix = {
        param($ScanResult)
        Write-Log '  sfc /scannow を実行中 (5〜15 分)…'
        $r = Invoke-Exe -File 'sfc.exe' -Arguments '/scannow' -Unicode -Quiet
        $text = $r.Lines -join ' '
        foreach ($l in ($r.Lines | Select-Object -Last 4)) { Write-Log "  $l" }
        if ($text -match 'did not find any integrity violations|整合性違反を検出しませんでした') {
            New-FixResult -Success $true -Message 'システムファイルに問題は見つかりませんでした'
        } elseif ($text -match 'successfully repaired|正常に修復しました') {
            New-FixResult -Success $true -Message '破損したシステムファイルを修復しました' -RebootRequired $true
        } elseif ($text -match 'unable to fix|修復できませんでした') {
            New-FixResult -Success $false -Message '修復できないファイルがあります。先に「システムイメージの健全性」の修復 (DISM) を実行してから再試行してください'
        } elseif ($text -match 'could not perform|実行できませんでした') {
            New-FixResult -Success $false -Message 'SFC を実行できませんでした。再起動後に再試行してください'
        } else {
            New-FixResult -Success ($r.ExitCode -eq 0) -Message ('sfc の結果: ' + (($r.Lines | Select-Object -Last 2) -join ' / '))
        }
    }
}

Register-Check @{
    Id = 'system.disk-errors'; Group = 'system'
    Name = 'ディスクのファイルシステム エラー'
    Description = '各ドライブをオンラインで検査 (chkdsk /scan 相当)'
    RequiresAdmin = $true; Long = $true; FixLabel = '修復を予約'
    Notes = 'システムドライブの修復は次回の再起動時に実行されます。'
    Scan = {
        $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.FileSystemType -eq 'NTFS' -and $_.DriveType -eq 'Fixed' })
        $items = @(); $bad = @()
        foreach ($v in $vols) {
            $res = [string](Repair-Volume -DriveLetter $v.DriveLetter -Scan -ErrorAction Stop)
            $items += ('{0}: {1}' -f $v.DriveLetter, $res)
            if ($res -ne 'NoErrorsFound') { $bad += [string]$v.DriveLetter }
        }
        if ($bad.Count -gt 0) { New-ScanResult -Status issue -Count $bad.Count -Summary ('エラーが見つかりました: ' + ($bad -join ', ')) -Items $items -Data @{ Drives = $bad } }
        else { New-ScanResult -Status ok -Summary 'エラーは見つかりませんでした' -Items $items }
    }
    Fix = {
        param($ScanResult)
        $sys = $env:SystemDrive.TrimEnd(':')
        $msgs = @(); $reboot = $false
        foreach ($d in $ScanResult.Data.Drives) {
            if ($d -eq $sys) {
                Repair-Volume -DriveLetter $d -OfflineScanAndFix -ErrorAction Stop | Out-Null
                $msgs += "${d}: は次回再起動時に修復"; $reboot = $true
            } else {
                $res = [string](Repair-Volume -DriveLetter $d -SpotFix -ErrorAction Stop)
                $msgs += "${d}: $res"
            }
        }
        New-FixResult -Success $true -Message ($msgs -join ' / ') -RebootRequired $reboot
    }
}

Register-Check @{
    Id = 'system.smart'; Group = 'system'
    Name = 'ドライブの健康状態 (S.M.A.R.T.)'
    Description = 'ディスク自身が報告する寿命・エラー情報'
    RequiresAdmin = $true
    Notes = '異常があればまずバックアップを取り、交換を検討してください。ソフトでは直せません。'
    Scan = {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        $items = @(); $bad = 0; $warn = 0
        foreach ($d in $disks) {
            $rc = $null
            try { $rc = Get-StorageReliabilityCounter -PhysicalDisk $d -ErrorAction Stop } catch { }
            $extra = ''
            if ($rc) {
                $parts = @()
                if ($null -ne $rc.Wear -and $rc.Wear -gt 0) { $parts += "消耗 $($rc.Wear)%" }
                if ($null -ne $rc.Temperature -and $rc.Temperature -gt 0) { $parts += "温度 $($rc.Temperature)°C" }
                if ($rc.ReadErrorsUncorrected) { $parts += "訂正不能読み取りエラー $($rc.ReadErrorsUncorrected)" }
                if ($rc.PowerOnHours) { $parts += "通電 $($rc.PowerOnHours) 時間" }
                if ($parts.Count) { $extra = ' / ' + ($parts -join ', ') }
                if ($rc.Wear -ge 90 -or $rc.ReadErrorsUncorrected -gt 0) { $bad++ } elseif ($rc.Wear -ge 70) { $warn++ }
            }
            if ([string]$d.HealthStatus -ne 'Healthy') { $bad++ }
            $items += '{0} ({1}, {2}): {3}{4}' -f $d.FriendlyName, $d.MediaType, (Format-Bytes $d.Size), $d.HealthStatus, $extra
        }
        if ($bad -gt 0) { New-ScanResult -Status issue -Count $bad -Summary 'ドライブに異常があります。バックアップを取ってください' -Items $items }
        elseif ($warn -gt 0) { New-ScanResult -Status recommend -Count $warn -Summary 'SSD の消耗が進んでいます' -Items $items }
        else { New-ScanResult -Status ok -Summary "$($disks.Count) 台すべて正常" -Items $items }
    }
}

Register-Check @{
    Id = 'system.events'; Group = 'system'
    Name = '重大なシステムエラー (イベントログ)'
    Description = '直近 7 日間の予期しないシャットダウン・ディスクエラー・アプリのクラッシュ'
    ActionLabel = '信頼性モニターを開く'
    Notes = '件数が多い場合は信頼性モニターで発生日時と原因アプリを確認してください。'
    Scan = {
        $since = (Get-Date).AddDays(-7)
        $critical = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1; StartTime = $since } -ErrorAction SilentlyContinue)
        $disk = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = @('disk', 'Ntfs', 'volmgr', 'storahci', 'stornvme', 'iaStorA', 'iaStorAC'); Level = @(1, 2); StartTime = $since } -ErrorAction SilentlyContinue)
        $crash = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue)
        $items = @()
        foreach ($set in @(@{ N = '重大'; E = $critical }, @{ N = 'ディスク'; E = $disk })) {
            $set.E | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                $msg = if ($first.Message) { ($first.Message -split "`r?`n")[0] } else { '' }
                if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 90) + '…' }
                $items += '[{0}] {1} (ID {2}) × {3}: {4}' -f $set.N, $first.ProviderName, $first.Id, $_.Count, $msg
            }
        }
        $crash | ForEach-Object {
            $app = ''
            if ($_.Message -match '^[^:]*:\s*([^,]+),') { $app = $Matches[1].Trim() }
            $app
        } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
            $items += '[クラッシュ] {0} × {1}' -f $_.Name, $_.Count
        }
        $summary = '重大 {0} 件 / ディスク {1} 件 / アプリのクラッシュ {2} 件 (7 日間)' -f $critical.Count, $disk.Count, $crash.Count
        if ($critical.Count -gt 0 -or $disk.Count -gt 0) { New-ScanResult -Status issue -Count ($critical.Count + $disk.Count) -Summary $summary -Items $items }
        elseif ($crash.Count -gt 3) { New-ScanResult -Status info -Count $crash.Count -Summary $summary -Items $items }
        else { New-ScanResult -Status ok -Summary $summary -Items $items }
    }
    Action = { Start-Tool 'perfmon.exe' -Arguments '/rel' }
}
