# =====================================================================
#  不要なアプリケーション (apps)
# =====================================================================

# メーカー製 PC に同梱されがちな宣伝／体験版／「最適化」系ソフトのパターン
$Global:PCTuneUp.PromoPatterns = @(
    @{ Pattern = 'Lenovo Smart Performance';                 Kind = '有料の最適化サービス (このアプリで代替可能)' },
    @{ Pattern = 'Lenovo Vantage';                           Kind = 'メーカー製ユーティリティ (BIOS/ドライバー更新には有用。Smart Performance の有料誘導は無視してよい)' },
    @{ Pattern = 'McAfee|マカフィー';                        Kind = 'セキュリティ体験版 (期限切れなら削除推奨。Windows Defender で代替可能)' },
    @{ Pattern = 'Norton|LifeLock|ノートン';                  Kind = 'セキュリティ体験版 (期限切れなら削除推奨)' },
    @{ Pattern = 'ウイルスバスター|Trend Micro';              Kind = 'セキュリティ体験版 (契約していなければ削除推奨)' },
    @{ Pattern = '^Avast|^AVG ';                             Kind = 'セキュリティソフト (意図して入れていなければ削除推奨)' },
    @{ Pattern = 'Driver Booster|Driver Updater|Driver Easy|DriverPack|Driver Support|Driver Reviver|Smart Driver'; Kind = 'ドライバー更新ソフト (不要。Windows Update とメーカーサイトで十分)' },
    @{ Pattern = 'Advanced SystemCare|IObit|PC Accelerate|PC Cleaner|MyCleanPC|OneSafe|Reimage|Restoro|Smart Defrag|PC Optimizer|System Mechanic|Glary|Wise Care|CleanMyPC|SpeedUpMyPC|PC HelpSoft|Auslogics|Fortect'; Kind = '「PC 高速化」系ソフト (不要。効果に乏しく有料誘導が多い)' },
    @{ Pattern = 'WildTangent|Candy Crush|Booking\.com|ExpressVPN Promotion|Dropbox Promotion|Amazon Music|Spotify Promotion'; Kind = '宣伝用プリインストール' },
    @{ Pattern = 'Web Companion|Search Protect|Ask Toolbar|Bing Bar|Hao123|Baidu|SearchProtect|Conduit|MyWay|Weather Nation'; Kind = '検索乗っ取り／広告系 (削除推奨)' }
)

# 多くの人が使わない Microsoft Store アプリ (再インストールは Store から可能)
$Global:PCTuneUp.StoreBloatPatterns = @(
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingFinance',
    'Microsoft.BingSports', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.People',
    'Microsoft.MixedReality.Portal', 'Microsoft.Microsoft3DViewer', 'Microsoft.SkypeApp', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.549981C3F5F10', 'Microsoft.WindowsMaps', 'Microsoft.PowerAutomateDesktop', 'MicrosoftCorporationII.MicrosoftFamily',
    'Clipchamp.Clipchamp', 'Microsoft.Todos', 'MicrosoftTeams', 'Microsoft.GamingApp',
    '*Disney*', '*Spotify*', '*TikTok*', '*Instagram*', '*Facebook*', '*Twitter*', '*CandyCrush*', '*Netflix*',
    '*PrimeVideo*', '*McAfee*', '*LinkedIn*', '*Hulu*', '*Duolingo*', '*Booking*', '*ESPN*', '*Roblox*', '*Minecraft*',
    '*king.com*', '*Bubble*', '*Farm*', '*Dolby*'
)

Register-Check @{
    Id = 'apps.promo'; Group = 'apps'
    Name = 'プリインストール／宣伝／「最適化」系ソフト'
    Description = 'メーカー同梱の体験版や、効果の乏しい有料 PC 高速化ソフトを検出'
    ActionLabel = 'アプリの設定を開く'
    Notes = '検出したものが本当に不要かは利用状況で判断してください。削除は Windows の「インストールされているアプリ」から行います。'
    Scan = {
        $found = @()
        foreach ($p in (Get-InstalledPrograms | Where-Object { $_.Name -and -not $_.SystemComponent })) {
            foreach ($pat in $Global:PCTuneUp.PromoPatterns) {
                if ($p.Name -match $pat.Pattern) {
                    $found += ('{0} ({1}) — {2}' -f $p.Name, $(if ($p.Publisher) { $p.Publisher } else { '発行元不明' }), $pat.Kind)
                    break
                }
            }
        }
        $found = @($found | Sort-Object -Unique)
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '該当するアプリはありません') }
        New-ScanResult -Status recommend -Count $found.Count -Summary ('{0} 件のアプリを確認してください' -f $found.Count) -Items $found
    }
    Action = { Start-Tool 'ms-settings:appsfeatures' }
}

Register-Check @{
    Id = 'apps.store-bloat'; Group = 'apps'
    Name = '使われにくい Microsoft Store アプリ'
    Description = 'ゲームやニュースなど、標準で入るが使われにくいストアアプリ (Store から再インストール可能)'
    Risk = 'medium'; FixLabel = '削除'
    ActionLabel = 'アプリの設定を開く'
    Notes = '現在のユーザーからのみ削除します。必要になったら Microsoft Store から再インストールできます。'
    Scan = {
        if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return (New-ScanResult -Status na -Summary 'この環境では確認できません') }
        $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable })
        $found = @()
        foreach ($pkg in $pkgs) {
            foreach ($pat in $Global:PCTuneUp.StoreBloatPatterns) {
                if ($pkg.Name -like $pat) { $found += $pkg; break }
            }
        }
        if ($found.Count -eq 0) { return (New-ScanResult -Status ok -Summary '該当するアプリはありません') }
        New-ScanResult -Status info -Count $found.Count `
            -Summary ('{0} 件のストアアプリが見つかりました (使っていなければ削除できます)' -f $found.Count) `
            -Items @($found | ForEach-Object { $_.Name }) `
            -Data @{ Names = @($found | ForEach-Object { $_.PackageFullName }) }
    }
    Fix = {
        param($ScanResult)
        $n = 0; $errors = @()
        foreach ($full in $ScanResult.Data.Names) {
            try { Remove-AppxPackage -Package $full -ErrorAction Stop; $n++; Write-Log "  削除: $full" }
            catch { $errors += $full }
        }
        $msg = "$n 件のストアアプリを削除しました"
        if ($errors.Count) { $msg += " ($($errors.Count) 件は削除できませんでした)" }
        New-FixResult -Success ($errors.Count -eq 0) -Message $msg
    }
    Action = { Start-Tool 'ms-settings:appsfeatures' }
}
