# =====================================================================
#  マルウェアとセキュリティ: defender / update / hardening
# =====================================================================

function Global:Get-ThirdPartySecurityProducts {
    param([ValidateSet('AntiVirusProduct', 'FirewallProduct')][string]$Class = 'AntiVirusProduct')
    @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName $Class -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' -and (([int]$_.productState) -band 0x1000) } |
        ForEach-Object { $_.displayName })
}

function Global:Get-DefenderStatus {
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) { return $null }
    try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
}

Register-Check @{
    Id = 'defender.realtime'; Group = 'defender'
    Name = 'リアルタイム保護'
    Description = 'Microsoft Defender のリアルタイム保護が動いているか'
    RequiresAdmin = $true; FixLabel = '有効にする'; ActionLabel = 'Windows セキュリティを開く'
    Scan = {
        $s = Get-DefenderStatus
        $third = Get-ThirdPartySecurityProducts -Class AntiVirusProduct
        if (-not $s) {
            if ($third.Count) { return (New-ScanResult -Status info -Summary ('他社製ウイルス対策が有効: ' + ($third -join ', ')) ) }
            return (New-ScanResult -Status error -Summary 'Defender の状態を取得できません')
        }
        $items = @("リアルタイム保護: $($s.RealTimeProtectionEnabled)", "ウイルス対策: $($s.AntivirusEnabled)", "改ざん防止: $($s.IsTamperProtected)", "クラウド保護 (MAPS): $($s.AMServiceEnabled)")
        if ($third.Count) { $items += '他社製: ' + ($third -join ', ') }
        if ($s.RealTimeProtectionEnabled) { New-ScanResult -Status ok -Summary 'リアルタイム保護は有効です' -Items $items }
        elseif ($third.Count) { New-ScanResult -Status info -Summary ('他社製ウイルス対策 (' + ($third -join ', ') + ') が有効なため Defender は待機中') -Items $items }
        else { New-ScanResult -Status issue -Count 1 -Summary 'リアルタイム保護が無効です' -Items $items }
    }
    Fix = {
        param($ScanResult)
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Start-Sleep -Seconds 2
        $s = Get-DefenderStatus
        if ($s -and $s.RealTimeProtectionEnabled) { New-FixResult -Success $true -Message 'リアルタイム保護を有効にしました' }
        else { New-FixResult -Success $false -Message '有効にできませんでした (改ざん防止や他社製ソフトによる制御の可能性)。Windows セキュリティから有効にしてください' }
    }
    Action = { Start-Tool 'windowsdefender://threat/' }
}

Register-Check @{
    Id = 'defender.signatures'; Group = 'defender'
    Name = 'ウイルス定義の更新'
    Description = '定義ファイルが 3 日以上古いと新しいマルウェアを検出できません'
    RequiresAdmin = $true; FixLabel = '今すぐ更新'
    Scan = {
        $s = Get-DefenderStatus
        if (-not $s -or -not $s.AntivirusEnabled) { return (New-ScanResult -Status na -Summary 'Defender が無効のため対象外') }
        $age = [int]$s.AntivirusSignatureAge
        $items = @("バージョン: $($s.AntivirusSignatureVersion)", "最終更新: $($s.AntivirusSignatureLastUpdated)")
        if ($age -le 3) { New-ScanResult -Status ok -Summary "定義は最新です ($age 日前に更新)" -Items $items }
        else { New-ScanResult -Status issue -Count 1 -Summary "定義が $age 日間更新されていません" -Items $items }
    }
    Fix = {
        param($ScanResult)
        Update-MpSignature -ErrorAction Stop
        $s = Get-DefenderStatus
        New-FixResult -Success $true -Message ("定義を更新しました (バージョン {0})" -f $s.AntivirusSignatureVersion)
    }
}

Register-Check @{
    Id = 'defender.quickscan'; Group = 'defender'
    Name = 'ウイルス スキャン'
    Description = '直近 7 日以内にクイック スキャンが実行されているか'
    RequiresAdmin = $true; Long = $true; FixLabel = 'クイック スキャン実行'
    Notes = 'クイック スキャンは 5〜15 分かかります。'
    Scan = {
        $s = Get-DefenderStatus
        if (-not $s -or -not $s.AntivirusEnabled) { return (New-ScanResult -Status na -Summary 'Defender が無効のため対象外') }
        $qs = [int64]$s.QuickScanAge; $fs = [int64]$s.FullScanAge
        $last = if ($s.QuickScanEndTime) { $s.QuickScanEndTime.ToString('yyyy-MM-dd HH:mm') } else { 'なし' }
        $items = @("最終クイック スキャン: $last", "最終フル スキャン: $(if ($s.FullScanEndTime) { $s.FullScanEndTime.ToString('yyyy-MM-dd HH:mm') } else { 'なし' })")
        if (($qs -le 7 -and $qs -ge 0) -or ($fs -le 7 -and $fs -ge 0)) { New-ScanResult -Status ok -Summary "最近スキャン済み ($last)" -Items $items }
        else { New-ScanResult -Status issue -Count 1 -Summary "7 日以上スキャンされていません (最終: $last)" -Items $items }
    }
    Fix = {
        param($ScanResult)
        Write-Log '  クイック スキャンを実行中…'
        Start-MpScan -ScanType QuickScan -ErrorAction Stop
        $s = Get-DefenderStatus
        $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-1) })
        if ($threats.Count) { New-FixResult -Success $false -Message "スキャン完了。$($threats.Count) 件の脅威を検出しました。Windows セキュリティで対処してください" }
        else { New-FixResult -Success $true -Message 'クイック スキャン完了。脅威は見つかりませんでした' }
    }
}

Register-Check @{
    Id = 'defender.pua'; Group = 'defender'
    Name = '望ましくないアプリのブロック (PUA 保護)'
    Description = '広告ソフトや抱き合わせインストーラーを Defender でブロックする設定'
    RequiresAdmin = $true; FixLabel = '有効にする'
    Scan = {
        if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return (New-ScanResult -Status na -Summary '対象外') }
        $s = Get-DefenderStatus
        if (-not $s -or -not $s.AntivirusEnabled) { return (New-ScanResult -Status na -Summary 'Defender が無効のため対象外') }
        $p = Get-MpPreference -ErrorAction Stop
        if ([int]$p.PUAProtection -eq 1) { New-ScanResult -Status ok -Summary '有効' }
        else { New-ScanResult -Status recommend -Count 1 -Summary '無効です。有効にすると抱き合わせソフトの侵入を防げます' }
    }
    Fix = {
        param($ScanResult)
        Set-MpPreference -PUAProtection Enabled -ErrorAction Stop
        New-FixResult -Success $true -Message 'PUA 保護を有効にしました'
    }
}

Register-Check @{
    Id = 'defender.firewall'; Group = 'defender'
    Name = 'ファイアウォール'
    Description = 'ドメイン／プライベート／パブリックの各プロファイルで有効か'
    RequiresAdmin = $true; FixLabel = '有効にする'
    Scan = {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        $off = @($profiles | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        $third = Get-ThirdPartySecurityProducts -Class FirewallProduct
        $items = @($profiles | ForEach-Object { '{0}: {1}' -f $_.Name, $(if ($_.Enabled) { '有効' } else { '無効' }) })
        if ($third.Count) { $items += '他社製: ' + ($third -join ', ') }
        if ($off.Count -eq 0) { New-ScanResult -Status ok -Summary 'すべてのプロファイルで有効' -Items $items }
        elseif ($third.Count) { New-ScanResult -Status info -Summary ('他社製ファイアウォール (' + ($third -join ', ') + ') が有効') -Items $items }
        else { New-ScanResult -Status issue -Count $off.Count -Summary ('無効なプロファイル: ' + ($off -join ', ')) -Items $items }
    }
    Fix = {
        param($ScanResult)
        Set-NetFirewallProfile -All -Enabled True -ErrorAction Stop
        New-FixResult -Success $true -Message 'すべてのプロファイルでファイアウォールを有効にしました'
    }
}

# ---- Windows Update -----------------------------------------------------

Register-Check @{
    Id = 'update.pending'; Group = 'update'
    Name = '未適用の更新プログラム'
    Description = 'Windows Update で利用可能になっているがまだ入っていない更新'
    RequiresAdmin = $true; Long = $true; Risk = 'medium'; FixLabel = 'ダウンロードして適用'
    ActionLabel = 'Windows Update を開く'
    Notes = '大型の機能更新 (バージョンアップ) は対象外です。適用後は再起動が必要になることがあります。'
    Scan = {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $updates = @()
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            $isUpgrade = $false
            for ($c = 0; $c -lt $u.Categories.Count; $c++) { if ($u.Categories.Item($c).Name -match 'Upgrades|アップグレード') { $isUpgrade = $true } }
            if ($isUpgrade) { continue }
            $updates += [pscustomobject]@{ Title = $u.Title; Size = [long]$u.MaxDownloadSize; Index = $i }
        }
        if ($updates.Count -eq 0) { return (New-ScanResult -Status ok -Summary '未適用の更新はありません') }
        $bytes = [long]0; foreach ($u in $updates) { $bytes += $u.Size }
        New-ScanResult -Status issue -Count $updates.Count -Bytes $bytes -Summary ('{0} 件の更新が未適用です ({1})' -f $updates.Count, (Format-Bytes $bytes)) `
            -Items @($updates | ForEach-Object { $_.Title })
    }
    Fix = {
        param($ScanResult)
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            $isUpgrade = $false
            for ($c = 0; $c -lt $u.Categories.Count; $c++) { if ($u.Categories.Item($c).Name -match 'Upgrades|アップグレード') { $isUpgrade = $true } }
            if ($isUpgrade) { continue }
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
            Write-Log "  対象: $($u.Title)"
        }
        if ($coll.Count -eq 0) { return (New-FixResult -Success $true -Message '適用する更新はありません') }
        Write-Log '  ダウンロード中…'
        $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $coll
        $dr = $downloader.Download()
        if ($dr.ResultCode -notin 2, 3) { return (New-FixResult -Success $false -Message "ダウンロードに失敗しました (ResultCode $($dr.ResultCode))") }
        Write-Log '  インストール中…'
        $installer = $session.CreateUpdateInstaller(); $installer.Updates = $coll
        $ir = $installer.Install()
        if ($ir.ResultCode -in 2, 3) {
            New-FixResult -Success $true -Message ("{0} 件の更新を適用しました{1}" -f $coll.Count, $(if ($ir.RebootRequired) { ' (再起動が必要)' } else { '' })) -RebootRequired ([bool]$ir.RebootRequired)
        } else {
            New-FixResult -Success $false -Message "インストールに失敗しました (ResultCode $($ir.ResultCode))。Windows Update の画面から再試行してください"
        }
    }
    Action = { Start-Tool 'ms-settings:windowsupdate' }
}

Register-Check @{
    Id = 'update.reboot'; Group = 'update'
    Name = '再起動待ちの更新'
    Description = '更新の適用が再起動待ちのままだと、次の更新が失敗することがあります'
    ActionLabel = '今すぐ再起動'
    ActionConfirm = '60 秒後に再起動します。作業中のファイルを保存してから続行してください。よろしいですか?'
    Scan = {
        $reasons = @()
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'コンポーネント サービス (CBS)' }
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
        $pfr = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
        if ($reasons.Count -gt 0) { New-ScanResult -Status issue -Count 1 -Summary ('再起動が必要です: ' + ($reasons -join ', ')) -Items $reasons }
        elseif ($pfr) { New-ScanResult -Status info -Summary '再起動時に置き換えられるファイルがあります (通常は問題ありません)' }
        else { New-ScanResult -Status ok -Summary '再起動待ちの更新はありません' }
    }
    Action = { Start-Tool 'shutdown.exe' -Arguments '/r', '/t', '60', '/c', 'PC TuneUp: reboot for pending updates' }
}

# ---- システム保護 -------------------------------------------------------

Register-Check @{
    Id = 'hardening.uac'; Group = 'hardening'
    Name = 'ユーザー アカウント制御 (UAC)'
    Description = 'UAC が無効だとマルウェアが黙って管理者権限を得られます'
    RequiresAdmin = $true; FixLabel = '有効にする'
    Scan = {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $lua = [int](Get-RegValue -Path $k -Name 'EnableLUA')
        $consent = Get-RegValue -Path $k -Name 'ConsentPromptBehaviorAdmin'
        $items = @("EnableLUA: $lua", "ConsentPromptBehaviorAdmin: $consent")
        if ($lua -ne 1) { New-ScanResult -Status issue -Count 1 -Summary 'UAC が無効です' -Items $items }
        elseif ($null -ne $consent -and [int]$consent -eq 0) { New-ScanResult -Status issue -Count 1 -Summary 'UAC の確認なしで昇格する設定になっています' -Items $items }
        else { New-ScanResult -Status ok -Summary 'UAC は有効です' -Items $items }
    }
    Fix = {
        param($ScanResult)
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        Backup-RegistryKey -PSPath $k -Tag 'uac' | Out-Null
        Set-RegValue -Path $k -Name 'EnableLUA' -Value 1
        Set-RegValue -Path $k -Name 'ConsentPromptBehaviorAdmin' -Value 5
        Set-RegValue -Path $k -Name 'PromptOnSecureDesktop' -Value 1
        New-FixResult -Success $true -Message 'UAC を既定の設定に戻しました (再起動後に反映)' -RebootRequired $true
    }
}

Register-Check @{
    Id = 'hardening.smartscreen'; Group = 'hardening'
    Name = 'SmartScreen'
    Description = '危険なダウンロードや実行ファイルを警告する機能'
    RequiresAdmin = $true; FixLabel = '有効にする'
    Scan = {
        $v = [string](Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'SmartScreenEnabled')
        if ($v -eq 'Off') { New-ScanResult -Status issue -Count 1 -Summary 'SmartScreen が無効です' }
        else { New-ScanResult -Status ok -Summary ('有効' + $(if ($v) { " ($v)" } else { '' })) }
    }
    Fix = {
        param($ScanResult)
        Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'SmartScreenEnabled' -Value 'Warn' -Type String
        New-FixResult -Success $true -Message 'SmartScreen を有効にしました'
    }
}

Register-Check @{
    Id = 'hardening.hosts'; Group = 'hardening'
    Name = 'hosts ファイルの改変'
    Description = 'hosts に見慣れないエントリがあると、偽サイトへ誘導されることがあります'
    ActionLabel = 'hosts を開く'
    Notes = '広告ブロックや開発用に自分で追加した行なら問題ありません。'
    Scan = {
        $path = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if (-not (Test-Path -LiteralPath $path)) { return (New-ScanResult -Status ok -Summary 'hosts ファイルはありません') }
        $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        $custom = @($lines | Where-Object { $_ -notmatch '^(127\.0\.0\.1|::1|0\.0\.0\.0)\s+(localhost|localhost\.localdomain|broadcasthost|ip6-\S+)\s*$' })
        if ($custom.Count -eq 0) { New-ScanResult -Status ok -Summary '追加エントリはありません' }
        else { New-ScanResult -Status info -Count $custom.Count -Summary "$($custom.Count) 行の追加エントリがあります (内容を確認してください)" -Items @($custom | Select-Object -First 40) }
    }
    Action = { Start-Tool 'notepad.exe' -Arguments (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') }
}
