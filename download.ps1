<#
.SYNOPSIS
    MSI 全局卸载清理器 v2（MSI / appwiz.cpl 双通道）
.DESCRIPTION
    默认显示 MSI Installer UserData 中的产品；appwiz.cpl 按钮显示“程序和功能”卸载注册表项目。
    两个模式完全隔离：MSI 卸载失败才允许逐项确认并备份注册表后清理；
    appwiz.cpl 仅使用软件注册的正常卸载方式，不进行任何强制注册表清理。
.NOTES
    适用于 Windows PowerShell 5.1；以管理员运行 64 位 PowerShell。
    点击“显示全部”返回默认 MSI 列表；模式切换清空全部勾选。
    强制清理仅删除有限的安装登记项，不等于卸载软件文件，也不保证修复安装器。
#><#
.SYNOPSIS
    MSI 全局卸载清理器 v2.1（MSI / appwiz.cpl 双通道）
.DESCRIPTION
    默认显示 MSI Installer UserData 中的产品；appwiz.cpl 按钮显示“程序和功能”卸载注册表项目。
    两个模式完全隔离：MSI 卸载失败才允许逐项确认并备份注册表后清理；
    appwiz.cpl 仅使用软件注册的正常卸载方式，不进行任何强制注册表清理。
.NOTES
    适用于 Windows PowerShell 5.1；以管理员运行 64 位 PowerShell。
    点击“显示全部”返回默认 MSI 列表；模式切换清空全部勾选。
    强制清理仅删除有限的安装登记项，不等于卸载软件文件，也不保证修复安装器。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[System.Windows.Forms.Application]::EnableVisualStyles()

# 环境校验：避免 32 位注册表重定向造成误操作
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    [System.Windows.Forms.MessageBox]::Show('请使用 64 位 Windows PowerShell 运行，避免读取或清理错误的注册表视图。','运行环境错误','OK','Error') | Out-Null
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show('请右键以管理员身份运行 Windows PowerShell，再启动本脚本。','需要管理员权限','OK','Warning') | Out-Null
    return
}

$script:baseDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MSIUninstallCleaner'
$logDir = Join-Path $script:baseDir 'Logs'
[void][IO.Directory]::CreateDirectory($logDir)
$script:logPath = Join-Path $logDir ('Uninstall_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Warning ('写入日志失败：' + $_.Exception.Message) }
}

function Show-Dialog {
    param([string]$Text, [string]$Title = 'MSI 全局卸载清理器', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    return [System.Windows.Forms.MessageBox]::Show($Text,$Title,([System.Windows.Forms.MessageBoxButtons]$Buttons),([System.Windows.Forms.MessageBoxIcon]$Icon))
}

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

function New-Table {
    $t = New-Object System.Data.DataTable
    [void]$t.Columns.Add('全选',[bool])
    foreach ($n in @('软件名称','版本','发行商','安装日期','GUID','模式','PackedGUID','UserPath','UninstallKey','UninstallString','IsWindowsInstaller')) {
        [void]$t.Columns.Add($n,[string])
    }
    return ,$t
}

$script:dt = New-Table
$script:mode = 'MSI'

# 默认 MSI 清单保留原始 UserData 来源，避免与控制面板卸载注册表混合
function Add-MsiRows {
    $registry = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties'
    $items = @(Get-ItemProperty -Path $registry -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Sort-Object DisplayName)
    foreach ($i in $items) {
        $userPath = Split-Path -Path $i.PSPath -Parent
        $packed = Split-Path -Path $userPath -Leaf
        if ($packed -notmatch '^[0-9A-Fa-f]{32}$') { continue }
        # 以 PackedGUID 还原的产品码为准，避免 UninstallString 指向其他产品时发生误卸载。
        $guid = Convert-PackedGuid $packed
        [void]$script:dt.Rows.Add($false,[string]$i.DisplayName,[string]$i.DisplayVersion,[string]$i.Publisher,
            [string]$i.InstallDate,$guid,'MSI',$packed,$userPath,'',[string]$i.UninstallString,'True')
    }
}

# appwiz.cpl 视图：HKLM 64/32 位 + HKCU，忽略控制面板通常不展示的系统组件/补丁项。
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
                    if (-not [string]::IsNullOrEmpty([string]$sub.GetValue('ParentKeyName',''))) { continue }
                    if (-not [string]::IsNullOrEmpty([string]$sub.GetValue('ReleaseType',''))) { continue }
                    $isMsi = ([string]$sub.GetValue('WindowsInstaller','0') -eq '1')
                    $uninst = [string]$sub.GetValue('UninstallString','')
                    $guid = [regex]::Match($keyName,'^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$').Value
                    [void]$script:dt.Rows.Add($false,$name,[string]$sub.GetValue('DisplayVersion',''),
                        [string]$sub.GetValue('Publisher',''),[string]$sub.GetValue('InstallDate',''),
                        $guid,'appwiz','','',($r.Prefix + '\' + $keyName),$uninst,[string]$isMsi)
                }
                catch { Write-Log ('读取控制面板项目失败：' + $keyName + ' / ' + $_.Exception.Message) }
                finally { if ($null -ne $sub) { $sub.Close() } }
            }
        }
        catch { Write-Log ('读取注册表失败：' + $r.Prefix + ' / ' + $_.Exception.Message) }
        finally {
            if ($null -ne $uninstall) { $uninstall.Close() }
            if ($null -ne $base) { $base.Close() }
        }
    }
}

Write-Log '启动程序：加载 MSI 和控制面板信息。'
Add-MsiRows
Add-AppwizRows
$msiCount = @($script:dt.Select("模式 = 'MSI'")).Count
$appwizCount = @($script:dt.Select("模式 = 'appwiz'")).Count
Write-Log ("读取完成：MSI $msiCount 项，appwiz.cpl $appwizCount 项。")

# ============================== 图形界面 ==============================
$form = New-Object System.Windows.Forms.Form -Property @{
    Text='MSI 全局卸载清理器 v2.1｜MSI 强制清理 / appwiz.cpl 正常卸载（独立通道）'
    Width=1190; Height=700; StartPosition='CenterScreen'; Font=(New-Object -TypeName System.Drawing.Font -ArgumentList @('Microsoft YaHei UI',9))
    MinimumSize=(New-Object -TypeName System.Drawing.Size -ArgumentList @(1000,560))
}
# 使用三行表格布局让顶部、列表、底部各占独立的空间，杜绝 Dock=Fill 覆盖表头。
$pTop = New-Object System.Windows.Forms.Panel -Property @{ Dock='Fill'; Margin=[System.Windows.Forms.Padding]::Empty }
$lbl = New-Object System.Windows.Forms.Label -Property @{Text='实时搜索：'; Left=12; Top=12; AutoSize=$true}
$txt = New-Object System.Windows.Forms.TextBox -Property @{Left=85; Top=8; Width=315; Height=25}
$lblMode = New-Object System.Windows.Forms.Label -Property @{Text='当前：MSI 安装记录（可强制清理）'; Left=425; Top=12; Width=440; Height=22; ForeColor='DarkBlue'}
$lblCnt = New-Object System.Windows.Forms.Label -Property @{Text='已勾选：0 项'; AutoSize=$true; Left=860; Top=12; ForeColor='Blue'; Anchor='Top,Right'}
$pTop.Controls.AddRange(@($lbl,$txt,$lblMode,$lblCnt))

# 同一行自动布置快捷按钮；便于以后增删关键词
$x = 12
$quickButtons = @{}
foreach ($spec in @(@('Autodesk',85),@('VBA',55),@('SolidWorks',100),@('C++',60),@('Aspen',70))) {
    $name = [string]$spec[0]
    $button = New-Object System.Windows.Forms.Button -Property @{Text=$name; Left=$x; Top=43; Width=[int]$spec[1]; Height=29}
    $pTop.Controls.Add($button)
    $quickButtons[$name] = $button
    $x += [int]$spec[1] + 8
}
$btnApp = New-Object System.Windows.Forms.Button -Property @{Text='appwiz.cpl'; Left=$x; Top=43; Width=105; Height=29}
$x += 113
$btnR = New-Object System.Windows.Forms.Button -Property @{Text='显示全部 (MSI)'; Left=$x; Top=43; Width=130; Height=29}
$pTop.Controls.AddRange(@($btnApp,$btnR))

$pBot = New-Object System.Windows.Forms.Panel -Property @{Dock='Fill'; Margin=[System.Windows.Forms.Padding]::Empty}
$btnClr = New-Object System.Windows.Forms.Button -Property @{Text='清空已选'; Left=12; Top=9; Width=120; Height=32}
$btnOk = New-Object System.Windows.Forms.Button -Property @{Text='开始 MSI 卸载'; Width=220; Height=34; Top=9; Anchor='Top,Right'}
$btnOk.Left = 750 # 初始位置由下面 pBot.Resize 根据底栏可用宽度重新计算
$pBot.Controls.AddRange(@($btnClr,$btnOk))

$dgv = New-Object System.Windows.Forms.DataGridView -Property @{
    Dock='Fill'; DataSource=$script:dt.DefaultView; AllowUserToAddRows=$false; AllowUserToDeleteRows=$false;
    ReadOnly=$true; RowHeadersVisible=$false; SelectionMode='FullRowSelect'; MultiSelect=$false;
    AutoSizeColumnsMode='Fill'; BackgroundColor='White'; AllowUserToOrderColumns=$true
}
# 使用 TableLayoutPanel 彻底隔离顶部筛选区、DataGridView 和底部操作区。
# 与把多个 Dock 控件直接加入 Form 不同，表格布局不会让 DataGridView 的表头被顶部按钮遮盖。
$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
    Dock='Fill'; ColumnCount=1; RowCount=3; Padding=[System.Windows.Forms.Padding]::Empty; Margin=[System.Windows.Forms.Padding]::Empty
}
[void]$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent,100)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute,90)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent,100)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute,53)))
$dgv.Margin = [System.Windows.Forms.Padding]::Empty
$mainLayout.Controls.Add($pTop,0,0)
$mainLayout.Controls.Add($dgv,0,1)
$mainLayout.Controls.Add($pBot,0,2)
$form.Controls.Add($mainLayout)

# 状态信息按顶部面板实际宽度对齐，而不是使用固定 x=955（高 DPI 下容易跑出右边界）。
$alignHeader = {
    $lblCnt.Left = [Math]::Max(730, $pTop.ClientSize.Width - $lblCnt.PreferredWidth - 16)
    $lblMode.Width = [Math]::Max(290, $lblCnt.Left - $lblMode.Left - 12)
}
$pTop.Add_Resize($alignHeader)
$pBot.Add_Resize({
    $btnOk.Left = [Math]::Max(145, $pBot.ClientSize.Width - $btnOk.Width - 15)
})

$updateCount = {
    $total = @($script:dt.Select("全选 = true AND 模式 = '$script:mode'")).Count
    $lblCnt.Text = "已勾选：$total 项"
    $dgv.Refresh()
}

function Set-Filter {
    $keyword = $txt.Text
    $safe = $keyword.Replace("'","''").Replace('[','[[]').Replace(']','[]]').Replace('%','[%]').Replace('*','[*]')
    $where = "[模式] = '$script:mode'"
    if ($keyword.Length -gt 0) { $where += " AND ([软件名称] LIKE '%$safe%' OR [发行商] LIKE '%$safe%')" }
    try { $script:dt.DefaultView.RowFilter = $where }
    catch { $script:dt.DefaultView.RowFilter = "[模式] = '$script:mode'"; Write-Log ('搜索条件无效：' + $_.Exception.Message) }
}

function Switch-Mode {
    param([string]$Target)
    if ($script:mode -ne $Target) {
        foreach ($row in $script:dt.Select('全选 = true')) { $row['全选'] = $false }
        $script:mode = $Target
    }
    $txt.Text = ''
    if ($Target -eq 'MSI') {
        $lblMode.Text = '当前：MSI 安装记录（卸载失败可选强制清理）'
        $lblMode.ForeColor = 'DarkBlue'
        $btnOk.Text = '开始 MSI 卸载'
    }
    else {
        $lblMode.Text = '当前：appwiz.cpl 控制面板程序（仅正常卸载）'
        $lblMode.ForeColor = 'DarkGreen'
        $btnOk.Text = '开始正常卸载'
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
        $rows = @($script:dt.DefaultView | ForEach-Object { $_.Row })
        if ($rows.Count -gt 0) {
            $newValue = (@($rows | Where-Object { -not [bool]$_['全选'] }).Count -gt 0)
            foreach ($row in $rows) { $row['全选'] = $newValue }
            & $updateCount
        }
    }
})
$dgv.Add_RowPrePaint({
    if ($_.RowIndex -ge 0 -and $null -ne $dgv.Rows[$_.RowIndex].DataBoundItem) {
        $row = $dgv.Rows[$_.RowIndex]
        $checked = [bool]$row.DataBoundItem.Row['全选']
        $row.DefaultCellStyle.BackColor = if ($checked) {[System.Drawing.Color]::FromArgb(210,238,255)} else {[System.Drawing.Color]::White}
        $row.DefaultCellStyle.SelectionBackColor = if ($checked) {[System.Drawing.Color]::FromArgb(145,205,255)} else {[System.Drawing.Color]::FromArgb(235,235,235)}
        $row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
    }
})
$txt.Add_TextChanged({ Set-Filter })
foreach ($key in @($quickButtons.Keys)) {
    # GetNewClosure 确保各按钮不会全部指向最后一个关键词
    $word = $key
    $quickButtons[$key].Add_Click({ $txt.Text = $word; $txt.Focus() }.GetNewClosure())
}
$btnApp.Add_Click({ Switch-Mode 'appwiz'; $txt.Focus() })
$btnR.Add_Click({ Switch-Mode 'MSI'; $txt.Focus() })
$btnClr.Add_Click({
    foreach ($row in $script:dt.Select('全选 = true')) { $row['全选'] = $false }
    & $updateCount
})
$form.Add_Shown({
    # Windows DPI/字体缩放后依据实际按钮尺寸分配行高，防止 125%/150% 缩放时剪裁。
    $mainLayout.RowStyles[0].Height = [Math]::Max(90, $btnR.Bottom + 15)
    $mainLayout.RowStyles[2].Height = [Math]::Max(53, $btnOk.Bottom + 10)
    & $alignHeader
    $dgv.Columns['全选'].FillWeight = 27
    $dgv.Columns['软件名称'].FillWeight = 230
    $dgv.Columns['版本'].FillWeight = 66
    $dgv.Columns['发行商'].FillWeight = 135
    $dgv.Columns['安装日期'].FillWeight = 70
    $dgv.Columns['GUID'].FillWeight = 150
    foreach ($col in @('模式','PackedGUID','UserPath','UninstallKey','UninstallString','IsWindowsInstaller')) {
        $dgv.Columns[$col].Visible = $false
    }
    Set-Filter
    $txt.Focus()
})
# 底部按钮由 pBot.Resize 对齐，不再相对窗体宽度定位。
# 不设置 AcceptButton：在搜索框按 Enter 绝不触发卸载

$script:confirmedMode = $null
$script:selection = @()
$btnOk.Add_Click({
    $rows = @($script:dt.Select("全选 = true AND 模式 = '$script:mode'"))
    if ($rows.Count -eq 0) { [void](Show-Dialog '请先勾选要卸载的软件。' '未选择软件' 'OK' 'Information'); return }
    $preview = @($rows | Select-Object -First 18 | ForEach-Object { '• ' + $_['软件名称'] }) -join "`r`n"
    if ($rows.Count -gt 18) { $preview += "`r`n……还有 $($rows.Count-18) 项" }
    $caption = if ($script:mode -eq 'MSI') {
        'MSI 模式：先正常卸载；失败后逐项询问是否备份并强制清理安装记录。'
    } else { 'appwiz.cpl 模式：只调用原生卸载程序，不执行任何注册表强制清理。' }
    $answer = Show-Dialog ("确认卸载以下 $($rows.Count) 项？`r`n`r`n$caption`r`n`r`n$preview") '请确认全部卸载项目' 'YesNo' 'Warning'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $script:selection = $rows
    $script:confirmedMode = $script:mode
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

# ============================== 卸载与备份 ==============================
function Invoke-Process {
    param([string]$FileName,[string]$Arguments)
    try {
        if ([string]::IsNullOrWhiteSpace($Arguments)) {
            $p = Start-Process -FilePath $FileName -Wait -PassThru -ErrorAction Stop
        }
        else {
            $p = Start-Process -FilePath $FileName -ArgumentList $Arguments -Wait -PassThru -ErrorAction Stop
        }
        return [pscustomobject]@{ Ok=$true; Code=[int]$p.ExitCode; Error='' }
    }
    catch { return [pscustomobject]@{ Ok=$false; Code=-1; Error=$_.Exception.Message } }
}

function Get-CleanTargets {
    param([System.Data.DataRow]$Row)
    $pk = [string]$Row['PackedGUID']
    $guid = [string]$Row['GUID']
    if ($pk -notmatch '^[0-9A-Fa-f]{32}$' -or $guid -notmatch '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
        throw '产品 GUID 或 PackedGUID 无效；拒绝清理。'
    }
    if ($guid -ine (Convert-PackedGuid $pk)) { throw 'GUID 与 PackedGUID 不一致；拒绝清理。' }
    $origin = Get-NativeRegistryPath ([string]$Row['UserPath'])
    if ($origin -notmatch '^HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\[^\\]+\\Products\\[0-9A-Fa-f]{32}$' -or
        -not $origin.EndsWith('\' + $pk,[StringComparison]::OrdinalIgnoreCase)) {
        throw '产品 UserData 路径不符合预期；拒绝清理。'
    }
    $paths = @(
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        "HKLM\SOFTWARE\Classes\Installer\Products\$pk"
        "HKLM\SOFTWARE\Classes\Installer\Features\$pk"
        $origin
    )
    # UpgradeCodes 中仅删除名称为本产品 PackedGUID 的特定值，绝不删除整个 UpgradeCodes 键。
    $upgrade = 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes'
    if (Test-Path -LiteralPath $upgrade) {
        foreach ($item in @(Get-ChildItem -LiteralPath $upgrade -ErrorAction Stop)) {
            if (@($item.GetValueNames()) -contains $pk) { $paths += (Get-NativeRegistryPath $item.PSPath) }
        }
    }
    $existing = @()
    foreach ($native in ($paths | Select-Object -Unique)) {
        $provider = Get-ProviderRegistryPath $native
        if ($provider -and (Test-Path -LiteralPath $provider)) { $existing += $native }
    }
    return [pscustomobject]@{ KeyPaths=$existing; Packed=$pk; Origin=$origin }
}

function Backup-RegistryKeys {
    param([string[]]$NativePaths,[string]$ProductName)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $safeName = [regex]::Replace($ProductName,'[^\p{L}\p{N} _.-]','_')
    if ($safeName.Length -gt 45) { $safeName = $safeName.Substring(0,45) }
    $folder = Join-Path (Join-Path $script:baseDir 'Backups') ('{0}_{1}' -f $stamp,$safeName)
    [void][IO.Directory]::CreateDirectory($folder)
    for ($i=0; $i -lt $NativePaths.Count; $i++) {
        $target = $NativePaths[$i]
        $fileName = Join-Path $folder ('Key_{0:D2}.reg' -f ($i + 1))
        & reg.exe export $target $fileName /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fileName)) {
            throw "注册表备份失败：$target。未执行删除。备份目录：$folder"
        }
    }
    Write-Log ("注册表备份完成：$folder，$($NativePaths.Count) 个键。")
    return $folder
}

function Invoke-ForceRegistryCleanup {
    param([System.Data.DataRow]$Row)
    try {
        $targets = Get-CleanTargets $Row
        if ($targets.KeyPaths.Count -eq 0) { throw '未找到对应的 MSI 安装登记键，未执行清理。' }
        $backupDir = Backup-RegistryKeys $targets.KeyPaths ([string]$Row['软件名称'])
        # 仅备份完毕后才开始执行删除
        $errors = @()
        foreach ($native in $targets.KeyPaths) {
            $provider = Get-ProviderRegistryPath $native
            if ($native -match '^HKLM\\SOFTWARE\\Classes\\Installer\\UpgradeCodes\\') {
                try {
                    Remove-ItemProperty -LiteralPath $provider -Name $targets.Packed -Force -ErrorAction Stop
                    Write-Log ("已移除 UpgradeCodes 的产品值：$native -> $($targets.Packed)")
                }
                catch { $errors += "$native : $($_.Exception.Message)" }
            }
            else {
                try {
                    Remove-Item -LiteralPath $provider -Recurse -Force -ErrorAction Stop
                    Write-Log ("已清理注册表键：$native")
                }
                catch { $errors += "$native : $($_.Exception.Message)" }
            }
        }
        if ($errors.Count -gt 0) { throw ('部分项目清理失败：' + ($errors -join ' | ') + '；备份目录：' + $backupDir) }
        return [pscustomobject]@{ Success=$true; Message=('已清理登记项；备份：' + $backupDir) }
    }
    catch {
        Write-Log ('强制清理中止或失败：' + $_.Exception.Message)
        return [pscustomobject]@{Success=$false; Message=$_.Exception.Message}
    }
}

function Invoke-MsiUninstall {
    param([System.Data.DataRow]$Row)
    $name = [string]$Row['软件名称']
    $guid = [string]$Row['GUID']
    Write-Log ('MSI 卸载开始：' + $name + ' ' + $guid)
    $code = -1
    $reason = ''
    if ($guid -match '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
        # 不再给非 Autodesk 软件注入 ADSK_SETUP_EXE=1；使用 /qn 不弹 MSI 卸载界面
        $result = Invoke-Process 'msiexec.exe' ("/x $guid REBOOT=ReallySuppress /qn")
        $code = $result.Code
        if (-not $result.Ok) { $reason = $result.Error }
    }
    else { $reason = '无法识别有效的 MSI 产品 GUID。' }
    if ($code -in @(0,3010,1641)) {
        Write-Log ("MSI 正常卸载成功：$name；退出码：$code")
        return '成功'
    }
    Write-Log ("MSI 卸载失败：$name；退出码：$code；$reason")
    # 在卸载失败后才允许用户明确选择是否强制清理，且按软件逐项确认。
    $msg = "MSI 卸载失败：$name`r`n产品 GUID：$guid`r`n退出码：$code`r`n$reason`r`n`r`n是否备份后【仅强制删除该产品的 MSI 安装登记项】？`r`n`r`n注意：这不会删除软件文件，也不保证重装问题得到解决。`r`n请不要对可能正在安装、修复或升级的产品执行此操作。"
    $answer = Show-Dialog $msg 'MSI 卸载失败 - 可选强制清理' 'YesNo' 'Warning'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Log ("用户跳过 MSI 强制清理：$name")
        return '失败（已跳过清理）'
    }
    $clean = Invoke-ForceRegistryCleanup $Row
    if ($clean.Success) {
        Write-Log ("MSI 强制清理完成：$name；$($clean.Message)")
        return '仅安装登记已清理'
    }
    return '强制清理失败'
}

function Split-UninstallCommand {
    param([string]$RawCommand)
    $cmd = [Environment]::ExpandEnvironmentVariables($RawCommand.Trim())
    if ($cmd -match '^"([^"]+)"\s*(.*)$') { return @($matches[1],$matches[2]) }
    if ($cmd -match '^(.+?\.(?:exe|com))(?:\s+(.*))?$') { return @($matches[1],$matches[2]) }
    # 普通的可执行文件名（例如 rundll32.exe）也符合上一项
    return @('','')
}

function Invoke-AppwizUninstall {
    param([System.Data.DataRow]$Row)
    $name = [string]$Row['软件名称']
    $cmd = [string]$Row['UninstallString']
    $isMsi = ([string]$Row['IsWindowsInstaller'] -eq 'True')
    $guid = [string]$Row['GUID']
    Write-Log ('appwiz.cpl 正常卸载开始：' + $name + '；注册表路径：' + $Row['UninstallKey'])
    if ($isMsi -or $cmd -match '(?i)\bmsiexec(?:\.exe)?\b') {
        if (-not $guid) { $guid = [regex]::Match($cmd,'\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}').Value }
        if ($guid -notmatch '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
            Write-Log ('appwiz.cpl 项目缺少有效 GUID：' + $name)
            return '失败（无有效 MSI GUID）'
        }
        # 控制面板中的 MSI 项目：以交互式 /x 调用，绝不进入 MSI 强制清理通道
        $result = Invoke-Process 'msiexec.exe' ("/x $guid")
    }
    else {
        if ([string]::IsNullOrWhiteSpace($cmd)) { Write-Log ('无卸载命令：' + $name); return '跳过（无卸载命令）' }
        $parts = Split-UninstallCommand $cmd
        if (-not $parts[0]) {
            Write-Log ('无法安全解析卸载命令：' + $cmd)
            return '跳过（卸载命令格式不支持）'
        }
        # 直接调用注册的可执行文件及参数，不通过 cmd.exe /c，避免对字符串二次解释
        $result = Invoke-Process ([string]$parts[0]) ([string]$parts[1])
    }
    if (-not $result.Ok) {
        Write-Log ("appwiz.cpl 卸载无法启动：$name；$($result.Error)")
        return '失败（无法启动卸载程序）'
    }
    Write-Log ("appwiz.cpl 卸载器已退出：$name；退出码 $($result.Code)（非 MSI 卸载器的退出码不一定代表卸载成功）")
    if ($result.Code -in @(0,3010,1641)) { return '卸载器已正常退出（需确认是否卸载完成）' }
    return ('卸载器返回非成功码：' + $result.Code)
}

if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $script:selection.Count -gt 0) {
    Write-Log ("批量任务开始：模式=$script:confirmedMode；数量=$($script:selection.Count)")
    $outcomes = @()
    foreach ($item in $script:selection) {
        $name = [string]$item['软件名称']
        try {
            $status = if ($script:confirmedMode -eq 'MSI') { Invoke-MsiUninstall $item } else { Invoke-AppwizUninstall $item }
        }
        catch { $status = '处理异常'; Write-Log ("异常：$name；$($_.Exception.Message)") }
        $outcomes += [pscustomobject]@{ Name=$name; Status=[string]$status }
    }
    $summary = @($outcomes | Select-Object -First 18 | ForEach-Object { "$($_.Name)：$($_.Status)" }) -join "`r`n"
    if ($outcomes.Count -gt 18) { $summary += "`r`n……其余结果请查看日志" }
    Write-Log ('任务结束。日志：' + $script:logPath)
    [void](Show-Dialog ("处理完成，共 $($outcomes.Count) 项。`r`n`r`n$summary`r`n`r`n日志：$script:logPath") '任务处理结果' 'OK' 'Information')
}
else { Write-Log '用户关闭窗口；未执行卸载。' }
$form.Dispose()


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[System.Windows.Forms.Application]::EnableVisualStyles()

# 环境校验：避免 32 位注册表重定向造成误操作
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    [System.Windows.Forms.MessageBox]::Show('请使用 64 位 Windows PowerShell 运行，避免读取或清理错误的注册表视图。','运行环境错误','OK','Error') | Out-Null
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show('请右键以管理员身份运行 Windows PowerShell，再启动本脚本。','需要管理员权限','OK','Warning') | Out-Null
    return
}

$script:baseDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MSIUninstallCleaner'
$logDir = Join-Path $script:baseDir 'Logs'
[void][IO.Directory]::CreateDirectory($logDir)
$script:logPath = Join-Path $logDir ('Uninstall_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Warning ('写入日志失败：' + $_.Exception.Message) }
}

function Show-Dialog {
    param([string]$Text, [string]$Title = 'MSI 全局卸载清理器', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    return [System.Windows.Forms.MessageBox]::Show($Text,$Title,([System.Windows.Forms.MessageBoxButtons]$Buttons),([System.Windows.Forms.MessageBoxIcon]$Icon))
}

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

function New-Table {
    $t = New-Object System.Data.DataTable
    [void]$t.Columns.Add('全选',[bool])
    foreach ($n in @('软件名称','版本','发行商','安装日期','GUID','模式','PackedGUID','UserPath','UninstallKey','UninstallString','IsWindowsInstaller')) {
        [void]$t.Columns.Add($n,[string])
    }
    return ,$t
}

$script:dt = New-Table
$script:mode = 'MSI'

# 默认 MSI 清单保留原始 UserData 来源，避免与控制面板卸载注册表混合
function Add-MsiRows {
    $registry = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties'
    $items = @(Get-ItemProperty -Path $registry -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Sort-Object DisplayName)
    foreach ($i in $items) {
        $userPath = Split-Path -Path $i.PSPath -Parent
        $packed = Split-Path -Path $userPath -Leaf
        if ($packed -notmatch '^[0-9A-Fa-f]{32}$') { continue }
        # 以 PackedGUID 还原的产品码为准，避免 UninstallString 指向其他产品时发生误卸载。
        $guid = Convert-PackedGuid $packed
        [void]$script:dt.Rows.Add($false,[string]$i.DisplayName,[string]$i.DisplayVersion,[string]$i.Publisher,
            [string]$i.InstallDate,$guid,'MSI',$packed,$userPath,'',[string]$i.UninstallString,'True')
    }
}

# appwiz.cpl 视图：HKLM 64/32 位 + HKCU，忽略控制面板通常不展示的系统组件/补丁项。
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
                    if (-not [string]::IsNullOrEmpty([string]$sub.GetValue('ParentKeyName',''))) { continue }
                    if (-not [string]::IsNullOrEmpty([string]$sub.GetValue('ReleaseType',''))) { continue }
                    $isMsi = ([string]$sub.GetValue('WindowsInstaller','0') -eq '1')
                    $uninst = [string]$sub.GetValue('UninstallString','')
                    $guid = [regex]::Match($keyName,'^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$').Value
                    [void]$script:dt.Rows.Add($false,$name,[string]$sub.GetValue('DisplayVersion',''),
                        [string]$sub.GetValue('Publisher',''),[string]$sub.GetValue('InstallDate',''),
                        $guid,'appwiz','','',($r.Prefix + '\' + $keyName),$uninst,[string]$isMsi)
                }
                catch { Write-Log ('读取控制面板项目失败：' + $keyName + ' / ' + $_.Exception.Message) }
                finally { if ($null -ne $sub) { $sub.Close() } }
            }
        }
        catch { Write-Log ('读取注册表失败：' + $r.Prefix + ' / ' + $_.Exception.Message) }
        finally {
            if ($null -ne $uninstall) { $uninstall.Close() }
            if ($null -ne $base) { $base.Close() }
        }
    }
}

Write-Log '启动程序：加载 MSI 和控制面板信息。'
Add-MsiRows
Add-AppwizRows
$msiCount = @($script:dt.Select("模式 = 'MSI'")).Count
$appwizCount = @($script:dt.Select("模式 = 'appwiz'")).Count
Write-Log ("读取完成：MSI $msiCount 项，appwiz.cpl $appwizCount 项。")

# ============================== 图形界面 ==============================
$form = New-Object System.Windows.Forms.Form -Property @{
    Text='MSI 全局卸载清理器 v2｜MSI 强制清理 / appwiz.cpl 正常卸载（独立通道）'
    Width=1190; Height=700; StartPosition='CenterScreen'; Font=(New-Object -TypeName System.Drawing.Font -ArgumentList @('Microsoft YaHei UI',9))
    MinimumSize=(New-Object -TypeName System.Drawing.Size -ArgumentList @(1000,560))
}
$pTop = New-Object System.Windows.Forms.Panel -Property @{ Dock='Top'; Height=83 }
$lbl = New-Object System.Windows.Forms.Label -Property @{Text='实时搜索：'; Left=12; Top=12; AutoSize=$true}
$txt = New-Object System.Windows.Forms.TextBox -Property @{Left=85; Top=8; Width=315; Height=25}
$lblMode = New-Object System.Windows.Forms.Label -Property @{Text='当前：MSI 安装记录（可强制清理）'; Left=425; Top=12; Width=440; Height=22; ForeColor='DarkBlue'}
$lblCnt = New-Object System.Windows.Forms.Label -Property @{Text='已勾选：0 项'; AutoSize=$true; Left=955; Top=12; ForeColor='Blue'}
$pTop.Controls.AddRange(@($lbl,$txt,$lblMode,$lblCnt))

# 同一行自动布置快捷按钮；便于以后增删关键词
$x = 12
$quickButtons = @{}
foreach ($spec in @(@('Autodesk',85),@('VBA',55),@('SolidWorks',100),@('C++',60),@('Aspen',70))) {
    $name = [string]$spec[0]
    $button = New-Object System.Windows.Forms.Button -Property @{Text=$name; Left=$x; Top=43; Width=[int]$spec[1]; Height=29}
    $pTop.Controls.Add($button)
    $quickButtons[$name] = $button
    $x += [int]$spec[1] + 8
}
$btnApp = New-Object System.Windows.Forms.Button -Property @{Text='appwiz.cpl'; Left=$x; Top=43; Width=105; Height=29}
$x += 113
$btnR = New-Object System.Windows.Forms.Button -Property @{Text='显示全部 (MSI)'; Left=$x; Top=43; Width=130; Height=29}
$pTop.Controls.AddRange(@($btnApp,$btnR))

$pBot = New-Object System.Windows.Forms.Panel -Property @{Dock='Bottom'; Height=53}
$btnClr = New-Object System.Windows.Forms.Button -Property @{Text='清空已选'; Left=12; Top=9; Width=120; Height=32}
$btnOk = New-Object System.Windows.Forms.Button -Property @{Text='开始 MSI 卸载'; Width=220; Height=34; Top=9; Anchor='Top,Right'}
$btnOk.Left = $form.ClientSize.Width - 235
$pBot.Controls.AddRange(@($btnClr,$btnOk))

$dgv = New-Object System.Windows.Forms.DataGridView -Property @{
    Dock='Fill'; DataSource=$script:dt.DefaultView; AllowUserToAddRows=$false; AllowUserToDeleteRows=$false;
    ReadOnly=$true; RowHeadersVisible=$false; SelectionMode='FullRowSelect'; MultiSelect=$false;
    AutoSizeColumnsMode='Fill'; BackgroundColor='White'; AllowUserToOrderColumns=$true
}
$form.Controls.AddRange(@($dgv,$pTop,$pBot))
# 确保 Dock=Fill 不遮住顶部和底部
$pTop.BringToFront()
$pBot.BringToFront()

$updateCount = {
    $total = @($script:dt.Select("全选 = true AND 模式 = '$script:mode'")).Count
    $lblCnt.Text = "已勾选：$total 项"
    $dgv.Refresh()
}

function Set-Filter {
    $keyword = $txt.Text
    $safe = $keyword.Replace("'","''").Replace('[','[[]').Replace(']','[]]').Replace('%','[%]').Replace('*','[*]')
    $where = "[模式] = '$script:mode'"
    if ($keyword.Length -gt 0) { $where += " AND ([软件名称] LIKE '%$safe%' OR [发行商] LIKE '%$safe%')" }
    try { $script:dt.DefaultView.RowFilter = $where }
    catch { $script:dt.DefaultView.RowFilter = "[模式] = '$script:mode'"; Write-Log ('搜索条件无效：' + $_.Exception.Message) }
}

function Switch-Mode {
    param([string]$Target)
    if ($script:mode -ne $Target) {
        foreach ($row in $script:dt.Select('全选 = true')) { $row['全选'] = $false }
        $script:mode = $Target
    }
    $txt.Text = ''
    if ($Target -eq 'MSI') {
        $lblMode.Text = '当前：MSI 安装记录（卸载失败可选强制清理）'
        $lblMode.ForeColor = 'DarkBlue'
        $btnOk.Text = '开始 MSI 卸载'
    }
    else {
        $lblMode.Text = '当前：appwiz.cpl 控制面板程序（仅正常卸载）'
        $lblMode.ForeColor = 'DarkGreen'
        $btnOk.Text = '开始正常卸载'
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
        $rows = @($script:dt.DefaultView | ForEach-Object { $_.Row })
        if ($rows.Count -gt 0) {
            $newValue = (@($rows | Where-Object { -not [bool]$_['全选'] }).Count -gt 0)
            foreach ($row in $rows) { $row['全选'] = $newValue }
            & $updateCount
        }
    }
})
$dgv.Add_RowPrePaint({
    if ($_.RowIndex -ge 0 -and $null -ne $dgv.Rows[$_.RowIndex].DataBoundItem) {
        $row = $dgv.Rows[$_.RowIndex]
        $checked = [bool]$row.DataBoundItem.Row['全选']
        $row.DefaultCellStyle.BackColor = if ($checked) {[System.Drawing.Color]::FromArgb(210,238,255)} else {[System.Drawing.Color]::White}
        $row.DefaultCellStyle.SelectionBackColor = if ($checked) {[System.Drawing.Color]::FromArgb(145,205,255)} else {[System.Drawing.Color]::FromArgb(235,235,235)}
        $row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
    }
})
$txt.Add_TextChanged({ Set-Filter })
foreach ($key in @($quickButtons.Keys)) {
    # GetNewClosure 确保各按钮不会全部指向最后一个关键词
    $word = $key
    $quickButtons[$key].Add_Click({ $txt.Text = $word; $txt.Focus() }.GetNewClosure())
}
$btnApp.Add_Click({ Switch-Mode 'appwiz'; $txt.Focus() })
$btnR.Add_Click({ Switch-Mode 'MSI'; $txt.Focus() })
$btnClr.Add_Click({
    foreach ($row in $script:dt.Select('全选 = true')) { $row['全选'] = $false }
    & $updateCount
})
$form.Add_Shown({
    $dgv.Columns['全选'].FillWeight = 27
    $dgv.Columns['软件名称'].FillWeight = 230
    $dgv.Columns['版本'].FillWeight = 66
    $dgv.Columns['发行商'].FillWeight = 135
    $dgv.Columns['安装日期'].FillWeight = 70
    $dgv.Columns['GUID'].FillWeight = 150
    foreach ($col in @('模式','PackedGUID','UserPath','UninstallKey','UninstallString','IsWindowsInstaller')) {
        $dgv.Columns[$col].Visible = $false
    }
    Set-Filter
    $txt.Focus()
})
$form.Add_Resize({ $btnOk.Left = $form.ClientSize.Width - $btnOk.Width - 15 })
# 不设置 AcceptButton：在搜索框按 Enter 绝不触发卸载

$script:confirmedMode = $null
$script:selection = @()
$btnOk.Add_Click({
    $rows = @($script:dt.Select("全选 = true AND 模式 = '$script:mode'"))
    if ($rows.Count -eq 0) { [void](Show-Dialog '请先勾选要卸载的软件。' '未选择软件' 'OK' 'Information'); return }
    $preview = @($rows | Select-Object -First 18 | ForEach-Object { '• ' + $_['软件名称'] }) -join "`r`n"
    if ($rows.Count -gt 18) { $preview += "`r`n……还有 $($rows.Count-18) 项" }
    $caption = if ($script:mode -eq 'MSI') {
        'MSI 模式：先正常卸载；失败后逐项询问是否备份并强制清理安装记录。'
    } else { 'appwiz.cpl 模式：只调用原生卸载程序，不执行任何注册表强制清理。' }
    $answer = Show-Dialog ("确认卸载以下 $($rows.Count) 项？`r`n`r`n$caption`r`n`r`n$preview") '请确认全部卸载项目' 'YesNo' 'Warning'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $script:selection = $rows
    $script:confirmedMode = $script:mode
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

# ============================== 卸载与备份 ==============================
function Invoke-Process {
    param([string]$FileName,[string]$Arguments)
    try {
        if ([string]::IsNullOrWhiteSpace($Arguments)) {
            $p = Start-Process -FilePath $FileName -Wait -PassThru -ErrorAction Stop
        }
        else {
            $p = Start-Process -FilePath $FileName -ArgumentList $Arguments -Wait -PassThru -ErrorAction Stop
        }
        return [pscustomobject]@{ Ok=$true; Code=[int]$p.ExitCode; Error='' }
    }
    catch { return [pscustomobject]@{ Ok=$false; Code=-1; Error=$_.Exception.Message } }
}

function Get-CleanTargets {
    param([System.Data.DataRow]$Row)
    $pk = [string]$Row['PackedGUID']
    $guid = [string]$Row['GUID']
    if ($pk -notmatch '^[0-9A-Fa-f]{32}$' -or $guid -notmatch '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
        throw '产品 GUID 或 PackedGUID 无效；拒绝清理。'
    }
    if ($guid -ine (Convert-PackedGuid $pk)) { throw 'GUID 与 PackedGUID 不一致；拒绝清理。' }
    $origin = Get-NativeRegistryPath ([string]$Row['UserPath'])
    if ($origin -notmatch '^HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\[^\\]+\\Products\\[0-9A-Fa-f]{32}$' -or
        -not $origin.EndsWith('\' + $pk,[StringComparison]::OrdinalIgnoreCase)) {
        throw '产品 UserData 路径不符合预期；拒绝清理。'
    }
    $paths = @(
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        "HKLM\SOFTWARE\Classes\Installer\Products\$pk"
        "HKLM\SOFTWARE\Classes\Installer\Features\$pk"
        $origin
    )
    # UpgradeCodes 中仅删除名称为本产品 PackedGUID 的特定值，绝不删除整个 UpgradeCodes 键。
    $upgrade = 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes'
    if (Test-Path -LiteralPath $upgrade) {
        foreach ($item in @(Get-ChildItem -LiteralPath $upgrade -ErrorAction Stop)) {
            if (@($item.GetValueNames()) -contains $pk) { $paths += (Get-NativeRegistryPath $item.PSPath) }
        }
    }
    $existing = @()
    foreach ($native in ($paths | Select-Object -Unique)) {
        $provider = Get-ProviderRegistryPath $native
        if ($provider -and (Test-Path -LiteralPath $provider)) { $existing += $native }
    }
    return [pscustomobject]@{ KeyPaths=$existing; Packed=$pk; Origin=$origin }
}

function Backup-RegistryKeys {
    param([string[]]$NativePaths,[string]$ProductName)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $safeName = [regex]::Replace($ProductName,'[^\p{L}\p{N} _.-]','_')
    if ($safeName.Length -gt 45) { $safeName = $safeName.Substring(0,45) }
    $folder = Join-Path (Join-Path $script:baseDir 'Backups') ('{0}_{1}' -f $stamp,$safeName)
    [void][IO.Directory]::CreateDirectory($folder)
    for ($i=0; $i -lt $NativePaths.Count; $i++) {
        $target = $NativePaths[$i]
        $fileName = Join-Path $folder ('Key_{0:D2}.reg' -f ($i + 1))
        & reg.exe export $target $fileName /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fileName)) {
            throw "注册表备份失败：$target。未执行删除。备份目录：$folder"
        }
    }
    Write-Log ("注册表备份完成：$folder，$($NativePaths.Count) 个键。")
    return $folder
}

function Invoke-ForceRegistryCleanup {
    param([System.Data.DataRow]$Row)
    try {
        $targets = Get-CleanTargets $Row
        if ($targets.KeyPaths.Count -eq 0) { throw '未找到对应的 MSI 安装登记键，未执行清理。' }
        $backupDir = Backup-RegistryKeys $targets.KeyPaths ([string]$Row['软件名称'])
        # 仅备份完毕后才开始执行删除
        $errors = @()
        foreach ($native in $targets.KeyPaths) {
            $provider = Get-ProviderRegistryPath $native
            if ($native -match '^HKLM\\SOFTWARE\\Classes\\Installer\\UpgradeCodes\\') {
                try {
                    Remove-ItemProperty -LiteralPath $provider -Name $targets.Packed -Force -ErrorAction Stop
                    Write-Log ("已移除 UpgradeCodes 的产品值：$native -> $($targets.Packed)")
                }
                catch { $errors += "$native : $($_.Exception.Message)" }
            }
            else {
                try {
                    Remove-Item -LiteralPath $provider -Recurse -Force -ErrorAction Stop
                    Write-Log ("已清理注册表键：$native")
                }
                catch { $errors += "$native : $($_.Exception.Message)" }
            }
        }
        if ($errors.Count -gt 0) { throw ('部分项目清理失败：' + ($errors -join ' | ') + '；备份目录：' + $backupDir) }
        return [pscustomobject]@{ Success=$true; Message=('已清理登记项；备份：' + $backupDir) }
    }
    catch {
        Write-Log ('强制清理中止或失败：' + $_.Exception.Message)
        return [pscustomobject]@{Success=$false; Message=$_.Exception.Message}
    }
}

function Invoke-MsiUninstall {
    param([System.Data.DataRow]$Row)
    $name = [string]$Row['软件名称']
    $guid = [string]$Row['GUID']
    Write-Log ('MSI 卸载开始：' + $name + ' ' + $guid)
    $code = -1
    $reason = ''
    if ($guid -match '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
        # 不再给非 Autodesk 软件注入 ADSK_SETUP_EXE=1；使用 /qn 不弹 MSI 卸载界面
        $result = Invoke-Process 'msiexec.exe' ("/x $guid REBOOT=ReallySuppress /qn")
        $code = $result.Code
        if (-not $result.Ok) { $reason = $result.Error }
    }
    else { $reason = '无法识别有效的 MSI 产品 GUID。' }
    if ($code -in @(0,3010,1641)) {
        Write-Log ("MSI 正常卸载成功：$name；退出码：$code")
        return '成功'
    }
    Write-Log ("MSI 卸载失败：$name；退出码：$code；$reason")
    # 在卸载失败后才允许用户明确选择是否强制清理，且按软件逐项确认。
    $msg = "MSI 卸载失败：$name`r`n产品 GUID：$guid`r`n退出码：$code`r`n$reason`r`n`r`n是否备份后【仅强制删除该产品的 MSI 安装登记项】？`r`n`r`n注意：这不会删除软件文件，也不保证重装问题得到解决。`r`n请不要对可能正在安装、修复或升级的产品执行此操作。"
    $answer = Show-Dialog $msg 'MSI 卸载失败 - 可选强制清理' 'YesNo' 'Warning'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Log ("用户跳过 MSI 强制清理：$name")
        return '失败（已跳过清理）'
    }
    $clean = Invoke-ForceRegistryCleanup $Row
    if ($clean.Success) {
        Write-Log ("MSI 强制清理完成：$name；$($clean.Message)")
        return '仅安装登记已清理'
    }
    return '强制清理失败'
}

function Split-UninstallCommand {
    param([string]$RawCommand)
    $cmd = [Environment]::ExpandEnvironmentVariables($RawCommand.Trim())
    if ($cmd -match '^"([^"]+)"\s*(.*)$') { return @($matches[1],$matches[2]) }
    if ($cmd -match '^(.+?\.(?:exe|com))(?:\s+(.*))?$') { return @($matches[1],$matches[2]) }
    # 普通的可执行文件名（例如 rundll32.exe）也符合上一项
    return @('','')
}

function Invoke-AppwizUninstall {
    param([System.Data.DataRow]$Row)
    $name = [string]$Row['软件名称']
    $cmd = [string]$Row['UninstallString']
    $isMsi = ([string]$Row['IsWindowsInstaller'] -eq 'True')
    $guid = [string]$Row['GUID']
    Write-Log ('appwiz.cpl 正常卸载开始：' + $name + '；注册表路径：' + $Row['UninstallKey'])
    if ($isMsi -or $cmd -match '(?i)\bmsiexec(?:\.exe)?\b') {
        if (-not $guid) { $guid = [regex]::Match($cmd,'\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}').Value }
        if ($guid -notmatch '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
            Write-Log ('appwiz.cpl 项目缺少有效 GUID：' + $name)
            return '失败（无有效 MSI GUID）'
        }
        # 控制面板中的 MSI 项目：以交互式 /x 调用，绝不进入 MSI 强制清理通道
        $result = Invoke-Process 'msiexec.exe' ("/x $guid")
    }
    else {
        if ([string]::IsNullOrWhiteSpace($cmd)) { Write-Log ('无卸载命令：' + $name); return '跳过（无卸载命令）' }
        $parts = Split-UninstallCommand $cmd
        if (-not $parts[0]) {
            Write-Log ('无法安全解析卸载命令：' + $cmd)
            return '跳过（卸载命令格式不支持）'
        }
        # 直接调用注册的可执行文件及参数，不通过 cmd.exe /c，避免对字符串二次解释
        $result = Invoke-Process ([string]$parts[0]) ([string]$parts[1])
    }
    if (-not $result.Ok) {
        Write-Log ("appwiz.cpl 卸载无法启动：$name；$($result.Error)")
        return '失败（无法启动卸载程序）'
    }
    Write-Log ("appwiz.cpl 卸载器已退出：$name；退出码 $($result.Code)（非 MSI 卸载器的退出码不一定代表卸载成功）")
    if ($result.Code -in @(0,3010,1641)) { return '卸载器已正常退出（需确认是否卸载完成）' }
    return ('卸载器返回非成功码：' + $result.Code)
}

if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $script:selection.Count -gt 0) {
    Write-Log ("批量任务开始：模式=$script:confirmedMode；数量=$($script:selection.Count)")
    $outcomes = @()
    foreach ($item in $script:selection) {
        $name = [string]$item['软件名称']
        try {
            $status = if ($script:confirmedMode -eq 'MSI') { Invoke-MsiUninstall $item } else { Invoke-AppwizUninstall $item }
        }
        catch { $status = '处理异常'; Write-Log ("异常：$name；$($_.Exception.Message)") }
        $outcomes += [pscustomobject]@{ Name=$name; Status=[string]$status }
    }
    $summary = @($outcomes | Select-Object -First 18 | ForEach-Object { "$($_.Name)：$($_.Status)" }) -join "`r`n"
    if ($outcomes.Count -gt 18) { $summary += "`r`n……其余结果请查看日志" }
    Write-Log ('任务结束。日志：' + $script:logPath)
    [void](Show-Dialog ("处理完成，共 $($outcomes.Count) 项。`r`n`r`n$summary`r`n`r`n日志：$script:logPath") '任务处理结果' 'OK' 'Information')
}
else { Write-Log '用户关闭窗口；未执行卸载。' }
$form.Dispose()
