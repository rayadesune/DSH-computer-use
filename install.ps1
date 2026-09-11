#requires -version 5.1
<#
  dsh-ui (Windows) 安装脚本：把工具装到用户目录并加进 PATH。
  默认装到 %LOCALAPPDATA%\dsh-ui\bin，同时留下 docs / skill 便于本地查阅。

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix D:\tools\dsh-ui
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>
param(
  [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'dsh-ui'),
  [switch]$Uninstall,
  [switch]$NoPath
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
foreach ($d in @('docs', 'skill-win', 'tests')) {
  $from = Join-Path $src $d
  if (Test-Path -LiteralPath $from) {
    $to = Join-Path $Prefix $d
    if (-not (Test-Path -LiteralPath $to)) { [void](New-Item -ItemType Directory -Force -Path $to) }
    Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
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
Write-Host "  程序: $bin\dsh-ui.cmd"
if ($added) {
  Write-Host "  已把 $bin 加入用户 PATH（新开终端生效；当前会话可先执行：`$env:Path += ';$bin'）"
} else {
  Write-Host "  PATH 未改动（已存在或 -NoPath）"
}
Write-Host "  状态: $env:LOCALAPPDATA\dsh-ui  (audit.log / denylist.txt)"
Write-Host ""
Write-Host "验证:" -ForegroundColor Cyan
Write-Host "  dsh-ui displays"
Write-Host "  dsh-ui --dry click 100 200"
Write-Host "  powershell -NoProfile -File `"$Prefix\tests\verify-windows.ps1`"   # 自检（会短暂弹出测试窗口）"
