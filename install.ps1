#requires -version 5.1
<#
  dsh-ui (Windows) 安装脚本：把 dsh-ui.ps1 + dsh-ui.cmd 装到 bin 目录并加进用户 PATH。
  默认只装可执行文件（与 macOS 版 install.sh 一致，文档与 skill 留在仓库里）。

  路径怎么选（对应 macOS 的 ~/.local/bin）：
    -Prefix "$env:USERPROFILE\.local"   -> 装到 %USERPROFILE%\.local\bin
                                           与 mac 的 ~/.local/bin 一一对应，推荐
    -Prefix "$env:LOCALAPPDATA\dsh-ui"  -> 装到 %LOCALAPPDATA%\dsh-ui\bin（Windows 原生用户级，默认）

  给 agent 用的 skill 是**另一件事**：DSH 从 %USERPROFILE%\.dsh\skills\<name>\SKILL.md 读全局技能
  （对应 macOS 版 Makefile 里的 SKILL_DEST），所以要加 -WithSkill 才会同步过去。

  用法:
    # 装二进制 + 同步全局 skill（推荐）
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix "$env:USERPROFILE\.local" -WithSkill
    # 只装二进制 / 连文档一起装 / 换技能目录
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix "$env:USERPROFILE\.local"
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix D:\tools\dsh-ui -WithDocs
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -SkillDest D:\skills\dsh-windows-ui -WithSkill
    # 卸载
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Prefix "$env:USERPROFILE\.local" -Uninstall
#>
param(
  [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'dsh-ui'),
  [switch]$Uninstall,
  [switch]$NoPath,
  [switch]$WithDocs,
  [switch]$WithSkill,
  [string]$SkillDest = (Join-Path $env:USERPROFILE '.dsh\skills\dsh-windows-ui')
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

# 全局 skill：DSH 从 <home>/.dsh/skills/<name>/SKILL.md 读用户级技能
# （源码 packages/skill/skill-filesystem：user-dsh = join(dshHome,'skills')），
# 与 macOS 版 Makefile 的 SKILL_DEST 是同一个约定。
$skillInstalled = $false
if ($WithSkill) {
  $skillSrc = Join-Path $src 'skill-win\SKILL.md'
  if (-not (Test-Path -LiteralPath $skillSrc)) { throw "缺少 skill: $skillSrc" }
  $null = New-Item -ItemType Directory -Force -Path $SkillDest
  Copy-Item -LiteralPath $skillSrc -Destination (Join-Path $SkillDest 'SKILL.md') -Force
  # 校验落地的技能头能解析出 name（写错 frontmatter 的 skill 会被 DSH 悄悄忽略）
  $head = [System.IO.File]::ReadAllLines((Join-Path $SkillDest 'SKILL.md'), [System.Text.Encoding]::UTF8)
  $nameLine = @($head | Select-Object -First 6 | Where-Object { $_ -match '^name:\s*\S' })[0]
  if (-not $nameLine) { throw "落地的 SKILL.md 前 6 行里没有 name: 字段：$SkillDest" }
  $skillInstalled = $true
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
if ($skillInstalled) {
  Write-Host "  全局 skill: $SkillDest\SKILL.md  ($nameLine)"
} else {
  Write-Host "  全局 skill: 未装（加 -WithSkill 同步到 $SkillDest）" -ForegroundColor DarkYellow
}
Write-Host ""
Write-Host "验证:" -ForegroundColor Cyan
Write-Host "  dsh-ui displays"
Write-Host "  dsh-ui --dry click 100 200"
if (-not $WithDocs) {
  Write-Host "  （文档与验证套件留在仓库里；想一并装到 $Prefix 请加 -WithDocs）" -ForegroundColor DarkGray
} else {
  Write-Host "  powershell -NoProfile -File `"$Prefix\tests\verify-windows.ps1`"   # 自检（会短暂弹出测试窗口）"
}
