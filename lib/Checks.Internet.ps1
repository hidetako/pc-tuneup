# =====================================================================
#  インターネット: ブラウザーの不要データ (browser) / ネットワーク設定 (network)
# =====================================================================

function Global:Get-BrowserCacheTargets {
    # ブラウザーごとのキャッシュフォルダー一覧。Cookie・履歴・パスワードには触れない
    $chromiumProfileDirs = @('Cache\Cache_Data', 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'ShaderCache')
    $chromiumRootDirs = @('GrShaderCache', 'ShaderCache', 'GraphiteDawnCache', 'Crashpad\reports')
    $browsers = @(
        @{ Name = 'Microsoft Edge'; Process = 'msedge';  Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data');            Kind = 'chromium' },
        @{ Name = 'Google Chrome';  Process = 'chrome';  Root = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data');             Kind = 'chromium' },
        @{ Name = 'Brave';          Process = 'brave';   Root = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'); Kind = 'chromium' },
        @{ Name = 'Vivaldi';        Process = 'vivaldi'; Root = (Join-Path $env:LOCALAPPDATA 'Vivaldi\User Data');                   Kind = 'chromium' },
        @{ Name = 'Mozilla Firefox'; Process = 'firefox'; Root = (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles');           Kind = 'firefox' }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.Root)) { continue }
        $paths = @()
        if ($b.Kind -eq 'chromium') {
            foreach ($d in $chromiumRootDirs) { $paths += Join-Path $b.Root $d }
            $profiles = Get-ChildItem -LiteralPath $b.Root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' -or $_.Name -eq 'System Profile' }
            foreach ($p in $profiles) { foreach ($d in $chromiumProfileDirs) { $paths += Join-Path $p.FullName $d } }
        } else {
            foreach ($p in (Get-ChildItem -LiteralPath $b.Root -Directory -ErrorAction SilentlyContinue)) {
                foreach ($d in 'cache2', 'startupCache', 'shader-cache') { $paths += Join-Path $p.FullName $d }
            }
        }
        [pscustomobject]@{ Name = $b.Name; Process = $b.Process; Paths = @($paths | Where-Object { Test-Path -LiteralPath $_ }) }
    }
}

Register-Check @{
    Id = 'browser.cache'; Group = 'browser'
    Name = 'ブラウザーのキャッシュ'
    Description = 'Edge / Chrome / Brave / Vivaldi / Firefox のキャッシュ (Cookie・履歴・パスワードは残します)'
    FixLabel = '削除'
    Notes = '起動中のブラウザーはスキップされます。閉じてから実行してください。'
    Scan = {
        $targets = @(Get-BrowserCacheTargets)
        if ($targets.Count -eq 0) { return (New-ScanResult -Status ok -Summary '対応ブラウザーが見つかりません') }
        $total = [long]0; $count = 0; $items = @()
        foreach ($t in $targets) {
            $files = Get-JunkFiles -Paths $t.Paths
            $bytes = [long]0; foreach ($f in $files) { $bytes += $f.Length }
            $total += $bytes; $count += $files.Count
            $running = if (Test-ProcessRunning $t.Process) { ' (起動中)' } else { '' }
            $items += '{0}: {1:N0} ファイル / {2}{3}' -f $t.Name, $files.Count, (Format-Bytes $bytes), $running
        }
        $status = if ($total -ge $Global:PCTuneUp.JunkIssueBytes) { 'issue' } elseif ($count -gt 0) { 'info' } else { 'ok' }
        New-ScanResult -Status $status -Count $count -Bytes $total -Summary ('{0:N0} ファイル / {1}' -f $count, (Format-Bytes $total)) -Items $items
    }
    Fix = {
        param($ScanResult)
        $freed = [long]0; $skipped = @(); $done = @()
        foreach ($t in (Get-BrowserCacheTargets)) {
            if (Test-ProcessRunning $t.Process) { $skipped += $t.Name; Write-Log "  $($t.Name) は起動中のためスキップ" 'WARN'; continue }
            $files = Get-JunkFiles -Paths $t.Paths
            $r = Remove-JunkFiles -Files $files -Roots $t.Paths
            $freed += $r.FreedBytes; $done += $t.Name
        }
        $msg = if ($done.Count) { '{0} のキャッシュを削除し {1} を解放しました' -f ($done -join ', '), (Format-Bytes $freed) } else { '削除できたブラウザーはありません' }
        if ($skipped.Count) { $msg += ' / 起動中のためスキップ: ' + ($skipped -join ', ') + ' (閉じてから再実行してください)' }
        New-FixResult -Success ($done.Count -gt 0 -or $skipped.Count -eq 0) -Message $msg -FreedBytes $freed
    }
}

New-JunkCheck -Id 'browser.inetcache' -Group 'browser' -Name 'Windows のインターネット一時ファイル' `
    -Description 'Windows 内蔵の Web コンポーネントや古いアプリが使うキャッシュ (INetCache)' -OlderThanDays 1 `
    -Exclude @('container.dat', 'desktop.ini') `
    -Paths { @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCookies\Low')) }

# ---- ネットワーク ------------------------------------------------------

Register-Check @{
    Id = 'network.connectivity'; Group = 'network'
    Name = '接続の健全性 (DNS / HTTPS)'
    Description = '名前解決と HTTPS 接続が正常に行えるか、応答時間も測定'
    RequiresAdmin = $true; Risk = 'medium'; FixLabel = 'ネットワークをリセット'
    Notes = '修復は DNS キャッシュのクリアと Winsock / TCP-IP のリセットを行います (再起動が必要)。VPN や特殊なネットワーク設定を使っている場合は実行しないでください。'
    Scan = {
        $hosts = 'www.microsoft.com', 'www.google.com'
        $items = @(); $dnsOk = 0; $tcpOk = 0; $slow = 0
        foreach ($h in $hosts) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $dns = '失敗'
            try { $null = Resolve-DnsName -Name $h -Type A -DnsOnly -ErrorAction Stop; $dnsMs = $sw.ElapsedMilliseconds; $dns = "$dnsMs ms"; $dnsOk++; if ($dnsMs -gt 500) { $slow++ } } catch { }
            $sw.Restart()
            $tcp = '失敗'
            try {
                $ok = Test-NetConnection -ComputerName $h -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
                if ($ok) { $tcp = "$($sw.ElapsedMilliseconds) ms"; $tcpOk++ }
            } catch { }
            $items += '{0}: DNS {1} / HTTPS {2}' -f $h, $dns, $tcp
        }
        $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gw) { $items += "既定のゲートウェイ: $($gw.NextHop)" }
        $dnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses
        if ($dnsServers) { $items += "DNS サーバー: $($dnsServers -join ', ')" }
        if ($dnsOk -eq 0) { New-ScanResult -Status issue -Count 1 -Summary '名前解決 (DNS) に失敗しています' -Items $items }
        elseif ($tcpOk -eq 0) { New-ScanResult -Status issue -Count 1 -Summary 'HTTPS 接続に失敗しています' -Items $items }
        elseif ($slow -gt 0) { New-ScanResult -Status recommend -Count 1 -Summary '名前解決が遅くなっています (500 ms 超)' -Items $items }
        else { New-ScanResult -Status ok -Summary '正常に接続できています' -Items $items }
    }
    Fix = {
        param($ScanResult)
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Invoke-Exe -File 'ipconfig.exe' -Arguments '/flushdns' -Quiet | Out-Null
        Invoke-Exe -File 'netsh.exe' -Arguments 'winsock', 'reset' -Quiet | Out-Null
        Invoke-Exe -File 'netsh.exe' -Arguments 'int', 'ip', 'reset' -Quiet | Out-Null
        New-FixResult -Success $true -Message 'DNS キャッシュをクリアし、Winsock と TCP/IP をリセットしました。再起動してください' -RebootRequired $true
    }
}

function Global:Get-WifiAdapterInfo {
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.PhysicalMediaType -match '802\.11|Wireless' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|WLAN'
    })
    foreach ($a in $adapters) {
        $key = Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue | Where-Object {
            (Get-RegValue -Path $_.PSPath -Name 'NetCfgInstanceId') -eq $a.InterfaceGuid
        } | Select-Object -First 1
        $pnp = if ($key) { Get-RegValue -Path $key.PSPath -Name 'PnPCapabilities' } else { $null }
        $pmEnabled = -not ($pnp -and (([int]$pnp) -band 8))
        [pscustomobject]@{ Adapter = $a; Key = $(if ($key) { $key.PSPath } else { $null }); PnPCapabilities = $pnp; PowerManagementEnabled = $pmEnabled }
    }
}

Register-Check @{
    Id = 'network.wifi-power'; Group = 'network'
    Name = 'Wi-Fi アダプターの省電力設定'
    Description = '省電力のために Wi-Fi を切る設定は、接続が不安定になる原因になりがちです'
    RequiresAdmin = $true; FixLabel = '省電力を無効にする'
    Notes = 'ノート PC では電池の持ちがわずかに短くなります。Wi-Fi が途切れる症状が無ければそのままでも構いません。'
    Scan = {
        $infos = @(Get-WifiAdapterInfo)
        if ($infos.Count -eq 0) { return (New-ScanResult -Status na -Summary 'Wi-Fi アダプターがありません') }
        $items = @(); $bad = @()
        foreach ($i in $infos) {
            $state = if ($i.PowerManagementEnabled) { '省電力で切断を許可 (既定)' } else { '省電力での切断を禁止' }
            $items += '{0}: {1}' -f $i.Adapter.InterfaceDescription, $state
            if ($i.PowerManagementEnabled) { $bad += $i }
        }
        $pc = Invoke-Exe -File 'powercfg.exe' -Arguments '/query', 'SCHEME_CURRENT', '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a' -Quiet
        $acLine = $pc.Lines | Where-Object { $_ -match 'AC' -and $_ -match '0x[0-9a-fA-F]+' } | Select-Object -First 1
        $acIdx = -1
        if ($acLine -and $acLine -match '0x([0-9a-fA-F]+)') { $acIdx = [Convert]::ToInt32($Matches[1], 16) }
        if ($acIdx -ge 0) { $items += '電源プラン (AC): ワイヤレス アダプターの省電力モード = ' + @('最大パフォーマンス', '低省電力', '中省電力', '最大省電力')[[math]::Min($acIdx, 3)] }
        if ($bad.Count -gt 0 -or $acIdx -gt 0) {
            New-ScanResult -Status recommend -Count ([math]::Max($bad.Count, 1)) -Summary 'Wi-Fi の省電力設定が有効です (接続が不安定なら無効化を推奨)' -Items $items -Data @{ Keys = @($bad | ForEach-Object { $_.Key } | Where-Object { $_ }); Names = @($bad | ForEach-Object { $_.Adapter.Name }); PnP = @($bad | ForEach-Object { [int]$_.PnPCapabilities }) }
        } else {
            New-ScanResult -Status ok -Summary '省電力による切断は無効になっています' -Items $items
        }
    }
    Fix = {
        param($ScanResult)
        $n = 0
        for ($i = 0; $i -lt $ScanResult.Data.Keys.Count; $i++) {
            $k = $ScanResult.Data.Keys[$i]
            Backup-RegistryKey -PSPath $k -Tag 'wifi-pnp' | Out-Null
            Set-RegValue -Path $k -Name 'PnPCapabilities' -Value 24
            $n++
        }
        Invoke-Exe -File 'powercfg.exe' -Arguments '/setacvalueindex', 'SCHEME_CURRENT', '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a', '0' -Quiet | Out-Null
        Invoke-Exe -File 'powercfg.exe' -Arguments '/setactive', 'SCHEME_CURRENT' -Quiet | Out-Null
        foreach ($name in $ScanResult.Data.Names) {
            try { Restart-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop; Write-Log "  アダプター再起動: $name" } catch { Write-Log "  アダプター再起動に失敗 ($name): 再起動後に反映されます" 'WARN' }
        }
        New-FixResult -Success $true -Message "Wi-Fi アダプター $n 台の省電力切断を無効にし、電源プランを最大パフォーマンスにしました"
    }
}

Register-Check @{
    Id = 'network.proxy'; Group = 'network'
    Name = 'プロキシ設定'
    Description = 'マルウェアや古いソフトが残したプロキシ設定は、接続不良の典型的な原因です'
    Risk = 'medium'; FixLabel = 'プロキシを解除'
    Notes = '会社のネットワークや VPN、セキュリティソフトが設定したプロキシは解除しないでください。'
    Scan = {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $enable = [int](Get-RegValue -Path $k -Name 'ProxyEnable')
        $server = [string](Get-RegValue -Path $k -Name 'ProxyServer')
        $pac = [string](Get-RegValue -Path $k -Name 'AutoConfigURL')
        $items = @()
        if ($enable -eq 1) { $items += "手動プロキシ: $server" }
        if ($pac) { $items += "自動構成スクリプト: $pac" }
        $wh = Invoke-Exe -File 'netsh.exe' -Arguments 'winhttp', 'show', 'proxy' -Quiet
        $whLine = $wh.Lines | Where-Object { $_ -match 'Proxy Server|プロキシ サーバー' } | Select-Object -First 1
        if ($whLine) { $items += "WinHTTP: $whLine" }
        if ($items.Count -eq 0) { return (New-ScanResult -Status ok -Summary 'プロキシは設定されていません') }
        New-ScanResult -Status info -Count $items.Count -Summary 'プロキシが設定されています (意図したものか確認してください)' -Items $items
    }
    Fix = {
        param($ScanResult)
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Backup-RegistryKey -PSPath $k -Tag 'internet-settings' | Out-Null
        Set-RegValue -Path $k -Name 'ProxyEnable' -Value 0
        Remove-ItemProperty -LiteralPath $k -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
        if (Test-IsAdmin) { Invoke-Exe -File 'netsh.exe' -Arguments 'winhttp', 'reset', 'proxy' -Quiet | Out-Null }
        New-FixResult -Success $true -Message 'プロキシ設定を解除しました'
    }
}
