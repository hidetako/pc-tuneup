#Requires -Version 5.1
# =====================================================================
#  PC TuneUp - 更新の確認と適用
#
#  配布版 (インストーラー版 / インストール不要版) にだけ
#  update-channel.json が同梱されている。そのファイルがあるときだけ
#  GitHub の Releases を見に行く。開発用のクローンでは何もしない。
#
#  このファイルは Core.ps1 の末尾から dot-source される。
# =====================================================================

function Get-UpdateChannel {
    <#
      配布版に同梱された update-channel.json を読む。
      無ければ $null (= 更新を確認しない)。
    #>
    param([string]$Path)
    if (-not $Path) {
        $Path = Join-Path (Split-Path -Parent $Global:PCTuneUp.LibRoot) 'update-channel.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "update-channel.json を読めません: $($_.Exception.Message)" 'WARN'
        return $null
    }
    if (-not $json.Repo) { return $null }
    [pscustomobject]@{
        Repo    = [string]$json.Repo
        # setup    インストーラーで入れた版。インストーラーを落として実行できる
        # portable インストール不要版。手動で入れ替えてもらう
        Kind    = $(if ($json.Kind) { [string]$json.Kind } else { 'portable' })
        Version = $(if ($json.Version) { [string]$json.Version } else { [string]$Global:PCTuneUp.Version })
        Path    = $Path
    }
}

function Compare-AppVersion {
    <#
      -1: A が古い / 0: 同じか判定できない / 1: A が新しい。
      読み取れない文字列は 0 を返す (= 更新を勧めない側に倒す)。
    #>
    param([string]$A, [string]$B)
    $va = $null; $vb = $null
    if (-not [version]::TryParse(($A -replace '^[vV]', ''), [ref]$va)) { return 0 }
    if (-not [version]::TryParse(($B -replace '^[vV]', ''), [ref]$vb)) { return 0 }
    $c = $va.CompareTo($vb)
    if ($c -lt 0) { return -1 }
    if ($c -gt 0) { return 1 }
    return 0
}

function Initialize-UpdateTls {
    # Windows PowerShell 5.1 の既定では TLS 1.2 が有効でないことがあり、
    # その状態では GitHub に接続できない。
    try {
        $tls12 = [Net.SecurityProtocolType]::Tls12
        if (([Net.ServicePointManager]::SecurityProtocol -band $tls12) -ne $tls12) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
        }
    } catch { }
}

function Get-UpdateUserAgent {
    # GitHub API は User-Agent が無いと 403 を返す
    'PCTuneUp/{0}' -f $Global:PCTuneUp.Version
}

function Get-LatestRelease {
    <#
      GitHub の「最新リリース」を取得する。下書きとプレリリースは API 側で除外される。
      リリースがまだ無い場合は 404 で例外になる。
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [int]$TimeoutSec = 15
    )
    Initialize-UpdateTls
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'User-Agent'           = Get-UpdateUserAgent
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = 'https://api.github.com/repos/{0}/releases/latest' -f $Repo
    $r = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
    [pscustomobject]@{
        Tag       = [string]$r.tag_name
        Version   = ([string]$r.tag_name) -replace '^[vV]', ''
        Name      = [string]$r.name
        Url       = [string]$r.html_url
        Published = [string]$r.published_at
        Assets    = @($r.assets | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.name
                Url  = [string]$_.browser_download_url
                Size = [long]$_.size
            }
        })
    }
}

function Test-UpdateAvailable {
    <#
      現在のバージョンと最新リリースを比べる。
      ネットワークが繋がらない・リリースが無い場合でも例外は投げず、Error に理由を入れて返す。
    #>
    param($Channel, [int]$TimeoutSec = 15)
    if (-not $Channel) { $Channel = Get-UpdateChannel }
    $out = [pscustomobject]@{
        Checked   = $false
        Available = $false
        Current   = [string]$Global:PCTuneUp.Version
        Latest    = $null
        Release   = $null
        Channel   = $Channel
        Error     = $null
    }
    if (-not $Channel) {
        $out.Error = '配布版ではないため、更新の確認は行いません'
        return $out
    }
    try {
        $rel = Get-LatestRelease -Repo $Channel.Repo -TimeoutSec $TimeoutSec
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '404' -or $msg -match 'Not Found') { $msg = '公開されているリリースがまだありません' }
        $out.Error = $msg
        Write-Log "更新を確認できません: $msg" 'WARN'
        return $out
    }
    $out.Checked = $true
    $out.Latest = $rel.Version
    $out.Release = $rel
    $out.Available = ((Compare-AppVersion -A $out.Current -B $rel.Version) -lt 0)
    if ($out.Available) { Write-Log ('更新があります: {0} → {1}' -f $out.Current, $rel.Version) }
    else { Write-Log ('最新版です ({0})' -f $out.Current) }
    $out
}

function Get-UpdateDir {
    $d = Join-Path $Global:PCTuneUp.DataDir 'updates'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $d
}

function Save-WebFile {
    # ファイルをダウンロードして、保存できたバイト数を返す
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSec = 600
    )
    Initialize-UpdateTls
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # 5.1 では進捗バーを出すとダウンロードが極端に遅くなるため、一時的に切る
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec $TimeoutSec `
            -Headers @{ 'User-Agent' = (Get-UpdateUserAgent) } -ErrorAction Stop
    } finally {
        $ProgressPreference = $prev
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "ダウンロードできませんでした: $Url" }
    (Get-Item -LiteralPath $Path).Length
}

function ConvertFrom-ChecksumFile {
    <#
      "<sha256>  <ファイル名>" 形式の行から、指定したファイルのハッシュを取り出す。
      見つからなければ $null。
    #>
    param([string[]]$Lines, [Parameter(Mandatory)][string]$FileName)
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            if ($Matches[2] -eq $FileName) { return $Matches[1].ToLowerInvariant() }
        }
    }
    return $null
}

function Get-ReleaseChecksum {
    # リリースに SHA256SUMS.txt が添付されていれば、その中の該当ハッシュを返す
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$FileName)
    $asset = @($Release.Assets | Where-Object { $_.Name -eq 'SHA256SUMS.txt' })[0]
    if (-not $asset) { return $null }
    $tmp = Join-Path (Get-UpdateDir) 'SHA256SUMS.txt'
    try {
        Save-WebFile -Url $asset.Url -Path $tmp -TimeoutSec 60 | Out-Null
        return (ConvertFrom-ChecksumFile -Lines (Get-Content -LiteralPath $tmp -Encoding UTF8) -FileName $FileName)
    } catch {
        Write-Log "SHA256SUMS.txt を取得できません: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Test-FileChecksum {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual.ToLowerInvariant() -eq $Expected.ToLowerInvariant())
}

function Save-Update {
    <#
      リリースから更新ファイルを落として、保存先のパスを返す。
      サイズと (公開されていれば) SHA256 を照合し、合わなければ消して中断する。

      チェックサムはリリースと同じ経路で配っているため、GitHub のアカウントが
      乗っ取られた場合までは守れない。転送中の破損と取り違えを防ぐためのもの。
    #>
    param(
        [Parameter(Mandatory)]$Release,
        [string]$Pattern = '-setup\.exe$'
    )
    $asset = @($Release.Assets | Where-Object { $_.Name -match $Pattern })[0]
    if (-not $asset) { throw "リリース $($Release.Tag) に該当するファイルがありません ($Pattern)" }
    $path = Join-Path (Get-UpdateDir) $asset.Name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    Write-Log ('ダウンロード: {0} ({1})' -f $asset.Name, (Format-Bytes $asset.Size))
    $size = Save-WebFile -Url $asset.Url -Path $path
    if ($asset.Size -gt 0 -and $size -ne $asset.Size) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw ('ダウンロードしたファイルのサイズが違います (期待 {0} / 実際 {1})' -f $asset.Size, $size)
    }
    $expected = Get-ReleaseChecksum -Release $Release -FileName $asset.Name
    if ($expected) {
        if (-not (Test-FileChecksum -Path $path -Expected $expected)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            throw 'ダウンロードしたファイルのチェックサムが一致しません。更新を中断しました。'
        }
        Write-Log 'チェックサム照合: 一致' 'OK'
    } else {
        Write-Log 'このリリースには SHA256SUMS.txt が無いため、サイズだけ確認しました' 'WARN'
    }
    $path
}

function Start-UpdateInstall {
    <#
      ダウンロードしたインストーラーを起動する。
      既定ではウィザードを表示する: 利用者が進行を見られるうえ、最後の
      「PC TuneUp を実行する」で更新後にそのまま起動できるため。
      -Silent を付けると進捗だけ出して自動で進む (CLI 用)。
    #>
    param([Parameter(Mandatory)][string]$SetupPath, [switch]$Silent)
    if (-not (Test-Path -LiteralPath $SetupPath)) { throw "インストーラーがありません: $SetupPath" }
    $argList = @('/NORESTART', '/CLOSEAPPLICATIONS')
    if ($Silent) { $argList += '/SILENT' }
    Write-Log ('インストーラーを起動します: {0} {1}' -f $SetupPath, ($argList -join ' '))
    Start-Process -FilePath $SetupPath -ArgumentList $argList -ErrorAction Stop | Out-Null
    $true
}
