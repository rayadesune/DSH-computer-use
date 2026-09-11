<#
  dsh-ui 的受控测试靶：一个自己写的 WinForms 窗口，把「被操作后的状态」写到 JSON 文件，
  让自动化验证可以断言「点击/输入/拖拽/滚动到底有没有真的生效」。

  用法:
    powershell.exe -NoProfile -STA -File tests/ui-target.ps1 -StateFile <path> [-X 120] [-Y 80]

  状态文件字段:
    pid / windowRect / header / text / submit / clear / flag / scrollY / drag / events
#>
param(
  [string]$StateFile = "$env:TEMP\dsh-ui-target.json",
  [int]$X = 120,
  [int]$Y = 80
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 让测试靶 DPI 感知：这样它报出来的坐标就是**物理像素**，与 dsh-ui 的坐标口径完全一致，
# 断言不需要再乘缩放系数。（默认的 DPI 不感知进程只会看到虚拟化后的逻辑坐标。）
Add-Type -Namespace UiTarget -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);
'@
try { [void][UiTarget.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
$script:scale = 1.0
try {
  Add-Type -AssemblyName System.Windows.Forms
  $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  $script:scale = [double]$g.DpiX / 96.0
  $g.Dispose()
} catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:state = [ordered]@{
  pid = $PID
  header = 'TARGET-ALPHA-9931'
  text = ''
  submit = 0
  clear = 0
  flag = $false
  scrollY = 0
  drag = [ordered]@{ sx = 0; sy = 0; ex = 0; ey = 0; moves = 0; done = $false }
  windowRect = @(0, 0, 0, 0)
  events = @()
}
$script:log = New-Object System.Collections.ArrayList

function Add-Event([string]$Name) {
  [void]$script:log.Add(("{0} {1}" -f (Get-Date).ToString('HH:mm:ss.fff'), $Name))
  $script:state.events = @($script:log)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH UI Target'
$form.ClientSize = New-Object System.Drawing.Size(760, 520)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point($X, $Y)
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)

$header = New-Object System.Windows.Forms.Label
$header.Name = 'HeaderLabel'
$header.Text = 'TARGET-ALPHA-9931'
$header.Font = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(12, 10)
$header.Size = New-Object System.Drawing.Size(400, 26)
$form.Controls.Add($header)

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Name = 'InputBox'
$txtInput.Multiline = $true
$txtInput.ScrollBars = 'Vertical'
$txtInput.AccessibleName = 'InputBox'
$txtInput.Location = New-Object System.Drawing.Point(12, 42)
$txtInput.Size = New-Object System.Drawing.Size(500, 150)
$txtInput.Font = New-Object System.Drawing.Font('Consolas', 11)
$txtInput.Add_TextChanged({ $script:state.text = $txtInput.Text })
$form.Controls.Add($txtInput)

$submit = New-Object System.Windows.Forms.Button
$submit.Name = 'Submit'
$submit.Text = 'Submit'
$submit.AccessibleName = 'Submit'
$submit.Location = New-Object System.Drawing.Point(12, 200)
$submit.Size = New-Object System.Drawing.Size(110, 34)
$submit.Add_Click({ $script:state.submit = [int]$script:state.submit + 1; Add-Event 'click:Submit' })
$form.Controls.Add($submit)

$clear = New-Object System.Windows.Forms.Button
$clear.Name = 'ClearInput'
$clear.Text = 'Clear'
$clear.AccessibleName = 'ClearInput'
$clear.Location = New-Object System.Drawing.Point(132, 200)
$clear.Size = New-Object System.Drawing.Size(110, 34)
$clear.Add_Click({ $txtInput.Text = ''; $script:state.clear = [int]$script:state.clear + 1; Add-Event 'click:Clear' })
$form.Controls.Add($clear)

$flag = New-Object System.Windows.Forms.CheckBox
$flag.Name = 'FlagBox'
$flag.Text = 'Flag me'
$flag.AccessibleName = 'FlagBox'
$flag.Location = New-Object System.Drawing.Point(254, 206)
$flag.Size = New-Object System.Drawing.Size(120, 26)
$flag.Add_CheckedChanged({ $script:state.flag = [bool]$flag.Checked; Add-Event ("check:" + $flag.Checked) })
$form.Controls.Add($flag)

# 可滚动列表：验证 scroll 是否真的滚动了内容（ListBox 可获焦点、UIA 可定位、能报 TopIndex）
$list = New-Object System.Windows.Forms.ListBox
$list.Name = 'ScrollList'
$list.AccessibleName = 'ScrollList'
$list.Location = New-Object System.Drawing.Point(12, 244)
$list.Size = New-Object System.Drawing.Size(500, 160)
$list.Font = New-Object System.Drawing.Font('Consolas', 10)
$list.IntegralHeight = $false
foreach ($i in 1..60) { [void]$list.Items.Add("SCROLL-ROW-$i") }
$form.Controls.Add($list)

# 拖拽区：记录起止点，用来断言 drag 的真实落点。
# 用 GroupBox 而不是 Panel —— WinForms 的 Panel 不向 UI Automation 暴露自己。
$dragArea = New-Object System.Windows.Forms.GroupBox
$dragArea.Name = 'DragArea'
$dragArea.AccessibleName = 'DragArea'
$dragArea.Text = 'DragArea'
$dragArea.Location = New-Object System.Drawing.Point(530, 42)
$dragArea.Size = New-Object System.Drawing.Size(210, 360)
$dragArea.BackColor = [System.Drawing.Color]::FromArgb(235, 244, 255)
$dragLabel = New-Object System.Windows.Forms.Label
$dragLabel.Text = 'DRAG AREA'
$dragLabel.Location = New-Object System.Drawing.Point(8, 20)
$dragLabel.AutoSize = $true
$dragArea.Controls.Add($dragLabel)
$script:dragging = $false
$dragArea.Add_MouseDown({
    $script:dragging = $true
    $script:state.drag.sx = $_.X; $script:state.drag.sy = $_.Y; $script:state.drag.moves = 0; $script:state.drag.done = $false
    Add-Event ("dragdown:{0},{1}" -f $_.X, $_.Y)
  })
$dragArea.Add_MouseMove({
    if ($script:dragging) { $script:state.drag.moves = [int]$script:state.drag.moves + 1 }
  })
$dragArea.Add_MouseUp({
    $script:dragging = $false
    $script:state.drag.ex = $_.X; $script:state.drag.ey = $_.Y; $script:state.drag.done = $true
    Add-Event ("dragup:{0},{1}" -f $_.X, $_.Y)
  })
$form.Controls.Add($dragArea)

$status = New-Object System.Windows.Forms.Label
$status.Name = 'StatusLabel'
$status.AccessibleName = 'StatusLabel'
$status.Text = 'READY-FOR-DSH'
$status.Font = New-Object System.Drawing.Font('Consolas', 12)
$status.ForeColor = [System.Drawing.Color]::FromArgb(20, 110, 40)
$status.Location = New-Object System.Drawing.Point(12, 420)
$status.Size = New-Object System.Drawing.Size(500, 26)
$form.Controls.Add($status)

# 状态落盘放在脚本作用域的函数里，由 Timer 调用：事件脚本块的作用域对集合字面量
# 有过诡异行为（`$ctl = [ordered]@{}` 在 PS 5.1 的事件作用域里会变成 $null），
# 函数调用则一切正常。
function Write-TargetState {
  try {
    $p = $form.PointToScreen((New-Object System.Drawing.Point(0, 0)))
    $script:state.windowRect = @([int]$p.X, [int]$p.Y, [int]$form.Width, [int]$form.Height)
    $script:state.text = $txtInput.Text
    $script:state.flag = [bool]$flag.Checked
    $script:state.scrollY = [int]$list.TopIndex
    # 控件矩形（物理像素，屏幕坐标）：Panel/GroupBox/ListBox 对 UI Automation 不可见，
    # 所以由靶子自己报出来，验证脚本用它来算点击/拖拽的落点。
    $ctl = [ordered]@{}
    $pairs = @(
      @('HeaderLabel', $header), @('InputBox', $txtInput), @('Submit', $submit),
      @('ClearInput', $clear), @('FlagBox', $flag), @('ScrollList', $list),
      @('DragArea', $dragArea), @('StatusLabel', $status)
    )
    foreach ($pr in $pairs) {
      $c = $pr[1]
      $o = $c.PointToScreen((New-Object System.Drawing.Point(0, 0)))
      $ctl[[string]$pr[0]] = @([int]$o.X, [int]$o.Y, [int]$c.Width, [int]$c.Height)
    }
    $script:state.controls = $ctl
    $json = ($script:state | ConvertTo-Json -Depth 6 -Compress)
    $tmp = "$StateFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    # 落地必须**原子**：Move-Item -Force 是「先删目标再改名」，读方正好落在那个窗口里
    # 就会扑空（套件实测遇到过"状态文件不存在"）。File.Replace 在 NTFS 上是原子的。
    if (Test-Path -LiteralPath $StateFile) {
      try { [System.IO.File]::Replace($tmp, $StateFile, $null) }
      catch { Move-Item -LiteralPath $tmp -Destination $StateFile -Force }
    } else {
      [System.IO.File]::Move($tmp, $StateFile)
    }
  } catch {
    $err = @{ tickError = $_.Exception.Message
      line = $_.InvocationInfo.ScriptLineNumber
      source = ([string]$_.InvocationInfo.Line).Trim()
      stack = $_.ScriptStackTrace } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($StateFile, $err, (New-Object System.Text.UTF8Encoding $false))
  }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({ Write-TargetState })
$timer.Start()

Add-Event 'start'
[void]$form.Show()
[System.Windows.Forms.Application]::Run($form)
