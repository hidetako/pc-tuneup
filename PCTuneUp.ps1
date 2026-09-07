#Requires -Version 5.1
<#
.SYNOPSIS
    PC TuneUp - Windows 11 用の無料メンテナンスツール (GUI / CLI)
.DESCRIPTION
    引数なしで実行すると GUI が開きます (管理者権限が無ければ昇格を求めます)。
    CLI:
      -Scan [-Full]                 点検して結果を表示
      -Scan -Fix -Auto [-Full]      点検し、低リスクの問題を自動修復
      -Fix -Id junk.user-temp,...   指定した項目だけ修復
      -List                         項目一覧
      -Report [path]                点検結果を JSON に保存 (-Scan と併用)
      -InstallSchedule              毎週の自動メンテナンスをタスク スケジューラに登録
      -UninstallSchedule            上記を削除
#>
[CmdletBinding()]
param(
    [switch]$Scan,
    [switch]$Fix,
    [switch]$Full,
    [switch]$Auto,
    [string[]]$Id,
    [switch]$List,
    [string]$Report,
    [switch]$NoElevate,
    [switch]$Hidden,
    [switch]$InstallSchedule,
    [switch]$UninstallSchedule,
    [switch]$Version
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')
Import-Checks

$cliMode = $Scan -or $Fix -or $List -or $Report -or $InstallSchedule -or $UninstallSchedule -or $Version
if ($cliMode) {
    $Global:PCTuneUp.Console = $true
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}

function Get-HostExe {
    $p = (Get-Process -Id $PID).Path
    if ($p) { return $p }
    if ($PSVersionTable.PSEdition -eq 'Core') { return 'pwsh.exe' } else { return 'powershell.exe' }
}

function Show-Fatal {
    param([string]$Message)
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($Message, 'PC TuneUp', 'OK', 'Error') | Out-Null
    } catch { Write-Host $Message -ForegroundColor Red }
}

# ---- バージョン / 一覧 ---------------------------------------------------
if ($Version) { Write-Host "PC TuneUp $($Global:PCTuneUp.Version)"; return }

if ($List) {
    $Global:PCTuneUp.Checks.Values | ForEach-Object {
        [pscustomobject]@{
            Id = $_.Id; Category = $_.Category; Group = $_.Group; Name = $_.Name
            Fix = [bool]$_.Fix; Risk = $_.Risk; Admin = $_.RequiresAdmin; Long = $_.Long
        }
    } | Format-Table -AutoSize
    return
}

# ---- スケジュール登録 -----------------------------------------------------
$taskName = 'PC TuneUp 週次メンテナンス'
if ($UninstallSchedule) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "タスク '$taskName' を削除しました"
    } else { Write-Host "タスク '$taskName' は登録されていません" }
    return
}
if ($InstallSchedule) {
    if (-not (Test-IsAdmin)) { Write-Host '管理者として実行してください' -ForegroundColor Red; return }
    $exe = Get-HostExe
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Scan -Fix -Auto -NoElevate' -f $PSCommandPath
    $action = New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '10:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User $user -RunLevel Highest -Force | Out-Null
    Write-Host "タスク '$taskName' を登録しました (毎週土曜 10:00、低リスクの問題を自動修復)。ログ: $(Join-Path $Global:PCTuneUp.DataDir 'logs')"
    return
}

# ---- GUI --------------------------------------------------------------
if (-not $cliMode) {
    if ($Global:PCTuneUp.IsWindows -and -not (Test-IsAdmin) -and -not $NoElevate) {
        $exe = Get-HostExe
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath), '-Hidden')
        try {
            Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -WorkingDirectory $PSScriptRoot | Out-Null
            return
        } catch {
            Write-Host '管理者への昇格がキャンセルされました。管理者権限なしで続行します (一部の項目はスキップされます)。' -ForegroundColor Yellow
        }
    }
    try {
        . (Join-Path $PSScriptRoot 'gui\Gui.ps1')
        Start-Gui
    } catch {
        Show-Fatal ("起動に失敗しました:`n" + $_.Exception.Message + "`n`n" + $_.ScriptStackTrace)
    }
    return
}

# ---- CLI: スキャン / 修復 ----------------------------------------------
if (-not (Test-IsAdmin)) {
    Write-Host '管理者権限がありません。管理者権限が必要な項目はスキップされます。' -ForegroundColor Yellow
}

$results = @{}
$fixResults = @{}

if ($Fix -and $Id -and -not $Scan) {
    $ids = $Id
} else {
    $ids = @(Get-Checks -IncludeLong:$Full | ForEach-Object { $_.Id })
    if ($Id) { $ids = @($ids | Where-Object { $_ -in $Id }) + @($Id | Where-Object { $_ -notin $ids }) }
}

foreach ($cid in $ids) {
    try { $results[$cid] = Invoke-CheckScan -Id $cid } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
}

Write-Host ''
Write-Host '=== 点検結果 ===' -ForegroundColor Cyan
$rows = foreach ($c in $Global:PCTuneUp.Checks.Values) {
    if (-not $results.ContainsKey($c.Id)) { continue }
    $r = $results[$c.Id]
    [pscustomobject]@{ Status = $r.Status; Group = $Global:PCTuneUp.Groups[$c.Group].Name; Name = $c.Name; Summary = $r.Summary; Id = $c.Id }
}
$rows | Format-Table -Property Status, Group, Name, Summary -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$issues = @($rows | Where-Object { $_.Status -eq 'issue' })
$rec = @($rows | Where-Object { $_.Status -eq 'recommend' })
Write-Host ("問題 {0} 件 / 推奨 {1} 件" -f $issues.Count, $rec.Count) -ForegroundColor $(if ($issues.Count) { 'Yellow' } else { 'Green' })

if ($Fix) {
    if ($Id -and -not $Scan) {
        $targets = @($Id)
    } elseif ($Auto) {
        $targets = @($Global:PCTuneUp.Checks.Values | Where-Object {
            $_.Fix -and $_.Risk -eq 'low' -and $results.ContainsKey($_.Id) -and $results[$_.Id].Status -eq 'issue'
        } | ForEach-Object { $_.Id })
    } else {
        $targets = @($Global:PCTuneUp.Checks.Values | Where-Object {
            $_.Fix -and $results.ContainsKey($_.Id) -and $results[$_.Id].Status -in 'issue', 'recommend'
        } | ForEach-Object { $_.Id })
        if ($targets.Count) {
            Write-Host ''
            Write-Host '修復対象:' -ForegroundColor Cyan
            foreach ($t in $targets) { $c = Get-Check $t; Write-Host ("  [{0}] {1} ({2})" -f $c.Risk, $c.Name, $c.FixLabel) }
            $ans = Read-Host '続行しますか? (y/N)'
            if ($ans -notmatch '^[yY]') { $targets = @() }
        }
    }
    if ($targets.Count -eq 0) {
        Write-Host '修復する項目はありません。'
    } else {
        Write-Host ''
        Write-Host '=== 修復 ===' -ForegroundColor Cyan
        foreach ($t in $targets) {
            $prev = $null; if ($results.ContainsKey($t)) { $prev = $results[$t] }
            $fixResults[$t] = Invoke-CheckFix -Id $t -ScanResult $prev
            $results[$t] = Invoke-CheckScan -Id $t
        }
        $freed = ($fixResults.Values | Measure-Object -Property FreedBytes -Sum).Sum
        $ok = @($fixResults.Values | Where-Object { $_.Success }).Count
        Write-Host ("修復 完了: 成功 {0} / 失敗 {1} / {2} 解放" -f $ok, ($fixResults.Count - $ok), (Format-Bytes $freed)) -ForegroundColor Green
        if ($fixResults.Values | Where-Object { $_.RebootRequired }) { Write-Host '一部の修復は再起動後に反映されます。' -ForegroundColor Yellow }
    }
}

if ($PSBoundParameters.ContainsKey('Report') -or $Auto) {
    $path = Export-Report -Results $results -FixResults $fixResults -Path $Report
    Write-Host "レポート: $path"
}
