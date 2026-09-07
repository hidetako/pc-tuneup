#Requires -Version 5.1
# =====================================================================
#  PC TuneUp - コアライブラリ
#  チェック項目の登録・実行、ファイル削除、レジストリバックアップ、ログ。
#  このファイルを dot-source してから Import-Checks を呼ぶ。
# =====================================================================

$Global:PCTuneUp = @{
    Version        = '1.0.0'
    IsWindows      = ($env:OS -eq 'Windows_NT')
    LibRoot        = $PSScriptRoot
    Checks         = [ordered]@{}
    LogQueue       = $null       # GUI ワーカーからログを渡す ConcurrentQueue
    Console        = $false      # CLI 実行時は $true (Write-Host にも出す)
    JunkIssueBytes = 10MB        # これ以上の不要ファイルがあれば「問題」扱い
}

if ($Global:PCTuneUp.IsWindows) {
    $Global:PCTuneUp.DataDir = Join-Path $env:LOCALAPPDATA 'PCTuneUp'
} else {
    $Global:PCTuneUp.DataDir = Join-Path $HOME '.pctuneup'
}
foreach ($sub in 'logs', 'backup', 'reports') {
    $d = Join-Path $Global:PCTuneUp.DataDir $sub
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$Global:PCTuneUp.LogFile = Join-Path (Join-Path $Global:PCTuneUp.DataDir 'logs') ((Get-Date -Format 'yyyyMMdd') + '.log')

# ---------------------------------------------------------------------
#  カテゴリとグループ (表示順どおり)
# ---------------------------------------------------------------------
$Global:PCTuneUp.Categories = [ordered]@{
    tuneup   = @{ Name = 'PC の調整';               Glyph = [string][char]0xE770; Blurb = '不要ファイル・Windows の設定・システムエラー・レジストリを点検し、PC を軽く保ちます。' }
    internet = @{ Name = 'インターネット';           Glyph = [string][char]0xE701; Blurb = 'ブラウザーに溜まった不要データとネットワーク設定を点検します。' }
    security = @{ Name = 'マルウェアとセキュリティ'; Glyph = [string][char]0xE72E; Blurb = 'ウイルス対策・ファイアウォール・更新プログラム・システム保護の状態を点検します。' }
}

$Global:PCTuneUp.Groups = [ordered]@{
    junk      = @{ Category = 'tuneup';   Name = '蓄積した不要ファイル';         Description = '一時ファイル・キャッシュ・古いログを削除して空き容量を確保' }
    apps      = @{ Category = 'tuneup';   Name = '不要なアプリケーション';       Description = 'プリインストールや使っていないアプリを洗い出す' }
    settings  = @{ Category = 'tuneup';   Name = 'Windows の設定';               Description = 'パフォーマンスに関わる Windows の設定を点検' }
    system    = @{ Category = 'tuneup';   Name = 'システム・エラー';             Description = 'システムファイル・ディスク・イベントログの異常を点検' }
    registry  = @{ Category = 'tuneup';   Name = 'レジストリ・エラー';           Description = '存在しないファイルを指す登録情報を、バックアップを取ってから除去' }
    browser   = @{ Category = 'internet'; Name = 'ブラウザーの不要データ';       Description = 'ブラウザーのキャッシュを整理 (Cookie や履歴は消しません)' }
    network   = @{ Category = 'internet'; Name = 'ネットワーク設定';             Description = '接続の健全性と Wi-Fi・プロキシの設定を点検' }
    defender  = @{ Category = 'security'; Name = 'ウイルス対策とファイアウォール'; Description = 'Microsoft Defender とファイアウォールの状態' }
    update    = @{ Category = 'security'; Name = 'Windows Update';               Description = '未適用の更新プログラムと再起動待ちを確認' }
    hardening = @{ Category = 'security'; Name = 'システム保護';                 Description = 'UAC・SmartScreen・hosts ファイルの状態' }
}

# ---------------------------------------------------------------------
#  ログ
# ---------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $Global:PCTuneUp.LogFile -Value $line -Encoding UTF8 } catch { }
    if ($Global:PCTuneUp.LogQueue) { $Global:PCTuneUp.LogQueue.Enqueue($line) }
    if ($Global:PCTuneUp.Console) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
}

# ---------------------------------------------------------------------
#  チェック項目の登録
#
#  Register-Check @{
#      Id            = 'group.name'      必須。一意
#      Group         = 'junk'            必須。$Global:PCTuneUp.Groups のキー
#      Name          = '表示名'          必須
#      Description   = '説明'            必須
#      Scan          = { New-ScanResult ... }   必須
#      Fix           = { param($ScanResult) New-FixResult ... }  任意。一括修復の対象
#      FixLabel      = '修復'            任意
#      Action        = { ... }           任意。設定画面を開くなど手動操作
#      ActionLabel   = '開く'            任意
#      ActionConfirm = '確認メッセージ'  任意。指定すると実行前に確認
#      Risk          = 'low'|'medium'    任意 (medium は既定で未選択)
#      RequiresAdmin = $true             任意
#      Long          = $true             任意。時間のかかる検査 (詳細スキャン時のみ)
#      Notes         = '補足'            任意
#  }
# ---------------------------------------------------------------------
function Register-Check {
    param([Parameter(Mandatory)][hashtable]$Definition)
    $d = $Definition
    foreach ($k in 'Id', 'Group', 'Name', 'Description', 'Scan') {
        if (-not $d.ContainsKey($k) -or -not $d[$k]) { throw "Register-Check: '$k' がありません (Id=$($d['Id']))" }
    }
    if (-not $Global:PCTuneUp.Groups.Contains($d.Group)) { throw "Register-Check: 不明なグループ '$($d.Group)' (Id=$($d.Id))" }
    if ($Global:PCTuneUp.Checks.Contains($d.Id)) { throw "Register-Check: ID が重複しています '$($d.Id)'" }
    $risk = if ($d['Risk']) { [string]$d.Risk } else { 'low' }
    if ($risk -notin 'low', 'medium', 'high') { throw "Register-Check: Risk は low/medium/high (Id=$($d.Id))" }

    $check = [pscustomobject]@{
        Id            = [string]$d.Id
        Group         = [string]$d.Group
        Category      = [string]$Global:PCTuneUp.Groups[$d.Group].Category
        Name          = [string]$d.Name
        Description   = [string]$d.Description
        Scan          = [scriptblock]$d.Scan
        Fix           = $d['Fix']
        FixLabel      = $(if ($d['FixLabel']) { [string]$d.FixLabel } else { '修復' })
        Action        = $d['Action']
        ActionLabel   = $(if ($d['ActionLabel']) { [string]$d.ActionLabel } else { '開く' })
        ActionConfirm = [string]$d['ActionConfirm']
        Risk          = $risk
        RequiresAdmin = [bool]$d['RequiresAdmin']
        Long          = [bool]$d['Long']
        Notes         = [string]$d['Notes']
    }
    $Global:PCTuneUp.Checks[$check.Id] = $check
}

function Import-Checks {
    param([string]$Root = $Global:PCTuneUp.LibRoot)
    $Global:PCTuneUp.Checks = [ordered]@{}
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Filter 'Checks.*.ps1' | Sort-Object Name)) {
        . $f.FullName
    }
    # グループ順 → 登録順で並べ替え
    $ordered = [ordered]@{}
    foreach ($g in $Global:PCTuneUp.Groups.Keys) {
        foreach ($c in $Global:PCTuneUp.Checks.Values) { if ($c.Group -eq $g) { $ordered[$c.Id] = $c } }
    }
    $Global:PCTuneUp.Checks = $ordered
}

function Get-Check {
    param([Parameter(Mandatory)][string]$Id)
    if (-not $Global:PCTuneUp.Checks.Contains($Id)) { throw "不明なチェック ID: $Id" }
    $Global:PCTuneUp.Checks[$Id]
}

function Get-Checks {
    param([string]$Category, [string]$Group, [switch]$IncludeLong)
    foreach ($c in $Global:PCTuneUp.Checks.Values) {
        if ($Category -and $c.Category -ne $Category) { continue }
        if ($Group -and $c.Group -ne $Group) { continue }
        if ($c.Long -and -not $IncludeLong) { continue }
        $c
    }
}

# ---------------------------------------------------------------------
#  結果オブジェクト
#   Status: ok / issue / recommend / info / error / skipped / na
# ---------------------------------------------------------------------
function New-ScanResult {
    param(
        [ValidateSet('ok', 'issue', 'recommend', 'info', 'error', 'skipped', 'na')][string]$Status = 'ok',
        [long]$Count = 0,
        [long]$Bytes = 0,
        [string]$Summary = '',
        [string[]]$Items = @(),
        [hashtable]$Data = @{}
    )
    [pscustomobject]@{
        Status  = $Status
        Count   = $Count
        Bytes   = $Bytes
        Summary = $Summary
        Items   = @($Items | Where-Object { $_ -ne $null })
        Data    = $Data
        Time    = Get-Date
    }
}

function New-FixResult {
    param(
        [bool]$Success = $true,
        [string]$Message = '',
        [long]$FreedBytes = 0,
        [bool]$RebootRequired = $false
    )
    [pscustomobject]@{
        Success        = $Success
        Message        = $Message
        FreedBytes     = $FreedBytes
        RebootRequired = $RebootRequired
        Time           = Get-Date
    }
}

function Select-ResultObject {
    # スクリプトブロックの出力からステータス付き結果だけを取り出す
    param([object[]]$Output, [string]$Property)
    $r = $Output | Where-Object { $null -ne $_ -and $_.PSObject.Properties[$Property] } | Select-Object -Last 1
    return $r
}

function Invoke-CheckScan {
    param([Parameter(Mandatory)][string]$Id)
    $check = Get-Check $Id
    Write-Log "スキャン: $($check.Name)"
    if ($check.RequiresAdmin -and -not (Test-IsAdmin)) {
        $r = New-ScanResult -Status skipped -Summary '管理者権限が必要です'
    } else {
        try {
            $out = @(& $check.Scan)
            $r = Select-ResultObject -Output $out -Property 'Status'
            if (-not $r) { $r = New-ScanResult -Status error -Summary '検査結果を取得できませんでした' }
        } catch {
            $r = New-ScanResult -Status error -Summary ('エラー: ' + $_.Exception.Message)
            Write-Log "  $($check.Name): $($_.Exception.Message)" 'WARN'
        }
    }
    $r | Add-Member -NotePropertyName Id -NotePropertyValue $Id -Force
    $tag = switch ($r.Status) { 'issue' { 'WARN' } 'error' { 'ERROR' } 'ok' { 'OK' } default { 'INFO' } }
    Write-Log "  → [$($r.Status)] $($r.Summary)" $tag
    return $r
}

function Invoke-CheckFix {
    param([Parameter(Mandatory)][string]$Id, $ScanResult)
    $check = Get-Check $Id
    if (-not $check.Fix) { return (New-FixResult -Success $false -Message 'この項目に自動修復はありません') }
    if ($check.RequiresAdmin -and -not (Test-IsAdmin)) { return (New-FixResult -Success $false -Message '管理者権限が必要です') }
    Write-Log "修復: $($check.Name)"
    try {
        if (-not $ScanResult) { $ScanResult = Invoke-CheckScan -Id $Id }
        $out = @(& $check.Fix $ScanResult)
        $r = Select-ResultObject -Output $out -Property 'Success'
        if (-not $r) { $r = New-FixResult -Success $true -Message '完了' }
    } catch {
        $r = New-FixResult -Success $false -Message ('エラー: ' + $_.Exception.Message)
    }
    $r | Add-Member -NotePropertyName Id -NotePropertyValue $Id -Force
    Write-Log "  → $(if ($r.Success) { '成功' } else { '失敗' }): $($r.Message)" $(if ($r.Success) { 'OK' } else { 'ERROR' })
    return $r
}

function Invoke-CheckAction {
    param([Parameter(Mandatory)][string]$Id)
    $check = Get-Check $Id
    if (-not $check.Action) { return }
    Write-Log "操作: $($check.Name) ($($check.ActionLabel))"
    try { & $check.Action | Out-Null } catch { Write-Log "  失敗: $($_.Exception.Message)" 'ERROR' }
}

# ---------------------------------------------------------------------
#  レポート
# ---------------------------------------------------------------------
function Export-Report {
    param([Parameter(Mandatory)][hashtable]$Results, [hashtable]$FixResults = @{}, [string]$Path)
    if (-not $Path) {
        $Path = Join-Path (Join-Path $Global:PCTuneUp.DataDir 'reports') ('PCTuneUp-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    }
    $items = foreach ($c in $Global:PCTuneUp.Checks.Values) {
        if (-not $Results.ContainsKey($c.Id)) { continue }
        $r = $Results[$c.Id]
        $f = $FixResults[$c.Id]
        [ordered]@{
            Id = $c.Id; Category = $c.Category; Group = $c.Group; Name = $c.Name
            Status = $r.Status; Count = $r.Count; Bytes = $r.Bytes; Summary = $r.Summary; Items = $r.Items
            Fix = $(if ($f) { [ordered]@{ Success = $f.Success; Message = $f.Message; FreedBytes = $f.FreedBytes; RebootRequired = $f.RebootRequired } } else { $null })
        }
    }
    $report = [ordered]@{
        Tool = 'PC TuneUp'; Version = $Global:PCTuneUp.Version; Computer = $env:COMPUTERNAME; User = $env:USERNAME
        Generated = (Get-Date -Format 's'); IsAdmin = (Test-IsAdmin)
        Summary = [ordered]@{
            Issues    = @($items | Where-Object { $_.Status -eq 'issue' }).Count
            Recommend = @($items | Where-Object { $_.Status -eq 'recommend' }).Count
            Errors    = @($items | Where-Object { $_.Status -eq 'error' }).Count
            JunkBytes = ($items | Where-Object { $_.Group -in 'junk', 'browser' } | Measure-Object -Property Bytes -Sum).Sum
        }
        Checks = @($items)
    }
    $json = $report | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $true))
    Write-Log "レポートを保存しました: $Path"
    return $Path
}

# ---------------------------------------------------------------------
#  汎用ヘルパー
# ---------------------------------------------------------------------
function Test-IsAdmin {
    if (-not $Global:PCTuneUp.IsWindows) { return $true }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Test-NameMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($p -eq '*' -or $Name -like $p) { return $true } }
    return $false
}

function Test-IsRootedPath {
    param([string]$Path)
    return ($Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\' -or $Path -match '^/')
}

function Test-ProcessRunning {
    param([string[]]$Names)
    return (@(Get-Process -Name $Names -ErrorAction SilentlyContinue).Count -gt 0)
}

function Start-Tool {
    # 設定画面や外部ツールを開く (失敗しても例外にしない)
    param([Parameter(Mandatory)][string]$Target, [string[]]$Arguments)
    try {
        if ($Arguments) { Start-Process -FilePath $Target -ArgumentList $Arguments } else { Start-Process -FilePath $Target }
    } catch { Write-Log "起動できません: $Target ($($_.Exception.Message))" 'WARN' }
}

function Invoke-Exe {
    # ネイティブコマンドを実行し、出力行を返す (必要ならログにも流す)
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$Unicode,     # sfc.exe など UTF-16 で出力するコマンド用
        [switch]$Quiet
    )
    $prev = $null
    try { $prev = [Console]::OutputEncoding } catch { }
    try {
        if ($Unicode) { try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode } catch { } }
        $lines = @(& $File @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } finally {
        if ($prev) { try { [Console]::OutputEncoding = $prev } catch { } }
    }
    $clean = @($lines | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ -and $_ -notmatch '^\d+(\.\d+)?%' })
    if (-not $Quiet) { foreach ($l in $clean) { Write-Log ('  ' + $l) } }
    [pscustomobject]@{ ExitCode = $code; Lines = $clean }
}

# ---------------------------------------------------------------------
#  ファイル削除ヘルパー
# ---------------------------------------------------------------------
function Get-JunkFiles {
    <#
      指定パス配下のファイルを列挙する。
      -OlderThanDays N  : 更新日時・作成日時の両方が N 日より前のものだけ
      -Include / -Exclude : ファイル名のワイルドカード
    #>
    param(
        [string[]]$Paths,
        [int]$OlderThanDays = 0,
        [string[]]$Include = @('*'),
        [string[]]$Exclude = @(),
        [switch]$NoRecurse
    )
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $p = [Environment]::ExpandEnvironmentVariables($p)
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $gci = @{ LiteralPath = $p; Force = $true; File = $true; ErrorAction = 'SilentlyContinue' }
        if (-not $NoRecurse) { $gci.Recurse = $true }
        foreach ($f in (Get-ChildItem @gci)) {
            if ($seen.ContainsKey($f.FullName)) { continue }
            if ($OlderThanDays -gt 0 -and ($f.LastWriteTime -ge $cutoff -or $f.CreationTime -ge $cutoff)) { continue }
            if (-not (Test-NameMatch $f.Name $Include)) { continue }
            if ($Exclude.Count -gt 0 -and (Test-NameMatch $f.Name $Exclude)) { continue }
            $seen[$f.FullName] = $true
            $result.Add($f)
        }
    }
    return , $result.ToArray()
}

function Remove-EmptyDirectories {
    param([string]$Root)
    $Root = [Environment]::ExpandEnvironmentVariables($Root)
    if (-not (Test-Path -LiteralPath $Root)) { return 0 }
    $n = 0
    $dirs = Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $dirs) {
        try {
            $any = Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction Stop | Select-Object -First 1
            if (-not $any) { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop; $n++ }
        } catch { }
    }
    return $n
}

function Remove-JunkFiles {
    param([object[]]$Files, [string[]]$Roots = @(), [switch]$WhatIf)
    $freed = [long]0; $deleted = 0; $failed = 0
    foreach ($f in $Files) {
        try {
            if (-not $WhatIf) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
            $freed += $f.Length; $deleted++
        } catch { $failed++ }
    }
    if (-not $WhatIf) { foreach ($r in $Roots) { if ($r) { Remove-EmptyDirectories -Root $r | Out-Null } } }
    Write-Log ("  削除 {0:N0} 件 / スキップ {1:N0} 件 (使用中など) / {2} 解放" -f $deleted, $failed, (Format-Bytes $freed))
    [pscustomobject]@{ Deleted = $deleted; Failed = $failed; FreedBytes = $freed }
}

function New-JunkScanResult {
    param([object[]]$Files, [string]$Note = '')
    $Files = @($Files)
    $bytes = [long]0
    foreach ($f in $Files) { $bytes += [long]$f.Length }
    $status = if ($bytes -ge $Global:PCTuneUp.JunkIssueBytes) { 'issue' } elseif ($Files.Count -gt 0) { 'info' } else { 'ok' }
    $summary = if ($Files.Count -eq 0) { '不要ファイルはありません' } else { '{0:N0} ファイル / {1}' -f $Files.Count, (Format-Bytes $bytes) }
    if ($Note) { $summary += ' ' + $Note }
    $items = @($Files | Sort-Object Length -Descending | Select-Object -First 40 | ForEach-Object { '{0}  ({1})' -f $_.FullName, (Format-Bytes $_.Length) })
    New-ScanResult -Status $status -Count $Files.Count -Bytes $bytes -Summary $summary -Items $items
}

function New-JunkCheck {
    <#
      「パス配下の古いファイルを消す」型のチェックを一括定義する。
      -Paths は実行時に評価されるスクリプトブロック (パス配列を返す)。
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Paths,
        [string]$Group = 'junk',
        [int]$OlderThanDays = 0,
        [string[]]$Include = @('*'),
        [string[]]$Exclude = @(),
        [switch]$NoRecurse,
        [bool]$RequiresAdmin = $false,
        [string]$Risk = 'low',
        [scriptblock]$BeforeFix,
        [scriptblock]$AfterFix,
        [string]$Notes = ''
    )
    $scan = {
        $p = @(& $Paths)
        $files = Get-JunkFiles -Paths $p -OlderThanDays $OlderThanDays -Include $Include -Exclude $Exclude -NoRecurse:$NoRecurse
        New-JunkScanResult -Files $files
    }.GetNewClosure()

    $fix = {
        param($ScanResult)
        $p = @(& $Paths)
        if ($BeforeFix) { & $BeforeFix | Out-Null }
        try {
            $files = Get-JunkFiles -Paths $p -OlderThanDays $OlderThanDays -Include $Include -Exclude $Exclude -NoRecurse:$NoRecurse
            $r = Remove-JunkFiles -Files $files -Roots $(if ($NoRecurse) { @() } else { $p })
        } finally {
            if ($AfterFix) { & $AfterFix | Out-Null }
        }
        $msg = '{0:N0} ファイルを削除し {1} を解放しました' -f $r.Deleted, (Format-Bytes $r.FreedBytes)
        if ($r.Failed -gt 0) { $msg += (' ({0:N0} 件は使用中のためスキップ)' -f $r.Failed) }
        New-FixResult -Success $true -Message $msg -FreedBytes $r.FreedBytes
    }.GetNewClosure()

    Register-Check @{
        Id = $Id; Group = $Group; Name = $Name; Description = $Description
        Scan = $scan; Fix = $fix; FixLabel = '削除'
        Risk = $Risk; RequiresAdmin = $RequiresAdmin; Notes = $Notes
    }
}

# ---------------------------------------------------------------------
#  レジストリヘルパー
# ---------------------------------------------------------------------
function Get-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Get-RegValues {
    # キー内の値を (Name, Value) で列挙する。PowerShell が付加する PS* プロパティは除く
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $skip = 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider'
    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $props) { return @() }
    @($props.PSObject.Properties | Where-Object { $_.Name -notin $skip } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Value = $_.Value }
    })
}

function Set-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function ConvertTo-RegExePath {
    param([string]$PSPath)
    $p = $PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $p = $p -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU:\\', 'HKEY_CURRENT_USER\' `
             -replace '^HKCR:\\', 'HKEY_CLASSES_ROOT\' -replace '^HKU:\\', 'HKEY_USERS\'
    return $p
}

function Backup-RegistryKey {
    # 削除前に reg.exe でキーをエクスポートする。戻り値は .reg ファイルのパス
    param([Parameter(Mandatory)][string]$PSPath, [string]$Tag = 'key')
    if (-not $Global:PCTuneUp.IsWindows) { return $null }
    $regPath = ConvertTo-RegExePath $PSPath
    $safe = ($Tag -replace '[^\w\-\.]+', '_')
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    $dir = Join-Path $Global:PCTuneUp.DataDir 'backup'
    $file = Join-Path $dir ('{0}-{1}.reg' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $safe)
    $out = & reg.exe export $regPath $file /y 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) {
        throw "レジストリのバックアップに失敗しました: $regPath ($out)"
    }
    Write-Log "  バックアップ: $file"
    return $file
}

function Get-ExecutablePath {
    <#
      コマンドライン文字列から実行ファイルのパスを取り出す。
      判定できない場合 (PATH 上の名前だけ、など) は $null。
    #>
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $s = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    $exe = $null
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        $exe = if ($end -gt 1) { $s.Substring(1, $end - 1) } else { $s.Trim('"') }
    } else {
        $m = [regex]::Match($s, '^(.+?\.(exe|com|bat|cmd|msi|scr|dll|sys|vbs|js|ps1))(\s|,|$)', 'IgnoreCase')
        $exe = if ($m.Success) { $m.Groups[1].Value } else { ($s -split '\s+')[0] }
    }
    $exe = $exe.Trim()
    if (-not $exe) { return $null }
    # サービスの ImagePath 形式を正規化
    if ($exe -match '^\\\?\?\\') { $exe = $exe.Substring(4) }
    if ($exe -match '^\\SystemRoot\\(.*)$') { $exe = Join-Path $env:SystemRoot $Matches[1] }
    if ($exe -match '^system32\\' -or $exe -match '^SysWOW64\\') { $exe = Join-Path $env:SystemRoot $exe }
    if (-not (Test-IsRootedPath $exe)) {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
        if ($env:SystemRoot) {
            $sys = Join-Path (Join-Path $env:SystemRoot 'System32') $exe
            if (Test-Path -LiteralPath $sys) { return $sys }
        }
        return $null
    }
    return $exe
}

function Get-InstalledPrograms {
    # アンインストール情報 (プログラムと機能の一覧) を列挙する
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            [pscustomobject]@{
                KeyPath         = $k.PSPath
                KeyName         = $k.PSChildName
                Name            = [string]$p.DisplayName
                Publisher       = [string]$p.Publisher
                Version         = [string]$p.DisplayVersion
                InstallDate     = [string]$p.InstallDate
                InstallLocation = [string]$p.InstallLocation
                UninstallString = [string]$(if ($p.UninstallString) { $p.UninstallString } else { $p.QuietUninstallString })
                SystemComponent = ([int]$p.SystemComponent -eq 1)
                WindowsInstaller = ([int]$p.WindowsInstaller -eq 1)
                EstimatedSizeKB = [long]$p.EstimatedSize
            }
        }
    }
}
