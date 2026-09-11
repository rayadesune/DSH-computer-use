#requires -version 5.1
<#
  Windows 侧的静态检查：不需要桌面、不需要 Windows API，任何平台上的 pwsh/Windows PowerShell
  都能跑。CI 用它守住本项目实际踩过的两个坑：

    * .ps1 丢了 UTF-8 BOM —— Windows PowerShell 5.1 会按系统 ANSI 代码页解码，
      中文注释吃掉相邻的花括号，脚本直接解析失败；
    * .cmd 里出现非 ASCII —— cmd.exe 按 OEM 代码页解析 .cmd，中文注释会把批处理拆散。

  另外检查：技能 frontmatter 是否可被 DSH 识别、Windows 侧产物是否齐全、
  --help 是否覆盖了分发器里实现的每一条命令。

  用法: pwsh -NoProfile -File tests/sanity-windows.ps1
  退出码: 0 通过 / 1 有失败项
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Continue'
$script:Fail = 0

function Check([string]$Name, [scriptblock]$Body) {
  try {
    $msg = & $Body
    if ($msg) { Write-Host ("  ok    {0}  {1}" -f $Name, $msg) -ForegroundColor Green }
    else { Write-Host ("  ok    " + $Name) -ForegroundColor Green }
  } catch {
    $script:Fail++
    Write-Host ("  FAIL  {0}  {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
  }
}

Write-Host "Windows 静态检查 (root=$Root)"

# ---------------------------------------------------------- 1. BOM ----
Check '.ps1 均带 UTF-8 BOM（否则 PS 5.1 按 GBK 解码）' {
  $files = @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
  $files += @(Get-ChildItem -LiteralPath (Join-Path $Root 'tests') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
  if ($files.Count -eq 0) { throw '一个 .ps1 都没找到，路径不对？' }
  $bad = @()
  foreach ($f in $files) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $bad += $f.Name }
  }
  if ($bad.Count -gt 0) { throw ("缺 BOM: " + ($bad -join ', ')) }
  return ("$($files.Count) 个文件")
}

# --------------------------------------------------- 2. .cmd 纯 ASCII ----
Check '.cmd 为纯 ASCII（cmd.exe 按 OEM 代码页解析批处理）' {
  $cmd = Join-Path $Root 'dsh-ui.cmd'
  if (-not (Test-Path -LiteralPath $cmd)) { throw '缺少 dsh-ui.cmd' }
  $b = [System.IO.File]::ReadAllBytes($cmd)
  $bad = @($b | Where-Object { $_ -gt 127 })
  if ($bad.Count -gt 0) { throw ("发现 $($bad.Count) 个非 ASCII 字节") }
  return ("$($b.Length) 字节全 ASCII")
}

# ------------------------------------------------- 3. Windows 产物齐全 ----
Check 'Windows 侧产物齐全' {
  $need = @('dsh-ui.ps1', 'dsh-ui.cmd', 'install.ps1',
    'docs/REFERENCE-WINDOWS.md', 'docs/VERIFICATION-WINDOWS.md',
    'skill-win/SKILL.md', 'tests/verify-windows.ps1', 'tests/ui-target.ps1')
  $missing = @()
  foreach ($n in $need) { if (-not (Test-Path -LiteralPath (Join-Path $Root $n))) { $missing += $n } }
  if ($missing.Count -gt 0) { throw ("缺少: " + ($missing -join ', ')) }
  return ("$($need.Count) 个文件都在")
}

# ------------------------------------------------------ 4. skill 头 ----
Check 'skill-win 的 frontmatter 能被 DSH 识别' {
  $p = Join-Path $Root 'skill-win/SKILL.md'
  $head = @([System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8) | Select-Object -First 6)
  if (-not ($head | Where-Object { $_ -match '^name:\s*dsh-windows-ui\s*$' })) { throw '前 6 行里没有 name: dsh-windows-ui' }
  if (-not ($head | Where-Object { $_ -match '^description:\s*\S' })) { throw '前 6 行里没有 description:' }
  if ($head[0].Trim() -ne '---') { throw '第一行不是 frontmatter 分隔符 ---' }
  return 'name/description/--- 都在'
}

# ----------------------------------------------------- 5. --help 覆盖 ----
Check '--help 覆盖分发器里的每一条命令' {
  $src = [System.IO.File]::ReadAllText((Join-Path $Root 'dsh-ui.ps1'), [System.Text.Encoding]::UTF8)

  $dStart = $src.IndexOf('function Invoke-Dispatch')
  if ($dStart -lt 0) { throw '找不到 Invoke-Dispatch' }
  $dEnd = $src.IndexOf("`n}", $dStart)
  $dispatch = $src.Substring($dStart, $dEnd - $dStart)

  # 分发器里的 case 标签就是权威命令表
  $cmds = @()
  foreach ($m in [regex]::Matches($dispatch, "(?m)^\s{4}'([^']+)'\s*\{")) { $cmds += $m.Groups[1].Value }
  $cmds = @($cmds | Where-Object { $_ -notmatch '^-' -and $_ -ne 'help' } | Sort-Object -Unique)
  if ($cmds.Count -lt 10) { throw "只解析出 $($cmds.Count) 条命令，解析逻辑可能失效了" }

  $hStart = $src.IndexOf("`$script:HelpText = @'")
  if ($hStart -lt 0) { throw '找不到 HelpText' }
  $hEnd = $src.IndexOf("'@", $hStart)
  $help = $src.Substring($hStart, $hEnd - $hStart)

  $missing = @()
  # 必须出现在**行首**才算数：纯子串匹配会被 "underX" 这类残留骗过去（本脚本自测时踩到过）
  foreach ($c in $cmds) {
    if ($help -notmatch ("(?m)^\s*" + [regex]::Escape($c) + '\b')) { $missing += $c }
  }
  if ($missing.Count -gt 0) { throw ("--help 未覆盖: " + ($missing -join ', ')) }
  return ("$($cmds.Count) 条命令都有说明")
}

Write-Host ""
if ($script:Fail -gt 0) {
  Write-Host ("静态检查失败: $($script:Fail) 项") -ForegroundColor Red
  exit 1
}
Write-Host "静态检查全部通过" -ForegroundColor Green
exit 0
