# =====================================================================
#  蓄積した不要ファイル (junk)
# =====================================================================

New-JunkCheck -Id 'junk.user-temp' -Name 'ユーザーの一時ファイル' `
    -Description '%TEMP% に残った 1 日以上前の一時ファイル' -OlderThanDays 1 `
    -Paths { @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp')) }

New-JunkCheck -Id 'junk.system-temp' -Name 'システムの一時ファイル' `
    -Description 'C:\Windows\Temp に残った 1 日以上前の一時ファイル' -OlderThanDays 1 -RequiresAdmin $true `
    -Paths { @((Join-Path $env:SystemRoot 'Temp')) }

New-JunkCheck -Id 'junk.wu-cache' -Name 'Windows Update のダウンロードキャッシュ' `
    -Description '適用済み更新プログラムのダウンロード残骸 (SoftwareDistribution\Download)' -RequiresAdmin $true `
    -Paths { @((Join-Path $env:SystemRoot 'SoftwareDistribution\Download')) } `
    -BeforeFix { foreach ($s in 'wuauserv', 'bits') { try { Stop-Service -Name $s -Force -ErrorAction Stop; Write-Log "  サービス停止: $s" } catch { } } } `
    -AfterFix  { foreach ($s in 'bits', 'wuauserv') { try { Start-Service -Name $s -ErrorAction Stop } catch { } } } `
    -Notes '削除中は Windows Update サービスを一時停止し、終了後に再開します。'

New-JunkCheck -Id 'junk.do-cache' -Name '配信の最適化キャッシュ' `
    -Description '他の PC と更新を共有するためのキャッシュ (再取得可能)' -RequiresAdmin $true `
    -Paths { @((Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')) } `
    -BeforeFix { if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { } } }

New-JunkCheck -Id 'junk.wer' -Name 'Windows エラー報告のアーカイブ' `
    -Description 'アプリのクラッシュ時に作られる報告ファイル (古いエラーとアラート)' `
    -Paths {
        @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\Temp'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\WER\Temp')
        )
    }

New-JunkCheck -Id 'junk.logs' -Name '古いシステムログ' `
    -Description '7 日以上前の CBS / DISM / Windows Update / セットアップのログ' -OlderThanDays 7 -RequiresAdmin $true `
    -Include @('*.log', '*.cab', '*.etl', '*.txt', '*.xml') -Exclude @('CBS.log', 'dism.log') `
    -Paths {
        @(
            (Join-Path $env:SystemRoot 'Logs\CBS'),
            (Join-Path $env:SystemRoot 'Logs\DISM'),
            (Join-Path $env:SystemRoot 'Logs\WindowsUpdate'),
            (Join-Path $env:SystemRoot 'Logs\MoSetup'),
            (Join-Path $env:SystemRoot 'Logs\NetSetup'),
            (Join-Path $env:SystemRoot 'Logs\SIH'),
            (Join-Path $env:SystemRoot 'Panther\UnattendGC')
        )
    }

New-JunkCheck -Id 'junk.dumps' -Name 'クラッシュダンプ' `
    -Description '7 日以上前のブルースクリーン／アプリのメモリダンプ' -OlderThanDays 7 -RequiresAdmin $true `
    -Include @('*.dmp', '*.DMP', '*.hdmp', '*.mdmp') `
    -Paths {
        @(
            (Join-Path $env:SystemRoot 'Minidump'),
            (Join-Path $env:SystemRoot 'LiveKernelReports'),
            (Join-Path $env:LOCALAPPDATA 'CrashDumps'),
            (Join-Path $env:SystemRoot 'MEMORY.DMP')
        )
    } `
    -Notes 'C:\Windows\MEMORY.DMP と Minidump を対象にします。直近 7 日分は原因調査のため残します。'

New-JunkCheck -Id 'junk.shader-cache' -Name 'GPU シェーダーキャッシュ' `
    -Description 'DirectX / GPU ドライバーが作るシェーダーキャッシュ (自動で再生成される)' -OlderThanDays 1 `
    -Paths {
        @(
            (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
            (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
            (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
            (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
            (Join-Path $env:LOCALAPPDATA 'AMD\GLCache'),
            (Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache')
        )
    }

New-JunkCheck -Id 'junk.thumbcache' -Name 'サムネイル／アイコンキャッシュ' `
    -Description 'エクスプローラーのサムネイル DB。壊れると画像が表示されない原因になる' -Risk 'medium' -NoRecurse `
    -Include @('thumbcache_*.db', 'iconcache_*.db') `
    -Paths { @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')) } `
    -BeforeFix { try { Stop-Process -Name explorer -Force -ErrorAction Stop; Start-Sleep -Seconds 2 } catch { } } `
    -AfterFix  { if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe } } `
    -Notes '削除のためにエクスプローラーを一度再起動します。開いているフォルダーウィンドウは閉じられます。画像のサムネイルが表示されない不具合があるときだけ実行してください。'

# ---- ごみ箱 ----------------------------------------------------------
Register-Check @{
    Id = 'junk.recycle-bin'; Group = 'junk'
    Name = 'ごみ箱 (以前削除したファイル)'
    Description = 'ごみ箱に残っているファイルを完全に削除'
    FixLabel = '空にする'
    Scan = {
        $files = @()
        foreach ($drv in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' })) {
            $bin = Join-Path $drv.Root '$Recycle.Bin'
            if (Test-Path -LiteralPath $bin) {
                $files += Get-JunkFiles -Paths @($bin) -Exclude @('desktop.ini')
            }
        }
        $r = New-JunkScanResult -Files $files
        $r.Items = @('ごみ箱の中身は Windows のごみ箱で確認できます')
        $r
    }
    Fix = {
        param($ScanResult)
        Clear-RecycleBin -Force -ErrorAction Stop
        New-FixResult -Success $true -Message ('ごみ箱を空にしました ({0} 解放)' -f (Format-Bytes $ScanResult.Bytes)) -FreedBytes $ScanResult.Bytes
    }
}

# ---- 以前の Windows インストール ---------------------------------------
Register-Check @{
    Id = 'junk.windows-old'; Group = 'junk'
    Name = '以前の Windows インストール'
    Description = 'Windows.old や $WINDOWS.~BT などアップグレードの残骸 (削除すると前のバージョンに戻せなくなります)'
    Risk = 'medium'; RequiresAdmin = $true; FixLabel = '削除'
    Notes = 'Windows 標準の「ディスク クリーンアップ」を使って安全に削除します。数分かかることがあります。'
    Scan = {
        $paths = @('Windows.old', '$WINDOWS.~BT', '$WINDOWS.~WS', '$GetCurrent', '$SysReset') |
            ForEach-Object { Join-Path $env:SystemDrive $_ }
        $present = @($paths | Where-Object { Test-Path -LiteralPath $_ })
        if ($present.Count -eq 0) { return (New-ScanResult -Status ok -Summary '残骸はありません') }
        $files = Get-JunkFiles -Paths $present
        $r = New-JunkScanResult -Files $files
        $r.Items = @($present)
        $r.Status = 'issue'
        $r
    }
    Fix = {
        param($ScanResult)
        $handlers = 'Previous Installations', 'Temporary Setup Files', 'Setup Log Files', 'Windows Upgrade Log Files', 'Windows ESD installation files'
        $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        foreach ($h in $handlers) {
            $k = Join-Path $root $h
            if (Test-Path -LiteralPath $k) { Set-RegValue -Path $k -Name 'StateFlags0099' -Value 2 }
        }
        Write-Log '  cleanmgr.exe /sagerun:99 を実行中…'
        $p = Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:99' -PassThru -Wait
        foreach ($h in $handlers) {
            $k = Join-Path $root $h
            if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name 'StateFlags0099' -ErrorAction SilentlyContinue }
        }
        $left = @($ScanResult.Items | Where-Object { Test-Path -LiteralPath $_ })
        if ($left.Count -gt 0) {
            New-FixResult -Success $false -Message ('ディスク クリーンアップ後も残っています: ' + ($left -join ', ') + '。再起動後にもう一度お試しください')
        } else {
            New-FixResult -Success $true -Message ('削除しました ({0} 解放)' -f (Format-Bytes $ScanResult.Bytes)) -FreedBytes $ScanResult.Bytes
        }
    }
}

# ---- コンポーネントストア (WinSxS) ------------------------------------
Register-Check @{
    Id = 'junk.component-store'; Group = 'junk'
    Name = 'Windows Update のクリーンアップ (コンポーネントストア)'
    Description = '置き換え済みの古いシステムコンポーネントを整理 (WinSxS)'
    RequiresAdmin = $true; Long = $true; FixLabel = 'クリーンアップ'
    Notes = 'DISM の AnalyzeComponentStore / StartComponentCleanup を使います。それぞれ数分かかります。'
    Scan = {
        $r = Invoke-Exe -File 'Dism.exe' -Arguments '/Online', '/Cleanup-Image', '/AnalyzeComponentStore' -Quiet
        if ($r.ExitCode -ne 0) { throw "DISM が失敗しました (終了コード $($r.ExitCode))" }
        $recLine  = $r.Lines | Where-Object { $_ -match 'Recommended|推奨' } | Select-Object -Last 1
        $sizeLine = $r.Lines | Where-Object { $_ -match 'Actual Size|実際のサイズ' } | Select-Object -First 1
        $reclaim  = $r.Lines | Where-Object { $_ -match 'Reclaimable|再利用' } | Select-Object -First 1
        $recommended = ($recLine -match 'Yes|はい')
        $detail = @($sizeLine, $reclaim, $recLine) | Where-Object { $_ }
        if ($recommended) {
            New-ScanResult -Status issue -Count 1 -Summary 'クリーンアップが推奨されています' -Items $detail
        } else {
            New-ScanResult -Status ok -Summary 'クリーンアップは不要です' -Items $detail
        }
    }
    Fix = {
        param($ScanResult)
        Write-Log '  Dism /StartComponentCleanup を実行中 (数分かかります)…'
        $r = Invoke-Exe -File 'Dism.exe' -Arguments '/Online', '/Cleanup-Image', '/StartComponentCleanup' -Quiet
        if ($r.ExitCode -eq 0) {
            New-FixResult -Success $true -Message 'コンポーネントストアをクリーンアップしました'
        } else {
            New-FixResult -Success $false -Message ("DISM が失敗しました (終了コード {0}): {1}" -f $r.ExitCode, (($r.Lines | Select-Object -Last 3) -join ' / '))
        }
    }
}
