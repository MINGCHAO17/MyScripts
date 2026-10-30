<#
.SYNOPSIS
    MSI 全局卸载清理器 v2.3.1 - 统一清单，智能卸载通道
.DESCRIPTION
    显示全部 = MSI Installer UserData + 控制面板卸载记录，按 MSI ProductCode 精确关联去重。
    同一个 MSI 产品两种来源仅显示一行，按 MSI 通道卸载；仅控制面板记录走注册卸载程序。
    MSI 卸载失败时可询问或按本地 INI 自动强制清理已备份的产品安装登记项。
.NOTES
    Windows PowerShell 5.1 (64-bit) + 管理员权限；可通过 irm URL | iex 运行。
    强制清理仅移除特定 MSI 安装登记信息，不代表删除软件文件或修复所有安装问题。
#>

# 远程 irm ... | iex 时自动清屏；不向终端打印正常运行日志。
# 仅从 irm ... | iex 的独立控制台运行时，在关闭 GUI 后结束该 PowerShell 会话。
$script:closeConsoleOnExit = ([string]::IsNullOrWhiteSpace($PSCommandPath) -and $Host.Name -eq 'ConsoleHost' -and $PSVersionTable.PSVersion.Major -eq 5)
Clear-Host -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-Dialog {
    param([string]$Text, [string]$Title = 'MSI 全局卸载清理器 v2.3.1', [string]$Buttons = 'OK', [string]$Icon = 'Information')
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
Write-Log ('启动 v2.3.1；AutoForceOnFailure=' + [int]$script:autoForceOnFailure)

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
    Text='MSI 全局卸载清理器 v2.3.1｜MSI + 控制面板统一列表（智能通道）'
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

# ============================== 卸载核心 ==============================
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

function Split-UninstallCommand {
    param([string]$RawCommand)
    $command = [Environment]::ExpandEnvironmentVariables($RawCommand.Trim())
    if ($command -match '^"([^"\r\n]+)"\s*(.*)$') { return @($matches[1],$matches[2]) }
    if ($command -match '^(.+?\.(?:exe|com))(?:\s+(.*))?$') { return @($matches[1],$matches[2]) }
    return @('','')
}


# ======================= 可视化批量卸载队列 =======================
# 注意: PowerShell 5.1 会把中文弯引号视作字符串引号。
# 对 UI 提示文字请使用【】或普通括号, 避免字符串被意外截断。
# 使用 WinForms Timer 轮询子进程退出状态，不在 GUI 线程使用 Start-Process -Wait。
# 进度条表示已处理的软件数量；原生 EXE 卸载器不提供统一百分比接口。
$script:queue = $null

function Update-QueueCaption {
    if ($null -eq $script:queue) { return }
    $q = $script:queue
    $q.Progress.Value = [Math]::Min($q.Rows.Count,[Math]::Max(0,$q.Completed))
    $q.Stats.Text = ('已处理 {0}/{1} 项  |  成功 {2}  |  已清理安装登记 {3}  |  待核实 {4}  |  失败 {5}  |  跳过 {6}' -f
        $q.Completed,$q.Rows.Count,$q.Success,$q.Cleaned,$q.Review,$q.Failed,$q.Skipped)
    $q.Grid.Refresh()
}

function Complete-QueueRow {
    param([string]$Message,[string]$Category)
    $q = $script:queue
    if ($null -eq $q -or $q.ActiveIndex -lt 0) { return }
    $ix = $q.ActiveIndex
    $q.View.Rows[$ix]['执行状态'] = $Message
    $q.Completed++
    switch ($Category) {
        'Success' { $q.Success++ }
        'Cleaned' { $q.Cleaned++ }
        'Review'  { $q.Review++ }
        'Skipped' { $q.Skipped++ }
        default   { $q.Failed++ }
    }
    $name = [string]$q.Rows[$ix]['软件名称']
    Write-Log ("任务 $($ix+1)/$($q.Rows.Count)：$name，$Message")
    if ($null -ne $q.ActiveProcess) {
        try { $q.ActiveProcess.Dispose() } catch {}
        $q.ActiveProcess = $null
    }
    $q.ActiveIndex = -1
    $q.PendingAppwiz = $false
    $q.Continue.Visible = $false
    Update-QueueCaption
}

function Finish-UninstallQueue {
    $q = $script:queue
    if ($null -eq $q -or $q.Finished) { return }
    $q.Finished = $true
    $q.Timer.Stop()
    $q.Stop.Enabled = $false
    $q.Continue.Visible = $false
    $q.Close.Visible = $true
    $q.Header.Text = ('批量卸载处理结束。成功 {0} 项，清理 MSI 登记 {1} 项，待核实 {2} 项，失败 {3} 项，跳过 {4} 项。' -f
       $q.Success,$q.Cleaned,$q.Review,$q.Failed,$q.Skipped)
    $q.Current.Text = '任务已结束。可在下方逐项查看结果，点击【关闭程序】退出。'
    $q.Dlg.Text = 'MSI 全局卸载清理器 v2.3.1｜卸载结果'
    Update-QueueCaption
    Write-Log ('批量队列结束；日志：' + $script:logPath)
}

function Start-QueueProcess {
    $q = $script:queue
    if ($null -eq $q -or $q.Finished -or -not $q.Started -or $null -ne $q.ActiveProcess -or $q.ActiveIndex -ge 0) { return }
    if ($q.StopAfterCurrent -or $q.NextIndex -ge $q.Rows.Count) {
        if ($q.StopAfterCurrent) {
            for ($j=$q.NextIndex; $j -lt $q.Rows.Count; $j++) {
                $q.View.Rows[$j]['执行状态'] = '未执行（已停止后续任务）'
                $q.Skipped++
                $q.Completed++
            }
            Write-Log ('用户停止后续卸载任务；本轮正在执行的任务均已结束。')
        }
        Finish-UninstallQueue
        return
    }

    $ix = $q.NextIndex
    $q.NextIndex++
    $q.ActiveIndex = $ix
    $r = [System.Data.DataRow]$q.Rows[$ix]
    $name = [string]$r['软件名称']
    $q.View.Rows[$ix]['执行状态'] = '准备启动卸载器…'
    $method = if ([string]$r['HasMsi'] -eq 'True') { 'MSI' } else { '控制面板' }
    $q.ActiveMethod = $method
    $q.Current.Text = ('正在执行 {0}/{1}：{2}  [{3}]' -f ($ix+1),$q.Rows.Count,$name,$method)
    $q.Grid.ClearSelection()
    if ($ix -lt $q.Grid.Rows.Count) {
        $q.Grid.Rows[$ix].Selected = $true
        $q.Grid.FirstDisplayedScrollingRowIndex = $ix
    }
    Update-QueueCaption

    $filename = ''
    $arguments = ''
    $hidden = $false
    if ($method -eq 'MSI') {
        $guid = [string]$r['GUID']
        if (-not (Test-ProductGuid $guid)) {
            Complete-QueueRow '失败（MSI ProductCode 无效）' 'Failed'
            return
        }
        $filename = 'msiexec.exe'
        $arguments = "/x $guid REBOOT=ReallySuppress /qn"
        $hidden = $true
    }
    else {
        $rawCmd = [string]$r['UninstallString']
        $guid = [string]$r['GUID']
        $registeredMsi = ([string]$r['IsWindowsInstaller'] -eq 'True') -or
            ($rawCmd -match '(?i)^\s*"?[^"\r\n]*?\bmsiexec(?:\.exe)?"?(?:\s|$)')
        if ($registeredMsi) {
            if (-not (Test-ProductGuid $guid)) { $guid = [regex]::Match($rawCmd,'\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}').Value }
            if (-not (Test-ProductGuid $guid)) {
                Complete-QueueRow '跳过（未找到有效 MSI ProductCode）' 'Skipped'
                return
            }
            $filename = 'msiexec.exe'
            $arguments = "/x $guid"
        }
        elseif ([string]::IsNullOrWhiteSpace($rawCmd)) {
            Complete-QueueRow '跳过（没有登记卸载命令）' 'Skipped'
            return
        }
        else {
            $parts = @(Split-UninstallCommand $rawCmd)
            if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$parts[0])) {
                Complete-QueueRow '跳过（卸载命令无法安全解析）' 'Skipped'
                return
            }
            $filename = [string]$parts[0]
            $arguments = if ($parts.Count -ge 2) { [string]$parts[1] } else { '' }
        }
    }

    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $filename
        $info.Arguments = $arguments
        $info.UseShellExecute = -not $hidden
        if ($hidden) {
            $info.CreateNoWindow = $true
            $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        }
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) { throw '卸载器未能启动。' }
        $q.ActiveProcess = $process
        $q.ActiveStart = Get-Date
        $q.View.Rows[$ix]['执行状态'] = '卸载器运行中…'
        Write-Log ("卸载任务启动：$name；通道=$method；进程ID=$($process.Id)；命令=$filename $arguments")
    }
    catch {
        Write-Log ("卸载器启动失败：$name；$($_.Exception.Message)")
        Complete-QueueRow ('启动失败：' + $_.Exception.Message) 'Failed'
    }
}

function Check-QueueTick {
    $q = $script:queue
    if ($null -eq $q -or $q.Finished -or -not $q.Started) { return }
    if ($q.InTick) { return }
    $q.InTick = $true
    try {
        if ($q.PendingAppwiz) {
            $r = [System.Data.DataRow]$q.Rows[$q.ActiveIndex]
            $registryPath = Get-ProviderRegistryPath ([string]$r['UninstallKey'])
            $stillPresent = ($registryPath -and (Test-Path -LiteralPath $registryPath -ErrorAction SilentlyContinue))
            if (-not $stillPresent) {
                Complete-QueueRow '控制面板卸载记录已移除（请核实软件状态）' 'Success'
            }
            elseif ((Get-Date) -ge $q.VerifyUntil) {
                $q.Continue.Visible = $true
                $q.Current.Text = "卸载器已退出，但注册表仍显示该程序。确认原卸载程序已结束后，点击【继续下一项】。"
                $q.View.Rows[$q.ActiveIndex]['执行状态'] = '等待人工确认（卸载记录仍在）'
            }
            else {
                $left = [Math]::Ceiling(($q.VerifyUntil-(Get-Date)).TotalSeconds)
                $q.View.Rows[$q.ActiveIndex]['执行状态'] = "卸载器已退出，正在核对安装记录（剩余 $left 秒）"
            }
        }
        elseif ($null -ne $q.ActiveProcess) {
            $process = $q.ActiveProcess
            if ($process.HasExited) {
                $code = [int]$process.ExitCode
                $row = [System.Data.DataRow]$q.Rows[$q.ActiveIndex]
                $name = [string]$row['软件名称']
                Write-Log ("卸载器已退出：$name；退出码=$code；通道=$($q.ActiveMethod)")
                if ($q.ActiveMethod -eq 'MSI') {
                    if ($code -in @(0,3010,1641)) {
                        $status = if ($code -eq 3010) { 'MSI 卸载成功（需要重启）' } elseif ($code -eq 1641) { 'MSI 卸载成功（已发出重启请求）' } else { 'MSI 卸载成功' }
                        Complete-QueueRow $status 'Success'
                    }
                    elseif ($code -eq 1602) { Complete-QueueRow '已取消（1602，不强制清理）' 'Skipped' }
                    elseif ($code -eq 1618) { Complete-QueueRow '安装程序冲突（1618，未清理）' 'Skipped' }
                    else {
                        $force = $script:autoForceOnFailure
                        if (-not $force) {
                            $prompt = "MSI 正常卸载失败：$name`r`n退出码：$code`r`n`r`n是否先备份注册表，再强制清理该产品的 MSI 安装登记？`r`n不会自动删除软件文件、驱动或服务。"
                            $force = ([System.Windows.Forms.MessageBox]::Show($q.Dlg,$prompt,'卸载失败：强制清理？',
                                [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -eq [System.Windows.Forms.DialogResult]::Yes)
                        }
                        if ($force) {
                            $q.View.Rows[$q.ActiveIndex]['执行状态'] = '正在备份并清理 MSI 登记…'
                            $q.Dlg.Refresh()
                            $cleanup = [string](Invoke-ForceRegistryCleanup $row)
                            if ($cleanup -eq '仅 MSI 安装登记已清理') { Complete-QueueRow '已强制清理 MSI 安装登记（非完整卸载）' 'Cleaned' }
                            else { Complete-QueueRow ("卸载失败($code)；$cleanup") 'Failed' }
                        }
                        else { Complete-QueueRow "MSI 卸载失败($code)；未强制清理" 'Failed' }
                    }
                }
                else {
                    if ($code -in @(0,3010,1641)) {
                        $registryPath = Get-ProviderRegistryPath ([string]$row['UninstallKey'])
                        $stillPresent = ($registryPath -and (Test-Path -LiteralPath $registryPath -ErrorAction SilentlyContinue))
                        if (-not $stillPresent -and $registryPath) {
                            Complete-QueueRow '卸载记录已移除（请核实软件状态）' 'Success'
                        }
                        elseif (-not $registryPath) {
                            Complete-QueueRow '卸载器已退出（没有可核对的注册表项）' 'Review'
                        }
                        else {
                            try { $process.Dispose() } catch {}
                            $q.ActiveProcess = $null
                            $q.PendingAppwiz = $true
                            $q.VerifyUntil = (Get-Date).AddSeconds(8)
                            $q.View.Rows[$q.ActiveIndex]['执行状态'] = '卸载器已退出，核对安装记录中…'
                        }
                    }
                    else {
                        Complete-QueueRow "控制面板卸载器退出码 $code（未强制清理）" 'Failed'
                    }
                }
            }
            else {
                $elapsed = [int]((Get-Date)-$q.ActiveStart).TotalSeconds
                $q.View.Rows[$q.ActiveIndex]['执行状态'] = "卸载器运行中（$elapsed 秒）"
            }
        }
        if ($q.ActiveIndex -lt 0 -and -not $q.Finished) { Start-QueueProcess }
        Update-QueueCaption
    }
    catch {
        $errorText = $_.Exception.Message
        Write-Log ('队列轮询异常：' + $errorText)
        # 保守处理：不因 UI 轮询异常就放弃仍在运行的卸载器并启动下一项。
        $running = $false
        if ($null -ne $q.ActiveProcess) {
            try { $running = -not $q.ActiveProcess.HasExited } catch { $running = $true }
        }
        if ($running) {
            $q.StopAfterCurrent = $true
            $q.Stop.Enabled = $false
            $q.Current.Text = '进度监控异常，停止新任务，等待当前卸载器结束。详情请查看日志。'
        }
        elseif ($q.ActiveIndex -ge 0) { Complete-QueueRow ('处理异常：' + $errorText) 'Failed' }
    }
    finally { $q.InTick = $false }
}

function Show-BatchUninstallDialog {
    param([System.Data.DataRow[]]$Rows)
    $dlg = New-Object System.Windows.Forms.Form -Property @{
        Text='请确认批量卸载项目';Width=1050;Height=660;StartPosition='CenterParent'
        Font=(New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei UI',9))
        MinimumSize=(New-Object System.Drawing.Size -ArgumentList @(850,510))
    }
    $header = New-Object System.Windows.Forms.Label -Property @{
        Dock='Top';Height=66;Padding=(New-Object System.Windows.Forms.Padding -ArgumentList @(12,12,12,7))
        Text='本次待处理项目，请核对后开始卸载。'
    }
    # 格式字符串里的换行必须是真实回车，避免单引号输出反斜杠文字。
    $header.Text = "本次已勾选 $($Rows.Count) 个项目。MSI 走 MSI 卸载，失败时按 INI 决定是否清理登记；控制面板独有项目走正常卸载。`r`n请核对全部项目后开始，卸载过程中本窗口会保留并实时显示进度。"
    $grid = New-Object System.Windows.Forms.DataGridView -Property @{
        Dock='Fill';ReadOnly=$true;AllowUserToAddRows=$false;AllowUserToDeleteRows=$false
        RowHeadersVisible=$false;SelectionMode='FullRowSelect';MultiSelect=$false
        AutoSizeColumnsMode='Fill';BackgroundColor='White';AllowUserToOrderColumns=$false
    }
    $viewTable = New-Object System.Data.DataTable
    foreach ($name in @('软件名称','版本','来源','卸载方式','执行状态')) { [void]$viewTable.Columns.Add($name,[string]) }
    foreach ($r in $Rows) {
        [void]$viewTable.Rows.Add([string]$r['软件名称'],[string]$r['版本'],[string]$r['来源'],[string]$r['卸载方式'],'待处理')
    }
    $grid.DataSource = $viewTable.DefaultView
    $grid.Columns['软件名称'].FillWeight = 220
    $grid.Columns['版本'].FillWeight = 60
    $grid.Columns['来源'].FillWeight = 95
    $grid.Columns['卸载方式'].FillWeight = 63
    $grid.Columns['执行状态'].FillWeight = 185
    foreach ($column in $grid.Columns) { $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable }

    $foot = New-Object System.Windows.Forms.Panel -Property @{Dock='Bottom';Height=148}
    $labelCurrent = New-Object System.Windows.Forms.Label -Property @{Left=12;Top=8;AutoEllipsis=$true;Width=990;Height=25;Text='尚未开始卸载，请核对上方所有勾选的软件。'}
    $progress = New-Object System.Windows.Forms.ProgressBar -Property @{Left=12;Top=38;Width=1000;Height=21;Minimum=0;Maximum=[Math]::Max(1,$Rows.Count);Value=0;Style='Continuous'}
    $stats = New-Object System.Windows.Forms.Label -Property @{Left=12;Top=66;Width=990;Height=20;Text="已处理 0/$($Rows.Count) 项"}
    $start = New-Object System.Windows.Forms.Button -Property @{Text='确认开始卸载';Left=520;Top=97;Width=150;Height=34}
    $stop = New-Object System.Windows.Forms.Button -Property @{Text='取消';Left=680;Top=97;Width=120;Height=34}
    $continue = New-Object System.Windows.Forms.Button -Property @{Text='继续下一项';Left=805;Top=97;Width=125;Height=34;Visible=$false}
    $close = New-Object System.Windows.Forms.Button -Property @{Text='关闭程序';Left=805;Top=97;Width=125;Height=34;Visible=$false}
    $foot.Controls.AddRange(@($labelCurrent,$progress,$stats,$start,$stop,$continue,$close))
    $foot.Add_Resize({
        $w = $foot.ClientSize.Width
        $labelCurrent.Width = $w-24; $stats.Width=$w-24; $progress.Width=$w-24
        $close.Left=$w-$close.Width-13
        $continue.Left=$close.Left
        $stop.Left=$continue.Left-$stop.Width-10
        $start.Left=$stop.Left-$start.Width-10
    })
    $dlg.Controls.Add($grid)
    $dlg.Controls.Add($header)
    $dlg.Controls.Add($foot)

    $timer = New-Object System.Windows.Forms.Timer -Property @{Interval=400}
    $script:queue = @{
        Dlg=$dlg; Header=$header; Grid=$grid; View=$viewTable; Progress=$progress; Stats=$stats
        Current=$labelCurrent; Start=$start; Stop=$stop; Continue=$continue; Close=$close; Timer=$timer
        Rows=@($Rows); NextIndex=0; ActiveIndex=-1; ActiveProcess=$null; ActiveMethod=''; ActiveStart=Get-Date
        PendingAppwiz=$false; VerifyUntil=Get-Date; Started=$false; StopAfterCurrent=$false
        Finished=$false; Completed=0; Success=0; Cleaned=0; Review=0; Failed=0; Skipped=0; InTick=$false
    }
    $start.Add_Click({
        $q = $script:queue
        if ($q.Started) { return }
        $q.Started=$true
        $script:batchActuallyStarted=$true
        $q.Start.Enabled=$false
        $q.Stop.Text='停止后续任务'
        $q.Dlg.Text='MSI 全局卸载清理器 v2.3.1｜正在批量卸载'
        $q.Header.Text='批量卸载进行中：程序将逐项启动卸载器，下面实时记录处理结果。停止后续任务不会结束当前卸载器。'
        Write-Log ("批量卸载开始：共 $($q.Rows.Count) 项，自动强制清理=$([int]$script:autoForceOnFailure)")
        Start-QueueProcess
        $q.Timer.Start()
    })
    $stop.Add_Click({
        $q = $script:queue
        if (-not $q.Started) { $q.Dlg.Close(); return }
        if ($q.StopAfterCurrent) { return }
        $choice = [System.Windows.Forms.MessageBox]::Show($q.Dlg,
            '是否停止尚未执行的卸载任务？正在运行的卸载器不会被结束，待它执行完毕后队列停止。',
            '停止后续任务',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            $q.StopAfterCurrent = $true
            $q.Stop.Enabled = $false
            $q.Current.Text = '已请求停止：正在等待当前卸载器完成…'
            # 原生卸载器已经退出但未能核实记录的情形，可直接结束该项目并停止余下任务。
            if ($q.PendingAppwiz) {
                Complete-QueueRow '卸载器已退出（未核实；用户停止后续任务）' 'Review'
                Start-QueueProcess
            }
            elseif ($q.ActiveIndex -lt 0) { Start-QueueProcess }
        }
    })
    $continue.Add_Click({
        $q = $script:queue
        if (-not $q.PendingAppwiz -or $q.ActiveIndex -lt 0) { return }
        $r = [System.Data.DataRow]$q.Rows[$q.ActiveIndex]
        $key = Get-ProviderRegistryPath ([string]$r['UninstallKey'])
        $exists = ($key -and (Test-Path -LiteralPath $key -ErrorAction SilentlyContinue))
        if ($exists) {
            $reply = [System.Windows.Forms.MessageBox]::Show($q.Dlg,
                "该软件的控制面板卸载登记仍然存在。只有在确认原生卸载器已完成后才建议继续。`r`n是否继续队列，并将此项标记为【待核实】？",
                '确认卸载器状态',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($reply -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Complete-QueueRow '卸载器已退出（卸载登记仍在，待核实）' 'Review'
        }
        else { Complete-QueueRow '卸载记录已移除（请核实软件状态）' 'Success' }
        Start-QueueProcess
    })
    $close.Add_Click({ $script:queue.Dlg.Close() })
    $timer.Add_Tick({ Check-QueueTick })
    $dlg.Add_FormClosing({
        $q = $script:queue
        if ($null -ne $q -and $q.Started -and -not $q.Finished) {
            $_.Cancel=$true
            [void][System.Windows.Forms.MessageBox]::Show($q.Dlg,
                '卸载任务仍在进行。请先点击【停止后续任务】，等待当前卸载器结束，再关闭窗口。',
                '正在卸载',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })
    try { [void]$dlg.ShowDialog($form) }
    finally {
        $timer.Stop(); $timer.Dispose()
        if ($null -ne $script:queue.ActiveProcess) { try { $script:queue.ActiveProcess.Dispose() } catch {} }
        $dlg.Dispose()
        $script:queue=$null
    }
}

$btnOk.Add_Click({
    $rows = @($script:dt.Select('全选 = true'))
    if ($rows.Count -eq 0) { [void](Show-Dialog '请先勾选要卸载的软件。' '尚未选择' 'OK' 'Information'); return }
    $script:batchActuallyStarted=$false
    Show-BatchUninstallDialog $rows
    # 确认对话框一旦启动卸载并最终关闭，原主窗口也关闭；取消确认则返回列表。
    if ($null -eq $script:queue -and $script:batchActuallyStarted) { $form.Close() }
})

# 记录是否真正开始任务，以区分【取消确认】与【处理完毕后关闭】。
# 在对话框中开始时设置，在对话框关闭后由主窗体点击事件读取。
$script:batchActuallyStarted=$false

[void]$form.ShowDialog()
Write-Log 'GUI 已关闭。'
$form.Dispose()

# 对于从 irm URL | iex 运行的独立 Windows PowerShell 5.1 控制台，按用户要求结束该会话。
# 运行本地 .ps1 时不主动退出用户原有的 PowerShell 会话。
if ($script:closeConsoleOnExit) { [Environment]::Exit(0) }
