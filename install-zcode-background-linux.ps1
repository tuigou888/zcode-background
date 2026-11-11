[CmdletBinding()]
param(
    # 桌面启动器路径（Linux 用 .desktop，非 Windows 的 .lnk）。
    [string]$ShortcutPath = (Join-Path $HOME ".local/share/applications/zcode-background.desktop"),

    # 背景启动脚本默认与本安装脚本放在同一目录。
    [string]$LauncherPath = (Join-Path $PSScriptRoot "zcode-background.ps1"),

    # 背景模式：image（固定单图）/ random（目录混合随机）/ video（目录随机视频）。
    [ValidateSet("image", "random", "video")]
    [string]$BackgroundMode = "random",

    # image 模式：固定图片路径；默认指向脚本同级 assets 示例图。
    [string]$ImagePath = (Join-Path $PSScriptRoot "assets/sample-background.jpg"),

    # random / video 模式：媒体目录（图片视频可混放）；默认指向脚本同级 assets。
    [string]$MediaDirectory = (Join-Path $PSScriptRoot "assets"),

    # 写入启动器的背景透明度（兜底默认值）；图片/视频可分别用下面两个参数覆盖。
    [ValidateRange(0.01, 1.0)]
    [double]$Opacity = 0.15,

    # 图片背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$ImageOpacity = 0,

    # 视频背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$VideoOpacity = 0,

    # 运行时轮换间隔（秒），默认 60 分钟；0 = 不轮换。
    [ValidateRange(0, 86400)]
    [int]$RotateInterval = 3600,

    # ZCode 使用的本地 Chrome DevTools Protocol 端口。
    [ValidateRange(1, 65535)]
    [int]$DebugPort = 9230,

    # 本地媒体 HTTP 服务起始端口；被占用自动 +1。
    [ValidateRange(1, 65535)]
    [int]$MediaPort = 9231,

    # ZCode 主程序路径；留空时自动探测（进程 → PATH → /opt 等常见位置）。
    [string]$ZCodePath = "",

    # PowerShell 7 路径；留空时用 PATH 里的 pwsh，找不到则自动下载到 ~/.local。
    [string]$PwshPath = "",

    # 找不到 pwsh 时禁止自动下载安装（直接报错）。
    [switch]$SkipPwshInstall
)

$ErrorActionPreference = "Stop"

function Find-ZCodeExecutable {
    # Linux 自动探测 ZCode 主程序路径。
    # 优先级：运行中进程 → PATH 上的 zcode → 常见安装路径。
    $proc = Get-Process -Name "ZCode","zcode" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        try {
            if ($proc.Path -and (Test-Path -LiteralPath $proc.Path -PathType Leaf)) {
                return $proc.Path
            }
        } catch {}
    }

    $inPath = Get-Command "zcode" -ErrorAction SilentlyContinue
    if ($inPath) {
        try {
            $item = Get-Item -LiteralPath $inPath.Source -ErrorAction Stop
            $resolved = if ($item.LinkType) { $item.ResolveTarget().Path } else { $item.FullName }
            if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                return $resolved
            }
        } catch {}
    }

    # 常见的 deb / 手动解压安装位置。
    $candidates = @(
        "/opt/ZCode/zcode",
        "/usr/lib/ZCode/zcode",
        "/usr/local/bin/zcode",
        "/snap/zcode/current/zcode",
        "/usr/bin/zcode"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Find-PwshExecutable {
    # 现有的系统/用户 pwsh。
    $inPath = Get-Command "pwsh" -ErrorAction SilentlyContinue
    if ($inPath) {
        try {
            $item = Get-Item -LiteralPath $inPath.Source -ErrorAction Stop
            $resolved = if ($item.LinkType) { $item.ResolveTarget().Path } else { $item.FullName }
            if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                return @{ Path = $resolved; Installed = $false }
            }
        } catch {}
    }
    # 上次自动安装留下的目录。
    $localRoot = Join-Path $HOME ".local/share/powershell"
    $localPwsh = Join-Path $localRoot "pwsh"
    if (Test-Path -LiteralPath $localPwsh -PathType Leaf) {
        return @{ Path = $localPwsh; Installed = $false }
    }
    return $null
}

function Install-PwshLocal {
    # 从 GitHub Releases 下载官方 linux-x64 tar.gz，解压到 ~/.local/share/powershell，
    # 并链接 ~/.local/bin/pwsh。无需 root，不依赖 snap/apt。
    param([string]$LocalRoot = (Join-Path $HOME ".local/share/powershell"))

    $destBin = Join-Path $HOME ".local/bin"
    New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $destBin -Force | Out-Null

    Write-Host "正在下载 PowerShell 7（官方 GitHub Releases）..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -TimeoutSec 30
    $asset = @($release.assets | Where-Object { $_.name -match "linux-x64.*\.tar\.gz$" }) | Select-Object -First 1
    if (-not $asset) {
        throw "未找到 PowerShell linux-x64 发布包。"
    }

    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpFile -TimeoutSec 600

    $tmpExtract = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-" + [Guid]::NewGuid().ToString("N"))
    Expand-Archive -LiteralPath $tmpFile -DestinationPath $tmpExtract -Force

    $pwshBinary = Join-Path $tmpExtract "pwsh"
    if (-not (Test-Path -LiteralPath $pwshBinary -PathType Leaf)) {
        throw "发布包内容异常：未找到 pwsh 可执行文件。"
    }

    # 清空后整目录替换，避免旧版本残留。
    Remove-Item -LiteralPath $LocalRoot -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $tmpExtract | Copy-Item -Destination $LocalRoot -Recurse -Force
    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue

    $localPwsh = Join-Path $LocalRoot "pwsh"
    if ($IsLinux) {
        chmod +x $localPwsh 2>$null
    }
    # ~/.local/bin/pwsh 链接到解压目录，保证后续 .desktop Exec 稳定可引用。
    $linkPath = Join-Path $destBin "pwsh"
    Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $localPwsh -Force | Out-Null

    return $localPwsh
}

function ConvertTo-DesktopArg {
    # 按 Desktop Entry 规范的 Exec 字段转义并加引号。
    param([Parameter(Mandatory)][string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('`', '\`').Replace('"', '\"').Replace('$', '\$').Replace('%', '\%')
    return '"' + $escaped + '"'
}

try {
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        throw "背景启动脚本不存在：$LauncherPath"
    }

    # 按模式校验资源（与 Windows 版安装脚本一致）。
    $resolvedMediaPath = ""
    if ($BackgroundMode -eq "image" -and [string]::IsNullOrWhiteSpace($MediaDirectory)) {
        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw "背景图片不存在：$ImagePath"
        }
        $resolvedMediaPath = (Resolve-Path -LiteralPath $ImagePath).Path
    }
    else {
        if ([string]::IsNullOrWhiteSpace($MediaDirectory)) {
            throw "$BackgroundMode 模式必须指定 -MediaDirectory 参数。"
        }
        if (-not (Test-Path -LiteralPath $MediaDirectory -PathType Container)) {
            throw "媒体目录不存在：$MediaDirectory"
        }
    }

    # ZCode 路径：未指定或不存在时自动探测。
    if ([string]::IsNullOrWhiteSpace($ZCodePath) -or -not (Test-Path -LiteralPath $ZCodePath -PathType Leaf)) {
        if (-not [string]::IsNullOrWhiteSpace($ZCodePath)) {
            Write-Warning "指定的 ZCode 路径不存在，尝试自动探测：$ZCodePath"
        }
        $detected = Find-ZCodeExecutable
        if ($detected) {
            $ZCodePath = $detected
            Write-Host "已自动探测到 ZCode：$ZCodePath"
        } else {
            throw "未找到 ZCode 安装路径。请用 -ZCodePath 参数手动指定。"
        }
    }
    $resolvedZCodePath = (Resolve-Path -LiteralPath $ZCodePath).Path

    # PowerShell 7：显式路径 → PATH → 自动下载到 ~/.local。
    if (-not [string]::IsNullOrWhiteSpace($PwshPath)) {
        if (-not (Test-Path -LiteralPath $PwshPath -PathType Leaf)) {
            throw "指定的 PowerShell 路径不存在：$PwshPath"
        }
        $resolvedPwshPath = (Resolve-Path -LiteralPath $PwshPath).Path
    } else {
        $pwshInfo = Find-PwshExecutable
        if ($pwshInfo) {
            $resolvedPwshPath = $pwshInfo.Path
        } else {
            if ($SkipPwshInstall) {
                throw "未找到 pwsh，已按 -SkipPwshInstall 跳过自动安装。请先安装 PowerShell 7。"
            }
            $resolvedPwshPath = Install-PwshLocal
            Write-Host "已安装 PowerShell 7：$resolvedPwshPath"
        }
    }

    $resolvedLauncherPath = (Resolve-Path -LiteralPath $LauncherPath).Path
    $resolvedMediaDirectory = if ($MediaDirectory) { (Resolve-Path -LiteralPath $MediaDirectory).Path } else { "" }
    $opacityLiteral = $Opacity.ToString("0.################", [Globalization.CultureInfo]::InvariantCulture)

    # 模式相关参数（与 Windows 版一致：image 支持目录轮换图片或固定单图）。
    $modeTokens = if ($BackgroundMode -eq "image" -and [string]::IsNullOrWhiteSpace($MediaDirectory)) {
        @("-BackgroundMode", "image", "-ImagePath", (ConvertTo-DesktopArg $resolvedMediaPath))
    } else {
        @("-BackgroundMode", $BackgroundMode, "-MediaDirectory", (ConvertTo-DesktopArg $resolvedMediaDirectory))
    }

    $opacityTokens = @("-Opacity", $opacityLiteral)
    if ($ImageOpacity -gt 0) {
        $opacityTokens += @("-ImageOpacity", $ImageOpacity.ToString("0.################", [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($VideoOpacity -gt 0) {
        $opacityTokens += @("-VideoOpacity", $VideoOpacity.ToString("0.################", [Globalization.CultureInfo]::InvariantCulture))
    }

    $execParts = @(
        (ConvertTo-DesktopArg $resolvedPwshPath),
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (ConvertTo-DesktopArg $resolvedLauncherPath),
        "-ZCodePath", (ConvertTo-DesktopArg $resolvedZCodePath)
    ) + $modeTokens + $opacityTokens + @(
        "-RotateInterval", "$RotateInterval",
        "-MediaPort", "$MediaPort",
        "-DebugPort", "$DebugPort"
    )
    $execLine = $execParts -join " "

    $desktopContent = @"
[Desktop Entry]
Type=Application
Name=ZCode Background
Comment=带图片/视频背景的 ZCode（模式：$BackgroundMode）
Exec=$execLine
Icon=zcode
Terminal=false
StartupWMClass=ZCode
Categories=Development;
"@

    $shortcutDir = Split-Path -Parent $ShortcutPath
    if (-not (Test-Path -LiteralPath $shortcutDir -PathType Container)) {
        New-Item -ItemType Directory -Path $shortcutDir -Force | Out-Null
    }
    [IO.File]::WriteAllText($ShortcutPath, $desktopContent, [Text.UTF8Encoding]::new($false))
    if ($IsLinux) {
        chmod +x $ShortcutPath 2>$null
    }

    # 让桌面环境/应用菜单感知新的 .desktop（存在 xdg-utils 时）。
    if (Get-Command "update-desktop-database" -ErrorAction SilentlyContinue) {
        & update-desktop-database $shortcutDir 2>$null
    }

    Write-Host "已创建 ZCode 背景启动器：$ShortcutPath"
    Write-Host "背景模式：$BackgroundMode"
    if ($BackgroundMode -eq "image") {
        Write-Host "图片：$resolvedMediaPath"
    } else {
        Write-Host "媒体目录：$resolvedMediaDirectory"
    }
    if ($ImageOpacity -gt 0 -and $VideoOpacity -gt 0) {
        Write-Host "透明度：图片 $ImageOpacity / 视频 $VideoOpacity"
    } else {
        Write-Host "透明度：$Opacity（图片视频统一）"
    }
    Write-Host "轮换间隔：$(if ($RotateInterval -gt 0) { "$RotateInterval 秒" } else { "关闭" })"
    Write-Host "PowerShell：$resolvedPwshPath"
    Write-Host "ZCode：$resolvedZCodePath"
    Write-Host ""
    Write-Host "从桌面应用菜单点击「ZCode Background」即可启动（会先关闭再重启 ZCode）。"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}