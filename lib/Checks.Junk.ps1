# =====================================================================
#  蓄積した不要ファイル (junk)
# =====================================================================

New-JunkCheck -Id 'junk.user-temp' -Name 'ユーザーの一時ファイル' `
    -Description '%TEMP% に残った 1 日以上前の一時ファイル' -OlderThanDays 1 `
    -Paths { @($env:TEMP, (Join-EnvPath $env:LOCALAPPDATA 'Temp')) }

New-JunkCheck -Id 'junk.system-temp' -Name 'システムの一時ファイル' `
    -Description 'C:\Windows\Temp に残った 1 日以上前の一時ファイル' -OlderThanDays 1 -RequiresAdmin $true `
    -Paths { @((Join-EnvPath $env:SystemRoot 'Temp')) }

New-JunkCheck -Id 'junk.wu-cache' -Name 'Windows Update のダウンロードキャッシュ' `
    -Description '適用済み更新プログラムのダウンロード残骸 (SoftwareDistribution\Download)' -RequiresAdmin $true `
    -Paths { @((Join-EnvPath $env:SystemRoot 'SoftwareDistribution\Download')) } `
    -BeforeFix { foreach ($s in 'wuauserv', 'bits') { try { Stop-Service -Name $s -Force -ErrorAction Stop; Write-Log "  サービス停止: $s" } catch { } } } `
    -AfterFix  { foreach ($s in 'bits', 'wuauserv') { try { Start-Service -Name $s -ErrorAction Stop } catch { } } } `
    -Notes '削除中は Windows Update サービスを一時停止し、終了後に再開します。'

New-JunkCheck -Id 'junk.do-cache' -Name '配信の最適化キャッシュ' `
    -Description '他の PC と更新を共有するためのキャッシュ (再取得可能)' -RequiresAdmin $true `
    -Paths { @((Join-EnvPath $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')) } `
    -BeforeFix { if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { } } }

New-JunkCheck -Id 'junk.wer' -Name 'Windows エラー報告のアーカイブ' `
    -Description 'アプリのクラッシュ時に作られる報告ファイル (古いエラーとアラート)' `
    -Paths {
        @(
            (Join-EnvPath $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
            (Join-EnvPath $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'),
            (Join-EnvPath $env:LOCALAPPDATA 'Microsoft\Windows\WER\Temp'),
            (Join-EnvPath $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
            (Join-EnvPath $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
            (Join-EnvPath $env:ProgramData 'Microsoft\Windows\WER\Temp')
        )
    }

New-JunkCheck -Id 'junk.logs' -Name '古いシステムログ' `
    -Description '7 日以上前の CBS / DISM / Windows Update / セットアップのログ' -OlderThanDays 7 -RequiresAdmin $true `
    -Include @('*.log', '*.cab', '*.etl', '*.txt', '*.xml') -Exclude @('CBS.log', 'dism.log') `
    -Paths {
        @(
            (Join-EnvPath $env:SystemRoot 'Logs\CBS'),
            (Join-EnvPath $env:SystemRoot 'Logs\DISM'),
            (Join-EnvPath $env:SystemRoot 'Logs\WindowsUpdate'),
            (Join-EnvPath $env:SystemRoot 'Logs\MoSetup'),
            (Join-EnvPath $env:SystemRoot 'Logs\NetSetup'),
            (Join-EnvPath $env:SystemRoot 'Logs\SIH'),
            (Join-EnvPath $env:SystemRoot 'Panther\UnattendGC')
        )
    }

New-JunkCheck -Id 'junk.dumps' -Name 'クラッシュダンプ' `
    -Description '7 日以上前のブルースクリーン／アプリのメモリダンプ' -OlderThanDays 7 -RequiresAdmin $true `
    -Include @('*.dmp', '*.DMP', '*.hdmp', '*.mdmp') `
    -Paths {
        @(
            (Join-EnvPath $env:SystemRoot 'Minidump'),
            (Join-EnvPath $env:SystemRoot 'LiveKernelReports'),
            (Join-EnvPath $env:LOCALAPPDATA 'CrashDumps'),
            (Join-EnvPath $env:SystemRoot 'MEMORY.DMP')
        )
    } `
    -Notes 'C:\Windows\MEMORY.DMP と Minidump を対象にします。直近 7 日分は原因調査のため残します。'

New-JunkCheck -Id 'junk.shader-cache' -Name 'GPU シェーダーキャッシュ' `
    -Description 'DirectX / GPU ドライバーが作るシェーダーキャッシュ (自動で再生成される)' -OlderThanDays 1 `
    -Paths {
        @(
            (Join-EnvPath $env:LOCALAPPDATA 'D3DSCache'),
            (Join-EnvPath $env:LOCALAPPDATA 'NVIDIA\DXCache'),
            (Join-EnvPath $env:LOCALAPPDATA 'NVIDIA\GLCache'),
            (Join-EnvPath $env:LOCALAPPDATA 'AMD\DxCache'),
            (Join-EnvPath $env:LOCALAPPDATA 'AMD\GLCache'),
            (Join-EnvPath $env:LOCALAPPDATA 'Intel\ShaderCache')
        )
    }

New-JunkCheck -Id 'junk.thumbcache' -Name 'サムネイル／アイコンキャッシュ' `
    -Description 'エクスプローラーのサムネイル DB。壊れると画像が表示されない原因になる' -Risk 'medium' -NoRecurse `
    -Include @('thumbcache_*.db', 'iconcache_*.db') `
    -Paths { @((Join-EnvPath $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')) } `
    -BeforeFix { try { Stop-Process -Name explorer -Force -ErrorAction Stop; Start-Sleep -Seconds 2 } catch { } } `
    -AfterFix  { if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe } } `
    -Notes '削除のためにエクスプローラーを一度再起動します。開いているフォルダーウィンドウは閉じられます。画像のサムネイルが表示されない不具合があるときだけ実行してください。'

# ---- ごみ箱 ----------------------------------------------------------
# ごみ箱の実体は各ドライブの $Recycle.Bin\<SID>\ で、アカウントごとに分かれている。
# 管理者で実行すると全員分が見えるが、Clear-RecycleBin が空にするのは実行中の
# アカウントの分だけ。全員分を数えて自分の分だけ消すと、修復しても件数が減らず
# 警告が消えない。そこで「このツールが空にする分」だけを数える:
#   self   実行中のアカウントのごみ箱                         → 空にする
#   orphan システム ドライブにある、既に存在しないアカウントの分 → 空にする (誰も取り出せない)
#   other  ほかのアカウントの分                               → 触らない (件数だけ知らせる)
# システム ドライブ以外にある見知らぬ SID は、別の PC でつないで使っているドライブの
# 可能性があるので orphan とは見なさない。
function Global:Get-RecycleBinState {
    param(
        [string[]]$BinPaths,       # 各ドライブの $Recycle.Bin (省略時は全ドライブから探す)
        [string]$SystemBinPath,    # システム ドライブの $Recycle.Bin
        [string]$CurrentSid,
        [string[]]$KnownSids       # この PC にプロファイルがあるアカウントの SID
    )
    if (-not $PSBoundParameters.ContainsKey('BinPaths')) {
        $BinPaths = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Root -match '^[A-Z]:\\$' } |
            ForEach-Object { Join-Path $_.Root '$Recycle.Bin' } |
            Where-Object { Test-Path -LiteralPath $_ })
    }
    if (-not $PSBoundParameters.ContainsKey('SystemBinPath')) {
        $SystemBinPath = Join-Path ($env:SystemDrive + '\') '$Recycle.Bin'
    }
    if (-not $PSBoundParameters.ContainsKey('CurrentSid')) {
        $CurrentSid = ''
        try { $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    }
    if (-not $PSBoundParameters.ContainsKey('KnownSids')) {
        $KnownSids = @()
        try {
            $KnownSids = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop |
                ForEach-Object { $_.PSChildName })
        } catch { }
    }
    # アカウントの一覧を正しく読めたときだけ「存在しないアカウント」を判定する。
    # 読めなかった場合に全員を存在しない扱いにして消してしまわないため。
    $canJudgeOrphan = ($CurrentSid -and ($KnownSids -contains $CurrentSid))

    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($bin in @($BinPaths)) {
        if (-not $bin -or -not (Test-Path -LiteralPath $bin)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $bin -Directory -Force -ErrorAction SilentlyContinue)) {
            # Get-JunkFiles は配列を 1 個の値として返すので、@() で直接包むと入れ子になる
            $files = Get-JunkFiles -Paths @($dir.FullName) -Exclude @('desktop.ini')
            $files = @($files)
            if ($files.Count -eq 0) { continue }
            $sid = $dir.Name
            $owner = 'other'
            if ($CurrentSid -and $sid -eq $CurrentSid) { $owner = 'self' }
            elseif ($canJudgeOrphan -and ($KnownSids -notcontains $sid) -and ($bin -eq $SystemBinPath)) { $owner = 'orphan' }
            $bytes = [long]0
            foreach ($f in $files) { $bytes += [long]$f.Length }
            $groups.Add([pscustomobject]@{ Sid = $sid; Path = $dir.FullName; Owner = $owner; Files = $files; Bytes = $bytes })
        }
    }
    $fixable = @($groups | Where-Object { $_.Owner -ne 'other' })
    [pscustomobject]@{
        Groups       = $groups.ToArray()
        Fixable      = $fixable
        FixableFiles = @($fixable | ForEach-Object { $_.Files })
        Others       = @($groups | Where-Object { $_.Owner -eq 'other' })
    }
}

function Global:Get-RecycleBinOwnerName {
    # SID をアカウント名に直す。直せなければ (別の PC のアカウントなど) SID のまま返す
    param([string]$Sid)
    try {
        return (New-Object Security.Principal.SecurityIdentifier $Sid).Translate([Security.Principal.NTAccount]).Value
    } catch { return $Sid }
}

function Global:Clear-RecycleBinState {
    <#
      ごみ箱を空にして、実際に減った量を返す。
      「空にした」と報告するのは、点検し直して本当に無くなっていた場合だけ。
    #>
    param([hashtable]$StateArgs = @{}, [switch]$SkipShell)
    $before = Get-RecycleBinState @StateArgs
    $beforeBytes = [long](($before.Fixable | Measure-Object -Property Bytes -Sum).Sum)

    # 自分のごみ箱はまずシェル経由で空にする (デスクトップのごみ箱アイコンも更新される)。
    # 空のドライブがあるだけで失敗を返すことがあるため、ここでは失敗にしない。
    if (-not $SkipShell) {
        try { Clear-RecycleBin -Force -ErrorAction Stop }
        catch { Write-Log ("  Clear-RecycleBin: {0}" -f $_.Exception.Message) 'WARN' }
    }
    # シェルが残した分と、存在しないアカウントの分は直接消す
    $left = Get-RecycleBinState @StateArgs
    if ($left.FixableFiles.Count -gt 0) {
        Remove-JunkFiles -Files $left.FixableFiles -Roots @($left.Fixable | ForEach-Object { $_.Path }) | Out-Null
    }

    $after = Get-RecycleBinState @StateArgs
    $afterBytes = [long](($after.Fixable | Measure-Object -Property Bytes -Sum).Sum)
    $freed = [Math]::Max([long]0, $beforeBytes - $afterBytes)
    if ($after.FixableFiles.Count -gt 0) {
        return New-FixResult -Success $false -FreedBytes $freed -Message (
            'ごみ箱に {0:N0} ファイル ({1}) が残りました。使用中のファイルがある可能性があります' -f $after.FixableFiles.Count, (Format-Bytes $afterBytes))
    }
    New-FixResult -Success $true -FreedBytes $freed -Message ('ごみ箱を空にしました ({0} 解放)' -f (Format-Bytes $freed))
}

Register-Check @{
    Id = 'junk.recycle-bin'; Group = 'junk'
    Name = 'ごみ箱 (以前削除したファイル)'
    Description = 'ごみ箱に残っているファイルを完全に削除'
    FixLabel = '空にする'
    Scan = {
        $state = Get-RecycleBinState
        $r = New-JunkScanResult -Files $state.FixableFiles
        $items = @('ごみ箱の中身は Windows のごみ箱で確認できます')
        $orphans = @($state.Fixable | Where-Object { $_.Owner -eq 'orphan' })
        if ($orphans.Count -gt 0) {
            $n = ($orphans | ForEach-Object { $_.Files.Count } | Measure-Object -Sum).Sum
            $b = ($orphans | Measure-Object -Property Bytes -Sum).Sum
            $items += ('既に存在しないアカウントのごみ箱: {0:N0} ファイル / {1} (一緒に空にします)' -f $n, (Format-Bytes $b))
        }
        if ($state.Others.Count -gt 0) {
            $otherCount = 0; $otherBytes = [long]0
            foreach ($grp in $state.Others) {
                $otherCount += $grp.Files.Count; $otherBytes += $grp.Bytes
                $items += ('{0} のごみ箱: {1:N0} ファイル / {2} (このツールでは消しません。そのアカウントで空にしてください)' -f `
                    (Get-RecycleBinOwnerName $grp.Sid), $grp.Files.Count, (Format-Bytes $grp.Bytes))
            }
            # 自分では消せない分を「問題」に数えると、修復しても警告が消えなくなる
            $r.Summary += (' (ほかのアカウントの分 {0:N0} ファイル / {1} は対象外)' -f $otherCount, (Format-Bytes $otherBytes))
        }
        $r.Items = $items
        $r
    }
    Fix = {
        param($ScanResult)
        Clear-RecycleBinState
    }
}

# ---- 以前の Windows インストール ---------------------------------------
Register-Check @{
    Id = 'junk.windows-old'; Group = 'junk'
    Name = '以前の Windows インストール'
    Description = 'Windows.old や $WINDOWS.~BT などアップグレードの残骸 (削除すると前のバージョンに戻せなくなります)'
    Risk = 'medium'; RequiresAdmin = $true; LongFix = $true; FixLabel = '削除'
    FixConfirm = 'ディスク クリーンアップで削除します (数分〜十数分。削除すると前の Windows に戻せなくなります)'
    Notes = 'Windows 標準の「ディスク クリーンアップ」を使って安全に削除します。数分かかることがあります。'
    Scan = {
        $paths = @('Windows.old', '$WINDOWS.~BT', '$WINDOWS.~WS', '$GetCurrent', '$SysReset') |
            ForEach-Object { Join-EnvPath $env:SystemDrive $_ }
        $present = @($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
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
    RequiresAdmin = $true; Long = $true; Manual = $true; LongFix = $true; FixLabel = 'クリーンアップ'
    FixConfirm = 'DISM でコンポーネントストアを整理します (5〜20 分。開始すると途中で止められません)'
    Notes = 'DISM の AnalyzeComponentStore / StartComponentCleanup を使います。それぞれ数分〜十数分かかり、再起動待ちの状態では応答が返らないことがあるため、一括点検には含めず この行の「詳細検査」から実行します。先に再起動を済ませておくと確実です。'
    Scan = {
        $r = Invoke-Exe -File 'Dism.exe' -Arguments '/Online', '/Cleanup-Image', '/AnalyzeComponentStore', '/English' -Quiet -TimeoutSeconds 900
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
        $r = Invoke-Exe -File 'Dism.exe' -Arguments '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/English' -Quiet -TimeoutSeconds 3600
        if ($r.ExitCode -eq 0) {
            New-FixResult -Success $true -Message 'コンポーネントストアをクリーンアップしました'
        } else {
            New-FixResult -Success $false -Message ("DISM が失敗しました (終了コード {0}): {1}" -f $r.ExitCode, (($r.Lines | Select-Object -Last 3) -join ' / '))
        }
    }
}
