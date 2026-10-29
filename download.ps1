<#
.SYNOPSIS
    MSI 全局强制卸载清理器（图形界面版）
.DESCRIPTION
    读取 HKLM 下所有 MSI 产品的 InstallProperties，以表格形式列出，
    支持实时搜索、快捷筛选（Autodesk / VBA / SolidWorks）、勾选后
    调用 msiexec /x 强制卸载，并清理相关注册表残留。
.NOTES
    1. 必须以【管理员身份】运行，否则卸载与注册表清理会失败。
    2. 建议运行方式：
         powershell -NoProfile -ExecutionPolicy Bypass -File ".\MSI-Force-Uninstall.ps1"
    3. 本脚本会强删注册表键，请确认勾选项无误后再执行。
#>

# ============================================================
# 0. 环境准备
# ============================================================
Clear-Host
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Data

# ============================================================
# 1. 构建数据表
# ============================================================
$dt = New-Object System.Data.DataTable
[void]$dt.Columns.Add('全选', [bool])
'软件名称', '版本', '发行商', '安装日期', 'GUID', 'PackedGUID', 'UserPath' | ForEach-Object {
    [void]$dt.Columns.Add($_, [string])
}

# 枚举所有 MSI 产品的 InstallProperties
$regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties'
Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Sort-Object DisplayName |
    ForEach-Object {
        # ...\Products\<PackedGUID>
        $userPath   = Split-Path $_.PSPath -Parent
        $packedGuid = Split-Path $userPath -Leaf

        # 优先从 UninstallString 中提取标准 GUID
        $guid = [regex]::Match($_.UninstallString, '\{[0-9A-Fa-f\-]{36}\}').Value

        # 提取不到时，由 32 位 PackedGUID 还原标准 GUID
        if (-not $guid -and $packedGuid.Length -eq 32) {
            $guid = "{" +
                (-join $packedGuid[7..0]) + "-" +
                (-join $packedGuid[11..8]) + "-" +
                (-join $packedGuid[15..12]) + "-" +
                (-join $packedGuid[17, 16, 19, 18]) + "-" +
                (-join $packedGuid[21, 20, 23, 22, 25, 24, 27, 26, 29, 28, 31, 30]) +
                "}"
        }

        [void]$dt.Rows.Add(
            $false,
            $_.DisplayName,
            "$($_.DisplayVersion)",
            "$($_.Publisher)",
            "$($_.InstallDate)",
            $guid,
            $packedGuid,
            $userPath
        )
    }

# ============================================================
# 2. 创建窗体与控件
# ============================================================
$form = New-Object System.Windows.Forms.Form -Property @{
    Text          = '【MSI全局强制卸载清理器】点击【全选】表头可一键全选/取消（智能联动当前筛选结果）'
    Width         = 1050
    Height        = 650
    StartPosition = 'CenterScreen'
    Font          = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
}

# ---------- 顶部工具栏 ----------
$pTop = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 38 }

$lbl = New-Object System.Windows.Forms.Label -Property @{
    Text = '实时搜索：'; AutoSize = $true; Left = 10; Top = 10
}
$txt = New-Object System.Windows.Forms.TextBox -Property @{
    Left = 80; Top = 7; Width = 310
}
$btnA = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Autodesk'; Left = 395; Top = 6; Width = 75; Height = 26
}
$btnV = New-Object System.Windows.Forms.Button -Property @{
    Text = 'VBA'; Left = 475; Top = 6; Width = 45; Height = 26
}
$btnS = New-Object System.Windows.Forms.Button -Property @{
    Text = 'SolidWorks'; Left = 525; Top = 6; Width = 85; Height = 26
}
$btnR = New-Object System.Windows.Forms.Button -Property @{
    Text = '显示全部'; Left = 615; Top = 6; Width = 75; Height = 26
}
$lblCnt = New-Object System.Windows.Forms.Label -Property @{
    Text = '已勾选: 0 项'; AutoSize = $true; Left = 700; Top = 10; ForeColor = 'Blue'
}

$pTop.Controls.AddRange(@($lbl, $txt, $btnA, $btnV, $btnS, $btnR, $lblCnt))

# ---------- 底部按钮区 ----------
$pBot      = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 48 }
$pBotLeft  = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Left'; Width = 150 }
$pBotRight = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Right'; Width = 230 }

$btnClr = New-Object System.Windows.Forms.Button -Property @{
    Text = '清空已选'; Left = 10; Top = 8; Width = 110; Height = 32
}
$btnOk = New-Object System.Windows.Forms.Button -Property @{
    Text = '开始卸载并清理 (Enter)'; Left = 10; Top = 8; Width = 200; Height = 32
    DialogResult = 'OK'
}

$pBotLeft.Controls.Add($btnClr)
$pBotRight.Controls.Add($btnOk)
$pBot.Controls.AddRange(@($pBotRight, $pBotLeft))

$form.AcceptButton = $btnOk

# ---------- 数据表格 ----------
$dgv = New-Object System.Windows.Forms.DataGridView -Property @{
    Dock                 = 'Fill'
    DataSource           = $dt.DefaultView
    AllowUserToAddRows   = $false
    ReadOnly             = $true
    RowHeadersVisible    = $false
    SelectionMode        = 'FullRowSelect'
    MultiSelect          = $false
    AutoSizeColumnsMode  = 'Fill'
    BackgroundColor      = 'White'
}

$form.Controls.AddRange(@($dgv, $pTop, $pBot))

# ============================================================
# 3. 事件处理
# ============================================================

# 刷新勾选计数
$updateCount = {
    $dgv.Refresh()
    $lblCnt.Text = "已勾选: $(@($dt.Select('全选 = true')).Count) 项"
}

# 单击行：切换勾选状态
$dgv.Add_CellMouseDown({
    if ($_.RowIndex -ge 0 -and $_.Button -eq 'Left') {
        $row = $dgv.Rows[$_.RowIndex].DataBoundItem.Row
        $row['全选'] = -not $row['全选']
        & $updateCount
    }
})

# 点击【全选】表头：对当前筛选结果一键全选 / 取消
$dgv.Add_ColumnHeaderMouseClick({
    if ($_.ColumnIndex -eq 0) {
        $rows = @($dt.DefaultView | ForEach-Object { $_.Row })
        if ($rows) {
            # 若当前已全部勾选 → 取消全选；否则 → 全部勾选
            $newState = -not (($rows | Where-Object { $_['全选'] -eq $false }).Count -eq 0)
            $rows | ForEach-Object { $_['全选'] = $newState }
            & $updateCount
        }
    }
})

# 行着色
$dgv.Add_RowPrePaint({
    if ($_.RowIndex -ge 0) {
        $row     = $dgv.Rows[$_.RowIndex]
        $checked = $row.DataBoundItem.Row['全选']

        if ($checked) {
            $row.DefaultCellStyle.BackColor          = [System.Drawing.Color]::FromArgb(210, 238, 255)
            $row.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(145, 205, 255)
        }
        else {
            $row.DefaultCellStyle.BackColor          = 'White'
            $row.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
        }
        $row.DefaultCellStyle.SelectionForeColor = 'Black'
    }
})

# 实时搜索过滤
$txt.Add_TextChanged({
    $k = $txt.Text.Replace("'", "''").Replace("[", "[[]").Replace("*", "[*]").Replace("%", "[%]")
    $dt.DefaultView.RowFilter = if ($k) {
        "软件名称 LIKE '%$k%' OR 发行商 LIKE '%$k%' OR 版本 LIKE '%$k%' OR GUID LIKE '%$k%'"
    }
    else { "" }
})

# 快捷筛选按钮
$btnA.Add_Click({ $txt.Text = 'Autodesk';   $txt.Focus() })
$btnV.Add_Click({ $txt.Text = 'VBA';        $txt.Focus() })
$btnS.Add_Click({ $txt.Text = 'SolidWorks'; $txt.Focus() })
$btnR.Add_Click({ $txt.Text = '';           $txt.Focus() })

# 清空已选
$btnClr.Add_Click({
    $dt.Select('全选 = true') | ForEach-Object { $_['全选'] = $false }
    & $updateCount
})

# 窗体显示后：设置列宽 / 隐藏辅助列
$form.Add_Shown({
    $dgv.Columns['全选'].FillWeight      = 25
    $dgv.Columns['软件名称'].FillWeight  = 220
    $dgv.Columns['版本'].FillWeight      = 60
    $dgv.Columns['发行商'].FillWeight    = 110
    $dgv.Columns['安装日期'].FillWeight  = 55
    $dgv.Columns['GUID'].FillWeight      = 140
    $dgv.Columns['PackedGUID'].Visible   = $false
    $dgv.Columns['UserPath'].Visible     = $false
    $txt.Focus()
})

# ============================================================
# 4. 执行卸载与清理
# ============================================================
if ($form.ShowDialog() -eq 'OK') {

    $selected = @($dt.Select('全选 = true'))

    foreach ($p in $selected) {

        $guid       = $p['GUID']
        $packedGuid = $p['PackedGUID']

        Write-Host "正在强制卸载并清理: $($p['软件名称']) ($guid)..." -ForegroundColor Yellow

        # --- 调用 msiexec 强制卸载 ---
        if ($guid) {
            Start-Process msiexec.exe -ArgumentList "/x $guid ADSK_SETUP_EXE=1 MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress /qn" -Wait

            # 删除卸载信息残留
            $uninstallKeys = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
            )
            Remove-Item $uninstallKeys -Recurse -Force -ErrorAction SilentlyContinue
        }

        # --- 清理 UpgradeCodes 中的 PackedGUID 值 ---
        Remove-ItemProperty 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\*' `
            -Name $packedGuid -Force -ErrorAction SilentlyContinue

        # --- 清理 Products / Features / UserData 键 ---
        $installerKeys = @(
            "HKLM:\SOFTWARE\Classes\Installer\Products\$packedGuid"
            "HKLM:\SOFTWARE\Classes\Installer\Features\$packedGuid"
            $p['UserPath']
        )
        Remove-Item $installerKeys -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "已彻底强删: $($p['软件名称'])" -ForegroundColor Green
    }
}
