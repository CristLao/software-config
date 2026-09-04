<#
.SYNOPSIS
    按清单顺序下载 Windows 安装包与字体, 或用 Edge 打开动态下载页.

.DESCRIPTION
    目标运行环境为 Windows PowerShell 5.1 (powershell.exe), 不需要 PowerShell 7,
    也不安装任何第三方模块.

    CSV 清单只支持两种动作:
      - download  : 同步下载 CSV 中给出的 HTTPS 直链.
      - open-edge : 非阻塞地用 Microsoft Edge 打开官网页面.

    脚本不使用 winget, 不爬取网站, 不推测下载地址, 不安装软件或字体, 不解压压缩包,
    也不把二进制文件保存到仓库.

    详见 docs/superpowers/specs/2026-07-11-windows-package-downloader-design.md.

.PARAMETER ConfigPath
    清单文件路径, 默认为脚本同目录的 windows-downloads.csv.

.PARAMETER OutputDirectory
    输出根目录, 默认为 $HOME\Downloads\WindowsPackages.

.PARAMETER Force
    对已存在目标文件重新下载.

.PARAMETER WhatIf
    仅校验并按顺序打印计划, 不创建目录, 不下载, 不写结果, 不打开 Edge.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\download_windows_assets.ps1

.EXAMPLE
    .\download_windows_assets.ps1 -OutputDirectory 'D:\Installers'

.EXAMPLE
    .\download_windows_assets.ps1 -WhatIf
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputDirectory,
    [switch]$Force,
    [switch]$WhatIf
)

# --- 进程级 TLS 1.2, 避免 Windows PowerShell 5.1 在旧系统设置下无法连接只允许 TLS 1.2 的站点.
$null = [System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.SecurityProtocolType]::Tls12 -bor `
    [System.Net.SecurityProtocolType]::Tls13

# ==============================================================================
# 常量
# ==============================================================================

$script:ExpectedHeader = @(
    'name', 'category', 'action', 'url', 'file_name',
    'sha256', 'homepage', 'notes'
)
$script:ValidActions   = @('download', 'open-edge')
$script:MaxRedirects   = 10
$script:MaxAttempts    = 3
$script:RetryDelaySec  = 2

# Windows 保留设备名, 不区分大小写, 含扩展名形式 (例如 NUL.txt 也视为非法).
$script:ReservedNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)

# 仅对扩展名为 .exe 或 .msi 的文件探测 Authenticode 签名.
$script:SignatureExtensions = @('.exe', '.msi')

# ==============================================================================
# 工具函数
# ==============================================================================

function ConvertTo-IsoLocalTime {
    # 本地 ISO 8601 时间, 例如 2026-07-11T18:30:45.
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
}

function Test-ReservedName {
    # 判断单个文件名/目录名是否命中 Windows 保留设备名 (含扩展名形式).
    param([string]$Name)

    $trimmed = $Name.Trim()
    $base = ($trimmed -split '\.')[0]
    return $script:ReservedNames -contains $base
}

function Test-ValidSegment {
    <#
        校验单层目录名或文件名的通用规则:
        - 不允许空值, '.', '..'
        - 不允许路径分隔符
        - 不允许 Windows 非法文件名字符
        - 不允许尾随空格或句点
        - 不允许 Windows 保留设备名
        返回 $true / $false.
    #>
    param([string]$Segment)

    if ([string]::IsNullOrWhiteSpace($Segment)) { return $false }
    if ($Segment -eq '.' -or $Segment -eq '..') { return $false }

    $illegal = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($ch in $illegal) {
        if ($Segment.Contains($ch)) { return $false }
    }

    # 尾随空格或句点在 NTFS 上会被截断, 由此可能造成路径歧义.
    $lastChar = $Segment[$Segment.Length - 1]
    if ($lastChar -eq ' ' -or $lastChar -eq '.') { return $false }

    if (Test-ReservedName $Segment) { return $false }

    return $true
}

function Get-AbsoluteHttpsUri {
    <#
        把字符串构造成绝对 System.Uri, 且 Scheme 必须为 https.
        无法构造或非 https 时返回 $null.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parsed = [System.Uri]$Value -as [System.Uri]
    if ($null -eq $parsed) { return $null }
    if (-not $parsed.IsAbsoluteUri) { return $null }
    if ($parsed.Scheme -ne 'https') { return $null }
    return $parsed
}

# ==============================================================================
# 读取清单
# ==============================================================================

function Read-DownloadList {
    <#
        .SYNOPSIS
            校验 BOM 和精确表头后以 UTF-8 读取 CSV, 保存从 1 开始的逻辑数据行索引.

        .OUTPUTS
            项目数组, 每项附加 RowIndex 属性 (从 1 开始).
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "清单文件不存在: $Path"
    }

    # --- 1. 预检文件开头三个字节必须为 UTF-8 BOM EF BB BF.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 3 `
            -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "清单必须使用 UTF-8 with BOM 编码: $Path"
    }

    # --- 2. 表头精确校验: 先从原始文本取第一行, 逐字段比对字段数/顺序/大小写.
    #       不能依赖 Import-Csv -Header, 后者会按预期字段名重塑列, 从而掩盖多余列.
    $rawText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $firstLineEnd = $rawText.IndexOfAny(@([char]"`r", [char]"`n"))
    if ($firstLineEnd -lt 0) { $firstLineEnd = $rawText.Length }
    $headerLine = $rawText.Substring(0, $firstLineEnd)

    # 约定表头字段均为纯标识符, 不含逗号或引号. 出现引号即视为可疑输入.
    if ($headerLine.Contains('"')) {
        throw ('表头不得包含双引号. 表头必须精确为: {0}' -f ($script:ExpectedHeader -join ','))
    }

    $actualFields = $headerLine.Split(',')

    if ($actualFields.Count -ne $script:ExpectedHeader.Count) {
        throw ('表头字段数错误: 期望 {0} 个, 实际 {1} 个. 表头必须精确为: {2}' `
            -f $script:ExpectedHeader.Count, $actualFields.Count, ($script:ExpectedHeader -join ','))
    }
    for ($i = 0; $i -lt $script:ExpectedHeader.Count; $i++) {
        if ($actualFields[$i] -cne $script:ExpectedHeader[$i]) {
            throw ('表头第 {0} 列应为 "{1}", 实际为 "{2}". 表头必须精确为: {3}' `
                -f ($i + 1), $script:ExpectedHeader[$i], $actualFields[$i], ($script:ExpectedHeader -join ','))
        }
    }

    # --- 3. 表头已验证, 用 CSV 自身表头导入数据行 (Import-Csv 自动跳过表头).
    $records = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
    if ($records.Count -eq 0) {
        throw '清单没有数据行.'
    }

    # --- 3. 去掉表头行后, 给每条数据行附加 RowIndex (从 1 开始).
    $items = New-Object System.Collections.ArrayList
    $rowIndex = 1
    for ($i = 0; $i -lt $records.Count; $i++) {
        $rec = $records[$i]

        # 跳过完全空行 (所有字段都为空).
        $allEmpty = $true
        foreach ($field in $script:ExpectedHeader) {
            if (-not [string]::IsNullOrEmpty($rec.$field)) { $allEmpty = $false; break }
        }
        if ($allEmpty) { continue }

        # 用 PSCustomObject 复制一份, 并附加 RowIndex; 原始字段保持 string 类型.
        $item = [ordered]@{}
        foreach ($field in $script:ExpectedHeader) {
            $item[$field] = [string]$rec.$field
        }
        $item['RowIndex'] = $rowIndex
        $items.Add([pscustomobject]$item) | Out-Null
        $rowIndex++
    }

    if ($items.Count -eq 0) {
        throw '清单没有数据行.'
    }

    return ,$items
}

# ==============================================================================
# 预检
# ==============================================================================

function Test-DownloadList {
    <#
        .SYNOPSIS
            在任何副作用前完成全部字段和重复路径校验.

        .OUTPUTS
            哈希表: 当校验通过时 @{ Ok = $true;  Items = <validated array> },
                    当校验失败时 @{ Ok = $false; Errors = <string array> }.
    #>
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $errors = New-Object System.Collections.ArrayList
    $validated = New-Object System.Collections.ArrayList

    # 规范化输出根目录, 用于后续唯一性与逃逸校验.
    $resolvedRoot = (Resolve-Path -LiteralPath $OutputRoot -ErrorAction SilentlyContinue)
    if ($null -eq $resolvedRoot) {
        # 尚不存在, 用 Path.GetFullPath 规范化. 先确保父目录可解析.
        try {
            $normRoot = [System.IO.Path]::GetFullPath($OutputRoot.TrimEnd('\', '/') + '\')
        } catch {
            $null = $errors.Add("输出根目录无法规范化: $OutputRoot")
            return @{ Ok = $false; Errors = $errors }
        }
    } else {
        $normRoot = [System.IO.Path]::GetFullPath(($resolvedRoot.Path).TrimEnd('\', '/') + '\')
    }

    # 记录已见的 download 目标路径 (规范化, 不区分大小写).
    $seenTargets = @{}

    foreach ($item in $Items) {
        $row = $item.RowIndex
        $name = $item.name.Trim()
        $category = $item.category
        $action = $item.action.Trim()
        $url = $item.url
        $fileName = $item.file_name
        $sha256 = $item.sha256
        $homepage = $item.homepage

        $itemErrors = New-Object System.Collections.ArrayList
        function Add-Err([string]$Msg) { $null = $itemErrors.Add($Msg) }

        # --- 必填字段非空.
        if ([string]::IsNullOrWhiteSpace($name)) {
            Add-Err 'name 不能为空.'
        }
        if ([string]::IsNullOrWhiteSpace($category)) {
            Add-Err 'category 不能为空.'
        }
        if ([string]::IsNullOrWhiteSpace($action)) {
            Add-Err 'action 不能为空.'
        } elseif ($script:ValidActions -notcontains $action) {
            Add-Err ("action 只能为 {0}." -f ($script:ValidActions -join ' 或 '))
        }
        if ([string]::IsNullOrWhiteSpace($url)) {
            Add-Err 'url 不能为空.'
        }
        if ([string]::IsNullOrWhiteSpace($homepage)) {
            Add-Err 'homepage 不能为空.'
        }

        # --- category 单层目录名校验.
        if (-not [string]::IsNullOrWhiteSpace($category)) {
            if (-not (Test-ValidSegment $category)) {
                Add-Err 'category 必须是合法的单层目录名 (不含路径分隔符, 不含 Windows 非法字符或保留名).'
            }
        }

        # --- action 分支约束.
        if (-not [string]::IsNullOrWhiteSpace($action) -and $script:ValidActions -contains $action) {
            if ($action -eq 'download') {
                # download: file_name 必填, 且必须等于其 Path.GetFileName() 结果.
                if ([string]::IsNullOrWhiteSpace($fileName)) {
                    Add-Err 'download 的 file_name 不能为空.'
                } else {
                    if (-not (Test-ValidSegment $fileName)) {
                        Add-Err 'file_name 必须是合法的纯文件名 (不含路径, 不含尾随空格/句点或保留名).'
                    } else {
                        $baseName = [System.IO.Path]::GetFileName($fileName.Trim())
                        if ($fileName.Trim() -ne $baseName) {
                            Add-Err 'file_name 不得包含路径分隔符.'
                        }
                    }
                }

                # sha256 留空或 64 位十六进制.
                if (-not [string]::IsNullOrEmpty($sha256)) {
                    if ($sha256.Trim() -notmatch '^[0-9A-Fa-f]{64}$') {
                        Add-Err 'sha256 必须留空或为 64 位十六进制.'
                    }
                }
            } elseif ($action -eq 'open-edge') {
                # open-edge: file_name 与 sha256 必须为空.
                if (-not [string]::IsNullOrEmpty($fileName)) {
                    Add-Err 'open-edge 的 file_name 必须为空.'
                }
                if (-not [string]::IsNullOrEmpty($sha256)) {
                    Add-Err 'open-edge 的 sha256 必须为空.'
                }
            }
        }

        # --- url 与 homepage 必须为绝对 HTTPS URL.
        if (-not [string]::IsNullOrWhiteSpace($url)) {
            if ($null -eq (Get-AbsoluteHttpsUri $url.Trim())) {
                Add-Err 'url 必须是绝对 HTTPS URL.'
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($homepage)) {
            if ($null -eq (Get-AbsoluteHttpsUri $homepage.Trim())) {
                Add-Err 'homepage 必须是绝对 HTTPS URL.'
            }
        }

        if ($itemErrors.Count -gt 0) {
            foreach ($e in $itemErrors) {
                $null = $errors.Add(('[{0}] {1} -> {2}' -f $row, $name, $e))
            }
            continue
        }

        # --- 规范化目标路径, 检查不能逃逸 OutputDirectory, 并检查重复.
        if ($action -eq 'download') {
            $target = Resolve-ItemPath -Item $item -OutputRoot $normRoot
            if ($null -eq $target) {
                $null = $errors.Add(('[{0}] {1} -> 目标路径无法规范化.' -f $row, $name))
            } else {
                $lower = $target.ToLowerInvariant()
                if (-not $lower.StartsWith($normRoot.ToLowerInvariant())) {
                    $null = $errors.Add(('[{0}] {1} -> 目标路径逃逸输出目录: {2}' -f $row, $name, $target))
                } elseif ($seenTargets.ContainsKey($lower)) {
                    $null = $errors.Add(('[{0}] {1} -> 目标路径与前面行重复: {2}' -f $row, $name, $target))
                } else {
                    $seenTargets[$lower] = $true
                }
            }
        }

        # 附加规范化输出根目录, 便于后续 Resolve-ItemPath 复用.
        $item | Add-Member -NotePropertyName '_OutputRoot' -NotePropertyValue $normRoot -Force
        $null = $validated.Add($item)
    }

    if ($errors.Count -gt 0) {
        return @{ Ok = $false; Errors = $errors }
    }
    return @{ Ok = $true; Items = $validated }
}

function Resolve-ItemPath {
    <#
        .SYNOPSIS
            安全组合分类目录和文件名, 返回规范化后的绝对目标路径.

        .DESCRIPTION
            输入 $Item 必须是 download 行. 若 $OutputRoot 未提供, 使用 $Item._OutputRoot.
    #>
    param(
        [Parameter(Mandatory)]$Item,
        [string]$OutputRoot
    )

    $root = $OutputRoot
    if ([string]::IsNullOrEmpty($root)) { $root = $Item._OutputRoot }
    if ([string]::IsNullOrEmpty($root)) { return $null }

    $category = $Item.category.Trim()
    $fileName = $Item.file_name.Trim()

    try {
        $dir = [System.IO.Path]::GetFullPath($root.TrimEnd('\', '/') + '\' + $category + '\')
        $target = [System.IO.Path]::GetFullPath($dir + $fileName)
        return $target
    } catch {
        return $null
    }
}

# ==============================================================================
# 完整性与签名
# ==============================================================================

function Get-FileIntegrity {
    <#
        .SYNOPSIS
            统一生成文件完整性记录.

        .OUTPUTS
            哈希表:
              @{ Sha256 = <string>;
                 SignatureStatus = <string>;
                 SignerSubject   = <string>;
                 SignatureError  = <string> }
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = @{
        Sha256           = ''
        SignatureStatus  = ''
        SignerSubject    = ''
        SignatureError   = ''
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $result
    }

    try {
        $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
        $result.Sha256 = $hash.Hash.ToLowerInvariant()
    } catch {
        $result.Sha256 = ''
    }

    $ext = [System.IO.Path]::GetExtension($Path)
    if ($script:SignatureExtensions -contains $ext.ToLowerInvariant()) {
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            if ($null -eq $sig) {
                $result.SignatureStatus = 'UnknownError'
                $result.SignatureError  = 'Get-AuthenticodeSignature 返回空结果.'
            } else {
                $result.SignatureStatus = [string]$sig.Status
                if ($null -ne $sig.SignerCertificate) {
                    $result.SignerSubject = [string]$sig.SignerCertificate.Subject
                }
                if (-not [string]::IsNullOrEmpty($sig.StatusMessage)) {
                    $result.SignatureError = [string]$sig.StatusMessage
                }
            }
        } catch {
            $result.SignatureStatus = 'UnknownError'
            $result.SignatureError  = $_.Exception.Message
        }
    }

    return $result
}

# ==============================================================================
# 下载
# ==============================================================================

function Invoke-HttpsDownload {
    <#
        .SYNOPSIS
            使用 HttpWebRequest 建立一次 GET 请求, 逐跳处理 HTTPS 重定向,
            并把最终响应流写入 $PartPath.

        .OUTPUTS
            @{ Ok = $true }  或  @{ Ok = $false; Error = <string> }
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$PartPath
    )

    $currentUrl = $Url
    $hop = 0

    try {
        while ($true) {
            $hop++
            if ($hop -gt ($script:MaxRedirects + 1)) {
                return @{ Ok = $false; Error = ('超过最大重定向次数 {0}.' -f $script:MaxRedirects) }
            }

            $req = [System.Net.HttpWebRequest]::Create($currentUrl)
            $req.Method = 'GET'
            $req.AllowAutoRedirect = $false
            $req.UserAgent = 'WindowsAssetsDownloader/1.0 (+PowerShell 5.1)'
            # 留出合理超时, 避免连接挂死; 单位毫秒.
            $req.Timeout = 60000
            $req.ReadWriteTimeout = 60000

            $resp = $null
            try {
                $resp = $req.GetResponse()
            } catch [System.Net.WebException] {
                # 重定向/4xx/5xx 通常以异常形式抛出; 响应仍可能在 Response 中.
                $resp = $_.Exception.Response
                if ($null -eq $resp) {
                    return @{ Ok = $false; Error = $_.Exception.Message }
                }
            }

            $statusCode = [int]$resp.StatusCode
            # 3xx: 301/302/303/307/308 -> 跟随 Location, 必须仍是 HTTPS.
            if ($statusCode -ge 300 -and $statusCode -lt 400) {
                if ($statusCode -ne 301 -and $statusCode -ne 302 `
                        -and $statusCode -ne 303 -and $statusCode -ne 307 -and $statusCode -ne 308) {
                    $resp.Close()
                    return @{ Ok = $false; Error = ('不支持的重定向状态码 {0}.' -f $statusCode) }
                }

                $location = $resp.Headers['Location']
                $resp.Close()
                if ([string]::IsNullOrEmpty($location)) {
                    return @{ Ok = $false; Error = '重定向缺少 Location 头.' }
                }

                # Location 可能是绝对或相对 URL, 用当前 URL 作为 base 解析.
                $nextUri = $null
                if (-not [System.Uri]::TryCreate($location, [System.UriKind]::RelativeOrAbsolute, [ref]$nextUri)) {
                    return @{ Ok = $false; Error = ('无法解析重定向 Location: {0}' -f $location) }
                }
                if (-not $nextUri.IsAbsoluteUri) {
                    $baseUri = [System.Uri]$currentUrl
                    $nextUri = [System.Uri]$baseUri, $nextUri
                }
                if ($nextUri.Scheme -ne 'https') {
                    return @{ Ok = $false; Error = ('重定向降级为非 HTTPS: {0}' -f $nextUri.AbsoluteUri) }
                }
                $currentUrl = $nextUri.AbsoluteUri
                continue
            }

            # 非 2xx 最终响应视为失败.
            if ($statusCode -lt 200 -or $statusCode -ge 300) {
                $resp.Close()
                return @{ Ok = $false; Error = ('HTTP {0}.' -f $statusCode) }
            }

            # 2xx: 把响应流写入 $PartPath.
            try {
                $responseStream = $resp.GetResponseStream()
                $fileStream = [System.IO.File]::Create($PartPath)
                $buffer = New-Object byte[] 81920
                while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                }
                $fileStream.Flush()
            } finally {
                if ($null -ne $fileStream)    { $fileStream.Close() }
                if ($null -ne $responseStream){ $responseStream.Close() }
                $resp.Close()
            }
            return @{ Ok = $true }
        }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Invoke-DownloadItem {
    <#
        .SYNOPSIS
            串行下载单项, 最多 $MaxAttempts 次总尝试, 校验哈希并原子落盘.

        .OUTPUTS
            单项结果对象 (由 New-ResultRecord 构造).
    #>
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Target,
        [switch]$Force
    )

    $startedAt = ConvertTo-IsoLocalTime
    $expected  = $Item.sha256.Trim()

    $categoryDir = [System.IO.Path]::GetDirectoryName($Target)

    $status       = 'Failed'
    $observedHash = ''
    $sigStatus    = ''
    $sigSubject   = ''
    $sigError     = ''
    $errorMessage = ''

    # --- Pending: 目标存在情况.
    if ((Test-Path -LiteralPath $Target -PathType Leaf) -and -not $Force) {
        $integrity = Get-FileIntegrity -Path $Target
        $observedHash = $integrity.Sha256
        $sigStatus    = $integrity.SignatureStatus
        $sigSubject   = $integrity.SignerSubject
        $sigError     = $integrity.SignatureError

        if ([string]::IsNullOrEmpty($expected)) {
            # 无预期哈希, 保留现有文件.
            $status = 'Skipped'
        } elseif ($observedHash -eq $expected.ToLowerInvariant()) {
            $status = 'Skipped'
        } else {
            # 现有文件哈希不符 -> Failed, 不覆盖.
            $status = 'Failed'
            $errorMessage = '目标文件已存在且哈希不匹配, 请使用 -Force 强制重新下载.'
        }

        return New-ResultRecord -Item $Item -Destination $Target -Status $status `
            -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
            -ExpectedSha256 $expected -ObservedSha256 $observedHash `
            -SignatureStatus $sigStatus -SignerSubject $sigSubject `
            -SignatureError $sigError -Error $errorMessage
    }

    # --- 准备分类目录与 .part 路径.
    if (-not (Test-Path -LiteralPath $categoryDir -PathType Container)) {
        try {
            $null = New-Item -ItemType Directory -Path $categoryDir -Force -ErrorAction Stop
        } catch {
            return New-ResultRecord -Item $Item -Destination $Target -Status 'Failed' `
                -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
                -ExpectedSha256 $expected -ObservedSha256 '' `
                -SignatureStatus '' -SignerSubject '' -SignatureError '' `
                -Error ('无法创建分类目录: {0}' -f $_.Exception.Message)
        }
    }

    $partName = [System.IO.Path]::GetFileName($Target) + '.part'
    $partPath = [System.IO.Path]::Combine($categoryDir, $partName)

    # --- Downloading: 最多 $MaxAttempts 次总尝试.
    $downloaded = $false
    for ($attempt = 1; $attempt -le $script:MaxAttempts; $attempt++) {
        # 清理上次 .part, 保证不会拼接残留.
        if (Test-Path -LiteralPath $partPath -PathType Leaf) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }

        $url = $Item.url.Trim()
        $dl = Invoke-HttpsDownload -Url $url -PartPath $partPath

        if ($dl.Ok) {
            $downloaded = $true
            break
        }

        if ($attempt -lt $script:MaxAttempts) {
            Start-Sleep -Seconds $script:RetryDelaySec
        } else {
            $errorMessage = ('下载失败 (尝试 {0}/{1}): {2}' -f $attempt, $script:MaxAttempts, $dl.Error)
        }
    }

    if (-not $downloaded) {
        if (Test-Path -LiteralPath $partPath -PathType Leaf) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }
        return New-ResultRecord -Item $Item -Destination $Target -Status 'Failed' `
            -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
            -ExpectedSha256 $expected -ObservedSha256 '' `
            -SignatureStatus '' -SignerSubject '' -SignatureError '' `
            -Error $errorMessage
    }

    # --- Verifying: 哈希校验 (在 .part 上计算, 因签名需在最终扩展名上探测).
    $sigStatus    = ''
    $sigSubject   = ''
    $sigError     = ''
    try {
        $observedHash = (Get-FileHash -LiteralPath $partPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch {
        $observedHash = ''
    }

    if (-not [string]::IsNullOrEmpty($expected) `
            -and $observedHash -ne $expected.ToLowerInvariant()) {
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        return New-ResultRecord -Item $Item -Destination $Target -Status 'Failed' `
            -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
            -ExpectedSha256 $expected -ObservedSha256 $observedHash `
            -SignatureStatus '' -SignerSubject '' -SignatureError '' `
            -Error 'SHA-256 校验失败.'
    }

    # --- 原子落盘: 同卷重命名 (Move) 或替换 (Replace).
    # PowerShell 5.1 把 string 参数的 $null 转为空字符串, 而 File.Replace 拒绝空备份路径,
    # 因此显式指定一个同卷备份文件 (与目标同目录, 保证不跨卷), 替换成功后删除备份.
    $targetExists = (Test-Path -LiteralPath $Target -PathType Leaf)
    $backupPath = [System.IO.Path]::Combine($categoryDir, ([System.IO.Path]::GetFileName($Target) + '.bak'))
    $finalized = $false
    try {
        if (-not $targetExists) {
            [System.IO.File]::Move($partPath, $Target)
        } else {
            # -Force: 用 .part 替换旧目标; 旧目标移到 .bak. Replace 要求目标存在, 失败时保留旧文件.
            [System.IO.File]::Replace($partPath, $Target, $backupPath, $false)
            # 替换成功后删除备份, 备份删除失败不影响下载结果.
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            }
        }
        $finalized = $true
    } catch {
        $status = 'Failed'
        $errorMessage = ('最终落盘失败: {0}' -f $_.Exception.Message)
        # 落盘失败时, 若旧目标存在, 记录旧目标完整性.
        if ($targetExists) {
            $oldIntegrity = Get-FileIntegrity -Path $Target
            $observedHash = $oldIntegrity.Sha256
            $sigStatus    = $oldIntegrity.SignatureStatus
            $sigSubject   = $oldIntegrity.SignerSubject
            $sigError     = $oldIntegrity.SignatureError
        } else {
            $observedHash = ''
        }
        # 清理 .part 与 .bak 残留.
        if (Test-Path -LiteralPath $partPath -PathType Leaf) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }

        return New-ResultRecord -Item $Item -Destination $Target -Status $status `
            -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
            -ExpectedSha256 $expected -ObservedSha256 $observedHash `
            -SignatureStatus $sigStatus -SignerSubject $sigSubject `
            -SignatureError $sigError -Error $errorMessage
    }

    # --- 落盘成功后, 在最终目标路径上计算完整性 (含签名, 因扩展名现在正确).
    $integrity = Get-FileIntegrity -Path $Target
    $observedHash = $integrity.Sha256
    $sigStatus    = $integrity.SignatureStatus
    $sigSubject   = $integrity.SignerSubject
    $sigError     = $integrity.SignatureError

    return New-ResultRecord -Item $Item -Destination $Target -Status 'Downloaded' `
        -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
        -ExpectedSha256 $expected -ObservedSha256 $observedHash `
        -SignatureStatus $sigStatus -SignerSubject $sigSubject `
        -SignatureError $sigError -Error ''
}

# ==============================================================================
# Edge 启动
# ==============================================================================

function Find-EdgeExecutable {
    <#
        .SYNOPSIS
            定位 msedge.exe 绝对路径, 按设计文档顺序查找.

        .OUTPUTS
            msedge.exe 绝对路径, 或 $null (未找到).
    #>

    $candidates = @()

    # 1-3. 注册表 App Paths.
    $appPathKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )
    foreach ($key in $appPathKeys) {
        try {
            $val = (Get-ItemProperty -LiteralPath $key -Name '(default)' -ErrorAction Stop).'(default)'
            if (-not [string]::IsNullOrEmpty($val)) {
                # 注册表值常带双引号, 这里去掉.
                $candidates += $val.Trim('"')
            }
        } catch { }
    }

    # 4-5. 常见安装路径.
    $candidates += "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    $candidates += "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"

    foreach ($cand in $candidates) {
        if (-not [string]::IsNullOrEmpty($cand) -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $cand).Path
        }
    }

    return $null
}

function Invoke-OpenEdgeItem {
    <#
        .SYNOPSIS
            用 Edge 打开 CSV 中的 url, 启动后立即返回.
    #>
    param(
        [Parameter(Mandatory)]$Item,
        [string]$EdgePath
    )

    $startedAt = ConvertTo-IsoLocalTime

    if ([string]::IsNullOrEmpty($EdgePath)) {
        return New-ResultRecord -Item $Item -Destination '' -Status 'Failed' `
            -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
            -ExpectedSha256 '' -ObservedSha256 '' `
            -SignatureStatus '' -SignerSubject '' -SignatureError '' `
            -Error '未找到 Microsoft Edge.'
    }

    try {
        # 不使用 -Wait; 只打开 CSV 的 url, 不自动点击或处理浏览器下载.
        $null = Start-Process -FilePath $EdgePath -ArgumentList @($Item.url.Trim()) -ErrorAction Stop
        return New-ResultRecord -Item $Item -Destination '' -Status 'Opened' `
            -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
            -ExpectedSha256 '' -ObservedSha256 '' `
            -SignatureStatus '' -SignerSubject '' -SignatureError '' -Error ''
    } catch {
        return New-ResultRecord -Item $Item -Destination '' -Status 'Failed' `
            -StartedAt $startedAt -FinishedAt (ConvertTo-IsoLocalTime) `
            -ExpectedSha256 '' -ObservedSha256 '' `
            -SignatureStatus '' -SignerSubject '' -SignatureError '' `
            -Error ('Edge 启动失败: {0}' -f $_.Exception.Message)
    }
}

# ==============================================================================
# 结果记录
# ==============================================================================

function New-ResultRecord {
    <#
        .SYNOPSIS
            使用统一列结构构造结果对象.
    #>
    param(
        [Parameter(Mandatory)]$Item,
        [string]$Destination,
        [Parameter(Mandatory)][ValidateSet('Downloaded','Skipped','Opened','Failed')][string]$Status,
        [Parameter(Mandatory)][string]$StartedAt,
        [Parameter(Mandatory)][string]$FinishedAt,
        [string]$ExpectedSha256,
        [string]$ObservedSha256,
        [string]$SignatureStatus,
        [string]$SignerSubject,
        [string]$SignatureError,
        [string]$Error
    )

    return [pscustomobject][ordered]@{
        index             = $Item.RowIndex
        name              = $Item.name.Trim()
        category          = $Item.category.Trim()
        action            = $Item.action.Trim()
        configured_url    = $Item.url.Trim()
        homepage          = $Item.homepage.Trim()
        destination       = $Destination
        status            = $Status
        started_at        = $StartedAt
        finished_at       = $FinishedAt
        expected_sha256   = $ExpectedSha256
        observed_sha256   = $ObservedSha256
        signature_status  = $SignatureStatus
        signer_subject    = $SignerSubject
        signature_error   = $SignatureError
        error             = $Error
    }
}

function Write-ResultReport {
    <#
        .SYNOPSIS
            覆盖写入 download-results.csv, 使用 UTF-8 with BOM.
    #>
    param(
        [Parameter(Mandatory)]$Results,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $path = [System.IO.Path]::Combine($OutputRoot.TrimEnd('\', '/'), 'download-results.csv')

    try {
        # PowerShell 5.1 的 Export-Csv -Encoding UTF8 写入 UTF-8 with BOM.
        $Results | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -Force -ErrorAction Stop
    } catch {
        Write-Host ('结果文件写入失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        throw
    }
}

# ==============================================================================
# 主流程
# ==============================================================================

function Invoke-Main {
    # 解析默认参数.
    if ([string]::IsNullOrEmpty($ConfigPath)) {
        $ConfigPath = [System.IO.Path]::Combine($PSScriptRoot, 'windows-downloads.csv')
    }
    if ([string]::IsNullOrEmpty($OutputDirectory)) {
        $OutputDirectory = [System.IO.Path]::Combine($HOME, 'Downloads', 'WindowsPackages')
    }

    Write-Host '清单: ' -NoNewline; Write-Host $ConfigPath
    Write-Host '输出: ' -NoNewline; Write-Host $OutputDirectory
    if ($Force)  { Write-Host '模式: -Force (已存在目标文件将被覆盖)' }
    if ($WhatIf) { Write-Host '模式: -WhatIf (仅校验并打印计划)' }
    Write-Host ''

    # --- 1. 读取清单.
    try {
        $items = Read-DownloadList -Path $ConfigPath
    } catch {
        Write-Host ('读取清单失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }

    # --- 2. 全量预检.
    $check = Test-DownloadList -Items $items -OutputRoot $OutputDirectory
    if (-not $check.Ok) {
        Write-Host '预检失败, 以下行存在问题:' -ForegroundColor Red
        foreach ($e in $check.Errors) { Write-Host ('  - {0}' -f $e) -ForegroundColor Red }
        Write-Host ''
        Write-Host '预检失败: 不创建输出目录, 不下载, 不打开 Edge, 不写结果文件.' -ForegroundColor Red
        exit 1
    }

    $validated = $check.Items

    # --- 3. WhatIf: 仅打印计划.
    if ($WhatIf) {
        Write-Host '预检通过. 计划 (按 CSV 顺序):' -ForegroundColor Green
        foreach ($item in $validated) {
            if ($item.action.Trim() -eq 'download') {
                $target = Resolve-ItemPath -Item $item
                Write-Host ('  [{0}] download  {1}' -f $item.RowIndex, $item.name.Trim())
                Write-Host ('        url     : {0}' -f $item.url.Trim())
                Write-Host ('        target  : {0}' -f $target)
            } else {
                Write-Host ('  [{0}] open-edge {1}' -f $item.RowIndex, $item.name.Trim())
                Write-Host ('        url     : {0}' -f $item.url.Trim())
            }
        }
        Write-Host ''
        Write-Host 'WhatIf: 未创建目录, 未下载, 未打开 Edge.' -ForegroundColor Green
        exit 0
    }

    # --- 4. 创建输出根目录.
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        try {
            $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
        } catch {
            Write-Host ('无法创建输出目录: {0}' -f $_.Exception.Message) -ForegroundColor Red
            exit 1
        }
    }

    # --- 5. 按顺序处理.
    $results = New-Object System.Collections.ArrayList
    $edgePath = $null  # 仅在首次 open-edge 时解析一次.
    $edgeResolved = $false

    foreach ($item in $validated) {
        $action = $item.action.Trim()
        if ($action -eq 'download') {
            $target = Resolve-ItemPath -Item $item
            $result = Invoke-DownloadItem -Item $item -Target $target -Force:$Force
        } else {
            if (-not $edgeResolved) {
                $edgePath = Find-EdgeExecutable
                $edgeResolved = $true
            }
            $result = Invoke-OpenEdgeItem -Item $item -EdgePath $edgePath
        }
        $null = $results.Add($result)

        # 控制台逐项状态.
        $color = switch ($result.status) {
            'Downloaded' { 'Green' }
            'Skipped'    { 'DarkGray' }
            'Opened'     { 'Cyan' }
            'Failed'     { 'Red' }
            default      { 'White' }
        }
        Write-Host ('  [{0}] {1} -> {2}' -f $result.index, $result.name, $result.status) -ForegroundColor $color
        if ($result.status -eq 'Failed' -and -not [string]::IsNullOrEmpty($result.error)) {
            Write-Host ('        error: {0}' -f $result.error) -ForegroundColor Red
        }
    }

    # --- 6. 写结果文件.
    try {
        Write-ResultReport -Results $results -OutputRoot $OutputDirectory
    } catch {
        exit 1
    }

    # --- 7. 汇总.
    $counts = @{ Downloaded = 0; Skipped = 0; Opened = 0; Failed = 0 }
    foreach ($r in $results) { $counts[$r.status]++ }

    Write-Host ''
    Write-Host ('汇总: Downloaded={0}  Skipped={1}  Opened={2}  Failed={3}' `
        -f $counts.Downloaded, $counts.Skipped, $counts.Opened, $counts.Failed)
    Write-Host ('结果: {0}' -f ([System.IO.Path]::Combine($OutputDirectory.TrimEnd('\', '/'), 'download-results.csv')))

    if ($counts.Failed -gt 0) { exit 1 } else { exit 0 }
}

Invoke-Main
