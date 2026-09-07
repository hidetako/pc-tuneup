#Requires -Version 5.1
# PC TuneUp の自動テスト。Windows でも Linux/macOS の pwsh でも実行できる部分だけを検証する。
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Pass = 0; $script:Fail = 0

function Assert {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}

# ---- 1. 構文 ---------------------------------------------------------
Write-Host '[構文チェック]'
$files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch 'node_modules' })
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) "$($f.Name) を解析できる"
    foreach ($e in $errors) { Write-Host "       $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "$($f.Name) は UTF-8 BOM 付き (Windows PowerShell 5.1 で日本語が化けない)"
}
$xaml = Join-Path $root 'gui\MainWindow.xaml'
try { [xml](Get-Content -LiteralPath $xaml -Raw -Encoding UTF8) | Out-Null; Assert $true 'MainWindow.xaml は整形式 XML' } catch { Assert $false "MainWindow.xaml: $($_.Exception.Message)" }

# ---- 2. 読み込みと登録 -------------------------------------------------
Write-Host '[チェック項目の登録]'
. (Join-Path $root 'lib\Core.ps1')
Import-Checks
$checks = @($Global:PCTuneUp.Checks.Values)
Assert ($checks.Count -ge 35) "チェック項目が 35 件以上ある ($($checks.Count) 件)"
$ids = $checks | ForEach-Object { $_.Id }
Assert (($ids | Sort-Object -Unique).Count -eq $ids.Count) 'ID が一意'
$badGroup = @($checks | Where-Object { -not $Global:PCTuneUp.Groups.Contains($_.Group) })
Assert ($badGroup.Count -eq 0) 'すべてのグループが定義済み'
$badScan = @($checks | Where-Object { $_.Scan -isnot [scriptblock] })
Assert ($badScan.Count -eq 0) 'Scan はすべて scriptblock'
$badFix = @($checks | Where-Object { $_.Fix -and $_.Fix -isnot [scriptblock] })
Assert ($badFix.Count -eq 0) 'Fix は scriptblock か未定義'
$noAction = @($checks | Where-Object { -not $_.Fix -and -not $_.Action -and $_.Id -ne 'system.smart' })
Assert ($noAction.Count -eq 0) "system.smart 以外は Fix か Action を持つ ($($noAction.Id -join ', '))"
$idPrefix = @($checks | Where-Object { -not $_.Id.StartsWith($_.Group + '.') })
Assert ($idPrefix.Count -eq 0) 'ID はグループ名で始まる'
foreach ($g in $Global:PCTuneUp.Groups.Keys) {
    Assert ((@(Get-Checks -Group $g -IncludeLong)).Count -gt 0) "グループ '$g' に項目がある"
}
Assert ((@(Get-Checks)).Count -lt $checks.Count) 'Get-Checks は既定で Long を除外する'
Assert ((Get-Check 'junk.user-temp').FixLabel -eq '削除') 'New-JunkCheck の FixLabel'
foreach ($fn in 'Get-RunKeyPaths', 'Get-StartupItems', 'Get-BrowserCacheTargets', 'Get-DefenderStatus') {
    Assert ([bool](Get-Command $fn -ErrorAction SilentlyContinue)) "ヘルパー関数 $fn が Import-Checks 後も見える"
}

# ---- 3. ヘルパー -----------------------------------------------------
Write-Host '[ヘルパー関数]'
Assert ((Format-Bytes 0) -eq '0 B') 'Format-Bytes 0'
Assert ((Format-Bytes 1536) -eq '2 KB') 'Format-Bytes KB'
Assert ((Format-Bytes 1.5MB) -eq '1.5 MB') 'Format-Bytes MB'
Assert ((Format-Bytes 3GB) -eq '3.00 GB') 'Format-Bytes GB'
Assert ((Get-ExecutablePath '"C:\Program Files\Foo\foo.exe" /silent') -eq 'C:\Program Files\Foo\foo.exe') 'Get-ExecutablePath: 引用符付き'
Assert ((Get-ExecutablePath 'C:\Foo\bar.exe -x -y') -eq 'C:\Foo\bar.exe') 'Get-ExecutablePath: 引数付き'
Assert ((Get-ExecutablePath 'C:\Foo Bar\baz.exe /q') -eq 'C:\Foo Bar\baz.exe') 'Get-ExecutablePath: 引用符なしスペース入り'
Assert ((Get-ExecutablePath 'C:\Foo\bar.EXE') -eq 'C:\Foo\bar.EXE') 'Get-ExecutablePath: 引数なし'
Assert ((Get-ExecutablePath '\??\C:\Windows\drv\x.sys') -eq 'C:\Windows\drv\x.sys') 'Get-ExecutablePath: \??\ 形式'
Assert ($null -eq (Get-ExecutablePath 'definitely-not-a-command-xyz.exe /a')) 'Get-ExecutablePath: PATH に無い名前は $null'
Assert ($null -eq (Get-ExecutablePath '')) 'Get-ExecutablePath: 空文字は $null'
Assert ((ConvertTo-RegExePath 'HKLM:\SOFTWARE\Foo') -eq 'HKEY_LOCAL_MACHINE\SOFTWARE\Foo') 'ConvertTo-RegExePath HKLM'
Assert ((ConvertTo-RegExePath 'Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Software\Bar') -eq 'HKEY_CURRENT_USER\Software\Bar') 'ConvertTo-RegExePath provider path'
Assert ((Test-IsRootedPath 'C:\x') -and -not (Test-IsRootedPath 'foo.exe')) 'Test-IsRootedPath'
$sr = New-ScanResult -Status issue -Count 3 -Summary 's'
Assert ($sr.Status -eq 'issue' -and $sr.Count -eq 3 -and $sr.Items.Count -eq 0) 'New-ScanResult'
$sel = Select-ResultObject -Output @('stray text', $null, (New-ScanResult -Status ok -Summary 'a'), (New-ScanResult -Status issue -Summary 'b')) -Property Status
Assert ($sel.Summary -eq 'b') 'Select-ResultObject は最後の結果を返す'

# ---- 4. ファイル削除ロジック -------------------------------------------
Write-Host '[不要ファイルの列挙と削除]'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pctuneup-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'sub\deep') -Force | Out-Null
$old = Join-Path $tmp 'old.log'; $new = Join-Path $tmp 'new.log'; $keep = Join-Path $tmp 'keep.txt'; $deep = Join-Path $tmp 'sub\deep\x.log'
foreach ($p in $old, $new, $keep, $deep) { [System.IO.File]::WriteAllText($p, ('x' * 2048)) }
foreach ($p in $old, $keep, $deep) { (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddDays(-10); (Get-Item -LiteralPath $p).CreationTime = (Get-Date).AddDays(-10) }
$all = Get-JunkFiles -Paths @($tmp)
Assert ($all.Count -eq 4) "Get-JunkFiles: 全件 ($($all.Count))"
$oldOnly = Get-JunkFiles -Paths @($tmp) -OlderThanDays 3
Assert ($oldOnly.Count -eq 3) "Get-JunkFiles: -OlderThanDays ($($oldOnly.Count))"
$logs = Get-JunkFiles -Paths @($tmp) -OlderThanDays 3 -Include '*.log'
Assert ($logs.Count -eq 2) "Get-JunkFiles: -Include ($($logs.Count))"
$excl = Get-JunkFiles -Paths @($tmp) -Include '*.log' -Exclude 'new.log'
Assert ($excl.Count -eq 2) "Get-JunkFiles: -Exclude ($($excl.Count))"
$top = Get-JunkFiles -Paths @($tmp) -NoRecurse
Assert ($top.Count -eq 3) "Get-JunkFiles: -NoRecurse ($($top.Count))"
$dup = Get-JunkFiles -Paths @($tmp, $tmp)
Assert ($dup.Count -eq 4) 'Get-JunkFiles: 重複パスをまとめる'
$single = Get-JunkFiles -Paths @($old)
Assert ($single.Count -eq 1) 'Get-JunkFiles: ファイルパスを直接指定できる'
$none = Get-JunkFiles -Paths @((Join-Path $tmp 'missing'), '', $null)
Assert ($none.Count -eq 0) 'Get-JunkFiles: 存在しないパスは無視'
$r = New-JunkScanResult -Files $logs
Assert ($r.Status -eq 'info' -and $r.Count -eq 2 -and $r.Bytes -eq 4096) 'New-JunkScanResult: 少量は info'
$Global:PCTuneUp.JunkIssueBytes = 4096
$r = New-JunkScanResult -Files $logs
Assert ($r.Status -eq 'issue') 'New-JunkScanResult: しきい値以上は issue'
$Global:PCTuneUp.JunkIssueBytes = 10MB
$del = Remove-JunkFiles -Files $logs -Roots @($tmp)
Assert ($del.Deleted -eq 2 -and $del.FreedBytes -eq 4096) 'Remove-JunkFiles: 削除数と解放量'
Assert (-not (Test-Path -LiteralPath $deep) -and (Test-Path -LiteralPath $keep) -and (Test-Path -LiteralPath $new)) 'Remove-JunkFiles: 対象だけ削除'
Assert (-not (Test-Path -LiteralPath (Join-Path $tmp 'sub'))) 'Remove-JunkFiles: 空になったフォルダーを削除'
Assert (Test-Path -LiteralPath $tmp) 'Remove-JunkFiles: ルート自体は残す'

# ---- 5. New-JunkCheck の closure ------------------------------------
Write-Host '[New-JunkCheck / Invoke-CheckScan / Invoke-CheckFix]'
$testDir = Join-Path $tmp 'closure'
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
1..3 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $testDir "f$_.tmp"), ('y' * 1000)) }
$before = 0; $after = 0
$Global:PCTuneUp.TestDir = $testDir
New-JunkCheck -Id 'junk.__test' -Name 'テスト' -Description 'テスト用' -Paths { @($Global:PCTuneUp.TestDir) } -Include '*.tmp' `
    -BeforeFix { $Global:PCTuneUp.TestBefore = 1 } -AfterFix { $Global:PCTuneUp.TestAfter = 1 }
$sr = Invoke-CheckScan -Id 'junk.__test'
Assert ($sr.Id -eq 'junk.__test' -and $sr.Count -eq 3 -and $sr.Bytes -eq 3000 -and $sr.Status -eq 'info') 'closure: Scan が正しいパスを見る'
$fr = Invoke-CheckFix -Id 'junk.__test' -ScanResult $sr
Assert ($fr.Success -and $fr.FreedBytes -eq 3000) 'closure: Fix が削除する'
Assert ($Global:PCTuneUp.TestBefore -eq 1 -and $Global:PCTuneUp.TestAfter -eq 1) 'closure: BeforeFix / AfterFix が呼ばれる'
Assert ((@(Get-ChildItem -LiteralPath $testDir -File)).Count -eq 0) 'closure: ファイルが消えている'
Register-Check @{ Id = 'system.__err'; Group = 'system'; Name = 'e'; Description = 'e'; Scan = { throw 'boom' } }
$er = Invoke-CheckScan -Id 'system.__err'
Assert ($er.Status -eq 'error' -and $er.Summary -match 'boom') 'Invoke-CheckScan は例外を error 結果にする'
Register-Check @{ Id = 'system.__nofix'; Group = 'system'; Name = 'n'; Description = 'n'; Scan = { New-ScanResult -Status ok } }
$nf = Invoke-CheckFix -Id 'system.__nofix'
Assert (-not $nf.Success) 'Fix の無い項目の Invoke-CheckFix は失敗を返す'
try { Register-Check @{ Id = 'junk.__test'; Group = 'junk'; Name = 'd'; Description = 'd'; Scan = { } }; Assert $false 'ID 重複は例外' } catch { Assert $true 'ID 重複は例外' }
try { Register-Check @{ Id = 'x.y'; Group = 'nope'; Name = 'd'; Description = 'd'; Scan = { } }; Assert $false '不明グループは例外' } catch { Assert $true '不明グループは例外' }

# ---- 6. レポート ------------------------------------------------------
Write-Host '[レポート]'
$results = @{ 'junk.__test' = $sr; 'system.__err' = $er }
$reportPath = Join-Path $tmp 'report.json'
$p = Export-Report -Results $results -FixResults @{ 'junk.__test' = $fr } -Path $reportPath
$json = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
Assert ($json.Tool -eq 'PC TuneUp' -and $json.Checks.Count -eq 2) 'Export-Report: JSON に 2 件'
Assert ($json.Summary.Errors -eq 1) 'Export-Report: エラー件数'
Assert (($json.Checks | Where-Object { $_.Id -eq 'junk.__test' }).Fix.Success -eq $true) 'Export-Report: 修復結果を含む'

# ---- 7. GUI ワーカースクリプトの構文 ----------------------------------
Write-Host '[GUI]'
$guiText = Get-Content -LiteralPath (Join-Path $root 'gui\Gui.ps1') -Raw -Encoding UTF8
$m = [regex]::Match($guiText, "WorkerScript = @'\r?\n(.*?)\r?\n'@", 'Singleline')
Assert $m.Success 'WorkerScript が定義されている'
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseInput($m.Groups[1].Value, [ref]$tokens, [ref]$errors) | Out-Null
Assert ($errors.Count -eq 0) 'WorkerScript を解析できる'
$xamlDoc = [xml](Get-Content -LiteralPath $xaml -Raw -Encoding UTF8)
$names = @($xamlDoc.SelectNodes('//*[@Name]') | ForEach-Object { $_.Name })
foreach ($n in 'ScanButton', 'FixButton', 'CancelButton', 'GroupsPanel', 'LogBox', 'StatusText', 'FullScanBox', 'CatTuneupBadgeText', 'CatSecurityGlyph') {
    Assert ($names -contains $n) "XAML に $n がある"
}
foreach ($n in $names) {
    $used = ($guiText -match [regex]::Escape("`$ui.$n") -or $guiText -match [regex]::Escape(".UI.$n") -or $guiText -match [regex]::Escape("'$n'") -or $n -match '^Cat')
    Assert $used "XAML の $n が Gui.ps1 で使われている"
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("合格 {0} / 不合格 {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
