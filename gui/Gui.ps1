# =====================================================================
#  PC TuneUp - WPF GUI
#  Start-Gui を呼ぶ前に Core.ps1 の dot-source と Import-Checks が必要。
# =====================================================================

$Global:PCTuneUpGui = @{}

$Global:PCTuneUpGui.Colors = @{
    issue     = '#D13438'; recommend = '#C47F00'; info = '#0F6CBD'; ok = '#107C10'
    error     = '#D13438'; skipped   = '#9CA3AF'; na   = '#9CA3AF'; none = '#9CA3AF'
    muted     = '#6B7280'; text      = '#1F2937'; border = '#E5E7EB'; accent = '#0F6CBD'; accentLight = '#EBF3FC'
}

# ワーカー ランスペースで実行するスクリプト (GUI スレッドをブロックしない)
$Global:PCTuneUpGui.WorkerScript = @'
param($LibRoot, $LogQueue, $ResultQueue, $Mode, $Ids, $ScanResults)
. (Join-Path $LibRoot 'Core.ps1')
Import-Checks
$Global:PCTuneUp.LogQueue = $LogQueue
foreach ($id in $Ids) {
    try {
        if ($Mode -eq 'fix') {
            $prev = $null
            if ($ScanResults -and $ScanResults.ContainsKey($id)) { $prev = $ScanResults[$id] }
            $fr = Invoke-CheckFix -Id $id -ScanResult $prev
            $ResultQueue.Enqueue([pscustomobject]@{ Kind = 'fix'; Id = $id; Result = $fr })
        } elseif ($Mode -eq 'action') {
            $ar = Invoke-CheckAction -Id $id
            $ResultQueue.Enqueue([pscustomobject]@{ Kind = 'fix'; Id = $id; Result = $ar })
        }
        $sr = Invoke-CheckScan -Id $id
        $ResultQueue.Enqueue([pscustomobject]@{ Kind = 'scan'; Id = $id; Result = $sr })
    } catch {
        Write-Log ("{0}: {1}" -f $id, $_.Exception.Message) 'ERROR'
        $ResultQueue.Enqueue([pscustomobject]@{ Kind = 'scan'; Id = $id; Result = (New-ScanResult -Status error -Summary ('エラー: ' + $_.Exception.Message)) })
    }
}
$ResultQueue.Enqueue([pscustomobject]@{ Kind = 'done' })
'@

function Get-GuiStyle {
    # XAML で定義したスタイルを名前で返す (起動時にキャッシュ済み。無ければウィンドウから検索)
    param([Parameter(Mandatory)][string]$Name)
    $G = $Global:PCTuneUpGui
    if ($G.Styles -and $G.Styles.ContainsKey($Name)) { return $G.Styles[$Name] }
    $w = $Global:PCTuneUpWindow
    if (-not $w) { throw "GUI ウィンドウが初期化されていません (スタイル '$Name' を解決できません)" }
    $style = $w.FindResource($Name)
    if (-not $G.Styles) { $G.Styles = @{} }
    $G.Styles[$Name] = $style
    return $style
}

function New-Brush {
    # #RRGGBB / #AARRGGBB を自前で解釈する。ColorConverter は値が壊れていると
    # 「トークンが無効です」で例外を投げるため、ここで検証して既定色に落とす。
    param([string]$Hex)
    $s = ([string]$Hex).Trim()
    if (-not ($s -match '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$')) {
        Write-Log "色の指定が不正です: '$Hex' → 既定色を使います" 'WARN'
        $s = '#1F2937'
    }
    $h = $s.Substring(1)
    if ($h.Length -eq 6) { $h = 'FF' + $h }
    $bytes = for ($i = 0; $i -lt 8; $i += 2) { [Convert]::ToByte($h.Substring($i, 2), 16) }
    $color = [System.Windows.Media.Color]::FromArgb($bytes[0], $bytes[1], $bytes[2], $bytes[3])
    $brush = New-Object System.Windows.Media.SolidColorBrush $color
    $brush.Freeze()
    return $brush
}

function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Weight = 'Normal', [string]$Color = '#1F2937', [switch]$NoWrap, [string]$Style = 'Normal')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.FontSize = $Size
    $tb.FontWeight = [System.Windows.FontWeight]::FromOpenTypeWeight($(if ($Weight -eq 'Bold') { 700 } elseif ($Weight -eq 'SemiBold') { 600 } else { 400 }))
    $tb.Foreground = New-Brush $Color
    $tb.TextWrapping = $(if ($NoWrap) { 'NoWrap' } else { 'Wrap' })
    if ($Style -eq 'Italic') { $tb.FontStyle = [System.Windows.FontStyles]::Italic }
    return $tb
}

function Get-StatusText {
    param($Check, $Result)
    if (-not $Result) {
        if ($Check.Long) { return @{ Text = '詳細検査で確認'; Color = $Global:PCTuneUpGui.Colors.none } }
        return @{ Text = '未点検'; Color = $Global:PCTuneUpGui.Colors.none }
    }
    $c = $Global:PCTuneUpGui.Colors
    switch ($Result.Status) {
        'issue'     {
            $t = if ($Result.Bytes -gt 0) { '● ' + (Format-Bytes $Result.Bytes) } elseif ($Result.Count -gt 1) { "● $($Result.Count) 件" } else { '● 問題あり' }
            return @{ Text = $t; Color = $c.issue }
        }
        'recommend' { return @{ Text = '● 推奨';     Color = $c.recommend } }
        'info'      { return @{ Text = '● 確認';     Color = $c.info } }
        'ok'        { return @{ Text = '✓ 問題なし'; Color = $c.ok } }
        'error'     { return @{ Text = '! エラー';   Color = $c.error } }
        'skipped'   { return @{ Text = '— スキップ'; Color = $c.skipped } }
        default     { return @{ Text = '— 対象外';   Color = $c.na } }
    }
}

function Test-Fixable {
    param($Check, $Result)
    return [bool]($Check.Fix -and $Result -and $Result.Status -in 'issue', 'recommend', 'info')
}

function Get-IssueCount {
    param([string]$Category, [string]$Group)
    $G = $Global:PCTuneUpGui
    $n = 0
    foreach ($c in $Global:PCTuneUp.Checks.Values) {
        if ($Category -and $c.Category -ne $Category) { continue }
        if ($Group -and $c.Group -ne $Group) { continue }
        if ($G.Results.ContainsKey($c.Id) -and $G.Results[$c.Id].Status -eq 'issue') { $n++ }
    }
    return $n
}

function Test-CategoryScanned {
    param([string]$Category)
    $G = $Global:PCTuneUpGui
    foreach ($c in $Global:PCTuneUp.Checks.Values) {
        if ($c.Category -eq $Category -and $G.Results.ContainsKey($c.Id)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------
#  描画
# ---------------------------------------------------------------------
function Update-Cards {
    $G = $Global:PCTuneUpGui; $ui = $G.UI
    foreach ($cat in $Global:PCTuneUp.Categories.Keys) {
        $prefix = 'Cat' + $cat.Substring(0, 1).ToUpper() + $cat.Substring(1)
        $n = Get-IssueCount -Category $cat
        $badge = $ui["${prefix}Badge"]; $badgeText = $ui["${prefix}BadgeText"]; $text = $ui["${prefix}Text"]; $btn = $ui[$prefix]
        if ($n -gt 0) { $badge.Visibility = 'Visible'; $badgeText.Text = "$n" } else { $badge.Visibility = 'Collapsed' }
        if (-not (Test-CategoryScanned $cat)) { $text.Text = '未点検' }
        elseif ($n -gt 0) { $text.Text = "$n 問題" } else { $text.Text = '問題なし' }
        if ($cat -eq $G.Category) { $btn.Background = New-Brush $G.Colors.accentLight; $btn.BorderBrush = New-Brush $G.Colors.accent }
        else { $btn.Background = New-Brush '#FFFFFF'; $btn.BorderBrush = New-Brush $G.Colors.border }
    }
    $ui.CategoryBlurb.Text = $Global:PCTuneUp.Categories[$G.Category].Blurb
}

function Update-GroupHeader {
    param([string]$Group)
    $G = $Global:PCTuneUpGui
    if (-not $G.GroupHeaders.ContainsKey($Group)) { return }
    $tb = $G.GroupHeaders[$Group]
    $scanned = $false
    foreach ($c in (Get-Checks -Group $Group -IncludeLong)) { if ($G.Results.ContainsKey($c.Id)) { $scanned = $true } }
    $n = Get-IssueCount -Group $Group
    if (-not $scanned) { $tb.Text = '未点検'; $tb.Foreground = New-Brush $G.Colors.none }
    elseif ($n -gt 0) { $tb.Text = "$n 問題"; $tb.Foreground = New-Brush $G.Colors.issue }
    else { $tb.Text = '問題なし'; $tb.Foreground = New-Brush $G.Colors.ok }
}

function Update-Row {
    param([string]$Id)
    $G = $Global:PCTuneUpGui
    if (-not $G.Rows.ContainsKey($Id)) { return }
    $row = $G.Rows[$Id]; $check = Get-Check $Id
    $result = $null; if ($G.Results.ContainsKey($Id)) { $result = $G.Results[$Id] }
    $st = Get-StatusText -Check $check -Result $result
    $row.Status.Text = $st.Text; $row.Status.Foreground = New-Brush $st.Color

    if ($result) {
        $row.Summary.Text = $result.Summary
        $row.Summary.Foreground = New-Brush $(if ($result.Status -in 'issue', 'error') { $G.Colors.issue } else { $G.Colors.text })
        $row.Summary.Visibility = 'Visible'
    } else { $row.Summary.Visibility = 'Collapsed' }

    $fixMsg = $null; if ($G.FixResults.ContainsKey($Id)) { $fixMsg = $G.FixResults[$Id] }
    if ($fixMsg) {
        $row.FixMsg.Text = $(if ($fixMsg.Success) { '✓ ' } else { '✕ ' }) + $fixMsg.Message + $(if ($fixMsg.RebootRequired) { ' [要再起動]' } else { '' })
        $row.FixMsg.Foreground = New-Brush $(if ($fixMsg.Success) { $G.Colors.ok } else { $G.Colors.issue })
        $row.FixMsg.Visibility = 'Visible'
    } else { $row.FixMsg.Visibility = 'Collapsed' }

    if ($result -and $result.Items.Count -gt 0) {
        $max = 5
        $lines = @($result.Items | Select-Object -First $max)
        if ($result.Items.Count -gt $max) { $lines += ('… 他 {0} 件 (レポートに全件出力されます)' -f ($result.Items.Count - $max)) }
        $row.Items.Text = ($lines -join "`n")
        $row.Items.Visibility = 'Visible'
    } else { $row.Items.Visibility = 'Collapsed' }

    $fixable = Test-Fixable -Check $check -Result $result
    $row.CheckBox.IsEnabled = $fixable
    $row.CheckBox.IsChecked = [bool]($fixable -and $G.Selected.ContainsKey($Id) -and $G.Selected[$Id])
}

function New-CheckRow {
    param($Check)
    $G = $Global:PCTuneUpGui
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,6,0,6'
    foreach ($w in '30', '*', '150', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = $(if ($w -eq '*') { New-Object System.Windows.GridLength 1, 'Star' } elseif ($w -eq 'Auto') { [System.Windows.GridLength]::Auto } else { New-Object System.Windows.GridLength ([double]$w) })
        $grid.ColumnDefinitions.Add($cd)
    }

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.VerticalAlignment = 'Top'; $cb.Margin = '0,3,0,0'; $cb.Tag = $Check.Id
    $cb.Add_Checked({ param($s, $e) $Global:PCTuneUpGui.Selected[$s.Tag] = $true; Update-FixButton })
    $cb.Add_Unchecked({ param($s, $e) $Global:PCTuneUpGui.Selected[$s.Tag] = $false; Update-FixButton })
    [System.Windows.Controls.Grid]::SetColumn($cb, 0); $grid.Children.Add($cb) | Out-Null

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = '0,0,12,0'
    $name = New-Text -Text $Check.Name -Weight SemiBold
    $desc = New-Text -Text $Check.Description -Size 12 -Color $G.Colors.muted
    $summary = New-Text -Text '' -Size 12
    $summary.Margin = '0,3,0,0'
    $fixMsg = New-Text -Text '' -Size 12
    $fixMsg.Margin = '0,3,0,0'
    $items = New-Text -Text '' -Size 11 -Color $G.Colors.muted
    $items.Margin = '0,4,0,0'; $items.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas, MS Gothic, Yu Gothic UI'
    $stack.Children.Add($name) | Out-Null; $stack.Children.Add($desc) | Out-Null
    $stack.Children.Add($summary) | Out-Null; $stack.Children.Add($fixMsg) | Out-Null; $stack.Children.Add($items) | Out-Null
    if ($Check.Notes) {
        $notes = New-Text -Text $Check.Notes -Size 11 -Color $G.Colors.muted -Style Italic
        $notes.Margin = '0,3,0,0'
        $stack.Children.Add($notes) | Out-Null
    }
    if ($Check.Risk -ne 'low') {
        $tagText = New-Text -Text '設定変更や再起動を伴うため、既定ではチェックを外しています' -Size 11 -Color $G.Colors.recommend
        $tagText.Margin = '0,2,0,0'
        $stack.Children.Add($tagText) | Out-Null
    }
    [System.Windows.Controls.Grid]::SetColumn($stack, 1); $grid.Children.Add($stack) | Out-Null

    $status = New-Text -Text '' -Size 12 -Weight SemiBold -NoWrap
    $status.HorizontalAlignment = 'Right'; $status.VerticalAlignment = 'Top'; $status.Margin = '0,2,12,0'
    [System.Windows.Controls.Grid]::SetColumn($status, 2); $grid.Children.Add($status) | Out-Null

    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation = 'Horizontal'; $btnPanel.VerticalAlignment = 'Top'
    if ($Check.Long) {
        # 時間のかかる項目は通常の点検では走らせない。行から個別に「詳細検査」できる
        $scanBtn = New-Object System.Windows.Controls.Button
        $scanBtn.Content = '詳細検査'; $scanBtn.Style = Get-GuiStyle 'LinkButton'; $scanBtn.Tag = $Check.Id
        $scanBtn.Add_Click({ param($s, $e) Start-Work -Mode scan -Ids @($s.Tag) })
        $btnPanel.Children.Add($scanBtn) | Out-Null
    }
    if ($Check.Action) {
        # 自動修復できない項目だけ、設定画面などを開くリンクを出す
        $actBtn = New-Object System.Windows.Controls.Button
        $actBtn.Content = $Check.ActionLabel; $actBtn.Style = Get-GuiStyle 'LinkButton'; $actBtn.Tag = $Check.Id
        $actBtn.Add_Click({ param($s, $e) Invoke-RowAction -Id $s.Tag })
        $btnPanel.Children.Add($actBtn) | Out-Null
    }
    [System.Windows.Controls.Grid]::SetColumn($btnPanel, 3); $grid.Children.Add($btnPanel) | Out-Null

    $G.Rows[$Check.Id] = @{ CheckBox = $cb; Status = $status; Summary = $summary; FixMsg = $fixMsg; Items = $items }
    Update-Row -Id $Check.Id
    return $grid
}

function Render-Category {
    $G = $Global:PCTuneUpGui; $ui = $G.UI
    $ui.GroupsPanel.Children.Clear()
    $G.Rows = @{}; $G.GroupHeaders = @{}
    foreach ($gk in $Global:PCTuneUp.Groups.Keys) {
        $grp = $Global:PCTuneUp.Groups[$gk]
        if ($grp.Category -ne $G.Category) { continue }
        $checks = @(Get-Checks -Group $gk -IncludeLong)
        if ($checks.Count -eq 0) { continue }

        $exp = New-Object System.Windows.Controls.Expander
        $exp.Style = Get-GuiStyle 'GroupExpander'; $exp.Tag = $gk
        $header = New-Object System.Windows.Controls.StackPanel
        $line = New-Object System.Windows.Controls.StackPanel
        $line.Orientation = 'Horizontal'
        $line.Children.Add((New-Text -Text $grp.Name -Size 14 -Weight SemiBold -NoWrap)) | Out-Null
        $count = New-Text -Text '' -Size 12 -Weight SemiBold -NoWrap
        $count.VerticalAlignment = 'Center'; $count.Margin = '14,0,0,0'
        $line.Children.Add($count) | Out-Null
        $header.Children.Add($line) | Out-Null
        $header.Children.Add((New-Text -Text $grp.Description -Size 12 -Color $G.Colors.muted)) | Out-Null
        $exp.Header = $header
        $G.GroupHeaders[$gk] = $count

        $body = New-Object System.Windows.Controls.StackPanel
        $body.Margin = '22,4,0,0'
        $i = 0
        foreach ($c in $checks) {
            if ($i -gt 0) {
                $sep = New-Object System.Windows.Controls.Separator
                $sep.Background = New-Brush $G.Colors.border; $sep.Margin = '0,2,0,2'
                $body.Children.Add($sep) | Out-Null
            }
            $body.Children.Add((New-CheckRow -Check $c)) | Out-Null
            $i++
        }
        $exp.Content = $body
        if ($G.Expanded.ContainsKey($gk)) { $exp.IsExpanded = $G.Expanded[$gk] }
        else { $exp.IsExpanded = (-not (Test-CategoryScanned $G.Category)) -or ((Get-IssueCount -Group $gk) -gt 0) }
        $exp.Add_Expanded({ param($s, $e) $Global:PCTuneUpGui.Expanded[$s.Tag] = $true })
        $exp.Add_Collapsed({ param($s, $e) $Global:PCTuneUpGui.Expanded[$s.Tag] = $false })
        $ui.GroupsPanel.Children.Add($exp) | Out-Null
        Update-GroupHeader -Group $gk
    }
    Update-Cards
    Update-FixButton
}

function Update-FixButton {
    $G = $Global:PCTuneUpGui
    $n = 0
    foreach ($id in $G.Selected.Keys) {
        if ($G.Selected[$id] -and $G.Results.ContainsKey($id) -and (Test-Fixable -Check (Get-Check $id) -Result $G.Results[$id])) { $n++ }
    }
    $G.UI.FixButton.Content = $(if ($n -gt 0) { "$n 件を修復" } else { '修復' })
    $G.UI.FixButton.IsEnabled = ($n -gt 0 -and -not $G.Busy)
}

function Add-LogLine {
    param([string]$Line)
    $box = $Global:PCTuneUpGui.UI.LogBox
    if ($box.LineCount -gt 3000) { $box.Clear() }
    $box.AppendText($Line + "`r`n")
    $box.ScrollToEnd()
}

function Set-Busy {
    param([bool]$Busy, [string]$Status = '')
    $G = $Global:PCTuneUpGui; $ui = $G.UI
    $G.Busy = $Busy
    $ui.ScanButton.IsEnabled = -not $Busy
    $ui.ReportButton.IsEnabled = (-not $Busy) -and ($G.Results.Count -gt 0)
    $ui.GroupsPanel.IsEnabled = -not $Busy
    $ui.FullScanBox.IsEnabled = -not $Busy
    $ui.CancelButton.Visibility = $(if ($Busy) { 'Visible' } else { 'Collapsed' })
    $ui.Progress.Visibility = $(if ($Busy) { 'Visible' } else { 'Hidden' })
    $ui.Progress.IsIndeterminate = $Busy
    if ($Status) { $ui.StatusText.Text = $Status }
    Update-FixButton
}

# ---------------------------------------------------------------------
#  ワーカー制御
# ---------------------------------------------------------------------
function Start-Work {
    param([ValidateSet('scan', 'fix', 'action')][string]$Mode, [string[]]$Ids)
    $G = $Global:PCTuneUpGui
    if ($G.Busy -or -not $Ids -or $Ids.Count -eq 0) { return }
    $G.Mode = $Mode; $G.WorkIds = $Ids; $G.WorkDone = 0
    $G.FixBatch = @{}
    foreach ($id in $Ids) { if ($Mode -eq 'scan') { $G.FixResults.Remove($id) } }
    $label = switch ($Mode) { 'scan' { '点検' } 'fix' { '修復' } default { '実行' } }
    Set-Busy -Busy $true -Status ("{0}中… (0 / {1})" -f $label, $Ids.Count)
    $G.UI.LogExpander.IsExpanded = $true

    $G.LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $G.ResultQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
    $scanCopy = @{}
    foreach ($id in $Ids) { if ($G.Results.ContainsKey($id)) { $scanCopy[$id] = $G.Results[$id] } }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($G.WorkerScript)
    [void]$ps.AddParameter('LibRoot', $Global:PCTuneUp.LibRoot)
    [void]$ps.AddParameter('LogQueue', $G.LogQueue)
    [void]$ps.AddParameter('ResultQueue', $G.ResultQueue)
    [void]$ps.AddParameter('Mode', $Mode)
    [void]$ps.AddParameter('Ids', $Ids)
    [void]$ps.AddParameter('ScanResults', $scanCopy)
    $G.Handle = $ps.BeginInvoke()
    $G.PS = $ps; $G.RS = $rs
    $G.Timer.Start()
}

function Invoke-WorkerTick {
    $G = $Global:PCTuneUpGui
    if (-not $G.PS) { return }
    $completed = $G.Handle.IsCompleted   # 先に読む: これ以前に投入された結果は必ず下で拾える
    $line = $null
    while ($G.LogQueue.TryDequeue([ref]$line)) { Add-LogLine $line }

    $item = $null
    while ($G.ResultQueue.TryDequeue([ref]$item)) {
        if (-not $item -or -not $item.PSObject.Properties['Kind']) { continue }
        switch ($item.Kind) {
            'scan' {
                $G.Results[$item.Id] = $item.Result
                $check = Get-Check $item.Id
                if ($G.Mode -eq 'scan') {
                    $G.Selected[$item.Id] = [bool]($item.Result.Status -eq 'issue' -and $check.Risk -eq 'low' -and $check.Fix)
                } elseif (-not (Test-Fixable -Check $check -Result $item.Result)) {
                    $G.Selected[$item.Id] = $false
                }
                $G.WorkDone++
                Update-Row -Id $item.Id
                Update-GroupHeader -Group $check.Group
                Update-Cards
                $label = switch ($G.Mode) { 'scan' { '点検' } 'fix' { '修復' } default { '実行' } }
                $G.UI.StatusText.Text = '{0}中… ({1} / {2}) {3}' -f $label, $G.WorkDone, $G.WorkIds.Count, $check.Name
            }
            'fix' {
                $G.FixResults[$item.Id] = $item.Result
                $G.FixBatch[$item.Id] = $item.Result
                Update-Row -Id $item.Id
            }
        }
    }

    if ($completed) {
        $G.Timer.Stop()
        try { $G.PS.EndInvoke($G.Handle) | Out-Null } catch { Add-LogLine ('[ERROR] ' + $_.Exception.Message) }
        foreach ($err in $G.PS.Streams.Error) { Add-LogLine ('[ERROR] ' + $err.ToString()) }
        while ($G.LogQueue.TryDequeue([ref]$line)) { Add-LogLine $line }
        try { $G.PS.Dispose(); $G.RS.Close(); $G.RS.Dispose() } catch { }
        $G.PS = $null; $G.RS = $null
        Complete-Work
    }
}

function Complete-Work {
    $G = $Global:PCTuneUpGui
    $cancelled = $G.Cancelled; $G.Cancelled = $false
    if ($cancelled) { Set-Busy -Busy $false -Status '中止しました'; Render-Category; return }
    if ($G.Mode -eq 'scan') {
        $issues = 0; $rec = 0; $bytes = [long]0
        foreach ($id in $G.WorkIds) {
            if (-not $G.Results.ContainsKey($id)) { continue }
            $r = $G.Results[$id]
            if ($r.Status -eq 'issue') { $issues++ }
            if ($r.Status -eq 'recommend') { $rec++ }
            if ((Get-Check $id).Group -in 'junk', 'browser') { $bytes += $r.Bytes }
        }
        $msg = '点検完了: 問題 {0} 件 / 推奨 {1} 件 / 削除できる不要ファイル {2}。' -f $issues, $rec, (Format-Bytes $bytes)
        $msg += $(if ($issues -gt 0) { ' 直したい項目にチェックが付いていることを確認して「修復」を押してください。' } else { ' 問題はありません。' })
        Set-Busy -Busy $false -Status $msg
    } else {
        $ok = 0; $ng = 0; $freed = [long]0; $reboot = $false
        foreach ($f in $G.FixBatch.Values) { if ($f.Success) { $ok++ } else { $ng++ }; $freed += $f.FreedBytes; if ($f.RebootRequired) { $reboot = $true } }
        $msg = '{3}完了: 成功 {0} 件 / 失敗 {1} 件 / {2} 解放。' -f $ok, $ng, (Format-Bytes $freed), $(if ($G.Mode -eq 'fix') { '修復' } else { '実行' })
        if ($reboot) { $msg += ' 一部の修復は再起動後に反映されます。' }
        Set-Busy -Busy $false -Status $msg
        if ($reboot) { [System.Windows.MessageBox]::Show('一部の修復を反映するには再起動が必要です。作業を保存してから再起動してください。', 'PC TuneUp', 'OK', 'Information') | Out-Null }
    }
    Render-Category
}

function Stop-Work {
    $G = $Global:PCTuneUpGui
    if (-not $G.PS) { return }
    $G.Cancelled = $true
    $G.UI.StatusText.Text = '中止しています… (実行中のコマンドが終わるまでお待ちください)'
    try { $G.PS.BeginStop($null, $null) | Out-Null } catch { }
}

function Start-Scan {
    $G = $Global:PCTuneUpGui
    $full = [bool]$G.UI.FullScanBox.IsChecked
    $ids = @(Get-Checks -IncludeLong:$full | ForEach-Object { $_.Id })
    Start-Work -Mode scan -Ids $ids
}

function Start-Fix {
    param([string[]]$Ids)
    $G = $Global:PCTuneUpGui
    if (-not $Ids) {
        $Ids = @()
        foreach ($c in $Global:PCTuneUp.Checks.Values) {
            if ($G.Selected.ContainsKey($c.Id) -and $G.Selected[$c.Id] -and $G.Results.ContainsKey($c.Id) -and (Test-Fixable -Check $c -Result $G.Results[$c.Id])) { $Ids += $c.Id }
        }
    }
    if ($Ids.Count -eq 0) { return }
    # 確認ダイアログは、設定変更・再起動・ブラウザー終了など「元に戻しにくい／気付きにくい」副作用を
    # 伴う項目が含まれるときだけ出す。不要ファイルの削除だけならそのまま実行する。
    $needConfirm = @()
    foreach ($id in $Ids) {
        $c = Get-Check $id
        if ($c.Risk -ne 'low' -or $c.FixConfirm) {
            $reason = if ($c.FixConfirm) { $c.FixConfirm } else { $c.FixLabel + ' (設定変更または再起動を伴います)' }
            $needConfirm += ('・' + $c.Name + ' — ' + $reason)
        }
    }
    if ($needConfirm.Count) {
        $text = "次の項目は注意が必要です。`n`n" + ($needConfirm -join "`n") + "`n`nこのまま $($Ids.Count) 件の修復を実行しますか?"
        $r = [System.Windows.MessageBox]::Show($text, 'PC TuneUp - 修復の確認', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
    }
    Start-Work -Mode fix -Ids $Ids
}

function Invoke-RowAction {
    param([string]$Id)
    $check = Get-Check $Id
    if ($check.ActionConfirm) {
        $r = [System.Windows.MessageBox]::Show($check.ActionConfirm, 'PC TuneUp', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    if ($check.ActionInWorker) {
        Start-Work -Mode action -Ids @($Id)
        return
    }
    Invoke-CheckAction -Id $Id | Out-Null
    Add-LogLine ("{0} [INFO] 操作: {1} ({2})" -f (Get-Date -Format 'HH:mm:ss'), $check.Name, $check.ActionLabel)
}

function Save-Report {
    $G = $Global:PCTuneUpGui
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'JSON レポート (*.json)|*.json'
    $dlg.FileName = 'PCTuneUp-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'
    $dlg.InitialDirectory = Join-Path $Global:PCTuneUp.DataDir 'reports'
    if ($dlg.ShowDialog() -eq $true) {
        $path = Export-Report -Results $G.Results -FixResults $G.FixResults -Path $dlg.FileName
        $G.UI.StatusText.Text = "レポートを保存しました: $path"
        Add-LogLine ("{0} [INFO] レポート: {1}" -f (Get-Date -Format 'HH:mm:ss'), $path)
    }
}

# ---------------------------------------------------------------------
#  起動
# ---------------------------------------------------------------------
function Start-Gui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $G = $Global:PCTuneUpGui
    $G.Results = @{}; $G.FixResults = @{}; $G.Selected = @{}; $G.Expanded = @{}; $G.Rows = @{}; $G.GroupHeaders = @{}
    $G.Category = 'tuneup'; $G.Busy = $false; $G.PS = $null; $G.Cancelled = $false

    $xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if (-not $window) { throw "MainWindow.xaml を読み込めませんでした ($xamlPath)" }
    $G.Window = $window
    $Global:PCTuneUpWindow = $window
    $G.Styles = @{}
    foreach ($styleName in 'LinkButton', 'GroupExpander', 'PrimaryButton', 'SecondaryButton') {
        $G.Styles[$styleName] = $window.FindResource($styleName)
    }
    Write-Log ("GUI 初期化: window={0} styles={1}" -f $window.GetType().Name, ($G.Styles.Keys -join ','))
    $ui = @{}
    foreach ($node in $xaml.SelectNodes('//*[@Name]')) { $ui[$node.Name] = $window.FindName($node.Name) }
    $G.UI = $ui

    $ui.CatTuneupGlyph.Text = $Global:PCTuneUp.Categories.tuneup.Glyph
    $ui.CatInternetGlyph.Text = $Global:PCTuneUp.Categories.internet.Glyph
    $ui.CatSecurityGlyph.Text = $Global:PCTuneUp.Categories.security.Glyph
    $ui.HeaderSub.Text = '点検して、見つかった問題を修復します。 v' + $Global:PCTuneUp.Version
    $ui.AdminBadge.Text = $(if (Test-IsAdmin) { '管理者として実行中' } else { '管理者権限なし: 一部の項目はスキップされます' })
    $ui.StatusText.Text = '「点検」を押してください。見つかった問題は「修復」で直します (レジストリは削除前にバックアップされます)。'

    foreach ($name in 'CatTuneup', 'CatInternet', 'CatSecurity') {
        $ui[$name].Add_Click({ param($s, $e) $Global:PCTuneUpGui.Category = [string]$s.Tag; Render-Category })
    }
    $ui.ScanButton.Add_Click({ Start-Scan })
    $ui.FixButton.Add_Click({ Start-Fix })
    $ui.CancelButton.Add_Click({ Stop-Work })
    $ui.ReportButton.Add_Click({ Save-Report })

    $G.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $G.Timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $G.Timer.Add_Tick({ Invoke-WorkerTick })

    $window.Add_Closing({
        param($s, $e)
        $G = $Global:PCTuneUpGui
        if ($G.PS) { try { $G.PS.Stop() } catch { } }
    })

    Render-Category
    Add-LogLine ("{0} [INFO] PC TuneUp {1} 起動。ログ: {2}" -f (Get-Date -Format 'HH:mm:ss'), $Global:PCTuneUp.Version, $Global:PCTuneUp.LogFile)
    $window.ShowDialog() | Out-Null
}
