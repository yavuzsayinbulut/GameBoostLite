# Theme and small control factories shared by every page.

$script:theme = @{
    Window      = [Drawing.Color]::FromArgb(13, 16, 22)
    Sidebar     = [Drawing.Color]::FromArgb(17, 21, 28)
    Card        = [Drawing.Color]::FromArgb(23, 28, 37)
    CardBorder  = [Drawing.Color]::FromArgb(36, 43, 56)
    Inset       = [Drawing.Color]::FromArgb(17, 21, 28)
    GridLine    = [Drawing.Color]::FromArgb(36, 43, 56)
    Text        = [Drawing.Color]::FromArgb(230, 235, 243)
    SubText     = [Drawing.Color]::FromArgb(150, 160, 178)
    Muted       = [Drawing.Color]::FromArgb(104, 114, 132)
    Accent      = [Drawing.Color]::FromArgb(46, 204, 128)
    Blue        = [Drawing.Color]::FromArgb(92, 160, 255)
    Amber       = [Drawing.Color]::FromArgb(255, 186, 84)
    Red         = [Drawing.Color]::FromArgb(255, 99, 99)
    Neutral     = [Drawing.Color]::FromArgb(48, 57, 73)
    Selection   = [Drawing.Color]::FromArgb(40, 52, 70)
}

$script:iconFontName = if ((New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains 'Segoe Fluent Icons') {
    'Segoe Fluent Icons'
} else { 'Segoe MDL2 Assets' }
$script:monoFontName = if ((New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains 'Cascadia Mono') {
    'Cascadia Mono'
} else { 'Consolas' }

$script:fonts = @{
    PageTitle = [Drawing.Font]::new('Segoe UI Semibold', 17)
    PageSub   = [Drawing.Font]::new('Segoe UI', 9.5)
    CardTitle = [Drawing.Font]::new('Segoe UI Semibold', 11)
    Body      = [Drawing.Font]::new('Segoe UI', 9.5)
    BodyBold  = [Drawing.Font]::new('Segoe UI Semibold', 9.5)
    Small     = [Drawing.Font]::new('Segoe UI', 8.75)
    Status    = [Drawing.Font]::new('Segoe UI Semibold', 20)
    Score     = [Drawing.Font]::new('Segoe UI Semibold', 32)
    Button    = [Drawing.Font]::new('Segoe UI Semibold', 9.5)
    BigButton = [Drawing.Font]::new('Segoe UI Semibold', 11.5)
    Mono      = [Drawing.Font]::new($script:monoFontName, 9)
    Logo      = [Drawing.Font]::new('Segoe UI Semibold', 15)
}

$script:toolTip = [Windows.Forms.ToolTip]::new()
$script:toolTip.AutoPopDelay = 12000
$script:toolTip.InitialDelay = 400

function New-UiLabel {
    param(
        $Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 0, [int]$Height = 0,
        $Font = $script:fonts.Body, $Color = $script:theme.Text, [switch]$Wrap
    )
    $label = [Windows.Forms.Label]::new()
    $label.UseMnemonic = $false
    $label.Text = $Text
    $label.Font = $Font
    $label.ForeColor = $Color
    $label.BackColor = Get-UiSurfaceColor $Parent
    $label.Location = [Drawing.Point]::new($X, $Y)
    if ($Width -gt 0) {
        $label.AutoSize = $false
        $label.Size = [Drawing.Size]::new($Width, [math]::Max($Height, 20))
        $label.AutoEllipsis = -not $Wrap
    } else {
        $label.AutoSize = $true
    }
    $Parent.Controls.Add($label)
    return $label
}

function Set-UiDarkScrollbars {
    param($Control)
    $Control.Add_HandleCreated({ [GameBoostWindow]::UseDarkScrollbars($this) })
}

# Cards paint their own fill; children must use that fill as their background.
function Get-UiSurfaceColor {
    param($Control)
    if ($Control -is [GameBoostCard]) { return $Control.FillColor }
    return $Control.BackColor
}

function New-UiCard {
    param($Parent, [string]$Title, [int]$X, [int]$Y, [int]$Width, [int]$Height)
    $card = [GameBoostCard]::new()
    $card.FillColor = $script:theme.Card
    $card.BorderColor = $script:theme.CardBorder
    $card.BackColor = Get-UiSurfaceColor $Parent
    $card.Location = [Drawing.Point]::new($X, $Y)
    $card.Size = [Drawing.Size]::new($Width, $Height)
    $Parent.Controls.Add($card)
    if ($Title) { [void](New-UiLabel $card $Title 18 14 -Font $script:fonts.CardTitle) }
    return $card
}

function New-UiButton {
    param(
        $Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 34,
        $Accent = $script:theme.Neutral, [scriptblock]$OnClick, [string]$Tip, $Font = $script:fonts.Button
    )
    $button = [GameBoostButton]::new()
    $button.Text = $Text
    $button.AccentColor = $Accent
    $button.TextColor = if ($Accent -eq $script:theme.Accent) { [Drawing.Color]::FromArgb(8, 28, 18) } else { [Drawing.Color]::White }
    $button.BackColor = Get-UiSurfaceColor $Parent
    $button.Font = $Font
    $button.Location = [Drawing.Point]::new($X, $Y)
    $button.Size = [Drawing.Size]::new($Width, $Height)
    if ($OnClick) { $button.Add_Click($OnClick) }
    if ($Tip) { $script:toolTip.SetToolTip($button, $Tip) }
    $Parent.Controls.Add($button)
    return $button
}

function New-UiToggle {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$Checked, [string]$Tip)
    $toggle = [GameBoostToggle]::new()
    $toggle.Text = $Text
    $toggle.Checked = $Checked
    $toggle.Font = $script:fonts.Body
    $toggle.OnColor = $script:theme.Accent
    $toggle.TextColor = $script:theme.Text
    $toggle.BackColor = Get-UiSurfaceColor $Parent
    $toggle.Location = [Drawing.Point]::new($X, $Y)
    $toggle.Size = [Drawing.Size]::new($Width, 30)
    if ($Tip) { $script:toolTip.SetToolTip($toggle, $Tip) }
    $Parent.Controls.Add($toggle)
    return $toggle
}

function New-UiTextBox {
    param($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Text = '', [switch]$Mono)
    $box = [Windows.Forms.RichTextBox]::new()
    $box.ReadOnly = $true
    $box.BorderStyle = 'None'
    $box.BackColor = $script:theme.Inset
    $box.ForeColor = $script:theme.Text
    $box.Font = if ($Mono) { $script:fonts.Mono } else { $script:fonts.Body }
    $box.DetectUrls = $false
    $box.ScrollBars = 'Vertical'
    $box.Location = [Drawing.Point]::new($X, $Y)
    $box.Size = [Drawing.Size]::new($Width, $Height)
    $box.Text = $Text
    Set-UiDarkScrollbars $box
    $Parent.Controls.Add($box)
    return $box
}

# Segmented tabs: one button per tab, the tab pages are panels in the same place.
function New-UiTabs {
    param($Parent, [int]$X, [int]$Y, [string[]]$Names, [int[]]$Widths, [Drawing.Rectangle]$Area)
    $tabs = [pscustomobject]@{ Buttons = [Collections.Generic.List[object]]::new(); Panels = [Collections.Generic.List[object]]::new(); Index = 0; Changed = $null }
    $left = $X
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $button = New-UiButton $Parent $Names[$i] $left $Y $Widths[$i] 30
        $button.Tag = [pscustomobject]@{ Tabs = $tabs; Index = $i }
        $button.Add_Click({ Select-UiTab $this.Tag.Tabs $this.Tag.Index })
        $tabs.Buttons.Add($button)
        $panel = [Windows.Forms.Panel]::new()
        $panel.BackColor = Get-UiSurfaceColor $Parent
        $panel.Location = $Area.Location
        $panel.Size = $Area.Size
        $Parent.Controls.Add($panel)
        $tabs.Panels.Add($panel)
        $left += $Widths[$i] + 6
    }
    Select-UiTab $tabs 0
    return $tabs
}

function Select-UiTab {
    param($Tabs, [int]$Index)
    $Tabs.Index = $Index
    for ($i = 0; $i -lt $Tabs.Buttons.Count; $i++) {
        $on = $i -eq $Index
        $Tabs.Panels[$i].Visible = $on
        $Tabs.Buttons[$i].AccentColor = if ($on) { $script:theme.Accent } else { $script:theme.Neutral }
        $Tabs.Buttons[$i].TextColor = if ($on) { [Drawing.Color]::FromArgb(8, 28, 18) } else { [Drawing.Color]::White }
        $Tabs.Buttons[$i].Invalidate()
    }
    if ($Tabs.Changed) { & $Tabs.Changed $Index }
}

function New-UiAlertView {
    param($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height)
    $view = [GameBoostAlertView]::new()
    $view.BackColor = Get-UiSurfaceColor $Parent
    $view.TextColor = $script:theme.Text
    $view.DetailColor = $script:theme.SubText
    $view.Location = [Drawing.Point]::new($X, $Y)
    $view.Size = [Drawing.Size]::new($Width, $Height)
    Set-UiDarkScrollbars $view
    $Parent.Controls.Add($view)
    return $view
}

function Set-UiAlerts {
    param($View, $Alerts, [int]$Limit = 0)
    if ($null -eq $View) { return }
    $order = @{ critical = 0; warning = 1; info = 2; ok = 3 }
    $sorted = @($Alerts | Where-Object { $_ } | Sort-Object { $order[$_.Severity] })
    if ($Limit -gt 0) { $sorted = @($sorted | Select-Object -First $Limit) }
    $View.ClearItems()
    if ($sorted.Count -eq 0) { $View.AddItem('ok', 'Her şey yolunda', 'Şu an önerilecek bir şey yok.') }
    foreach ($alert in $sorted) { $View.AddItem($alert.Severity, $alert.Title, $alert.Detail) }
    $View.Commit()
}

function New-UiGrid {
    param($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height, [string[]]$Columns, [int[]]$Widths)
    $grid = [Windows.Forms.DataGridView]::new()
    $grid.Location = [Drawing.Point]::new($X, $Y)
    $grid.Size = [Drawing.Size]::new($Width, $Height)
    $grid.BackgroundColor = $script:theme.Inset
    $grid.BorderStyle = 'None'
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.GridColor = $script:theme.GridLine
    $grid.ForeColor = $script:theme.Text
    $grid.Font = $script:fonts.Body
    $grid.DefaultCellStyle.BackColor = $script:theme.Inset
    $grid.DefaultCellStyle.ForeColor = $script:theme.Text
    $grid.DefaultCellStyle.SelectionBackColor = $script:theme.Selection
    $grid.DefaultCellStyle.SelectionForeColor = $script:theme.Text
    $grid.DefaultCellStyle.Padding = [Windows.Forms.Padding]::new(6, 0, 6, 0)
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $script:theme.Card
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:theme.SubText
    $grid.ColumnHeadersDefaultCellStyle.Font = $script:fonts.BodyBold
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:theme.Card
    $grid.ColumnHeadersDefaultCellStyle.Padding = [Windows.Forms.Padding]::new(6, 0, 6, 0)
    $grid.ColumnHeadersBorderStyle = 'None'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ColumnHeadersHeight = 32
    $grid.RowTemplate.Height = 30
    $grid.EnableHeadersVisualStyles = $false
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.ClipboardCopyMode = 'EnableWithoutHeaderText'
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $index = $grid.Columns.Add("c$i", $Columns[$i])
        $grid.Columns[$index].SortMode = 'NotSortable'
        if ($i -lt $Widths.Count -and $Widths[$i] -gt 0) { $grid.Columns[$index].Width = $Widths[$i] }
        else { $grid.Columns[$index].AutoSizeMode = 'Fill' }
    }
    Set-UiDarkScrollbars $grid
    $Parent.Controls.Add($grid)
    return $grid
}

function Set-UiGridRows {
    param($Grid, $Rows, [string]$EmptyText = 'Bulunamadı')
    $Grid.Rows.Clear()
    $count = 0
    foreach ($row in $Rows) {
        if ($null -eq $row) { continue }
        $values = @($row.Values)
        $index = $Grid.Rows.Add($values)
        if ($row.Color) { $Grid.Rows[$index].DefaultCellStyle.ForeColor = $row.Color }
        $count++
    }
    if ($count -eq 0) {
        $empty = [object[]]::new($Grid.Columns.Count)
        $empty[0] = $EmptyText
        $index = $Grid.Rows.Add($empty)
        $Grid.Rows[$index].DefaultCellStyle.ForeColor = $script:theme.Muted
    }
    $Grid.ClearSelection()
}

function New-UiRow {
    param([object[]]$Values, $Color)
    return [pscustomobject]@{ Values = $Values; Color = $Color }
}

# Two column "key: value" lines inside a card.
function New-UiKeyValues {
    param($Parent, [string[]]$Keys, [int]$X, [int]$Y, [int]$KeyWidth, [int]$ValueWidth, [int]$RowHeight = 26)
    $labels = @{}
    for ($i = 0; $i -lt $Keys.Count; $i++) {
        $top = $Y + ($i * $RowHeight)
        [void](New-UiLabel $Parent $Keys[$i] $X $top $KeyWidth 22 -Color $script:theme.SubText)
        $labels[$Keys[$i]] = New-UiLabel $Parent '—' ($X + $KeyWidth) $top $ValueWidth 22
    }
    return $labels
}

function Set-UiValue {
    param($Labels, [string]$Key, [string]$Value, $Color = $script:theme.Text)
    if (-not $Labels.ContainsKey($Key)) { return }
    $label = $Labels[$Key]
    $label.Text = if ([string]::IsNullOrWhiteSpace($Value)) { '—' } else { $Value }
    $label.ForeColor = $Color
    $script:toolTip.SetToolTip($label, $label.Text)
}

function Invoke-UiBusy {
    param([scriptblock]$Action)
    $form.UseWaitCursor = $true
    [Windows.Forms.Application]::DoEvents()
    try { & $Action } finally { $form.UseWaitCursor = $false }
}

function Copy-UiText {
    param([string]$Text, [string]$What = 'Metin')
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    try {
        [Windows.Forms.Clipboard]::SetText($Text)
        Add-Log "$What panoya kopyalandı."
    } catch { Add-Log 'Panoya kopyalanamadı.' }
}

function Show-UiMessage {
    param([string]$Text, [string]$Title = 'GameBoost Lite', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    return [Windows.Forms.MessageBox]::Show($form, $Text, $Title, $Buttons, $Icon)
}
