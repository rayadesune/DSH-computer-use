<#
  dsh-ui (Windows) 自动化验证套件。

  设计原则：
  - 只操作「自己启动的测试靶窗口」(tests/ui-target.ps1)，不碰用户的窗口；输入类测试全部打在自己人身上。
  - 每个断言都回到**状态文件**取证：点击是否真的落到按钮上、输入进去的字是不是原文、拖拽的真实起止点。
  - 只读类命令（shot/diff/find-text/find-ax/wait-for/under/displays）直接在真实桌面上跑。

  用法:
    pwsh -NoProfile -File tests/verify-windows.ps1                # 全量
    pwsh -NoProfile -File tests/verify-windows.ps1 -SkipInput     # 跳过真实输入类
    pwsh -NoProfile -File tests/verify-windows.ps1 -AlsoPs51      # 额外验证 Windows PowerShell 5.1 宿主
#>
param(
  [switch]$SkipInput,
  [switch]$AlsoPs51,
  [string]$ResultFile = "$PSScriptRoot\results-windows.json"
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$Root = Split-Path -Parent $PSScriptRoot
$Tool = Join-Path $Root 'dsh-ui.ps1'
$TargetScript = Join-Path $PSScriptRoot 'ui-target.ps1'
# 每次运行用独立的状态文件：万一上一次被中断（Ctrl+C / 上游管道被掐断）留下了孤儿靶子，
# 两个靶子写同一个文件会互相盖掉，出现"区域对不上 / 找不到标签"这类假失败。
$StateFile = Join-Path $env:TEMP ("dsh-ui-verify-state-{0}.json" -f $PID)
$DenyFile = Join-Path $env:LOCALAPPDATA 'dsh-ui\denylist.txt'
$AuditFile = Join-Path $env:LOCALAPPDATA 'dsh-ui\audit.log'
$WorkDir = Join-Path $env:TEMP 'dsh-ui-verify'
if (-not (Test-Path $WorkDir)) { [void](New-Item -ItemType Directory -Force -Path $WorkDir) }

# 清掉上次中断留下的孤儿靶子进程
function Remove-StaleTargets {
  try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -like '*ui-target.ps1*' })
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    return $procs.Count
  } catch { return 0 }
}
$staleCount = Remove-StaleTargets
if ($staleCount -gt 0) { Write-Host "已清理上次残留的测试靶进程: $staleCount 个" -ForegroundColor DarkYellow }

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:Results = New-Object System.Collections.ArrayList
$script:CurrentGroup = ''

function Group([string]$Name) {
  $script:CurrentGroup = $Name
  Write-Host ""
  Write-Host "== $Name" -ForegroundColor Yellow
}

function T([string]$Name, [scriptblock]$Body) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $err = $null
  try { & $Body | Out-Null } catch { $err = $_.Exception.Message }
  $sw.Stop()
  $status = 'PASS'
  if ($err) { $status = 'FAIL' }
  if ($status -eq 'PASS') { $script:Pass++ } else { $script:Fail++ }
  [void]$script:Results.Add([ordered]@{ group = $script:CurrentGroup; name = $Name; status = $status
      ms = $sw.ElapsedMilliseconds; detail = $err })
  $color = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
  Write-Host ("  {0}  {1}  ({2}ms)" -f $status, $Name, $sw.ElapsedMilliseconds) -ForegroundColor $color
  if ($err) { Write-Host ("        -> $err") -ForegroundColor Red }
}

function Skip([string]$Name, [string]$Why) {
  $script:Skip++
  [void]$script:Results.Add([ordered]@{ group = $script:CurrentGroup; name = $Name; status = 'SKIP'; ms = 0; detail = $Why })
  Write-Host ("  SKIP  {0}  ({1})" -f $Name, $Why) -ForegroundColor DarkYellow
}

function Assert([bool]$Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function Assert-Match([string]$Text, [string]$Pattern, [string]$What) {
  if ($Text -notmatch $Pattern) { throw ("$What 不匹配 /$Pattern/：`n" + $Text) }
}

# 调用工具，返回 @{ Out = 行数组; Text = 全文; Code = 退出码 }
function Invoke-Tool {
  param([string[]]$Command, [string]$Exe = 'pwsh', [switch]$Quiet)
  if ($Exe -eq 'ps51') {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tool @Command 2>&1
  } else {
    $out = & pwsh -NoProfile -File $Tool @Command 2>&1
  }
  $code = $LASTEXITCODE
  $lines = @($out | ForEach-Object { [string]$_ })
  $text = ($lines -join "`n")
  if (-not $Quiet) {
    $preview = $text
    if ($preview.Length -gt 400) { $preview = $preview.Substring(0, 400) + '…' }
    Write-Host ("        $ $($Command -join ' ')  -> exit=$code") -ForegroundColor DarkGray
    foreach ($l in ($preview -split "`n")) { Write-Host ("          " + $l) -ForegroundColor DarkGray }
  }
  return [pscustomobject]@{ Out = $lines; Text = $text; Code = $code }
}

function Get-TargetState {
  if (-not (Test-Path -LiteralPath $StateFile)) { throw "状态文件不存在: $StateFile" }
  $raw = [System.IO.File]::ReadAllText($StateFile, [System.Text.Encoding]::UTF8)
  return ($raw | ConvertFrom-Json)
}

# 测试靶自己报出来的控件矩形（物理像素）。Panel/GroupBox/ListBox 对 UIA 不可见，
# 这几个控件的落点只能由靶子提供。
function Get-CtlRect {
  param([string]$Name)
  $s = Get-TargetState
  $c = $s.controls.$Name
  if ($null -eq $c) { throw "状态文件里没有控件 $Name 的矩形" }
  return @([int]$c[0], [int]$c[1], [int]$c[2], [int]$c[3])
}

# 从 find-ax --json 里取出某个控件
function Get-AxControl {
  param([string]$Name, [int]$TargetPid)
  $r = Invoke-Tool -Command @('find-ax', $Name, '--pid', "$TargetPid", '--json', '--max', '40') -Quiet
  if ($r.Code -ne 0) { throw ("find-ax '$Name' 退出 $($r.Code)：$($r.Text)") }
  $obj = $r.Text | ConvertFrom-Json
  foreach ($m in $obj.matches) { if ($m.name -eq $Name) { return $m } }
  if ($obj.matches.Count -gt 0) { return $obj.matches[0] }
  throw "find-ax 没有返回 '$Name' 的匹配"
}

function Click-Point {
  param([int]$X, [int]$Y)
  $r = Invoke-Tool -Command @('click', "$X", "$Y") -Quiet
  if ($r.Code -ne 0) { throw "click $X $Y 退出 $($r.Code)：$($r.Text)" }
}

# --------------------------------------------------------------- setup ----
Write-Host "dsh-ui (Windows) 验证套件" -ForegroundColor Cyan
Write-Host "工具: $Tool"
Write-Host "宿主: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"

$denyBackup = $null
if (Test-Path -LiteralPath $DenyFile) { $denyBackup = [System.IO.File]::ReadAllText($DenyFile, [System.Text.Encoding]::UTF8) }

$target = $null
$prevCursor = $null
$scale = 1.0
try {
  $prevCursor = (Invoke-Tool -Command @('pos') -Quiet).Text

  # 桌面几何
  $disp = (Invoke-Tool -Command @('displays', '--json') -Quiet)
  Assert ($disp.Code -eq 0) "displays --json 退出 $($disp.Code)"
  $dispObj = $disp.Text | ConvertFrom-Json
  $scale = [double]$dispObj.displays[0].scale

  # 启动测试靶
  Remove-Item -LiteralPath $StateFile -ErrorAction SilentlyContinue
  $target = Start-Process powershell.exe -PassThru -ArgumentList @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $TargetScript, '-StateFile', $StateFile) -WindowStyle Normal
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StateFile)) { Start-Sleep -Milliseconds 200 }
  Assert (Test-Path -LiteralPath $StateFile) '测试靶没有写出状态文件'
  Start-Sleep -Milliseconds 600
  $st = Get-TargetState
  $tpid = [int]$st.pid
  Write-Host "测试靶: pid=$tpid scale=$scale" -ForegroundColor Cyan

  # ============================================================ A. CLI ===
  Group 'A. CLI 基线 / 退出码 / 审计'

  T 'help 覆盖所有已分发命令' {
    $r = Invoke-Tool -Command @('--help') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)"
    $cmds = @('move', 'click', 'tap', 'press', 'dclick', 'rclick', 'drag', 'scroll', 'type', 'keys', 'key',
      'pos', 'shot', 'displays', 'find-text', 'find-ax', 'win', 'wait-for', 'diff', 'clipboard', 'batch', 'guard', 'under', '--dry')
    $missing = @()
    foreach ($c in $cmds) { if ($r.Text -notmatch [regex]::Escape($c)) { $missing += $c } }
    Assert ($missing.Count -eq 0) ("--help 未覆盖: " + ($missing -join ', '))
  }

  T 'displays 文本 + JSON' {
    $r = Invoke-Tool -Command @('displays') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)"
    Assert-Match $r.Text 'px=\d+x\d+ .*scale=' 'displays 输出'
    Assert ($dispObj.displays.Count -ge 1) 'displays --json 没有显示器'
    Assert ($null -ne $dispObj.displays[0].origin_tl) 'displays --json 缺 origin_tl'
  }

  T 'pos 打印光标（左上原点）' {
    $r = Invoke-Tool -Command @('pos') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)"
    Assert-Match $r.Text '^ok cursor=\(-?\d+,-?\d+\) top-left-coords$' 'pos 输出'
  }

  T '用法错误 exit=2（非数字坐标 / 未知选项 / 未知命令）' {
    $a = Invoke-Tool -Command @('move', 'foo', 'bar') -Quiet
    Assert ($a.Code -eq 2) "move foo bar exit=$($a.Code)"
    $b = Invoke-Tool -Command @('click', '10', '20', '--bogus') -Quiet
    Assert ($b.Code -eq 2) "click --bogus exit=$($b.Code)"
    $c = Invoke-Tool -Command @('definitely-not-a-command') -Quiet
    Assert ($c.Code -eq 2) "未知命令 exit=$($c.Code)"
  }

  T '未命中 exit=1（find-text 查不到）' {
    $r = Invoke-Tool -Command @('find-text', 'ZZZ-NOPE-12345', '-R', '0,0,200,120') -Quiet
    Assert ($r.Code -eq 1) "exit=$($r.Code)"
  }

  T '审计日志逐条落盘' {
    Assert (Test-Path -LiteralPath $AuditFile) '审计日志不存在'
    $lines = [System.IO.File]::ReadAllLines($AuditFile, [System.Text.Encoding]::UTF8)
    Assert ($lines.Count -gt 0) '审计日志为空'
    $last = $lines[$lines.Count - 1]
    Assert-Match $last 'code=\d+ pid=\d+ dry=[01] cmd=' '审计行格式'
    $hit = $false
    foreach ($l in $lines) { if ($l -match 'cmd=.*find-text ZZZ-NOPE-12345') { $hit = $true } }
    Assert $hit '审计日志里没有刚跑过的 find-text'
  }

  T '--dry 矩阵：每条输入类命令都只打印动作、不执行' {
    $cases = @(
      @{ a = @('--dry', 'move', '100', '200'); re = '(?m)^dry: would move \(100,200\)$' },
      @{ a = @('--dry', 'click', '100', '200'); re = '(?m)^dry: would click \(100,200\) hold=30ms$' },
      @{ a = @('--dry', 'click', '100', '200', '--no-activate'); re = '(?m)^dry: would click \(100,200\) hold=30ms no-activate$' },
      @{ a = @('--dry', 'tap', '10', '20'); re = '(?m)^dry: would tap \(10,20\) hold=60ms$' },
      @{ a = @('--dry', 'press', '10', '20'); re = '(?m)^dry: would press \(10,20\) hold=800ms$' },
      # dclick/rclick 的 dry 行也带 hold=30ms：与 macOS 版一致（那边同样打印解析出的 holdMS，
      # 即使 dclick 实际忽略该参数）
      @{ a = @('--dry', 'dclick', '10', '20'); re = '(?m)^dry: would dclick \(10,20\) hold=30ms$' },
      @{ a = @('--dry', 'rclick', '10', '20'); re = '(?m)^dry: would rclick \(10,20\) hold=30ms$' },
      @{ a = @('--dry', 'drag', '10', '10', '200', '200', '--ms', '300'); re = '(?m)^dry: would drag \(10,10\) -> \(200,200\) settle=80 hold=80 move=300 steps=12 momentum=0$' },
      @{ a = @('--dry', 'scroll', '300'); re = '(?m)^dry: would scroll 300$' },
      @{ a = @('--dry', 'scroll', '-300', '--drag'); re = '(?m)^dry: would scroll -300 \(as drag\)$' },
      @{ a = @('--dry', 'type', '中文'); re = '(?m)^dry: would type 2 字符$' },
      @{ a = @('--dry', 'keys', 'Ab-1!'); re = '(?m)^dry: would send 5 个键码字符:$' },
      @{ a = @('--dry', 'key', 'ctrl+shift+s'); re = '(?m)^dry: would press ctrl\+shift\+s$' },
      @{ a = @('--dry', 'shot', '-R', '0,0,100,100', '--grid', '--zoom'); re = '(?m)^dry: would shot -R 0,0,100,100 --grid 50 --zoom 2$' },
      @{ a = @('--dry', 'clipboard', 'set', 'hello'); re = '(?m)^dry: would set clipboard \(5 字符\)$' },
      @{ a = @('--dry', 'win', 'focus', '1'); re = '(?m)^dry: would focus window \[1\] ' }
    )
    foreach ($c in $cases) {
      $r = Invoke-Tool -Command $c.a -Quiet
      Assert ($r.Code -eq 0) ("--dry " + ($c.a -join ' ') + " exit=$($r.Code)")
      Assert-Match $r.Text $c.re ("dry 输出不符: " + ($c.a -join ' '))
    }
    # find-text 的 --dry 会照常截图 + OCR，只把「点击」那一步换成打印；
    # 所以它需要一个真能识别出文字的区域，单独用靶子的标签矩形来测。
    $hdrDry = Get-CtlRect 'HeaderLabel'
    $region = "{0},{1},560,60" -f ([int]$hdrDry[0] - 8), ([int]$hdrDry[1] - 8)
    $r = Invoke-Tool -Command @('--dry', 'find-text', 'TARGET-ALPHA-9931', '--click', '-R', $region) -Quiet
    Assert ($r.Code -eq 0) "find-text --dry exit=$($r.Code)：$($r.Text)"
    Assert-Match $r.Text '匹配 1 处' 'find-text --dry 仍应真的跑 OCR'
    Assert-Match $r.Text '(?m)^dry: would click ' 'find-text --dry 的点击应换成 dry 行'
  }

  # ====================================================== B. 截图/像素 ===
  Group 'B. 截图 / 网格 / 缩放 / diff / wait-for'

  $shotA = Join-Path $WorkDir 'a.png'
  $shotB = Join-Path $WorkDir 'b.png'

  T 'shot -R 区域截图：尺寸与映射一致' {
    $r = Invoke-Tool -Command @('shot', '-o', $shotA, '-R', '0,0,320,200') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    Assert (Test-Path -LiteralPath $shotA) '没生成文件'
    Assert-Match $r.Text 'px=320x200' 'shot 头部'
    Assert-Match $r.Text 'mapping: global_x = 0 \+ px_x' 'mapping 行（Windows 截图 1:1，不除以 scale）'
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::FromFile($shotA)
    try { Assert (($bmp.Width -eq 320) -and ($bmp.Height -eq 200)) "PNG 尺寸 $($bmp.Width)x$($bmp.Height)" } finally { $bmp.Dispose() }
  }

  T 'shot --grid/--zoom 派生文件 + 网格像素' {
    $r = Invoke-Tool -Command @('shot', '-o', $shotB, '-R', '0,0,320,200', '--grid', '40', '--zoom', '2') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    $zoom = Join-Path $WorkDir 'b-zoom2x.png'
    $grid = Join-Path $WorkDir 'b-zoom2x-grid.png'
    Assert (Test-Path -LiteralPath $zoom) "缺少 $zoom"
    Assert (Test-Path -LiteralPath $grid) "缺少 $grid"
    Add-Type -AssemblyName System.Drawing
    $z = [System.Drawing.Bitmap]::FromFile($zoom)
    try { Assert (($z.Width -eq 640) -and ($z.Height -eq 400)) "放大图尺寸 $($z.Width)x$($z.Height)" } finally { $z.Dispose() }
    $g = [System.Drawing.Bitmap]::FromFile($grid)
    try {
      # 第一条竖线在 x=0（红、粗），第一条横线在 y=0（蓝、粗）。
      # 取样点要避开另一条轴上的线（pxStep = 40pt × 1.25 = 50px）。
      $red = $g.GetPixel(0, 125)
      $blue = $g.GetPixel(125, 0)
      Assert (($red.R -gt 150) -and ($red.R -gt ($red.B + 40))) "x=0 处不是红线：RGB($($red.R),$($red.G),$($red.B))"
      Assert (($blue.B -gt 150) -and ($blue.B -gt ($blue.R + 40))) "y=0 处不是蓝线：RGB($($blue.R),$($blue.G),$($blue.B))"
    } finally { $g.Dispose() }
  }

  T 'diff 同图 -> 无差异' {
    $r = Invoke-Tool -Command @('diff', $shotA, $shotA) -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)"
    Assert-Match $r.Text '无差异' 'diff 输出'
  }

  T 'wait-for --stable 在静止区域收敛' {
    $r = Invoke-Tool -Command @('wait-for', '--stable', '-R', '0,0,240,120', '--timeout', '10') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    Assert-Match $r.Text 'ok 画面稳定' 'wait-for --stable'
  }

  T 'wait-for --change 对参考图变化收敛' {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Drawing
    $black = Join-Path $WorkDir 'black.png'
    $bmp = New-Object System.Drawing.Bitmap 240, 120
    $gg = [System.Drawing.Graphics]::FromImage($bmp); $gg.Clear([System.Drawing.Color]::Black); $gg.Dispose()
    $bmp.Save($black, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $r = Invoke-Tool -Command @('wait-for', '--change', $black, '-R', '0,0,240,120', '--min-change', '1000', '--timeout', '10') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    Assert-Match $r.Text '画面已变化并稳定' 'wait-for --change'
  }

  T 'wait-for --text 等到 OCR 出现指定文字' {
    $hdr = Get-CtlRect 'HeaderLabel'
    $x = [int]$hdr[0] - 8; $y = [int]$hdr[1] - 8
    $r = Invoke-Tool -Command @('wait-for', '--text', 'TARGET-ALPHA-9931', '-R', "$x,$y,560,60", '--timeout', '12') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    Assert-Match $r.Text 'ok 找到' 'wait-for --text'
  }

  T 'wait-for --text 等不到时超时 exit=1' {
    $r = Invoke-Tool -Command @('wait-for', '--text', 'ZZZ-NEVER-APPEARS', '--timeout', '2', '--interval', '0.5') -Quiet
    Assert ($r.Code -eq 1) "exit=$($r.Code)，期望 1"
    Assert-Match $r.Text '超时' 'wait-for 超时输出'
  }

  # ================================================= C. OCR / UIA 定位 ===
  Group 'C. 定位：find-text (OCR) / find-ax (UIA) / under'

  $header = Get-AxControl -Name 'TARGET-ALPHA-9931' -TargetPid $tpid
  $submitAx = Get-AxControl -Name 'Submit' -TargetPid $tpid
  $inputAx = Get-AxControl -Name 'InputBox' -TargetPid $tpid
  $dragRect = Get-CtlRect 'DragArea'
  $scrollRect = Get-CtlRect 'ScrollList'
  Write-Host ("        控件: header=$($header.center) submit=$($submitAx.center) input=$($inputAx.center) drag=$($dragRect -join ',') scroll=$($scrollRect -join ',')") -ForegroundColor DarkGray

  T 'find-ax --pid 找到按钮并给出可点击坐标' {
    Assert ($null -ne $submitAx) '没有拿到 Submit'
    Assert ($submitAx.pressable -eq $true) 'Submit 未标记为 pressable'
    Assert (($submitAx.size[0] -gt 0) -and ($submitAx.size[1] -gt 0)) 'Submit 尺寸异常'
  }

  T 'find-ax --app 按窗口标题匹配应用' {
    $r = Invoke-Tool -Command @('find-ax', 'Submit', '--app', 'DSH UI Target', '--json') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    $o = $r.Text | ConvertFrom-Json
    $found = $false
    foreach ($m in $o.matches) { if ($m.pid -eq $tpid) { $found = $true } }
    Assert $found '按标题匹配没有命中测试靶进程'
  }

  T 'find-text 命中的坐标落在靶控件内（OCR 定位精度）' {
    $hdr = Get-CtlRect 'HeaderLabel'
    $x0 = [int]$hdr[0] - 8; $y0 = [int]$hdr[1] - 8
    $r = Invoke-Tool -Command @('find-text', 'TARGET-ALPHA-9931', '-R', "$x0,$y0,560,60", '--json') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    $o = $r.Text | ConvertFrom-Json
    Assert ($o.ok -eq $true) 'ok != true'
    Assert ($o.matches.Count -ge 1) '没有匹配'
    $gx = [int]$o.matches[0].global[0]; $gy = [int]$o.matches[0].global[1]
    Assert (($gx -ge [int]$hdr[0]) -and ($gx -le ([int]$hdr[0] + [int]$hdr[2]))) "命中的 x=$gx 不在标控件内（控件 x=$($hdr[0])..$([int]$hdr[0] + [int]$hdr[2])）"
    Assert (($gy -ge [int]$hdr[1]) -and ($gy -le ([int]$hdr[1] + [int]$hdr[3]))) "命中的 y=$gy 不在标控件内（控件 y=$($hdr[1])..$([int]$hdr[1] + [int]$hdr[3])）"
  }

  T 'under 报告落点所属应用' {
    $cx = [int]$submitAx.center[0]; $cy = [int]$submitAx.center[1]
    $r = Invoke-Tool -Command @('under', "$cx", "$cy") -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    Assert-Match $r.Text 'PowerShell' 'under 输出'
  }

  T '--dry 预演一整套动作后靶子状态零变化' {
    $before = Get-TargetState
    $dragR = Get-CtlRect 'DragArea'
    $scrollR = Get-CtlRect 'ScrollList'
    # 全部指向真实控件：如果哪条命令真的执行了，下面的状态断言必然失败
    $cmds = @(
      @('--dry', 'click', "$([int]$submitAx.center[0])", "$([int]$submitAx.center[1])"),
      @('--dry', 'tap', "$([int]$submitAx.center[0])", "$([int]$submitAx.center[1])"),
      @('--dry', 'dclick', "$([int]$submitAx.center[0])", "$([int]$submitAx.center[1])"),
      @('--dry', 'type', 'SHOULD-NOT-APPEAR'),
      @('--dry', 'keys', 'XYZ'),
      @('--dry', 'key', 'ctrl+a'),
      @('--dry', 'drag', "$([int]$dragR[0] + 40)", "$([int]$dragR[1] + 40)", "$([int]$dragR[0] + 140)", "$([int]$dragR[1] + 160)"),
      @('--dry', 'move', "$([int]$scrollR[0] + 20)", "$([int]$scrollR[1] + 20)"),
      @('--dry', 'scroll', '300'),
      @('--dry', 'clipboard', 'set', 'SHOULD-NOT-SET'),
      @('--dry', 'win', 'move', '1', '10', '10', '300', '200')
    )
    foreach ($c in $cmds) {
      $r = Invoke-Tool -Command $c -Quiet
      Assert ($r.Code -eq 0) ("--dry " + ($c -join ' ') + " exit=$($r.Code)")
    }
    Start-Sleep -Milliseconds 600
    $after = Get-TargetState
    Assert ($after.submit -eq $before.submit) "干跑后按钮计数 $($before.submit) -> $($after.submit)"
    Assert ($after.clear -eq $before.clear) "干跑后清理计数变化"
    Assert ($after.text -eq $before.text) "干跑后文本框内容变化：'$($after.text)'"
    Assert ($after.drag.done -eq $before.drag.done) '干跑后靶子收到了拖拽事件'
    Assert ([int]$after.scrollY -eq [int]$before.scrollY) "干跑后列表滚动位置变化：$($before.scrollY) -> $($after.scrollY)"
    Assert (($after.windowRect -join ',') -eq ($before.windowRect -join ',')) "干跑后窗口位置变化：$($before.windowRect -join ',') -> $($after.windowRect -join ',')"
    $clip = (Invoke-Tool -Command @('clipboard', 'get') -Quiet).Text.Trim()
    Assert ($clip -ne 'SHOULD-NOT-SET') '干跑改动了剪贴板'
  }

  # ======================================================= D. 窗口管理 ===
  Group 'D. 窗口：win list / move / focus / maximize'

  T 'win list --json 含测试靶且坐标与 UIA 一致' {
    $r = Invoke-Tool -Command @('win', 'list', '--json') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)"
    $o = $r.Text | ConvertFrom-Json
    $win = $null
    foreach ($w in $o.windows) { if ($w.pid -eq $tpid -and $w.title -eq 'DSH UI Target') { $win = $w } }
    Assert ($null -ne $win) '没找到测试靶窗口'
    $dx = [math]::Abs([int]$win.pos[0] - ([int]$header.pos[0] - 12))
    $dy = [math]::Abs([int]$win.pos[1] - ([int]$header.pos[1] - 42))
    Assert (($dx -le 40) -and ($dy -le 60)) "窗口原点与控件偏移过大 dx=$dx dy=$dy"
  }

  T 'win move 移动窗口并回读' {
    $r = Invoke-Tool -Command @('win', 'move', '1', '260', '140') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
    Start-Sleep -Milliseconds 400
    # 序号每次重新枚举，这里按 pid 找
    $r2 = Invoke-Tool -Command @('win', 'list', '--json') -Quiet
    $o = $r2.Text | ConvertFrom-Json
    $idx = 0; $w = $null
    foreach ($cand in $o.windows) { $idx++; if ($cand.pid -eq $tpid -and $cand.title -eq 'DSH UI Target') { $w = $cand; break } }
    Assert ($null -ne $w) '移动后找不到窗口'
    Assert (([math]::Abs([int]$w.pos[0] - 260) -le 4) -and ([math]::Abs([int]$w.pos[1] - 140) -le 4)) "窗口位置 $($w.pos -join ',') 与请求 (260,140) 不符"
  }

  T 'win focus 使窗口成为前台' {
    $r = Invoke-Tool -Command @('win', 'list', '--json') -Quiet
    $o = $r.Text | ConvertFrom-Json
    $idx = 0; $want = 0
    foreach ($cand in $o.windows) { $idx++; if ($cand.pid -eq $tpid -and $cand.title -eq 'DSH UI Target') { $want = $idx } }
    Assert ($want -gt 0) '找不到窗口序号'
    $f = Invoke-Tool -Command @('win', 'focus', "$want") -Quiet
    Assert ($f.Code -eq 0) "exit=$($f.Code)：$($f.Text)"
    Assert-Match $f.Text 'ok focused' 'win focus 输出'
    Start-Sleep -Milliseconds 300
    $r2 = Invoke-Tool -Command @('win', 'list', '--json') -Quiet
    $o2 = $r2.Text | ConvertFrom-Json
    $fg = $false
    foreach ($cand in $o2.windows) { if ($cand.pid -eq $tpid -and $cand.foreground -eq $true) { $fg = $true } }
    Assert $fg 'focus 后窗口仍不是前台'
  }

  T 'win maximize 填满工作区' {
    $r = Invoke-Tool -Command @('win', 'list', '--json') -Quiet
    $o = $r.Text | ConvertFrom-Json
    $idx = 0; $want = 0
    foreach ($cand in $o.windows) { $idx++; if ($cand.pid -eq $tpid -and $cand.title -eq 'DSH UI Target') { $want = $idx } }
    $m = Invoke-Tool -Command @('win', 'maximize', "$want") -Quiet
    Assert ($m.Code -eq 0) "exit=$($m.Code)：$($m.Text)"
    Assert-Match $m.Text 'ok maximized' 'win maximize 输出'
    Start-Sleep -Milliseconds 400
    $work = $dispObj.displays[0].work_px
    $r2 = Invoke-Tool -Command @('win', 'list', '--json') -Quiet
    $o2 = $r2.Text | ConvertFrom-Json
    foreach ($cand in $o2.windows) {
      if ($cand.pid -eq $tpid -and $cand.title -eq 'DSH UI Target') {
        Assert ([int]$cand.size[0] -ge ([int]$work[0] - 8)) "宽度 $($cand.size[0]) 小于工作区 $($work[0])"
      }
    }
    # 还原成固定尺寸，后面的输入测试要用稳定坐标（序号每次重新枚举，必须重新查）
    $r3 = Invoke-Tool -Command @('win', 'list', '--json') -Quiet
    $o3 = $r3.Text | ConvertFrom-Json
    $idx3 = 0; $want3 = 0
    foreach ($cand in $o3.windows) { $idx3++; if ($cand.pid -eq $tpid -and $cand.title -eq 'DSH UI Target') { $want3 = $idx3 } }
    $restore = Invoke-Tool -Command @('win', 'move', "$want3", '260', '140', '780', '560') -Quiet
    Assert ($restore.Code -eq 0) "还原失败 exit=$($restore.Code)"
    Start-Sleep -Milliseconds 400
  }

  if ($SkipInput) {
    Group 'E. 真实输入（已跳过）'
    Skip '输入类全部' '-SkipInput'
  } else {
    Group 'E. 真实输入（只打在自己启动的测试靶上）'

    $submitAx = Get-AxControl -Name 'Submit' -TargetPid $tpid
    $inputAx = Get-AxControl -Name 'InputBox' -TargetPid $tpid
    $dragRect = Get-CtlRect 'DragArea'
    $scrollRect = Get-CtlRect 'ScrollList'

    T 'click 真的点到 Submit 按钮上' {
      $before = (Get-TargetState).submit
      Click-Point -X ([int]$submitAx.center[0]) -Y ([int]$submitAx.center[1])
      Start-Sleep -Milliseconds 500
      $after = (Get-TargetState).submit
      Assert (($after - $before) -eq 1) "submit 计数 $before -> $after（期望 +1）"
    }

    T '--dry click 不产生任何副作用' {
      $before = (Get-TargetState).submit
      $r = Invoke-Tool -Command @('--dry', 'click', "$([int]$submitAx.center[0])", "$([int]$submitAx.center[1])") -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)"
      Assert-Match $r.Text '^dry: would click' 'dry 输出'
      Start-Sleep -Milliseconds 300
      $after = (Get-TargetState).submit
      Assert ($after -eq $before) "dry 运行后 submit 变成了 $after"
    }

    T 'type 输入中文+ASCII（KEYEVENTF_UNICODE）' {
      Click-Point -X ([int]$inputAx.center[0]) -Y ([int]$inputAx.center[1])
      Start-Sleep -Milliseconds 300
      $r = Invoke-Tool -Command @('type', '中文 DSH-123 abc') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      Start-Sleep -Milliseconds 500
      $t = (Get-TargetState).text
      Assert ($t -eq '中文 DSH-123 abc') "文本框内容为 '$t'"
    }

    T 'keys ASCII 真实键码（大写/符号带 shift）' {
      $r = Invoke-Tool -Command @('keys', 'Ab-1!') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      Assert-Match $r.Text 'ok keys 发送 5 个字符' 'keys 输出'
      Start-Sleep -Milliseconds 500
      $t = (Get-TargetState).text
      Assert ($t -eq '中文 DSH-123 abcAb-1!') "文本框内容为 '$t'"
    }

    T 'key ctrl+a / delete 清空文本' {
      $r = Invoke-Tool -Command @('key', 'ctrl+a') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      Start-Sleep -Milliseconds 200
      $r2 = Invoke-Tool -Command @('key', 'delete') -Quiet
      Assert ($r2.Code -eq 0) "exit=$($r2.Code)"
      Start-Sleep -Milliseconds 400
      $t = (Get-TargetState).text
      Assert ($t -eq '') "文本框应为空，实际 '$t'"
    }

    T 'clipboard set + ctrl+v 粘贴' {
      $r = Invoke-Tool -Command @('clipboard', 'set', '粘贴-测试-42') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      $ver = Invoke-Tool -Command @('clipboard', 'get') -Quiet
      Assert ($ver.Text.Trim() -eq '粘贴-测试-42') "剪贴板回读为 '$($ver.Text.Trim())'"
      $p = Invoke-Tool -Command @('key', 'ctrl+v') -Quiet
      Assert ($p.Code -eq 0) "ctrl+v exit=$($p.Code)"
      Start-Sleep -Milliseconds 500
      $t = (Get-TargetState).text
      Assert ($t -eq '粘贴-测试-42') "粘贴后文本框为 '$t'"
    }

    T 'drag 真实拖拽：落点与请求方向/幅度一致' {
      # 靶子与工具都是 DPI 感知的，坐标口径一致，可以直接按物理像素断言
      $sx = [int]$dragRect[0] + 40; $sy = [int]$dragRect[1] + 40
      $ex = $sx + 100; $ey = $sy + 120
      $r = Invoke-Tool -Command @('drag', "$sx", "$sy", "$ex", "$ey", '--ms', '300', '--steps', '12') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      Start-Sleep -Milliseconds 500
      $d = (Get-TargetState).drag
      Assert ($d.done -eq $true) '拖拽没有收到 MouseUp'
      $gotX = [int]$d.ex - [int]$d.sx; $gotY = [int]$d.ey - [int]$d.sy
      Assert ([math]::Abs($gotX - 100) -le 3) "水平位移 $gotX（期望 100）"
      Assert ([math]::Abs($gotY - 120) -le 3) "垂直位移 $gotY（期望 120）"
      Assert ([int]$d.moves -gt 3) "拖拽过程中的 MouseMove 次数过少：$($d.moves)"
    }

    T 'scroll 滚动可滚动列表' {
      $cx = [int]$scrollRect[0] + [int]($scrollRect[2] / 2)
      $cy = [int]$scrollRect[1] + [int]($scrollRect[3] / 2)
      # 先点一下列表让它拿到焦点：Windows 的滚轮消息发给焦点窗口
      Click-Point -X $cx -Y $cy
      Start-Sleep -Milliseconds 400
      $r = Invoke-Tool -Command @('scroll', '300') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      Start-Sleep -Milliseconds 600
      $before = (Get-TargetState).scrollY
      $r2 = Invoke-Tool -Command @('scroll', '600') -Quiet
      Assert ($r2.Code -eq 0) "exit=$($r2.Code)"
      Start-Sleep -Milliseconds 600
      $after = (Get-TargetState).scrollY
      Assert ([int]$after -gt [int]$before) "TopIndex 未增加：$before -> $after（滚轮没有生效）"
    }

    T 'find-ax --click 点到按钮上' {
      $before = (Get-TargetState).submit
      $ax = Get-AxControl -Name 'Submit' -TargetPid $tpid
      $r = Invoke-Tool -Command @('find-ax', 'Submit', '--pid', "$tpid", '--click') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      Start-Sleep -Milliseconds 500
      $after = (Get-TargetState).submit
      Assert (($after - $before) -eq 1) "submit 计数 $before -> $after（期望 +1）"
    }

    T 'find-text --click 点到 OCR 命中的按钮上' {
      # 用 OCR 找窗口左上区域的 Submit 按钮并点掉，然后断言 Submit 计数增加。
      # （实测 Windows OCR 会把 12px 的 "Clear" 读成 "CI ear"，所以这里挑识别更稳的 "Submit"。）
      $wx = [int]$inputAx.pos[0] - 20; $wy = [int]$inputAx.pos[1] - 20
      $before = (Get-TargetState).submit
      $r = Invoke-Tool -Command @('find-text', 'Submit', '-R', "$wx,$wy,700,260", '--json', '--click') -Quiet
      Assert ($r.Code -eq 0) "exit=$($r.Code)：$($r.Text)"
      $o = $r.Text | ConvertFrom-Json
      Assert ($o.ok -eq $true) 'OCR 没有命中 Submit'
      Assert ($null -ne $o.clicked) '没有报告点击坐标'
      Start-Sleep -Milliseconds 500
      $after = (Get-TargetState).submit
      Assert (($after - $before) -eq 1) "submit 计数 $before -> $after（期望 +1）"
    }

    T 'denylist 命中时 exit=3 且不执行' {
      $before = (Get-TargetState).submit
      $lines = @()
      if ($denyBackup) { $lines = @([System.IO.File]::ReadAllLines($DenyFile, [System.Text.Encoding]::UTF8)) }
      $lines += 'DSH UI Target'
      [System.IO.File]::WriteAllLines($DenyFile, $lines, (New-Object System.Text.UTF8Encoding $false))
      try {
        $ax = Get-AxControl -Name 'Submit' -TargetPid $tpid
        $r = Invoke-Tool -Command @('click', "$([int]$ax.center[0])", "$([int]$ax.center[1])") -Quiet
        Assert ($r.Code -eq 3) "被拦截时 exit=$($r.Code)，期望 3"
        Start-Sleep -Milliseconds 300
        $after = (Get-TargetState).submit
        Assert ($after -eq $before) "拦截后仍然点了按钮（$before -> $after）"
      } finally {
        if ($null -ne $denyBackup) { [System.IO.File]::WriteAllText($DenyFile, $denyBackup, (New-Object System.Text.UTF8Encoding $false)) }
      }
    }
  }

  # ============================================================ F. 批量 ===
  Group 'F. batch / guard'

  T 'batch 从 stdin 逐条执行并逐条审计' {
    $script = @(
      '# 注释行应被跳过',
      'pos',
      '--dry click 11 22',
      'guard'
    ) -join "`n"
    $tmp = Join-Path $WorkDir 'batch.txt'
    [System.IO.File]::WriteAllText($tmp, $script, (New-Object System.Text.UTF8Encoding $false))
    $out = Get-Content -LiteralPath $tmp -Raw | & pwsh -NoProfile -File $Tool batch 2>&1
    $code = $LASTEXITCODE
    $text = (@($out | ForEach-Object { [string]$_ }) -join "`n")
    Write-Host "        batch -> exit=$code" -ForegroundColor DarkGray
    foreach ($l in ($text -split "`n")) { Write-Host ("          " + $l) -ForegroundColor DarkGray }
    Assert ($code -eq 0) "exit=$code"
    Assert-Match $text '> pos' 'batch 回显'
    Assert-Match $text 'dry: would click \(11,22\)' 'batch 内的 dry'
    Assert-Match $text 'ok 批量完成 3 条' 'batch 统计'
  }

  T 'guard 打印名单/日志/干跑状态' {
    $r = Invoke-Tool -Command @('guard') -Quiet
    Assert ($r.Code -eq 0) "exit=$($r.Code)"
    Assert-Match $r.Text '拦截名单:' 'guard 输出'
    Assert-Match $r.Text '审计日志:' 'guard 输出'
    Assert-Match $r.Text '干跑模式:' 'guard 输出'
  }

  # ===================================================== G. PowerShell 5.1 ===
  Group 'G. Windows PowerShell 5.1 宿主（可选）'
  if ($AlsoPs51) {
    T 'PS 5.1: --help / displays / pos' {
      $h = Invoke-Tool -Command @('--help') -Exe 'ps51' -Quiet
      Assert ($h.Code -eq 0) "help exit=$($h.Code)"
      $d = Invoke-Tool -Command @('displays') -Exe 'ps51' -Quiet
      Assert ($d.Code -eq 0) "displays exit=$($d.Code)：$($d.Text)"
      $p = Invoke-Tool -Command @('pos') -Exe 'ps51' -Quiet
      Assert ($p.Code -eq 0) "pos exit=$($p.Code)"
    }
    T 'PS 5.1: shot / diff / find-text' {
      $f1 = Join-Path $WorkDir 'ps51-a.png'
      $s = Invoke-Tool -Command @('shot', '-o', $f1, '-R', '0,0,320,200') -Exe 'ps51' -Quiet
      Assert ($s.Code -eq 0) "shot exit=$($s.Code)：$($s.Text)"
      $d = Invoke-Tool -Command @('diff', $f1, $f1) -Exe 'ps51' -Quiet
      Assert ($d.Code -eq 0) "diff exit=$($d.Code)：$($d.Text)"
      $ft = Invoke-Tool -Command @('find-text', 'TARGET-ALPHA-9931', '-R', '0,0,700,400') -Exe 'ps51' -Quiet
      Assert ($ft.Code -eq 0) "find-text(PS5.1 进程内 OCR) exit=$($ft.Code)：$($ft.Text)"
    }
    T 'PS 5.1: find-ax / win list' {
      $fa = Invoke-Tool -Command @('find-ax', 'Submit', '--pid', "$tpid") -Exe 'ps51' -Quiet
      Assert ($fa.Code -eq 0) "find-ax exit=$($fa.Code)：$($fa.Text)"
      $wl = Invoke-Tool -Command @('win', 'list') -Exe 'ps51' -Quiet
      Assert ($wl.Code -eq 0) "win list exit=$($wl.Code)"
      Assert-Match $wl.Text 'DSH UI Target' 'win list 输出'
    }
  } else {
    Skip 'PS 5.1 全组' '未加 -AlsoPs51'
  }

  # ================================================= H. 安装 / 启动器 ===
  Group 'H. install.ps1 + dsh-ui.cmd'
  $testPrefix = Join-Path $env:TEMP 'dsh-ui-install-test'

  T 'install.ps1 安装后可运行、-Uninstall 可清理' {
    Remove-Item -LiteralPath $testPrefix -Recurse -Force -ErrorAction SilentlyContinue
    $ins = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'install.ps1') -Prefix $testPrefix -NoPath 2>&1
    Assert ($LASTEXITCODE -eq 0) "install exit=$LASTEXITCODE：$($ins -join ' ')"
    $launcher = Join-Path $testPrefix 'bin\dsh-ui.cmd'
    $scriptCopy = Join-Path $testPrefix 'bin\dsh-ui.ps1'
    Assert (Test-Path -LiteralPath $launcher) '缺少 dsh-ui.cmd'
    Assert (Test-Path -LiteralPath $scriptCopy) '缺少 dsh-ui.ps1'
    # 副本仍可解析（BOM 丢了就会在这里暴露）
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptCopy, [ref]$null, [ref]$errors)
    Assert ((-not $errors) -or $errors.Count -eq 0) ("安装副本解析失败: " + $(if ($errors) { $errors[0].Message } else { '' }))
    try {
      $p1 = Start-Process cmd -ArgumentList '/c', "`"$launcher`" displays" -Wait -PassThru -WindowStyle Hidden
      Assert ($p1.ExitCode -eq 0) "displays via launcher exit=$($p1.ExitCode)"
      $p2 = Start-Process cmd -ArgumentList '/c', "`"$launcher`" move foo bar" -Wait -PassThru -WindowStyle Hidden
      Assert ($p2.ExitCode -eq 2) "用法错误经启动器应原样传出 exit=2，实际 $($p2.ExitCode)"
    } finally {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'install.ps1') -Prefix $testPrefix -Uninstall 2>&1 | Out-Null
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $testPrefix 'bin'))) '卸载后 bin 仍存在'
  }

  T 'dsh-ui.cmd 保持纯 ASCII（cmd 按 OEM 代码页解析 .cmd）' {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Root 'dsh-ui.cmd'))
    $bad = @($bytes | Where-Object { $_ -gt 127 })
    Assert ($bad.Count -eq 0) "dsh-ui.cmd 含 $($bad.Count) 个非 ASCII 字节；cmd.exe 会按 OEM 代码页解析，中文注释会把批处理拆坏"
  }

  T 'install.ps1 默认只装可执行文件（不把 docs/tests 倒进 bin 的上级目录）' {
    # 这条是给「装进 %USERPROFILE%\.local」准备的：bin 的上级目录是用户自己的目录，
    # 默认往里塞 docs/ tests/ 就是污染。想一并装用 -WithDocs。
    Remove-Item -LiteralPath $testPrefix -Recurse -Force -ErrorAction SilentlyContinue
    try {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'install.ps1') -Prefix $testPrefix -NoPath 2>&1 | Out-Null
      Assert ($LASTEXITCODE -eq 0) "install exit=$LASTEXITCODE"
      $entries = @(Get-ChildItem -LiteralPath $testPrefix -Directory | ForEach-Object { $_.Name })
      $extra = @($entries | Where-Object { $_ -in @('docs', 'tests', 'skill-win') })
      Assert ($extra.Count -eq 0) ("默认安装不应产生额外目录，实际: " + ($extra -join ', '))
      Assert (Test-Path -LiteralPath (Join-Path $testPrefix 'bin\dsh-ui.cmd')) '缺少 dsh-ui.cmd'

      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'install.ps1') -Prefix $testPrefix -NoPath -WithDocs 2>&1 | Out-Null
      Assert (Test-Path -LiteralPath (Join-Path $testPrefix 'tests\verify-windows.ps1')) '-WithDocs 应把验证套件一并装过去'
      Assert (Test-Path -LiteralPath (Join-Path $testPrefix 'docs\REFERENCE-WINDOWS.md')) '-WithDocs 应把手册一并装过去'

      # 全局 skill：DSH 从 <home>/.dsh/skills/<name>/SKILL.md 读用户级技能，所以它得单独同步
      $skillDest = Join-Path $testPrefix 'skill-dest\dsh-windows-ui'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'install.ps1') -Prefix $testPrefix -NoPath -WithSkill -SkillDest $skillDest 2>&1 | Out-Null
      $skillFile = Join-Path $skillDest 'SKILL.md'
      Assert (Test-Path -LiteralPath $skillFile) '-WithSkill 应把 SKILL.md 同步到 -SkillDest'
      $head = [System.IO.File]::ReadAllLines($skillFile, [System.Text.Encoding]::UTF8)
      $nameLine = @($head | Select-Object -First 6 | Where-Object { $_ -match '^name:\s*dsh-windows-ui\s*$' })
      Assert ($nameLine.Count -eq 1) 'SKILL.md 的 frontmatter 里应有 name: dsh-windows-ui（DSH 靠它注册技能）'
      Assert ((Get-FileHash $skillFile).Hash -eq (Get-FileHash (Join-Path $Root 'skill-win\SKILL.md')).Hash) '同步过去的 SKILL.md 应与仓库副本逐字节一致'
    } finally {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'install.ps1') -Prefix $testPrefix -Uninstall 2>&1 | Out-Null
    }
  }
}
catch {
  Write-Host ""
  Write-Host ("套件异常终止: " + $_.Exception.Message) -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
  $script:Fail++
}
finally {
  # 还原现场：关掉测试靶、把光标放回去、恢复拦截名单
  if ($target -and -not $target.HasExited) { try { $target.Kill(); Start-Sleep -Milliseconds 300 } catch { } }
  [void](Remove-StaleTargets)   # 兜底：连中途重新拉起的靶子一起收掉
  if (Test-Path -LiteralPath $StateFile) { Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue }
  if ($null -ne $denyBackup) { try { [System.IO.File]::WriteAllText($DenyFile, $denyBackup, (New-Object System.Text.UTF8Encoding $false)) } catch { } }
  if ($prevCursor -and $prevCursor -match 'cursor=\((-?\d+),(-?\d+)\)') {
    try { [void](Invoke-Tool -Command @('move', $Matches[1], $Matches[2]) -Quiet) } catch { }
  }
}

Write-Host ""
Write-Host ("结果: PASS {0} / FAIL {1} / SKIP {2}" -f $script:Pass, $script:Fail, $script:Skip) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
$summary = [ordered]@{
  when = (Get-Date).ToString('s')
  host = "$($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
  os = [System.Environment]::OSVersion.VersionString
  scale = $scale
  pass = $script:Pass; fail = $script:Fail; skip = $script:Skip
  results = $script:Results
}
[System.IO.File]::WriteAllText($ResultFile, ($summary | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
Write-Host "结果文件: $ResultFile"
if ($script:Fail -gt 0) { exit 1 }
exit 0
