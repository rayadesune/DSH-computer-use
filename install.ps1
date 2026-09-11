#requires -version 5.1
<#
  dsh-ui (Windows) 安装脚本：把 dsh-ui.ps1 + dsh-ui.cmd 装到 bin 目录并加进用户 PATH。
  默认只装可执行文件（与 macOS 版 install.sh 一致，文档与 skill 留在仓库里）。

  路径怎么选（对应 macOS 的 ~/.local/bin）：
    -Prefix "$env:USERPROFILE\.local"   -> 装到 %USERPROFILE%\.local\bin
                                           与 mac 的 ~/.local/bin 一一对应，推荐
    -Prefix "$env:LOCALAPPDATA\dsh-ui"  -> 装到 %LOCALAPPDATA%\dsh-ui\bin（Windows 原生用户级，默认）

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix "$env:USERPROFILE\.local"
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix D:\tools\dsh-ui -WithDocs
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix "$env:USERPROFILE\.local" -Uninstall
#>
param(
  [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'dsh-ui'),
  [switch]$Uninstall,
  [switch]$NoPath,
  [switch]$WithDocs
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$bin = Join-Path $Prefix 'bin'

function Add-UserPath([string]$Dir) {
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($null -eq $cur) { $cur = '' }
  $parts = @($cur.Split(';') | Where-Object { $_ -ne '' })
  foreach ($p in $parts) { if ($p.TrimEnd('\') -ieq $Dir.TrimEnd('\')) { return $false } }
  $new = (@($parts) + $Dir) -join ';'
  [Environment]::SetEnvironmentVariable('Path', $new, 'User')
  return $true
}

function Remove-UserPath([string]$Dir) {
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($null -eq $cur) { return $false }
  $parts = @($cur.Split(';') | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ine $Dir.TrimEnd('\') })
  [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
  return $true
}

if ($Uninstall) {
  if (Test-Path -LiteralPath $bin) { Remove-Item -LiteralPath $bin -Recurse -Force }
  [void](Remove-UserPath $bin)
  Write-Host "已卸载: $bin" -ForegroundColor Green
  Write-Host "（审计日志与拦截名单保留在 $env:LOCALAPPDATA\dsh-ui，需要的话手动删）"
  exit 0
}

[void](New-Item -ItemType Directory -Force -Path $bin)
foreach ($f in @('dsh-ui.ps1', 'dsh-ui.cmd')) {
  $from = Join-Path $src $f
  if (-not (Test-Path -LiteralPath $from)) { throw "缺少文件: $from" }
  Copy-Item -LiteralPath $from -Destination (Join-Path $bin $f) -Force
}
# 默认只装可执行文件（macOS 版 install.sh 也只装二进制，文档与 skill 留在仓库里）。
# 加 -WithDocs 才会把 docs / skill-win / tests 一并复制到 $Prefix 下。
if ($WithDocs) {
  foreach ($d in @('docs', 'skill-win', 'tests')) {
    $from = Join-Path $src $d
    if (Test-Path -LiteralPath $from) {
      $to = Join-Path $Prefix $d
      if (-not (Test-Path -LiteralPath $to)) { [void](New-Item -ItemType Directory -Force -Path $to) }
      Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
    }
  }
}

# 校验副本仍然可解析（BOM 丢失会让 PS 5.1 解析失败，这里当场发现）
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $bin 'dsh-ui.ps1'), [ref]$null, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
  throw ("复制后的 dsh-ui.ps1 解析失败（多半是 BOM 丢了）：" + $errors[0].Message)
}

$added = $false
if (-not $NoPath) { $added = Add-UserPath $bin }

Write-Host ""
Write-Host "dsh-ui (Windows) 已安装" -ForegroundColor Green
Write-Host "  程序: $bin\dsh-ui.cmd  (同目录下还有 dsh-ui.ps1)"
if ($added) {
  Write-Host "  已把 $bin 加入用户 PATH（新开终端生效；当前会话可先执行：`$env:Path += ';$bin'）"
} else {
  Write-Host "  PATH 未改动（$bin 已在用户 PATH 里，或指定了 -NoPath）"
}
Write-Host "  状态: $env:LOCALAPPDATA\dsh-ui  (audit.log / denylist.txt)"
Write-Host ""
Write-Host "验证:" -ForegroundColor Cyan
Write-Host "  dsh-ui displays"
Write-Host "  dsh-ui --dry click 100 200"
if (-not $WithDocs) {
  Write-Host "  （文档与验证套件留在仓库里；想一并装到 $Prefix 请加 -WithDocs）" -ForegroundColor DarkGray
} else {
  Write-Host "  powershell -NoProfile -File `"$Prefix\tests\verify-windows.ps1`"   # 自检（会短暂弹出测试窗口）"
}
