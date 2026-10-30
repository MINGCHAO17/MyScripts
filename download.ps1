<#
.SYNOPSIS
    MSI 全局卸载清理器 v2.2 - 统一清单，智能卸载通道
.DESCRIPTION
    显示全部 = MSI Installer UserData + 控制面板卸载记录，按 MSI ProductCode 精确关联去重。
    同一个 MSI 产品两种来源仅显示一行，按 MSI 通道卸载；仅控制面板记录走注册卸载程序。
    MSI 卸载失败时可询问或按本地 INI 自动强制清理已备份的产品安装登记项。
.NOTES
    Windows PowerShell 5.1 (64-bit) + 管理员权限；可通过 irm URL | iex 运行。
    强制清理仅移除特定 MSI 安装登记信息，不代表删除软件文件或修复所有安装问题。
#>

# 远程 irm ... | iex 时自动清屏；不向终端打印正常运行日志。
Clear-Host -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-Dialog {
    param([string]$Text, [string]$Title = 'MSI 全局卸载清理器 v2.2', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    return [System.Windows.Forms.MessageBox]::Show($Text,$Title,([System.Windows.Forms.MessageBoxButtons]$Buttons),([System.Windows.Forms.MessageBoxIcon]$Icon))
}

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    [void](Show-Dialog '请使用 64 位 Windows PowerShell 运行，以免注册表重定向造成错误。' '运行环境错误' 'OK' 'Error')
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList @($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [void](Show-Dialog '请以管理员身份打开 64 位 Windows PowerShell，再运行该脚本。' '需要管理员权限' 'OK' 'Warning')
    return
}

$script:baseDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MSIUninstallCleaner'
$logDir = Join-Path $script:baseDir 'Logs'
[void][IO.Directory]::CreateDirectory($logDir)
$script:logPath = Join-Path $logDir ('Uninstall_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$script:logFailureReported = $false
function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch {
        if (-not $script:logFailureReported) {
            $script:logFailureReported = $true
            [void](Show-Dialog ('无法写入日志：' + $script:logPath + "`r`n" + $_.Exception.Message) '日志保存失败' 'OK' 'Warning')
        }
    }
}

# INI 放在固定的本地用户配置目录，适用于 GitHub irm | iex 单文件运行。
$script:iniPath = Join-Path $script:baseDir 'config.ini'
$script:autoForceOnFailure = $false
$iniTemplate = @'
[MSI]
; MSI 卸载失败后是否自动强制清理安装登记记录
; 0=失败后逐项弹窗询问（默认，推荐）
; 1=真正卸载失败后自动清理（但 1602 用户取消、1618 安装冲突不清理）
; 强制清理前始终备份目标注册表；备份失败则不删除
AutoForceOnFailure=0
'@
try {
    if (-not (Test-Path -LiteralPath $script:iniPath)) {
        [IO.File]::WriteAllText($script:iniPath, $iniTemplate, (New-Object System.Text.UTF8Encoding -ArgumentList @($true)))
    }
    $section = ''
    foreach ($line in [IO.File]::ReadAllLines($script:iniPath,[Text.Encoding]::UTF8)) {
        $item = $line.Trim()
        if ($item -match '^\s*\[([^\]]+)\]\s*$') { $section = $matches[1].Trim(); continue }
        if ($item -match '^\s*[;#]' -or $item.Length -eq 0) { continue }
        if ($section -ieq 'MSI' -and $item -match '^AutoForceOnFailure\s*=\s*([01])\s*(?:[;#].*)?$') {
            $script:autoForceOnFailure = ($matches[1] -eq '1')
        }
    }
}
catch { Write-Log ('无法读取或生成 INI，采用人工确认模式：' + $_.Exception.Message) }
Write-Log ('启动 v2.2；AutoForceOnFailure=' + [int]$script:autoForceOnFailure)

function Convert-PackedGuid {
    param([string]$Packed)
    if ($Packed -cnotmatch '^[0-9A-Fa-f]{32}$') { return '' }
    $p = $Packed.ToUpperInvariant()
    return ('{' + (-join $p[7..0]) + '-' + (-join $p[11..8]) + '-' + (-join $p[15..12]) + '-' +
        (-join $p[17,16,19,18]) + '-' + (-join $p[21,20,23,22,25,24,27,26,29,28,31,30]) + '}')
}
function Get-NativeRegistryPath {
    param([string]$Path)
    $s = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::','' -replace '^Registry::',''
    $s = $s -replace '^HKLM:\\','HKLM\' -replace '^HKCU:\\','HKCU\'
    $s = $s -replace '^HKEY_LOCAL_MACHINE\\','HKLM\' -replace '^HKEY_CURRENT_USER\\','HKCU\'
    return $s
}
function Get-ProviderRegistryPath {
    param([string]$Path)
    $s = Get-NativeRegistryPath $Path
    if ($s -match '^HKLM\\') { return ('Registry::HKEY_LOCAL_MACHINE\' + $s.Substring(5)) }
    if ($s -match '^HKCU\\') { return ('Registry::HKEY_CURRENT_USER\' + $s.Substring(5)) }
    return ''
}
function Test-ProductGuid {
    param([string]$Value)
    return ($Value -match '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$')
}

function New-Table {
    $t = New-Object System.Data.DataTable
    [void]$t.Columns.Add('全选',[bool])
    foreach ($n in @('软件名称','版本','发行商','安装日期','来源','卸载方式','GUID','PackedGUID','UserPath','UninstallKey','UninstallString','HasMsi','HasAppwiz','IsWindowsInstaller')) {
        [void]$t.Columns.Add($n,[string])
    }
    return ,$t
}
$script:dt = New-Table
$script:msiByGuid = @{}
$script:scope = 'ALL'

function Add-MsiRows {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties'
    $items = @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Sort-Object DisplayName)
    foreach ($i in $items) {
        $userPath = Split-Path -Path $i.PSPath -Parent
        $packed = Split-Path -Path $userPath -Leaf
        if ($packed -notmatch '^[0-9A-Fa-f]{32}$') { continue }
        $guid = Convert-PackedGuid $packed
        if (-not (Test-ProductGuid $guid)) { continue }
        if ($script:msiByGuid.ContainsKey($guid)) {
            Write-Log ('MSI UserData 重复 ProductCode，保留第一条显示：' + $guid + ' / ' + $userPath)
            continue
        }
        $row = $script:dt.Rows.Add($false,[string]$i.DisplayName,[string]$i.DisplayVersion,
            [string]$i.Publisher,[string]$i.InstallDate,'MSI','MSI', $guid,$packed,$userPath,
            '',[string]$i.UninstallString,'True','False','True')
        $script:msiByGuid[$guid] = $row
    }
}

# 按卸载键的 ProductCode 严格关联；不按名称或发行商推断 MSI 是否同一产品。
function Add-AppwizRows {
    $roots = @(
        @{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; View=[Microsoft.Win32.RegistryView]::Registry64; Prefix='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    if ([Environment]::Is64BitOperatingSystem) {
        $roots += @{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; View=[Microsoft.Win32.RegistryView]::Registry32; Prefix='HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
    }
    $roots += @{ Hive=[Microsoft.Win32.RegistryHive]::CurrentUser; View=[Microsoft.Win32.RegistryView]::Default; Prefix='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
    foreach ($r in $roots) {
        $base = $null
        $uninstall = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($r.Hive,$r.View)
            $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -eq $uninstall) { continue }
            foreach ($keyName in $uninstall.GetSubKeyNames()) {
                $sub = $null
                try {
                    $sub = $uninstall.OpenSubKey($keyName)
                    if ($null -eq $sub) { continue }
                    $name = [string]$sub.GetValue('DisplayName','')
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    if ([string]$sub.GetValue('SystemComponent','0') -eq '1') { continue }
                    if (-not [string]::IsNullOrWhiteSpace([string]$sub.GetValue('ParentKeyName',''))) { continue }
                    if (-not [string]::IsNullOrWhiteSpace([string]$sub.GetValue('ReleaseType',''))) { continue }
                    $isMsi = ([string]$sub.GetValue('WindowsInstaller','0') -eq '1')
                    $uninst = [string]$sub.GetValue('UninstallString','')
                    $guid = [regex]::Match($keyName,'^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$').Value
                    $isMsiCommand = ($uninst -match '(?i)^\s*"?[^"\r\n]*?\bmsiexec(?:\.exe)?"?(?:\s|$)')
                    $uninstallKey = $r.Prefix + '\' + $keyName
                    if ($guid -and $script:msiByGuid.ContainsKey($guid) -and ($isMsi -or $isMsiCommand)) {
                        $existing = [System.Data.DataRow]$script:msiByGuid[$guid]
                        $existing['HasAppwiz'] = 'True'
                        $existing['来源'] = 'MSI + 控制面板'
                        if ([string]::IsNullOrWhiteSpace([string]$existing['UninstallKey'])) {
                            $existing['UninstallKey'] = $uninstallKey
                        }
                        Write-Log ('已合并相同 MSI ProductCode：' + $guid + ' / ' + $name)
                        continue
                    }
                    # 未找到真实 MSI UserData 产品记录的控制面板项目，仍只走控制面板正常卸载通道。
                    [void]$script:dt.Rows.Add($false,$name,[string]$sub.GetValue('DisplayVersion',''),
                        [string]$sub.GetValue('Publisher',''),[string]$sub.GetValue('InstallDate',''),
                        '控制面板','正常卸载',$guid,'','',$uninstallKey,$uninst,
                        'False','True',[string]$isMsi)
                }
                catch { Write-Log ('读取控制面板项目失败：' + $keyName + ' / ' + $_.Exception.Message) }
                finally { if ($null -ne $sub) { $sub.Close() } }
            }
        }
        catch { Write-Log ('读取卸载注册表失败：' + $r.Prefix + ' / ' + $_.Exception.Message) }
        finally {
            if ($null -ne $uninstall) { $uninstall.Close() }
            if ($null -ne $base) { $base.Close() }
        }
    }
}

Write-Log '开始读取 MSI 和控制面板程序。'
Add-MsiRows
Add-AppwizRows
$msiCount = @($script:dt.Select("HasMsi = 'True'")).Count
$appwizCount = @($script:dt.Select("HasAppwiz = 'True'")).Count
$bothCount = @($script:dt.Select("HasMsi = 'True' AND HasAppwiz = 'True'")).Count
Write-Log ("读取完毕：MSI=$msiCount，控制面板=$appwizCount，合并交集=$bothCount，统一行数=$($script:dt.Rows.Count)")

# ============================== GUI ==============================
$form = New-Object System.Windows.Forms.Form -Property @{
    Text='MSI 全局卸载清理器 v2.2｜MSI + 控制面板统一列表（智能通道）'
    Width=1270; Height=730; StartPosition='CenterScreen'
    Font=(New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei UI',9))
    MinimumSize=(New-Object System.Drawing.Size -ArgumentList @(1050,580))
}
$pTop = New-Object System.Windows.Forms.Panel -Property @{Dock='Fill';Margin=[System.Windows.Forms.Padding]::Empty}
$lbl = New-Object System.Windows.Forms.Label -Property @{Text='实时搜索：';Left=12;Top=12;AutoSize=$true}
$txt = New-Object System.Windows.Forms.TextBox -Property @{Left=85;Top=8;Width=350;Height=26}
$lblMode = New-Object System.Windows.Forms.Label -Property @{Text='当前：显示全部（MSI + 控制面板，已去重）';Left=455;Top=12;Width=590;Height=23;ForeColor='DarkBlue'}
$lblCnt = New-Object System.Windows.Forms.Label -Property @{Text='已勾选：0 项';AutoSize=$true;ForeColor='Blue';Left=1060;Top=12}
$pTop.Controls.AddRange(@($lbl,$txt,$lblMode,$lblCnt))

$x = 12
$quickButtons = @{}
foreach ($spec in @(@('Autodesk',87),@('VBA',58),@('SolidWorks',103),@('C++',64),@('Aspen',75))) {
    $name = [string]$spec[0]
    $button = New-Object System.Windows.Forms.Button -Property @{Text=$name;Left=$x;Top=43;Width=[int]$spec[1];Height=29}
    $pTop.Controls.Add($button)
    $quickButtons[$name] = $button
    $x += [int]$spec[1] + 8
}
$btnMsi = New-Object System.Windows.Forms.Button -Property @{Text='MSI';Left=$x;Top=43;Width=66;Height=29}
$x += 74
$btnApp = New-Object System.Windows.Forms.Button -Property @{Text='appwiz.cpl';Left=$x;Top=43;Width=107;Height=29}
$x += 115
$btnAll = New-Object System.Windows.Forms.Button -Property @{Text='显示全部';Left=$x;Top=43;Width=98;Height=29}
$pTop.Controls.AddRange(@($btnMsi,$btnApp,$btnAll))

$pBot = New-Object System.Windows.Forms.Panel -Property @{Dock='Fill';Margin=[System.Windows.Forms.Padding]::Empty}
$btnClr = New-Object System.Windows.Forms.Button -Property @{Text='清空已选';Left=12;Top=9;Width=120;Height=34}
$btnOk = New-Object System.Windows.Forms.Button -Property @{Text='开始卸载（智能通道）';Width=240;Height=34;Top=9;Left=950}
$pBot.Controls.AddRange(@($btnClr,$btnOk))
$dgv = New-Object System.Windows.Forms.DataGridView -Property @{
    Dock='Fill';DataSource=$script:dt.DefaultView;AllowUserToAddRows=$false;AllowUserToDeleteRows=$false
    ReadOnly=$true;RowHeadersVisible=$false;SelectionMode='FullRowSelect';MultiSelect=$false
    AutoSizeColumnsMode='Fill';BackgroundColor='White';AllowUserToOrderColumns=$true
}
$dgv.Margin = [System.Windows.Forms.Padding]::Empty
$layout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
    Dock='Fill';ColumnCount=1;RowCount=3;Padding=[System.Windows.Forms.Padding]::Empty;Margin=[System.Windows.Forms.Padding]::Empty
}
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent,100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute,90)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent,100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute,54)))
$layout.Controls.Add($pTop,0,0)
$layout.Controls.Add($dgv,0,1)
$layout.Controls.Add($pBot,0,2)
$form.Controls.Add($layout)
$alignHeader = {
    $lblCnt.Left = [Math]::Max(850, $pTop.ClientSize.Width - $lblCnt.PreferredWidth - 18)
    $lblMode.Width = [Math]::Max(310, $lblCnt.Left - $lblMode.Left - 14)
}
$pTop.Add_Resize($alignHeader)
$pBot.Add_Resize({ $btnOk.Left = [Math]::Max(150,$pBot.ClientSize.Width - $btnOk.Width - 15) })

$updateCount = {
    $total = @($script:dt.Select('全选 = true')).Count
    $lblCnt.Text = "已勾选：$total 项"
    $dgv.Refresh()
}
function Set-Filter {
    $keyword = $txt.Text
    $safe = $keyword.Replace("'","''").Replace('[','[[]').Replace(']','[]]').Replace('%','[%]').Replace('*','[*]')
    $scopeFilter = switch ($script:scope) {
        'MSI'   { "[HasMsi] = 'True'" }
        'APP'   { "[HasAppwiz] = 'True'" }
        default { '' }
    }
    $searchFilter = if ($keyword.Length -gt 0) {
        "([软件名称] LIKE '%$safe%' OR [发行商] LIKE '%$safe%')"
    } else { '' }
    $filter = @($scopeFilter,$searchFilter) | Where-Object { $_ }
    try { $script:dt.DefaultView.RowFilter = ($filter -join ' AND ') }
    catch { $script:dt.DefaultView.RowFilter = $scopeFilter; Write-Log ('搜索条件不支持，已恢复范围筛选：' + $_.Exception.Message) }
}
function Switch-Scope {
    param([string]$Target)
    $script:scope = $Target
    $txt.Text = ''
    if ($Target -eq 'MSI') {
        $lblMode.Text = '当前：仅 MSI 安装记录（失败后可强制清理）'
        $lblMode.ForeColor = 'DarkBlue'
    }
    elseif ($Target -eq 'APP') {
        $lblMode.Text = '当前：仅控制面板项目（MSI 交集仍走 MSI）'
        $lblMode.ForeColor = 'DarkGreen'
    }
    else {
        $lblMode.Text = '当前：显示全部（MSI + 控制面板，已去重）'
        $lblMode.ForeColor = 'DarkBlue'
    }
    Set-Filter
    & $updateCount
}

$dgv.Add_CellMouseDown({
    if ($_.RowIndex -ge 0 -and $_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $item = $dgv.Rows[$_.RowIndex].DataBoundItem
        if ($null -ne $item) { $item.Row['全选'] = -not [bool]$item.Row['全选']; & $updateCount }
    }
})
$dgv.Add_ColumnHeaderMouseClick({
    if ($_.ColumnIndex -eq 0) {
        $visible = @($script:dt.DefaultView | ForEach-Object { $_.Row })
        if ($visible.Count -gt 0) {
            $value = (@($visible | Where-Object { -not [bool]$_['全选'] }).Count -gt 0)
            foreach ($item in $visible) { $item['全选'] = $value }
            & $updateCount
        }
    }
})
$dgv.Add_RowPrePaint({
    if ($_.RowIndex -ge 0 -and $null -ne $dgv.Rows[$_.RowIndex].DataBoundItem) {
        $viewRow = $dgv.Rows[$_.RowIndex]
        $checked = [bool]$viewRow.DataBoundItem.Row['全选']
        $viewRow.DefaultCellStyle.BackColor = if ($checked) {[Drawing.Color]::FromArgb(210,238,255)} else {[Drawing.Color]::White}
        $viewRow.DefaultCellStyle.SelectionBackColor = if ($checked) {[Drawing.Color]::FromArgb(145,205,255)} else {[Drawing.Color]::FromArgb(235,235,235)}
        $viewRow.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::Black
    }
})
$txt.Add_TextChanged({ Set-Filter })
foreach ($key in @($quickButtons.Keys)) {
    $word = $key
    $quickButtons[$key].Add_Click({ $txt.Text = $word; $txt.Focus() }.GetNewClosure())
}
$btnMsi.Add_Click({ Switch-Scope 'MSI'; $txt.Focus() })
$btnApp.Add_Click({ Switch-Scope 'APP'; $txt.Focus() })
$btnAll.Add_Click({ Switch-Scope 'ALL'; $txt.Focus() })
$btnClr.Add_Click({
    foreach ($item in $script:dt.Select('全选 = true')) { $item['全选'] = $false }
    & $updateCount
})
$form.Add_Shown({
    $layout.RowStyles[0].Height = [Math]::Max(90,$btnAll.Bottom + 15)
    $layout.RowStyles[2].Height = [Math]::Max(54,$btnOk.Bottom + 10)
    & $alignHeader
    $weights = @{ '全选'=28; '软件名称'=230; '版本'=65; '发行商'=145; '安装日期'=75; '来源'=116; '卸载方式'=76; 'GUID'=153 }
    foreach ($name in $weights.Keys) { $dgv.Columns[$name].FillWeight = $weights[$name] }
    foreach ($name in @('PackedGUID','UserPath','UninstallKey','UninstallString','HasMsi','HasAppwiz','IsWindowsInstaller')) {
        $dgv.Columns[$name].Visible = $false
    }
    Set-Filter
    $txt.Focus()
})
# 不设置 Form.AcceptButton；在实时搜索框按回车不会触发任何卸载动作。

function Confirm-SelectedRows {
    param([System.Data.DataRow[]]$Rows)
    $confirm = New-Object System.Windows.Forms.Form -Property @{
        Text='请确认全部选中的卸载项目';Width=930;Height=560;StartPosition='CenterParent'
        Font=(New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei UI',9))
        MinimumSize=(New-Object System.Drawing.Size -ArgumentList @(760,420))
    }
    $header = New-Object System.Windows.Forms.Label -Property @{
        Dock='Top';Height=66;Padding=(New-Object System.Windows.Forms.Padding -ArgumentList @(12,10,12,5))
        Text=("本次准备处理 $($Rows.Count) 项。MSI 项目失败后可强制清理安装登记；控制面板独有项目只执行正常卸载。`r`n已选项目包含其他筛选范围中的勾选，请逐项核对：")
    }
    $view = New-Object System.Windows.Forms.DataGridView -Property @{
        Dock='Fill';ReadOnly=$true;AllowUserToAddRows=$false;AllowUserToDeleteRows=$false
        RowHeadersVisible=$false;SelectionMode='FullRowSelect';AutoSizeColumnsMode='Fill'
    }
    $confirmTable = New-Object System.Data.DataTable
    foreach ($name in @('软件名称','版本','来源','卸载方式')) { [void]$confirmTable.Columns.Add($name,[string]) }
    foreach ($r in $Rows) {
        [void]$confirmTable.Rows.Add([string]$r['软件名称'],[string]$r['版本'],[string]$r['来源'],[string]$r['卸载方式'])
    }
    $view.DataSource = $confirmTable.DefaultView
    $buttons = New-Object System.Windows.Forms.Panel -Property @{Dock='Bottom';Height=55}
    $yes = New-Object System.Windows.Forms.Button -Property @{Text='确认开始卸载';Width=145;Height=33;DialogResult='Yes';Top=10;Left=610;Anchor='Top,Right'}
    $no = New-Object System.Windows.Forms.Button -Property @{Text='取消';Width=105;Height=33;DialogResult='No';Top=10;Left=765;Anchor='Top,Right'}
    $buttons.Controls.AddRange(@($yes,$no))
    $buttons.Add_Resize({
        $no.Left = $buttons.ClientSize.Width - $no.Width - 14
        $yes.Left = $no.Left - $yes.Width - 10
    })
    $confirm.Controls.Add($view)
    $confirm.Controls.Add($header)
    $confirm.Controls.Add($buttons)
    $confirm.CancelButton = $no
    try { return ($confirm.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::Yes) }
    finally { $confirm.Dispose() }
}

$script:selection = @()
$btnOk.Add_Click({
    $rows = @($script:dt.Select('全选 = true'))
    if ($rows.Count -eq 0) { [void](Show-Dialog '请先勾选要卸载的软件。' '尚未选择' 'OK' 'Information'); return }
    if (-not (Confirm-SelectedRows $rows)) { return }
    $script:selection = $rows
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

# ============================== 卸载核心 ==============================
function Invoke-Process {
    param([string]$FileName,[string]$Arguments,[bool]$Hidden = $false)
    try {
        $opt = @{ FilePath=$FileName; Wait=$true; PassThru=$true; ErrorAction='Stop' }
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) { $opt['ArgumentList'] = $Arguments }
        if ($Hidden) { $opt['WindowStyle'] = 'Hidden' }
        $p = Start-Process @opt
        return [pscustomobject]@{ Ok=$true; Code=[int]$p.ExitCode; Error='' }
    }
    catch { return [pscustomobject]@{ Ok=$false; Code=-1; Error=$_.Exception.Message } }
}

function Get-CleanTargets {
    param([System.Data.DataRow]$Row)
    if ([string]$Row['HasMsi'] -ne 'True') { throw '此项目没有 MSI UserData 记录，不允许强制清理。' }
    $packed = [string]$Row['PackedGUID']
    $guid = [string]$Row['GUID']
    if ($packed -notmatch '^[0-9A-Fa-f]{32}$' -or -not (Test-ProductGuid $guid)) {
        throw '无效的产品 GUID 或 PackedGUID，拒绝清理。'
    }
    if ($guid -ine (Convert-PackedGuid $packed)) { throw 'GUID 与 PackedGUID 不一致，拒绝清理。' }
    $origin = Get-NativeRegistryPath ([string]$Row['UserPath'])
    if ($origin -notmatch '^HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\[^\\]+\\Products\\[0-9A-Fa-f]{32}$' -or
        -not $origin.EndsWith(('\' + $packed),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'UserData 源路径不符合预期，拒绝清理。'
    }
    $candidate = @(
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        "HKLM\SOFTWARE\Classes\Installer\Products\$packed"
        "HKLM\SOFTWARE\Classes\Installer\Features\$packed"
        $origin
    )
    # 仅在当前用户的控制面板卸载记录确属 MSI 产品时才加入该键。
    $appKey = [string]$Row['UninstallKey']
    if ($appKey -match '^HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\\{[0-9A-Fa-f-]{36}\}$' -and
        $appKey.EndsWith(('\' + $guid),[StringComparison]::OrdinalIgnoreCase)) { $candidate += $appKey }
    $upgradeRoot = 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes'
    $upgradePaths = @()
    if (Test-Path -LiteralPath $upgradeRoot) {
        foreach ($key in @(Get-ChildItem -LiteralPath $upgradeRoot -ErrorAction Stop)) {
            if (@($key.GetValueNames()) -contains $packed) { $upgradePaths += (Get-NativeRegistryPath $key.PSPath) }
        }
    }
    $existingKeys = @()
    foreach ($native in ($candidate | Select-Object -Unique)) {
        $provider = Get-ProviderRegistryPath $native
        if ($provider -and (Test-Path -LiteralPath $provider)) { $existingKeys += $native }
    }
    # 键备份必须覆盖 UpgradeCodes 中将会删除值的父键；删除时只删匹配 packed 的值。
    foreach ($native in $upgradePaths) {
        $provider = Get-ProviderRegistryPath $native
        if ($provider -and (Test-Path -LiteralPath $provider)) { $existingKeys += $native }
    }
    return [pscustomobject]@{ KeyPaths=@($existingKeys | Select-Object -Unique); Packed=$packed; Origin=$origin }
}

function Backup-RegistryKeys {
    param([string[]]$NativePaths,[string]$ProductName)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $safe = [regex]::Replace($ProductName,'[^\p{L}\p{N} _.-]','_')
    if ($safe.Length -gt 42) { $safe = $safe.Substring(0,42) }
    $folder = Join-Path (Join-Path $script:baseDir 'Backups') ('{0}_{1}_{2}' -f $stamp,$safe,([Guid]::NewGuid().ToString('N').Substring(0,6)))
    [void][IO.Directory]::CreateDirectory($folder)
    for ($j=0; $j -lt $NativePaths.Count; $j++) {
        $native = $NativePaths[$j]
        $regFile = Join-Path $folder ('Key_{0:D2}.reg' -f ($j + 1))
        & reg.exe export $native $regFile /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $regFile) -or ((Get-Item -LiteralPath $regFile).Length -eq 0)) {
            throw "注册表备份失败：$native。未执行强制删除。备份目录：$folder"
        }
    }
    Write-Log ("备份完成：$folder；键数=$($NativePaths.Count)")
    return $folder
}

function Invoke-ForceRegistryCleanup {
    param([System.Data.DataRow]$Row)
    $name = [string]$Row['软件名称']
    try {
        $targets = Get-CleanTargets $Row
        if ($targets.KeyPaths.Count -eq 0) { throw '找不到与该 MSI 对应的安装登记项，未删除。' }
        $backupDir = Backup-RegistryKeys $targets.KeyPaths $name
        $errors = @()
        foreach ($native in $targets.KeyPaths) {
            $provider = Get-ProviderRegistryPath $native
            if ($native -match '^HKLM\\SOFTWARE\\Classes\\Installer\\UpgradeCodes\\') {
                try {
                    Remove-ItemProperty -LiteralPath $provider -Name $targets.Packed -Force -ErrorAction Stop
                    Write-Log ("清理 UpgradeCodes 中产品值：$native / $($targets.Packed)")
                }
                catch { $errors += "$native：$($_.Exception.Message)" }
            }
            else {
                try {
                    Remove-Item -LiteralPath $provider -Recurse -Force -ErrorAction Stop
                    Write-Log ("清理安装记录键：$native")
                }
                catch { $errors += "$native：$($_.Exception.Message)" }
            }
        }
        if ($errors.Count -gt 0) { throw ("部分清理失败：" + ($errors -join ' | ') + "；备份：$backupDir") }
        Write-Log ("MSI 登记清理完成：$name；备份：$backupDir")
        return '仅 MSI 安装登记已清理'
    }
    catch {
        Write-Log ("强制清理失败：$name；$($_.Exception.Message)")
        return ('强制清理失败：' + $_.Exception.Message)
    }
}

function Invoke-MsiUninstall {
    param([System.Data.DataRow]$Row)
    $name = [string]$Row['软件名称']
    $guid = [string]$Row['GUID']
    if (-not (Test-ProductGuid $guid)) { Write-Log ("MSI GUID 不合法：$name"); return '失败（无效 GUID）' }
    Write-Log ("MSI 卸载开始：$name；ProductCode=$guid")
    $result = Invoke-Process 'msiexec.exe' ("/x $guid REBOOT=ReallySuppress /qn") $true
    $code = [int]$result.Code
    if ($result.Ok -and $code -in @(0,3010,1641)) {
        Write-Log ("MSI 正常卸载成功：$name；退出码=$code")
        return '正常 MSI 卸载成功'
    }
    Write-Log ("MSI 卸载失败：$name；退出码=$code；$($result.Error)")
    if (-not $result.Ok) { return ('未能启动 msiexec：' + $result.Error) }
    if ($code -eq 1602) { return '已取消（1602，不强制清理）' }
    if ($code -eq 1618) { return '安装冲突（1618，稍后重试）' }

    if ($script:autoForceOnFailure) {
        Write-Log ("根据 INI 自动备份并强制清理：$name，退出码=$code")
        return (Invoke-ForceRegistryCleanup $Row)
    }
    $text = "MSI 正常卸载失败：$name`r`n产品 GUID：$guid`r`n错误码：$code`r`n`r`n是否先备份注册表，然后强制清理这个产品的 MSI 安装登记？`r`n`r`n注意：不会自动删除程序文件、服务或驱动，也不保证修复重新安装问题。"
    $answer = Show-Dialog $text 'MSI 卸载失败 - 是否强制清理' 'YesNo' 'Warning'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Log ("用户取消强制清理：$name")
        return ("MSI 卸载失败（$code），未清理")
    }
    return (Invoke-ForceRegistryCleanup $Row)
}

function Split-UninstallCommand {
    param([string]$RawCommand)
    $command = [Environment]::ExpandEnvironmentVariables($RawCommand.Trim())
    if ($command -match '^"([^"\r\n]+)"\s*(.*)$') { return @($matches[1],$matches[2]) }
    if ($command -match '^(.+?\.(?:exe|com))(?:\s+(.*))?$') { return @($matches[1],$matches[2]) }
    return @('','')
}
function Invoke-AppwizUninstall {
    param([System.Data.DataRow]$Row)
    $name = [string]$Row['软件名称']
    $cmd = [string]$Row['UninstallString']
    $isMsi = ([string]$Row['IsWindowsInstaller'] -eq 'True')
    $guid = [string]$Row['GUID']
    Write-Log ("控制面板卸载开始：$name；登记键=$($Row['UninstallKey'])")
    if ($isMsi -or ($cmd -match '(?i)^\s*"?[^"\r\n]*?\bmsiexec(?:\.exe)?"?(?:\s|$)')) {
        if (-not (Test-ProductGuid $guid)) { $guid = [regex]::Match($cmd,'\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}').Value }
        if (-not (Test-ProductGuid $guid)) {
            Write-Log ("控制面板 MSI 项目无法得到 ProductCode：$name")
            return '失败（没有有效 MSI ProductCode）'
        }
        # 控制面板独有 MSI 安装项只进行正常交互式卸载，不调用强制清理。
        $result = Invoke-Process 'msiexec.exe' ("/x $guid")
    }
    else {
        if ([string]::IsNullOrWhiteSpace($cmd)) { Write-Log ("没有正常卸载命令：$name"); return '跳过（无卸载命令）' }
        $parts = Split-UninstallCommand $cmd
        if (-not $parts[0]) { Write-Log ("命令无法解析：$cmd"); return '跳过（卸载命令不支持）' }
        $result = Invoke-Process ([string]$parts[0]) ([string]$parts[1])
    }
    if (-not $result.Ok) { Write-Log ("卸载器无法启动：$name；$($result.Error)"); return ('卸载器启动失败：' + $result.Error) }
    Write-Log ("控制面板卸载器已退出：$name；退出码=$($result.Code)")
    if ($result.Code -in @(0,3010,1641)) { return '正常卸载程序已退出（请确认结果）' }
    return ("卸载程序返回：$($result.Code)")
}

# 先关闭唯一窗体；之后逐条执行智能卸载。不是两个连续的 GUI 脚本。
if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $script:selection.Count -gt 0) {
    $msiSelected = @($script:selection | Where-Object { $_['HasMsi'] -eq 'True' }).Count
    Write-Log ("批量卸载开始：总数=$($script:selection.Count)；MSI=$msiSelected；控制面板独有=$($script:selection.Count-$msiSelected)")
    $outcomes = @()
    foreach ($item in $script:selection) {
        $name = [string]$item['软件名称']
        $method = if ([string]$item['HasMsi'] -eq 'True') { 'MSI' } else { '控制面板' }
        try {
            if ($method -eq 'MSI') { $status = Invoke-MsiUninstall $item }
            else { $status = Invoke-AppwizUninstall $item }
        }
        catch { $status = '处理异常'; Write-Log ("处理异常：$name；$($_.Exception.Message)") }
        $outcomes += [pscustomobject]@{ Name=$name; Method=$method; Status=[string]$status }
        Write-Log ("卸载任务结果：$name / $method / $status")
    }
    $resultText = @($outcomes | Select-Object -First 20 | ForEach-Object { "$($_.Name) [$($_.Method)]：$($_.Status)" }) -join "`r`n"
    if ($outcomes.Count -gt 20) { $resultText += "`r`n……更多详情请查看本地日志" }
    Write-Log ('批量任务结束；日志：' + $script:logPath)
    [void](Show-Dialog ("处理完毕，共 $($outcomes.Count) 项。`r`n`r`n$resultText`r`n`r`n日志：$script:logPath") '卸载结果' 'OK' 'Information')
}
else { Write-Log '用户关闭窗口，未执行卸载。' }
$form.Dispose()
