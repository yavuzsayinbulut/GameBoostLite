# Window pages. Every page reads its data only when it is opened (or when Yenile is pressed).

$script:pages = [ordered]@{}
$script:currentPage = $null
$script:asyncJobs = [Collections.Generic.List[object]]::new()

$script:pollTimer = [Windows.Forms.Timer]::new()
$script:pollTimer.Interval = 200
$script:pollTimer.Add_Tick({
    foreach ($entry in @($script:asyncJobs)) {
        if (-not $entry.Job.Done) { continue }
        [void]$script:asyncJobs.Remove($entry)
        & $entry.OnDone $entry.Job
    }
    if ($script:asyncJobs.Count -eq 0) { $script:pollTimer.Stop() }
})

# Background tests (ping, input rate) finish on their own thread; the UI checks them here.
function Wait-UiJob {
    param($Job, [scriptblock]$OnDone)
    $script:asyncJobs.Add([pscustomobject]@{ Job = $Job; OnDone = $OnDone })
    $script:pollTimer.Start()
}

function Start-DelayedAction {
    param([int]$Milliseconds, [scriptblock]$Action)
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = $Milliseconds
    $timer.Tag = $Action
    $timer.Add_Tick({
        $this.Stop()
        $action = $this.Tag
        $this.Dispose()
        & $action
    })
    $timer.Start()
}

function New-Page {
    param([string]$Key, [string]$Title, [string]$Subtitle, [int]$Glyph, [scriptblock]$OnShow, [string]$Nav)
    $panel = [Windows.Forms.Panel]::new()
    $panel.Location = [Drawing.Point]::new(216, 0)
    $panel.Size = [Drawing.Size]::new(964, 720)
    $panel.BackColor = $script:theme.Window
    $panel.Visible = $false
    $form.Controls.Add($panel)
    [void](New-UiLabel $panel $Title 26 18 -Font $script:fonts.PageTitle)
    [void](New-UiLabel $panel $Subtitle 29 56 -Font $script:fonts.PageSub -Color $script:theme.SubText)

    $button = [GameBoostNavButton]::new()
    $button.Text = if ($Nav) { $Nav } else { $Title }
    $button.Glyph = [string][char]$Glyph
    $button.IconFontName = $script:iconFontName
    $button.Font = $script:fonts.Body
    $button.BackColor = $script:theme.Sidebar
    $button.AccentColor = $script:theme.Accent
    $button.TextColor = $script:theme.SubText
    $button.SelectedTextColor = $script:theme.Text
    $button.Location = [Drawing.Point]::new(10, 96 + $script:pages.Count * 40)
    $button.Size = [Drawing.Size]::new(196, 38)
    $button.Tag = $Key
    $button.Add_Click({ Show-Page ([string]$this.Tag) })
    $script:sidebar.Controls.Add($button)
    $script:pages[$Key] = @{ Panel = $panel; Button = $button; OnShow = $OnShow; Loaded = $false }
    return $panel
}

function Show-Page {
    param([string]$Key)
    $page = $script:pages[$Key]
    if (-not $page) { return }
    $page.Panel.Visible = $true
    $page.Panel.BringToFront()
    foreach ($entry in $script:pages.GetEnumerator()) {
        $entry.Value.Button.Selected = $entry.Key -eq $Key
        if ($entry.Key -ne $Key) { $entry.Value.Panel.Visible = $false }
    }
    $script:currentPage = $Key
    if ($page.OnShow) { & $page.OnShow $page }
    $page.Loaded = $true
}

function Test-WindowInUse {
    return $form.Visible -and $form.WindowState -ne [Windows.Forms.FormWindowState]::Minimized -and
        [GameBoostEngine]::ForegroundProcessId() -eq $PID
}

# ---------------------------------------------------------------- system tray
# The window's X only hides it; BOOST keeps running. Quitting (and undoing BOOST) is Çıkış in the tray menu.

function Hide-ToTray {
    $form.Hide()
    [GameBoostEngine]::TrimCurrentProcess()
    if (-not $script:trayHintShown -and $script:trayIcon) {
        $script:trayHintShown = $true
        Save-CustomSettings -Quiet
        $script:trayIcon.ShowBalloonTip(5000, 'GameBoost Lite arka planda çalışıyor',
            'Açmak için saatin yanındaki simgeye tıkla. Tamamen kapatmak için sağ tık > Çıkış.', 'Info')
    }
}

function Show-FromTray {
    $form.Show()
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = 'Normal' }
    $form.Activate()
    Update-VisibleData
}

function Exit-GameBoost {
    param([switch]$Restart)
    $what = if ($Restart) { 'Yeniden başlatırsan' } else { 'Çıkarsan' }
    $parts = [Collections.Generic.List[string]]::new()
    if ($script:boosted) {
        $parts.Add("BOOST açık. $what güç planı ve verimlilik modu geri alınır.")
        if ($Restart) { $parts.Add($(if ($script:options.AutoBoost) { 'Oyun açıksa otomatik BOOST birkaç saniye içinde yeniden başlar.' } else { 'BOOST''u sonra yeniden başlatman gerekir.' })) }
    }
    if ($script:download) { $parts.Add('İndirme modu kapanır; bilgisayar yeniden uyuyabilir.') }
    if ($script:saver) { $parts.Add('Tasarruf modu kapanır; ekran, parlaklık ve güç ayarları eski haline döner.') }
    if ($parts.Count -gt 0) {
        Show-FromTray
        $question = if ($Restart) { 'Yeniden başlatılsın mı?' } else { 'Çıkılsın mı?' }
        $message = "$($parts -join ' ')`r`n`r`n$question"
        if ((Show-UiMessage $message 'GameBoost Lite' 'YesNo' 'Question') -ne 'Yes') { return }
    }
    if ($Restart -and -not (Start-GameBoostCopy)) {
        [void](Show-UiMessage 'Yeniden başlatılamadı; GameBoost açık kalıyor.' 'GameBoost Lite' 'OK' 'Warning')
        return
    }
    $script:exitRequested = $true
    $form.Close()
}

# Loads the app's files again (after an update). The new copy waits until this one has undone
# BOOST and released the single-instance lock, then opens its window.
function Start-GameBoostCopy {
    $mainScript = Join-Path $script:appRoot 'GameBoostLite.ps1'
    return Start-HiddenProcess 'powershell.exe' "-NoProfile -STA -ExecutionPolicy Bypass -File `"$mainScript`" -Restart"
}

function Get-ActiveModesText {
    $modes = @()
    if ($script:download) { $modes += 'İndirme' }
    if ($script:saver) { $modes += $(if ($script:saver.Level -eq 'super') { 'Süper tasarruf' } else { 'Tasarruf' }) }
    return ($modes -join ' · ')
}

function Update-TrayState {
    if (-not $script:trayIcon) { return }
    $modes = Get-ActiveModesText
    $text = "GameBoost Lite · $(Get-BoostStatusText)$(if ($modes) { " · $modes" })"
    # Windows allows at most 63 characters here.
    $script:trayIcon.Text = if ($text.Length -gt 63) { $text.Substring(0, 63) } else { $text }
    $script:trayBoostItem.Enabled = -not $script:boosted
    $script:trayNormalItem.Enabled = $script:boosted
    $script:trayDownloadItem.Text = if ($script:download) { 'İndirme modunu kapat' } else { 'İndirme modunu aç' }
    $script:traySaverItem.Text = if ($script:saver) { 'Tasarruf modunu kapat' } else { 'Tasarruf modunu aç' }
    $script:traySaverItem.Enabled = -not $script:boosted
}

function New-TrayIcon {
    $menu = [Windows.Forms.ContextMenuStrip]::new()
    $menu.Renderer = [GameBoostMenuRenderer]::new($script:theme.Card, $script:theme.Selection, $script:theme.CardBorder, $script:theme.Muted)
    $menu.BackColor = $script:theme.Card
    $menu.Font = $script:fonts.Body
    $menu.ShowImageMargin = $false
    $open = $menu.Items.Add('GameBoost''u aç')
    $open.Font = $script:fonts.BodyBold
    [void]$menu.Items.Add('-')
    $script:trayBoostItem = $menu.Items.Add("BOOST'u başlat")
    $script:trayNormalItem = $menu.Items.Add('Normal moda dön')
    [void]$menu.Items.Add('-')
    $script:trayDownloadItem = $menu.Items.Add('İndirme modunu aç')
    $script:traySaverItem = $menu.Items.Add('Tasarruf modunu aç')
    [void]$menu.Items.Add('-')
    $restart = $menu.Items.Add('Yeniden başlat')
    $quit = $menu.Items.Add('Çıkış')
    foreach ($item in $menu.Items) { $item.ForeColor = $script:theme.Text; $item.Padding = [Windows.Forms.Padding]::new(4, 3, 4, 3) }
    $open.Add_Click({ Show-FromTray })
    $script:trayBoostItem.Add_Click({ Show-FromTray; Start-Boost })
    $script:trayNormalItem.Add_Click({ Restore-NormalMode 'Normal moda dönüldü.' -Manual })
    $script:trayDownloadItem.Add_Click({ if ($script:download) { Stop-DownloadMode } else { Start-DownloadMode } })
    $script:traySaverItem.Add_Click({ if ($script:saver) { Stop-SaverMode } else { [void](Start-SaverMode 'normal') } })
    $restart.Add_Click({ Exit-GameBoost -Restart })
    $quit.Add_Click({ Exit-GameBoost })

    $icon = [Windows.Forms.NotifyIcon]::new()
    $icon.Icon = if ($script:appIcon) { $script:appIcon } else { [Drawing.SystemIcons]::Application }
    $icon.ContextMenuStrip = $menu
    $icon.Add_MouseClick({ param($sender, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-FromTray } })
    # A clicked notification opens the page it is about.
    $icon.Add_BalloonTipClicked({ Show-FromTray; if ($script:noticeTarget) { Show-Page $script:noticeTarget } })
    $script:trayIcon = $icon
    Update-TrayState
    $icon.Visible = $true
}

# ---------------------------------------------------------------- Oyun Modu

function Build-HomePage {
    $page = New-Page 'home' 'Oyun Modu' 'Tek tuşla oyuna hazırlan. Yapılan her değişiklik geri alınır.' 0xE7FC {
        param($Page)
        Update-Metrics
        Update-HomeAlerts
    }

    $status = New-UiCard $page 'Durum' 28 88 440 262
    $script:statusLabel = New-UiLabel $status 'NORMAL MOD' 15 40 -Font $script:fonts.Status -Color $script:theme.Blue
    $script:gameLabel = New-UiLabel $status 'Oyun: bekleniyor' 18 84 404 22 -Color $script:theme.SubText
    $script:metricsLabel = New-UiLabel $status 'Ölçülüyor...' 18 108 404 22 -Color $script:theme.SubText -Font $script:fonts.Small
    $script:boostButton = New-UiButton $status "BOOST'U BAŞLAT" 18 144 254 54 $script:theme.Accent { Start-Boost } -Font $script:fonts.BigButton `
        -Tip 'Yüksek performans planı, Oyun Modu, seçili uygulamaları kapatma ve arka plan verimlilik modu.'
    $script:restoreButton = New-UiButton $status 'NORMAL MOD' 282 144 140 54 $script:theme.Neutral { Restore-NormalMode 'Normal moda dönüldü.' -Manual } -Font $script:fonts.BigButton
    $script:restoreButton.Enabled = $false
    [void](New-UiLabel $status "Steam, Epic, EA, Ubisoft ve Rockstar kapatılmaz. BOOST'tan sonra oyunu launcher'dan normal aç." 18 210 404 40 `
        -Color $script:theme.Muted -Font $script:fonts.Small -Wrap)

    $smart = New-UiCard $page '' 484 88 452 262
    $smartTitle = New-UiLabel $smart 'Akıllı durum' 18 14 -Font $script:fonts.CardTitle
    $script:readinessLabel = New-UiLabel $smart '' (18 + $smartTitle.PreferredWidth + 4) 17 -Font $script:fonts.BodyBold -Color $script:theme.SubText
    [void](New-UiButton $smart 'Tümü' 368 11 68 28 -OnClick { Show-Page 'care' })
    $script:homeAlerts = New-UiAlertView $smart 16 48 424 202

    $settings = New-UiCard $page 'BOOST ayarları' 28 366 440 330
    $toggles = @(
        @('CloseWorkApps', 'Çalışma uygulamalarını kapat', 'Code, Codex, Edge ve Teams nazikçe kapatılır; kaydetmen istenebilir.'),
        @('CloseGameBar', 'Game Bar / Xbox arka planını kapat', 'Kullanılmayan Xbox Game Bar süreçleri kapatılır.'),
        @('CloseDiscord', "Discord'u kapat", 'Oyunda sesli sohbet kullanıyorsan kapalı bırak.'),
        @('CloseDocker', "Docker + WSL'yi durdur", 'Yalnızca çalışıyorsa. WSL birkaç GB RAM boşaltır; açık container''lar durur.'),
        @('EfficiencyMode', 'Arka planı verimlilik moduna al', 'Tarayıcı ve sohbet uygulamaları oyunla yarışmaz. Öne getirdiğin uygulama hemen normale döner; BOOST bitince hepsi geri alınır.'),
        @('AutoRestore', 'Oyun kapanınca normal moda dön', 'Güç planı ve verimlilik modu kendiliğinden geri alınır.'),
        @('MinimizeOnBoost', "BOOST'ta sistem tepsisine gizle", 'Pencere saatin yanındaki simgeye iner; BOOST çalışmaya devam eder. Açmak için simgeye tıkla.')
    )
    $script:optionToggles = @{}
    for ($i = 0; $i -lt $toggles.Count; $i++) {
        $key = $toggles[$i][0]
        $toggle = New-UiToggle $settings $toggles[$i][1] 18 (46 + $i * 38) 404 $script:options[$key] $toggles[$i][2]
        $toggle.Tag = $key
        $toggle.Add_CheckedChanged({ Invoke-OptionToggle $this })
        $script:optionToggles[$key] = $toggle
    }

    $activity = New-UiCard $page 'Etkinlik' 484 366 452 176
    $script:logBox = New-UiTextBox $activity 16 46 422 118 -Mono
    $script:logBox.BackColor = $script:theme.Card
    $script:logBox.ForeColor = $script:theme.SubText

    # New automation is off until the user turns it on.
    $automation = New-UiCard $page 'Otomatik' 484 556 452 140
    $automationToggles = @(
        @('AutoStart', 'Windows açılınca başlat', 'Oturum açınca GameBoost penceresiz başlar. Görev Yöneticisi > Başlangıç uygulamaları''nda da görünür.'),
        @('StartInTray', 'Başlangıçta tepside bekle', 'Windows ile başladığında pencere açılmaz; saatin yanındaki simgede bekler.'),
        @('AutoBoost', 'Oyun algılanınca otomatik BOOST', 'Steam, Epic, EA, Ubisoft, Rockstar ve Xbox oyunlarında. Soru sormaz, hiçbir uygulamayı kapatmaz: güç planı (prizdeyken), Oyun Modu, arka plan verimlilik modu ve Game Bar. NORMAL MOD''a basarsan o oyun kapanana kadar tekrar başlamaz.')
    )
    for ($i = 0; $i -lt $automationToggles.Count; $i++) {
        $key = $automationToggles[$i][0]
        $toggle = New-UiToggle $automation $automationToggles[$i][1] 18 (42 + $i * 30) 416 $script:options[$key] $automationToggles[$i][2]
        $toggle.Tag = $key
        $toggle.Add_CheckedChanged({ Invoke-OptionToggle $this })
        $script:optionToggles[$key] = $toggle
    }
}

function Invoke-OptionToggle {
    param($Toggle)
    if ($script:revertingToggle) { return }
    $key = [string]$Toggle.Tag
    if ($key -eq 'AutoStart') {
        if (-not (Set-AutoStart $Toggle.Checked)) {
            Add-Log 'Windows başlangıç ayarı değiştirilemedi.'
            $script:revertingToggle = $true
            $Toggle.Checked = -not $Toggle.Checked
            $script:revertingToggle = $false
            return
        }
        Add-Log $(if ($Toggle.Checked) { 'GameBoost, Windows açılınca başlayacak.' } else { 'Windows açılınca başlatma kapatıldı.' })
    }
    $script:options[$key] = $Toggle.Checked
    Save-CustomSettings -Quiet
    # Efficiency mode takes effect at once during BOOST, in both directions.
    if ($key -eq 'EfficiencyMode' -and $script:boosted) {
        if ($Toggle.Checked) {
            $snapshot = [GameBoostEngine]::Snapshot()
            Enable-BackgroundEfficiency $snapshot
        } else {
            $restored = Restore-EfficiencyTargets
            Add-Log "Verimlilik modu kapatıldı; $restored süreç normal hızına döndü."
        }
    }
    if ($key -eq 'AutoBoost') {
        Update-AutoBoostWatcher
        Add-Log $(if ($Toggle.Checked) { 'Otomatik BOOST açık: desteklenen bir oyun algılanınca başlar.' } else { 'Otomatik BOOST kapatıldı.' })
    }
}

# ---------------------------------------------------------------- Modlar

function New-OptionToggle {
    param($Parent, [string]$Key, [string]$Text, [int]$X, [int]$Y, [int]$Width, [string]$Tip)
    $toggle = New-UiToggle $Parent $Text $X $Y $Width $script:options[$Key] $Tip
    $toggle.Tag = $Key
    $toggle.Add_CheckedChanged({ Invoke-OptionToggle $this })
    return $toggle
}

function Build-ModesPage {
    $page = New-Page 'modes' 'Modlar' 'İndirme ve tasarruf modları, akıllı bildirimler. Kapatınca her şey eski haline döner.' 0xE945 { param($Page) Update-ModesPage }
    [void](New-UiButton $page 'Yenile' 836 22 100 32 -OnClick { Update-ModesPage })

    $download = New-UiCard $page 'İndirme modu' 28 88 440 360
    $script:downloadStatus = New-UiLabel $download '' 18 44 404 22 -Font $script:fonts.BodyBold
    $script:downloadLive = New-UiLabel $download '' 18 68 404 20 -Color $script:theme.SubText
    [void](New-UiLabel $download 'Bilgisayar uyumaz (ekran kapanabilir) · Wi-Fi güç tasarrufu kapanır · Wi-Fi koparsa aynı ağa yeniden bağlanır · trafik durunca haber verir.' `
        18 92 404 48 -Font $script:fonts.Small -Color $script:theme.SubText -Wrap)
    [void](New-OptionToggle $download 'DownloadAutoStop' 'Trafik durunca modu kapat, uykuya izin ver' 18 140 404 `
        'İndirme 2 dk boyunca durgun kalırsa mod kendiliğinden kapanır ve bilgisayar normal zamanında uyur.')
    $script:downloadButton = New-UiButton $download 'İndirme modunu aç' 18 178 200 36 $script:theme.Accent {
        if ($script:download) { Stop-DownloadMode } else { Start-DownloadMode }
        Update-ModesPage
    }
    [void](New-UiButton $download 'Hız testi' 226 178 196 36 -OnClick { Show-Page 'network'; Start-SpeedTest } `
        -Tip 'Ağ / Wi-Fi sayfasında indirme ve yükleme hızını ölçer.')
    $script:downloadChecks = New-UiAlertView $download 16 224 410 124

    $saver = New-UiCard $page 'Tasarruf modu' 484 88 452 360
    $script:saverStatus = New-UiLabel $saver '' 18 44 416 22 -Font $script:fonts.BodyBold
    $script:saverBattery = New-UiLabel $saver '' 18 68 416 20 -Color $script:theme.SubText
    $saverText = "Tasarruf: arka plan uygulamaları verimlilik modunda, dahili ekran 60 Hz, parlaklık en fazla %50.`r`n" +
        'Süper: + parlaklık %30, pilde turbo kapalı, pilde Windows Enerji tasarrufu.'
    $saverInfo = New-UiLabel $saver $saverText 18 92 416 64 -Font $script:fonts.Small -Color $script:theme.SubText -Wrap
    $script:toolTip.SetToolTip($saverInfo, "$(Get-SaverDescription 'normal')`r`n`r`n$(Get-SaverDescription 'super')")
    [void](New-OptionToggle $saver 'SaverRefresh' 'Dahili ekranı 60 Hz''e al' 18 158 416 'Mod kapanınca önceki Hz''e döner. Harici ekranlara dokunmaz.')
    [void](New-OptionToggle $saver 'SaverBrightness' 'Parlaklığı düşür (Tasarruf %50, Süper %30)' 18 188 416 `
        'Yalnızca daha parlaksa düşürür. Mod sırasında parlaklığı kendin değiştirirsen kapanınca senin ayarın kalır.')
    $script:saverButton = New-UiButton $saver 'Tasarruf' 18 226 128 36 $script:theme.Accent { [void](Start-SaverMode 'normal'); Update-ModesPage }
    $script:superButton = New-UiButton $saver 'Süper tasarruf' 154 226 140 36 $script:theme.Accent { [void](Start-SaverMode 'super'); Update-ModesPage }
    $script:saverStopButton = New-UiButton $saver 'Kapat' 302 226 132 36 -OnClick { Stop-SaverMode; Update-ModesPage }
    $script:saverApplied = New-UiLabel $saver '' 18 272 416 76 -Font $script:fonts.Small -Wrap

    $notices = New-UiCard $page 'Akıllı bildirimler' 28 464 440 232
    [void](New-OptionToggle $notices 'SmartNotices' 'Bildirim gönder' 18 42 404 'Saatin yanındaki bildirimler; tıklayınca ilgili sayfa açılır.')
    $noticeInfo = New-UiLabel $notices 'Pil, RAM, yoran uygulama, disk, güncelleme, indirme. Oyunda, tam ekranda ve Odak açıkken gönderilmez.' `
        18 74 404 36 -Font $script:fonts.Small -Color $script:theme.SubText -Wrap
    $script:toolTip.SetToolTip($noticeInfo, 'Her konunun kendi tekrar sınırı var; günde en fazla 8 sıradan bildirim. İndirme ve kritik pil bildirimleri sınırsızdır ama oyun sırasında yalnızca listeye yazılır.')
    $script:noticeBox = New-UiTextBox $notices 16 116 410 104
    $script:noticeBox.Font = $script:fonts.Small
    $script:noticeBox.BackColor = $script:theme.Card
    $script:noticeBox.ForeColor = $script:theme.SubText

    $power = New-UiCard $page 'Pil ve güç' 484 464 452 232
    $script:powerChecks = New-UiAlertView $power 16 44 420 138
    $script:gpuUsersButton = New-UiButton $power 'NVIDIA kartını kim uyandırıyor? (5 sn)' 16 188 300 32 -OnClick {
        $script:gpuUsersButton.Enabled = $false
        $script:gpuUsersButton.Text = 'Bakılıyor...'
        Start-GpuUsersScan {
            $script:gpuUsersButton.Enabled = $true
            $script:gpuUsersButton.Text = 'NVIDIA kartını kim uyandırıyor? (5 sn)'
            Set-UiAlerts $script:powerChecks (Get-PowerChecks)
        }
    } -Tip 'Ayrı ekran kartında bellek tutan uygulamaları bulur; kart uyanıkken pil birkaç watt daha hızlı biter.'
}

# Checks need CIM, netsh and WinRT: read when the page opens or on Yenile, not every tick.
function Update-ModesPage {
    if (-not $script:downloadChecks) { return }
    Invoke-UiBusy {
        Set-UiAlerts $script:downloadChecks (Get-DownloadChecks)
        Set-UiAlerts $script:powerChecks (Get-PowerChecks)
    }
    Update-ModesUi
    Update-NoticeList
}

# Buttons, sidebar and tray follow the modes.
function Update-ModesUi {
    $modes = Get-ActiveModesText
    if ($script:sidebarFooter) {
        $script:sidebarFooter.Text = if ($modes) { "●  $modes açık" } else { 'v2.0 · değişiklikler geri alınır' }
        $script:sidebarFooter.ForeColor = if ($modes) { $script:theme.Accent } else { $script:theme.Muted }
    }
    Update-TrayState
    if (-not $script:downloadButton) { return }
    $script:downloadButton.Text = if ($script:download) { 'İndirme modunu kapat' } else { 'İndirme modunu aç' }
    $script:saverButton.Enabled = -not $script:boosted -and -not ($script:saver -and $script:saver.Level -eq 'normal')
    $script:superButton.Enabled = -not $script:boosted -and -not ($script:saver -and $script:saver.Level -eq 'super')
    $script:saverStopButton.Enabled = [bool]$script:saver
    $script:saverApplied.Text = if ($script:saver) {
        "Uygulanan: $(if ($script:saver.Applied.Count) { $script:saver.Applied -join ' · ' } else { 'ekran ve güç ayarları zaten tasarruflu' })" +
            " · verimlilik modunda $($script:saver.Efficiency.Count) süreç. Kapat ile hepsi eski haline döner."
    } elseif ($script:boosted) { 'BOOST açıkken tasarruf modu başlatılmaz; oyun bitince kullanabilirsin.' }
    else { 'Öne aldığın uygulama hemen normal hızına döner. Oyun başlarsa (BOOST) tasarruf kendiliğinden kapanır.' }
    $script:saverApplied.ForeColor = if ($script:saver) { $script:theme.Text } else { $script:theme.SubText }
    Update-ModesLive
}

function Update-ModesLive {
    if (-not $script:downloadStatus) { return }
    $now = Get-ModesNow
    if ($script:download) {
        $minutes = [math]::Floor(($now - $script:download.Started).TotalMinutes)
        $script:downloadStatus.Text = "Açık · $minutes dk · bilgisayar uyumuyor"
        $script:downloadStatus.ForeColor = $script:theme.Accent
        $script:downloadLive.Text = '↓ {0} · ↑ {1} · en yüksek ↓ {2} · toplam ↓ {3}' -f (Format-Mbps $script:download.RateDown), (Format-Mbps $script:download.RateUp),
            (Format-Mbps $script:download.PeakDown), (Format-ByteSize $script:download.Received)
        if ($script:download.WifiDownSince) { $script:downloadLive.Text = "Wi-Fi koptu; yeniden bağlanılıyor ($($script:download.ReconnectTries)/3)" }
    } else {
        $script:downloadStatus.Text = 'Kapalı'
        $script:downloadStatus.ForeColor = $script:theme.SubText
        $script:downloadLive.Text = if ($script:lastSpeedResult) {
            'Son hız testi: ↓ {0} · ↑ {1} · {2:HH:mm}' -f (Format-Mbps $script:lastSpeedResult.Down), (Format-Mbps $script:lastSpeedResult.Up), $script:lastSpeedResult.At
        } else { 'Büyük indirme veya yükleme başlatmadan önce aç.' }
    }
    if ($script:saver) {
        $name = if ($script:saver.Level -eq 'super') { 'Süper tasarruf' } else { 'Tasarruf' }
        $script:saverStatus.Text = "$name açık · $([math]::Floor(($now - $script:saver.Started).TotalMinutes)) dk"
        $script:saverStatus.ForeColor = $script:theme.Accent
    } else {
        $script:saverStatus.Text = 'Kapalı'
        $script:saverStatus.ForeColor = $script:theme.SubText
    }
    $power = [Windows.Forms.SystemInformation]::PowerStatus
    if ($power.PowerLineStatus -eq [Windows.Forms.PowerLineStatus]::Offline) {
        $estimate = Get-BatteryEstimate
        $percent = [math]::Round($power.BatteryLifePercent * 100)
        $script:saverBattery.Text = if ($estimate) { "Pil %$percent · ~$($estimate.Watts) W çekiş · bu hızla ~$(Format-Duration $estimate.Hours) (son $($estimate.Minutes) dk)" }
            else { "Pil %$percent · çekiş birkaç dakikada ölçülür" }
    } else { $script:saverBattery.Text = 'Prizde · tasarruf ayarları pilde daha çok fark eder' }
}

function Update-NoticeList {
    if (-not $script:noticeBox) { return }
    $lines = foreach ($notice in $script:noticeLog) {
        '{0:HH:mm}  {1}{2} · {3}' -f $notice.At, $notice.Title, $(if (-not $notice.Shown) { ' (sessizdeydi)' }), $notice.Text
    }
    $script:noticeBox.Text = if (@($lines).Count) { $lines -join "`r`n" } else { 'Henüz bildirim yok.' }
}

# ---------------------------------------------------------------- Oyun Ayarları

function Build-TweaksPage {
    $page = New-Page 'tweaks' 'Oyun Ayarları' 'Önerilen Windows ayarları, mikrofon gürültü engelleme ve Windows''ta açılacak özellikler.' 0xE713 {
        param($Page)
        Update-TweaksPage
    }
    $card = New-UiCard $page 'Önerilen Windows ayarları' 28 88 560 420
    $script:tweakToggles = @{}
    for ($i = 0; $i -lt $script:windowsTweaks.Count; $i++) {
        $tweak = $script:windowsTweaks[$i]
        $top = 46 + $i * 52
        $toggle = New-UiToggle $card $tweak.Label 18 $top 520 $false $tweak.Help
        $toggle.Tag = $tweak.Key
        $toggle.Add_CheckedChanged({ Invoke-TweakToggle $this })
        $script:tweakToggles[$tweak.Key] = $toggle
        [void](New-UiLabel $card $tweak.Help 68 ($top + 27) 474 18 -Color $script:theme.Muted -Font $script:fonts.Small)
    }
    [void](New-UiButton $card 'Önerilenlerin hepsini aç' 18 366 250 36 $script:theme.Accent { Enable-AllTweaks })
    [void](New-UiButton $card 'Hepsini eski haline döndür' 280 366 262 36 -OnClick { Restore-AllTweaks } `
        -Tip 'GameBoost''un değiştirdiği her ayarı, değiştirmeden önceki değerine döndürür.')

    $mic = New-UiCard $page 'Mikrofon gürültü engelleme' 604 88 332 420
    [void](New-UiLabel $mic 'Gürültü engellemeyi ses yazılımları yapar; Windows''ta tek bir anahtarı yok. Bu bilgisayarda kullanabileceklerin:' 18 44 296 52 `
        -Color $script:theme.SubText -Font $script:fonts.Small -Wrap)
    [void](New-UiLabel $mic 'NVIDIA Broadcast' 18 104 190 20 -Font $script:fonts.BodyBold)
    $script:broadcastStatus = New-UiLabel $mic '' 18 124 190 34 -Color $script:theme.Muted -Font $script:fonts.Small -Wrap
    $script:broadcastButton = New-UiButton $mic 'İndir' 216 106 98 32 -OnClick {
        $tools = Get-MicToolsInfo
        if ($tools.BroadcastPath) { Start-Process -FilePath $tools.BroadcastPath }
        else { Start-Process 'https://www.nvidia.com/en-us/geforce/broadcasting/broadcast-app/' }
    } -Tip 'Yapay zekâ ile klavye, fan ve oda gürültüsünü siler; yankıyı da giderir. RTX ekran kartı gerekir.'
    [void](New-UiLabel $mic 'SteelSeries Sonar' 18 166 190 20 -Font $script:fonts.BodyBold)
    $script:sonarStatus = New-UiLabel $mic '' 18 186 190 34 -Color $script:theme.Muted -Font $script:fonts.Small -Wrap
    $script:sonarButton = New-UiButton $mic 'GG''yi aç' 216 168 98 32 -OnClick {
        $tools = Get-MicToolsInfo
        if ($tools.SteelSeriesPath) { Start-Process -FilePath $tools.SteelSeriesPath }
    } -Tip 'Sonar > Mikrofon: ClearCast gürültü engelleme, ses yükseltme ve dengeleyici.'
    [void](New-UiLabel $mic 'Discord' 18 228 296 20 -Font $script:fonts.BodyBold)
    [void](New-UiLabel $mic 'Ayarlar > Ses ve Görüntü > Gürültü bastırma: Krisp. Otomatik kazanç kontrolü de açık olsun.' 18 248 296 34 `
        -Color $script:theme.Muted -Font $script:fonts.Small -Wrap)
    [void](New-UiButton $mic 'Windows ses geliştirmeleri' 18 292 296 32 -OnClick { Start-Process 'ms-settings:sound' } `
        -Tip 'Mikrofon özellikleri > Ses geliştirmeleri / Ses netliği (sürücü destekliyorsa).')
    [void](New-UiButton $mic 'Mikrofon testine git' 18 332 296 32 -OnClick { Show-Page 'audio' })
    [void](New-UiLabel $mic 'En büyük fark mikrofonlu kulaklıktan gelir; dahili mikrofon fan sesini de alır.' 18 372 296 36 `
        -Color $script:theme.Muted -Font $script:fonts.Small -Wrap)

    $manual = New-UiCard $page 'Windows ayarlarında açılacak özellikler' 28 522 908 174
    [void](New-UiLabel $manual 'Bunların güvenli bir anahtarı yok; ilgili Windows sayfası tek tıkla açılır.' 18 44 872 20 -Color $script:theme.SubText)
    $links = @(
        @('Grafik: HAGS ve VRR', 'ms-settings:display-advancedgraphics-default'),
        @('Oyunda bildirimleri sustur', 'ms-settings:notifications'),
        @('Oyun Modu ve Game Bar', 'ms-settings:gaming-gamemode'),
        @('Güç modu', 'ms-settings:powersleep'),
        @('Depolama Sensörü', 'ms-settings:storagepolicies')
    )
    for ($i = 0; $i -lt $links.Count; $i++) {
        $button = New-UiButton $manual $links[$i][0] (18 + $i * 176) 74 168 34 -OnClick { Start-Process ([string]$this.Tag) }
        $button.Tag = $links[$i][1]
    }
    [void](New-UiLabel $manual ('HAGS ve değişken yenileme hızı (VRR) sürücüye ve oyuna göre fayda sağlar; açtıktan sonra oyunda karşılaştır. ' +
        'Bildirimler: Rahatsız Etmeyin > "Otomatik olarak aç" > "Oyun oynarken".') 18 118 872 40 -Color $script:theme.Muted -Font $script:fonts.Small -Wrap)
}

function Update-TweaksPage {
    $script:revertingTweak = $true
    try {
        foreach ($tweak in $script:windowsTweaks) { $script:tweakToggles[$tweak.Key].Checked = Test-TweakOn $tweak }
    } finally { $script:revertingTweak = $false }
    $tools = Get-MicToolsInfo
    if ($tools.BroadcastPath) {
        $script:broadcastStatus.Text = 'Kurulu · gürültü ve yankı giderme'
        $script:broadcastButton.Text = 'Aç'
        $script:broadcastButton.Enabled = $true
    } elseif ($tools.RtxName) {
        $script:broadcastStatus.Text = "$($tools.RtxName) destekler · kurulu değil"
        $script:broadcastButton.Text = 'İndir'
        $script:broadcastButton.Enabled = $true
    } else {
        $script:broadcastStatus.Text = 'RTX ekran kartı gerekir'
        $script:broadcastButton.Enabled = $false
    }
    $script:sonarStatus.Text = if ($tools.SteelSeriesPath) { 'GG kurulu · Sonar > Mikrofon > ClearCast' } else { 'SteelSeries GG kurulu değil' }
    $script:sonarButton.Enabled = [bool]$tools.SteelSeriesPath
}

function Invoke-TweakToggle {
    param($Toggle)
    if ($script:revertingTweak) { return }
    $tweak = $script:windowsTweaks | Where-Object Key -eq ([string]$Toggle.Tag) | Select-Object -First 1
    $ok = if ($Toggle.Checked) { Enable-Tweak $tweak } else { Restore-Tweak $tweak }
    if ($ok) { Add-Log "$($tweak.Label): $(if ($Toggle.Checked) { 'açıldı' } else { 'eski haline döndü' })." }
    else { Add-Log "$($tweak.Label): değiştirilemedi." }
    Update-TweaksPage
}

function Enable-AllTweaks {
    $pending = @($script:windowsTweaks | Where-Object { -not (Test-TweakOn $_) })
    if ($pending.Count -eq 0) { Add-Log 'Önerilen ayarların hepsi zaten açık.'; return }
    $list = ($pending | ForEach-Object { "   •  $($_.Label)" }) -join "`r`n"
    $message = "Şu ayarlar açılacak:`r`n`r`n$list`r`n`r`nÖnceki değerler kaydedilir; ""Hepsini eski haline döndür"" ile geri alınır. Devam edilsin mi?"
    if ((Show-UiMessage $message 'Önerilen ayarlar' 'YesNo' 'Question') -ne 'Yes') { return }
    $changed = 0
    foreach ($tweak in $pending) { if (Enable-Tweak $tweak) { $changed++ } }
    Add-Log "Önerilen ayarlar: $changed / $($pending.Count) ayar açıldı."
    Update-TweaksPage
}

function Restore-AllTweaks {
    $backup = Read-TweakBackup
    $saved = @($script:windowsTweaks | Where-Object { $backup.ContainsKey($_.Key) })
    if ($saved.Count -eq 0) { Add-Log 'GameBoost hiçbir Windows ayarını değiştirmemiş.'; return }
    $restored = 0
    foreach ($tweak in $saved) { if (Restore-Tweak $tweak) { $restored++ } }
    Add-Log "$restored ayar GameBoost öncesi değerine döndü."
    Update-TweaksPage
}

# ---------------------------------------------------------------- Canlı İzleme

function Build-LivePage {
    $page = New-Page 'live' 'Canlı İzleme' 'Hangi uygulama ne kadar RAM kullanıyor ve BOOST ona ne yapacak.' 0xE9D9 {
        param($Page)
        $Page.Button.Text = 'Canlı İzleme'
        Refresh-ProcessGrid
    }
    $card = New-UiCard $page '' 28 88 908 608
    $script:processSummary = New-UiLabel $card 'Süreçler okunuyor...' 18 20 760 22 -Font $script:fonts.BodyBold
    [void](New-UiButton $card 'Yenile' 798 14 94 32 -OnClick { Refresh-ProcessGrid })
    $script:processGrid = New-UiGrid $card 16 58 876 488 @('Uygulama', 'Adet', 'RAM (MB)', 'BOOST işlemi') @(330, 80, 110, 0)
    $script:activityNoticeLabel = New-UiLabel $card 'Sessiz izleme BOOST ile başlar. Uyarılar oyunun odağını bölmez.' 18 558 870 40 `
        -Color $script:theme.SubText -Wrap
}

# ---------------------------------------------------------------- Kapatma Listesi

function Build-ClosePage {
    $page = New-Page 'close' 'Kapatma Listesi' 'BOOST sırasında kapatılacak ek uygulamaları seç.' 0xE71D { param($Page) Refresh-CustomList }
    $card = New-UiCard $page 'Özel liste' 28 88 520 608
    [void](New-UiLabel $card '★ önerilenler güvenle kapatılabilir. Sistem, launcher ve anti-cheat süreçleri listede görünmez.' 18 44 488 36 `
        -Color $script:theme.SubText -Font $script:fonts.Small -Wrap)
    $script:customList = [Windows.Forms.CheckedListBox]::new()
    $script:customList.Location = [Drawing.Point]::new(16, 86)
    $script:customList.Size = [Drawing.Size]::new(488, 404)
    $script:customList.BackColor = $script:theme.Inset
    $script:customList.ForeColor = $script:theme.Text
    $script:customList.BorderStyle = 'None'
    $script:customList.Font = $script:fonts.Body
    $script:customList.CheckOnClick = $true
    $script:customList.IntegralHeight = $false
    Set-UiDarkScrollbars $script:customList
    $card.Controls.Add($script:customList)
    [void](New-UiLabel $card 'Listede yoksa süreç adı:' 18 500 300 20 -Color $script:theme.SubText)
    $script:customNameBox = [Windows.Forms.TextBox]::new()
    $script:customNameBox.Location = [Drawing.Point]::new(18, 524)
    $script:customNameBox.Size = [Drawing.Size]::new(300, 26)
    $script:customNameBox.BackColor = $script:theme.Inset
    $script:customNameBox.ForeColor = $script:theme.Text
    $script:customNameBox.BorderStyle = 'FixedSingle'
    $script:customNameBox.Font = $script:fonts.Body
    $card.Controls.Add($script:customNameBox)
    [void](New-UiButton $card 'Seçimi kaydet' 330 520 174 34 $script:theme.Accent { Save-CustomListFromUi })
    [void](New-UiButton $card 'Önerilenleri seç' 18 562 150 32 -OnClick { Select-RecommendedCustomItems })
    [void](New-UiButton $card 'Listeyi yenile' 178 562 140 32 -OnClick { Refresh-CustomList })

    $protect = New-UiCard $page 'Korunanlar' 564 88 372 608
    $text = New-UiTextBox $protect 16 46 340 546 @'
HİÇ KAPATILMAZ
  • Steam, Epic, EA, Ubisoft, Rockstar launcher'ları
  • Windows, Explorer ve Defender
  • Ses, ağ ve ekran sürücüleri
  • NVIDIA, Intel ve OMEN bileşenleri
  • Easy Anti-Cheat, BattlEye
  • Algılanan oyun

VERİMLİLİK MODUNA ALINMAZ
  • Discord, Spotify, TeamSpeak (ses ve sohbet)
  • OBS, Medal (kayıt ve yayın)
  • SteelSeries, Logitech, Razer, Corsair
  • MSI Afterburner, RTSS, HWiNFO
  • Anti-cheat ve Windows bileşenleri
  • Öne getirdiğin her uygulama

NASIL KAPATILIR
  • Çalışma uygulamaları ve özel liste nazikçe kapatılır; kaydetme fırsatı verilir. Kapanmayan açık bırakılır.
  • Game Bar, Discord ve Docker kapanmazsa sonlandırılır.
  • Verimlilik modu ve güç planı BOOST bitince geri alınır.
'@
    $text.BackColor = $script:theme.Card
}

# ---------------------------------------------------------------- Ekran / TV

function Get-RefreshCandidate {
    param($Monitors)
    # Cloned screens share one source; the fix there is a topology change, not a Hz change.
    return $Monitors | Where-Object {
        -not $_.Cloned -and $_.Refresh -gt 0 -and $_.GdiName -and $_.MaxRefreshAtResolution -gt [math]::Round($_.Refresh) + 1
    } | Select-Object -First 1
}

function Build-DisplayPage {
    $page = New-Page 'display' 'Ekran / TV' 'Bağlı ekranlar, yenileme hızı ve harici ekran performansı.' 0xE7F4 { param($Page) Update-DisplayPage }
    [void](New-UiButton $page 'Yenile' 836 22 100 32 -OnClick { Update-DisplayPage })

    $list = New-UiCard $page 'Bağlı ekranlar' 28 88 908 196
    $script:displayGrid = New-UiGrid $list 16 46 876 134 @('Ekran', 'Bağlantı', 'Ekran kartı', 'Çözünürlük', 'Şu an', 'En yüksek', 'HDR') @(180, 110, 230, 110, 80, 90, 0)

    $diag = New-UiCard $page 'Teşhis' 28 298 520 240
    $script:displayAlerts = New-UiAlertView $diag 16 48 488 180

    $actions = New-UiCard $page 'Hızlı işlemler' 564 298 372 240
    $script:refreshFixButton = New-UiButton $actions 'En yüksek Hz''e geç' 16 46 340 36 $script:theme.Accent { Invoke-BestRefresh } `
        -Tip 'Yalnızca yenileme hızını değiştirir. 15 saniye içinde onaylamazsan eski ayara döner.'
    [void](New-UiButton $actions 'Yalnızca harici' 16 90 164 34 -OnClick { Set-DisplayTopology 'external' } `
        -Tip 'Laptop ekranını kapatır; oyun harici ekranda en az ek yükle çalışır.')
    [void](New-UiButton $actions 'Genişlet' 192 90 164 34 -OnClick { Set-DisplayTopology 'extend' })
    [void](New-UiButton $actions 'Çoğalt' 16 132 164 34 -OnClick { Set-DisplayTopology 'clone' } `
        -Tip 'Aynı görüntü iki ekranda; oyunda en yavaş ekranın Hz değeri geçerli olur.')
    [void](New-UiButton $actions 'Yalnızca laptop' 192 132 164 34 -OnClick { Set-DisplayTopology 'internal' })
    [void](New-UiButton $actions 'Gelişmiş ekran' 16 184 164 34 -OnClick { Start-Process 'ms-settings:display-advanced' })
    [void](New-UiButton $actions 'Grafik ayarları' 192 184 164 34 -OnClick { Start-Process 'ms-settings:display-advancedgraphics' } `
        -Tip 'Oyun başına GPU seçimi, değişken yenileme hızı ve pencereli oyun iyileştirmeleri.')

    $modes = New-UiCard $page 'Desteklenen modlar' 28 552 908 144
    [void](New-UiButton $modes 'Kopyala' 798 10 94 28 -OnClick { Copy-UiText $script:displayModesBox.Text 'Ekran modları' })
    $script:displayModesBox = New-UiTextBox $modes 16 46 876 86 -Mono
    $script:displayModesBox.BackColor = $script:theme.Card
}

function Update-DisplayPage {
    $monitors = @([GameBoostDisplay]::GetMonitors())
    $script:displayMonitors = $monitors
    $rows = foreach ($monitor in $monitors) {
        $hz = [int][math]::Round($monitor.Refresh)
        $color = if ($hz -le 30) { $script:theme.Red } elseif ($monitor.MaxRefreshAtResolution -gt $hz + 1) { $script:theme.Amber } else { $null }
        $hdr = if ($monitor.HdrSupported) { if ($monitor.HdrEnabled) { 'Açık' } else { 'Destekli' } } else { 'Yok' }
        $name = if ($monitor.Cloned) { "$($monitor.Name)  (çoğaltılmış)" } elseif ($monitor.Primary) { "$($monitor.Name)  (ana)" } else { $monitor.Name }
        $adapter = ($monitor.Adapter -replace '\(R\)|\(TM\)', '' -replace 'NVIDIA GeForce ', 'NVIDIA ' -replace '\s+', ' ').Trim()
        New-UiRow @($name, $monitor.Connection, $adapter, "$($monitor.Width)×$($monitor.Height)", "$hz Hz", "$($monitor.MaxRefreshAtResolution) Hz", $hdr) $color
    }
    Set-UiGridRows $script:displayGrid $rows 'Ekran bulunamadı'
    Update-DisplayAlerts
    # USB-C details need a slow device query (~2 s): run it off the UI thread, reuse for two minutes.
    if (-not $script:usbCQueryRunning -and
        (-not $script:insightCache.UsbC -or ([datetime]::UtcNow - $script:insightCache.UsbCAt).TotalSeconds -gt 120)) {
        Start-UsbCQuery
    }

    $candidate = Get-RefreshCandidate $monitors
    $script:refreshFixButton.Enabled = $null -ne $candidate
    $script:refreshFixButton.Text = if ($candidate) {
        "$($candidate.Name): $([math]::Round($candidate.Refresh)) → $($candidate.MaxRefreshAtResolution) Hz"
    } elseif ($monitors | Where-Object Cloned) { 'Önce "Yalnızca harici" veya "Genişlet" seç' }
    else { 'Tüm ekranlar en yüksek Hz''te' }

    $lines = foreach ($monitor in $monitors) {
        "$($monitor.Name) [$($monitor.Connection)]  Hz: $($monitor.RatesAtResolution -join ', ')"
        "  " + ($monitor.Modes -join '   ')
    }
    $script:displayModesBox.Text = ($lines -join "`r`n")
}

function Update-DisplayAlerts {
    $monitors = @($script:displayMonitors)
    Set-UiAlerts $script:displayAlerts (@(Get-DisplayAlerts $monitors) + @(Get-UsbCAlerts $script:insightCache.UsbC $monitors))
}

function Start-UsbCQuery {
    $script:usbCQueryRunning = $true
    $shell = [powershell]::Create()
    [void]$shell.AddScript(${function:Get-UsbCDisplayInfo}.ToString())
    $job = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
    $job | Add-Member -MemberType ScriptProperty -Name Done -Value { $this.Handle.IsCompleted }
    Wait-UiJob $job {
        param($Job)
        try {
            $result = @($Job.Shell.EndInvoke($Job.Handle)) | Select-Object -First 1
            if ($result) {
                $script:insightCache.UsbC = $result
                $script:insightCache.UsbCAt = [datetime]::UtcNow
            }
        } catch { } finally {
            $Job.Shell.Dispose()
            $script:usbCQueryRunning = $false
        }
        if ($script:currentPage -eq 'display') { Update-DisplayAlerts }
    }
}

function Set-DisplayTopology {
    param([ValidateSet('external', 'extend', 'clone', 'internal')][string]$Mode)
    $external = @($script:displayMonitors | Where-Object { -not $_.Internal })
    if ($Mode -ne 'internal' -and $external.Count -eq 0 -and @($script:displayMonitors).Count -le 1) {
        [void](Show-UiMessage 'Harici ekran bağlı görünmüyor. Kabloyu taktıktan sonra Yenile''ye bas.')
        return
    }
    $names = @{ external = 'Yalnızca harici ekran'; extend = 'Genişlet'; clone = 'Çoğalt'; internal = 'Yalnızca laptop ekranı' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\DisplaySwitch.exe') -ArgumentList "/$Mode"
    Add-Log "Ekran düzeni: $($names[$Mode])."
    Start-DelayedAction 3500 { if ($script:currentPage -eq 'display') { Update-DisplayPage } }
}

function Show-RefreshConfirm {
    param([string]$Name, [int]$Hz)
    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = 'Yenileme hızı'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.TopMost = $true
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [Drawing.Size]::new(440, 172)
    $dialog.BackColor = $script:theme.Card
    $dialog.Font = $script:fonts.Body
    [void](New-UiLabel $dialog "$Name artık $Hz Hz. Görüntü düzgün mü?" 20 18 400 24 -Font $script:fonts.BodyBold)
    [void](New-UiLabel $dialog 'Onaylamazsan 15 saniye sonra eski ayara dönülür.' 20 46 400 22 -Color $script:theme.SubText)
    $countdown = New-UiLabel $dialog '15 sn' 20 76 400 24 -Color $script:theme.Amber -Font $script:fonts.BodyBold
    $countdown.Tag = 15
    [void](New-UiButton $dialog 'Koru' 20 116 194 38 $script:theme.Accent { $this.FindForm().DialogResult = 'Yes' })
    [void](New-UiButton $dialog 'Geri al' 226 116 194 38 $script:theme.Neutral { $this.FindForm().DialogResult = 'No' })
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 1000
    $timer.Add_Tick({
        $countdown.Tag = [int]$countdown.Tag - 1
        $countdown.Text = "$($countdown.Tag) sn"
        if ([int]$countdown.Tag -le 0) { $dialog.DialogResult = 'No' }
    }.GetNewClosure())
    $dialog.Add_HandleCreated({ [GameBoostWindow]::UseDarkTitleBar($this.Handle, $script:theme.Card) })
    $timer.Start()
    try { $result = $dialog.ShowDialog($form) } finally { $timer.Stop(); $timer.Dispose(); $dialog.Dispose() }
    return $result -eq 'Yes'
}

function Invoke-BestRefresh {
    $monitor = Get-RefreshCandidate @([GameBoostDisplay]::GetMonitors())
    if (-not $monitor) { Update-DisplayPage; return }
    $target = $monitor.MaxRefreshAtResolution
    $code = [GameBoostDisplay]::ApplyRefresh($monitor.GdiName, $target, $false)
    if ($code -ne 0) {
        [void](Show-UiMessage "$($monitor.Name) için $target Hz uygulanamadı (kod $code). Kablo veya ekran bu modu desteklemiyor olabilir." 'Yenileme hızı' 'OK' 'Warning')
        return
    }
    if (Show-RefreshConfirm $monitor.Name $target) {
        [void][GameBoostDisplay]::ApplyRefresh($monitor.GdiName, $target, $true)
        Add-Log "$($monitor.Name): $target Hz kalıcı olarak ayarlandı."
    } else {
        [void][GameBoostDisplay]::RevertToPrevious($monitor.GdiName)
        Add-Log "$($monitor.Name): değişiklikten önceki ekran moduna dönüldü."
    }
    Update-DisplayPage
}

# ---------------------------------------------------------------- Ses

function Build-AudioPage {
    $page = New-Page 'audio' 'Ses' 'Ses çıkışları, mikrofonlar ve oyun için doğru ayarlar.' 0xE767 { param($Page) Update-AudioPage }
    [void](New-UiButton $page 'Yenile' 836 22 100 32 -OnClick { Update-AudioPage })

    $list = New-UiCard $page 'Ses aygıtları' 28 88 908 284
    $script:audioGrid = New-UiGrid $list 16 46 876 222 @('Aygıt', 'Yön', 'Tür', 'Biçim', 'Durum') @(330, 70, 150, 190, 0)

    $diag = New-UiCard $page 'Teşhis' 28 386 300 310
    $script:audioAlerts = New-UiAlertView $diag 16 48 270 250

    $mic = New-UiCard $page 'Mikrofon' 342 386 300 310
    $script:micInfoLabel = New-UiLabel $mic '' 18 44 264 40 -Color $script:theme.SubText -Font $script:fonts.Small -Wrap
    $script:micTestButton = New-UiButton $mic '5 sn mikrofon testi' 18 88 264 34 $script:theme.Accent { Start-MicTest } `
        -Tip 'Konuşurken 5 saniye dinler ve seviyeyi ölçer. Kayıt saklanmaz.'
    $script:micResultLabel = New-UiLabel $mic 'Teste basıp normal sesinle konuş.' 18 128 264 70 -Color $script:theme.SubText -Wrap
    $script:micLevelButton = New-UiButton $mic 'Seviyeyi %100 yap' 18 204 264 34 -OnClick { Set-MicLevelFull } `
        -Tip 'Windows mikrofon seviyesini en yükseğe alır. "Önceki seviyeye dön" ile geri alınır.'
    $script:micUndoButton = New-UiButton $mic 'Önceki seviyeye dön' 18 246 264 34 -OnClick { Undo-MicLevel }

    $side = New-UiCard $page 'Kısayollar' 656 386 280 310
    $script:audioVolumeLabel = New-UiLabel $side '' 18 46 244 46 -Color $script:theme.SubText -Wrap
    [void](New-UiButton $side 'Ses ayarları' 18 102 244 34 -OnClick { Start-Process 'ms-settings:sound' })
    [void](New-UiButton $side 'Ses denetim masası' 18 144 244 34 -OnClick { Start-Process 'control.exe' -ArgumentList 'mmsys.cpl' } `
        -Tip 'Biçim (kHz), mikrofon artırma (+dB), özel mod ve ses geliştirmeleri buradan değişir.')
    [void](New-UiButton $side 'Uygulama ses düzeyleri' 18 186 244 34 -OnClick { Start-Process 'ms-settings:apps-volume' } `
        -Tip 'Oyunun ve Discord''un hangi aygıttan çıkacağını ayrı ayrı seç.')
    [void](New-UiButton $side 'Mikrofon izni' 18 228 244 34 -OnClick { Start-Process 'ms-settings:privacy-microphone' } `
        -Tip 'Discord ve oyunların mikrofonu kullanabilmesi için masaüstü uygulamalarına izin verilmeli.')
}

function Start-MicTest {
    $microphone = Get-DefaultMicrophone
    if (-not $microphone) { $script:micResultLabel.Text = 'Varsayılan mikrofon yok.'; return }
    $script:micTestButton.Enabled = $false
    $script:micResultLabel.Text = 'Dinleniyor: 5 saniye normal sesinle konuş...'
    $script:micResultLabel.ForeColor = $script:theme.Amber
    $test = [GameBoostMicTest]::new()
    $test.Start(5)
    Wait-UiJob $test { param($Job) Show-MicTestResult $Job }
}

# Levels are dBFS: speech around -20 is clear, below -28 is quiet, near 0 distorts.
function Show-MicTestResult {
    param($Job)
    $script:micTestButton.Enabled = $true
    $color = $script:theme.Amber
    if ($Job.Error) {
        $text = 'Mikrofon açılamadı. Başka bir uygulama kullanıyor olabilir ya da mikrofon izni kapalı.'
        $color = $script:theme.Red
    } elseif ($Job.Silent) {
        $text = 'Hiç ses gelmedi. Mikrofon izni kapalı veya mikrofon sessizde olabilir.'
        $color = $script:theme.Red
    } elseif ($Job.SpeechDb - $Job.NoiseDb -lt 6) {
        $text = 'Konuşma algılanmadı. Test sırasında normal sesinle konuş ve tekrar dene.'
    } elseif ($Job.PeakDb -ge -1) {
        $text = 'Çok yüksek: ses patlayabilir. Seviyeyi biraz düşür.'
    } elseif ($Job.SpeechDb -lt -40) {
        $text = 'Çok düşük: karşı taraf zor duyar. Seviyeyi artır, kulaklık mikrofonu kullan.'
        $color = $script:theme.Red
    } elseif ($Job.SpeechDb -lt -28) {
        $text = 'Düşük: seviyeyi artır veya mikrofona yaklaş.'
    } else {
        $text = 'İyi: sesin net duyulur.'
        $color = $script:theme.Accent
    }
    if (-not $Job.Error -and -not $Job.Silent -and $Job.NoiseDb -gt -45) { $text += ' Arka plan gürültüsü yüksek (fan?): Discord''da gürültü bastırmayı aç.' }
    if (-not $Job.Error -and -not $Job.Silent) {
        $text += "`r`nKonuşma {0:0} dB · tepe {1:0} dB · gürültü {2:0} dB" -f $Job.SpeechDb, $Job.PeakDb, $Job.NoiseDb
    }
    $script:micResultLabel.Text = $text
    $script:micResultLabel.ForeColor = $color
    Add-Log ("Mikrofon testi: {0}" -f ($text -split "`r`n")[0])
}

function Set-MicLevelFull {
    $microphone = Get-DefaultMicrophone
    if (-not $microphone) { return }
    $previous = [GameBoostAudio]::SetEndpointVolume($microphone.Id, 1.0)
    if ($previous -lt 0) { Add-Log 'Mikrofon seviyesi değiştirilemedi.'; return }
    # Keep the first value so repeated presses still undo to the original level.
    if (-not $script:micLevelUndo -or $script:micLevelUndo.Id -ne $microphone.Id) {
        $script:micLevelUndo = [pscustomobject]@{ Id = $microphone.Id; Level = $previous; Name = $microphone.Name }
    }
    Add-Log ('Mikrofon seviyesi %100 yapıldı (önceki %{0:0}).' -f ($script:micLevelUndo.Level * 100))
    Update-AudioPage
}

function Undo-MicLevel {
    $undo = $script:micLevelUndo
    if (-not $undo) { return }
    if ([GameBoostAudio]::SetEndpointVolume($undo.Id, $undo.Level) -ge 0) {
        Add-Log ('Mikrofon seviyesi önceki değere döndü (%{0:0}).' -f ($undo.Level * 100))
        $script:micLevelUndo = $null
    } else { Add-Log 'Mikrofon seviyesi geri alınamadı; aygıt çıkarılmış olabilir.' }
    Update-AudioPage
}

function Update-AudioPage {
    $devices = @([GameBoostAudio]::GetDevices())
    $sorted = $devices | Sort-Object IsCapture, @{ Expression = { -not $_.IsDefault } }, Name
    $rows = foreach ($device in $sorted) {
        $state = @()
        if (-not $device.Active) { $state += 'Takılı değil' }
        if ($device.IsDefault) { $state += 'Varsayılan' }
        if ($device.IsDefaultCommunications) { $state += 'Sohbet' }
        if ($device.Active -and $state.Count -eq 0) { $state += 'Hazır' }
        $color = if ($device.IsDefault -and $device.Active) { $script:theme.Accent } elseif (-not $device.Active) { $script:theme.Muted } else { $null }
        $direction = if ($device.IsCapture) { 'Giriş' } else { 'Çıkış' }
        New-UiRow @($device.Name, $direction, (Get-AudioFormFactorName $device.FormFactor), (Get-AudioFormatText $device), ($state -join ' · ')) $color
    }
    Set-UiGridRows $script:audioGrid $rows 'Ses aygıtı bulunamadı'
    Set-UiAlerts $script:audioAlerts (Get-AudioAlerts $devices)
    $default = $devices | Where-Object { -not $_.IsCapture -and $_.IsDefault } | Select-Object -First 1
    $script:audioVolumeLabel.Text = if ($default) {
        $level = if ($default.Volume -ge 0) { "%$([math]::Round($default.Volume * 100))" } else { '?' }
        "Çıkış: $($default.Name)`r`nSes düzeyi: $level$(if ($default.Muted) { ' · sessizde' })"
    } else { 'Varsayılan çıkış yok.' }

    $microphone = Get-DefaultMicrophone $devices
    $script:micInfoLabel.Text = if ($microphone) {
        $level = if ($microphone.Volume -ge 0) { "%$([math]::Round($microphone.Volume * 100))" } else { '?' }
        $shortName = $microphone.Name -replace '\s*\(.*$', ''
        "$shortName`r`nSeviye: $level$(if ($microphone.Muted) { ' · sessizde' })"
    } else { 'Varsayılan mikrofon yok.' }
    $script:micTestButton.Enabled = $null -ne $microphone
    $script:micLevelButton.Enabled = $null -ne $microphone -and $microphone.Volume -ge 0 -and $microphone.Volume -lt 0.99
    $script:micUndoButton.Enabled = $null -ne $script:micLevelUndo
}

# ---------------------------------------------------------------- Ağ / Wi-Fi

function Build-NetworkPage {
    $page = New-Page 'network' 'Ağ / Wi-Fi' 'Bağlantı kalitesi, gecikme testi ve oyun için Wi-Fi sürücü ayarları.' 0xE701 {
        param($Page)
        if (-not $script:insightCache.Network -or -not $Page.Loaded) { Update-NetworkPage }
    }
    [void](New-UiButton $page 'Wi-Fi ayarları' 600 22 120 32 -OnClick { Start-Process 'ms-settings:network-wifi' })
    [void](New-UiButton $page 'Konum izni' 728 22 100 32 -OnClick { Start-Process 'ms-settings:privacy-location' } `
        -Tip 'Windows, ağ adı, kanal ve sinyal gücünü yalnızca konum izni varsa gösterir.')
    [void](New-UiButton $page 'Yenile' 836 22 100 32 -OnClick { Update-NetworkPage })

    $connection = New-UiCard $page 'Bağlantı' 28 88 440 300
    $script:networkValues = New-UiKeyValues $connection @('Bağdaştırıcı', 'Donanım', 'Etkin mod', 'Durum', 'Bağlantı hızı', 'Bant', 'Ağ / sinyal', 'IP / modem') 18 48 116 296 28

    $ping = New-UiCard $page 'Hız ve gecikme testi' 484 88 452 300
    [void](New-UiLabel $ping 'Gecikme: modeme ve internete 10''ar ping. Hız: Cloudflare sunucusuyla ~15 sn indirme ve yükleme (en fazla ~360 MB veri).' 18 44 416 36 `
        -Color $script:theme.SubText -Font $script:fonts.Small -Wrap)
    $script:pingButton = New-UiButton $ping 'Gecikme testi' 18 84 150 34 $script:theme.Accent { Start-PingTest }
    $script:speedButton = New-UiButton $ping 'Hız testi' 176 84 150 34 $script:theme.Accent { Start-SpeedTest } `
        -Tip 'Bağlantıyı ~15 sn doldurur; çalışırken basınca durur.'
    $script:pingValues = New-UiKeyValues $ping @('Modem', 'İnternet', 'İndirme', 'Yükleme') 18 128 86 330 25
    $script:pingVerdict = New-UiLabel $ping '' 18 230 416 62 -Font $script:fonts.Small -Wrap

    $drivers = New-UiCard $page 'Wi-Fi sürücü ayarları' 28 402 600 294
    $script:wifiGrid = New-UiGrid $drivers 16 46 568 192 @('Ayar', 'Şu an', 'Oyun için', '') @(170, 150, 150, 0)
    $script:wifiApplyButton = New-UiButton $drivers 'Önerilenleri uygula' 16 248 196 34 $script:theme.Accent { Invoke-WifiFix } `
        -Tip 'Yönetici izni ister. Wi-Fi birkaç saniye kopar. Önceki değerler yedeklenir.'
    $script:wifiRevertButton = New-UiButton $drivers 'Geri al' 222 248 110 34 -OnClick { Invoke-WifiRevert }
    [void](New-UiButton $drivers 'Komutları kopyala' 342 248 242 34 -OnClick { Copy-WifiCommands })

    $diag = New-UiCard $page 'Teşhis' 644 402 292 294
    $script:networkAlerts = New-UiAlertView $diag 16 48 262 234
}

function Update-NetworkPage {
    Invoke-UiBusy {
        $script:insightCache.Network = Get-NetworkInfo
        $script:insightCache.NetworkAlerts = @(Get-NetworkAlerts $script:insightCache.Network)
    }
    $info = $script:insightCache.Network
    $values = $script:networkValues
    $adapter = if ($info.Wifi) { $info.Wifi } else { $info.Ethernet }
    if ($adapter) {
        Set-UiValue $values 'Bağdaştırıcı' $adapter.InterfaceDescription
        Set-UiValue $values 'Durum' $(if ($adapter.Status -eq 'Up') { 'Bağlı' } else { 'Bağlı değil' }) $(if ($adapter.Status -eq 'Up') { $script:theme.Accent } else { $script:theme.Amber })
        Set-UiValue $values 'Bağlantı hızı' $(if ($adapter.Status -eq 'Up') { "$([math]::Round($adapter.ReceiveLinkSpeed / 1e6)) Mbps" })
    }
    $modeRow = $info.Rows | Where-Object Keyword -eq 'IEEE11nMode' | Select-Object -First 1
    Set-UiValue $values 'Donanım' $info.Generation
    Set-UiValue $values 'Etkin mod' $info.ActiveMode $(if ($modeRow -and -not $modeRow.Ok) { $script:theme.Amber } else { $script:theme.Text })
    Set-UiValue $values 'Bant' $info.Band
    $signal = if ($info.Ssid) { "$($info.Ssid) · %$($info.Signal) · kanal $($info.Channel)" } elseif ($info.LocationBlocked) { 'Konum izni gerekli' } else { $null }
    Set-UiValue $values 'Ağ / sinyal' $signal $(if ($info.LocationBlocked) { $script:theme.Muted } else { $script:theme.Text })
    Set-UiValue $values 'IP / modem' $(if ($info.IPv4) { "$($info.IPv4)  ·  $($info.Gateway)" })

    $rows = foreach ($row in $info.Rows) {
        New-UiRow @($row.Label, $row.Current, $row.Recommended, $(if ($row.Ok) { '✓ uygun' } else { 'değiştir' })) $(if ($row.Ok) { $null } else { $script:theme.Amber })
    }
    Set-UiGridRows $script:wifiGrid $rows 'Wi-Fi bağdaştırıcısı bulunamadı'
    for ($i = 0; $i -lt @($info.Rows).Count -and $i -lt $script:wifiGrid.Rows.Count; $i++) {
        foreach ($cell in $script:wifiGrid.Rows[$i].Cells) { $cell.ToolTipText = @($info.Rows)[$i].Why }
    }
    $script:wifiApplyButton.Enabled = @($info.Rows | Where-Object { -not $_.Ok }).Count -gt 0
    $script:wifiRevertButton.Enabled = Test-Path -LiteralPath (Get-WifiBackupPath)
    Set-UiAlerts $script:networkAlerts $script:insightCache.NetworkAlerts
}

function Get-DefaultGateway {
    foreach ($interface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($interface.OperationalStatus -ne 'Up' -or $interface.Description -match 'Virtual|Hyper-V') { continue }
        $gateway = @($interface.GetIPProperties().GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.IPAddressToString -ne '0.0.0.0' }) | Select-Object -First 1
        if ($gateway) { return $gateway.Address.IPAddressToString }
    }
    return $null
}

function Format-PingResult {
    param([double[]]$Result)
    if ($Result[0] -lt 0) { return 'Yanıt yok' }
    return '{0:0.#} ms  ·  dalgalanma {1:0.#} ms  ·  kayıp %{2}' -f $Result[0], $Result[3], $Result[4]
}

function Start-PingTest {
    $gateway = Get-DefaultGateway
    if (-not $gateway) { $script:pingVerdict.Text = 'Ağ bağlantısı bulunamadı.'; $script:pingVerdict.ForeColor = $script:theme.Red; return }
    $script:pingButton.Enabled = $false
    $script:pingButton.Text = 'Ölçülüyor...'
    $script:pingVerdict.Text = ''
    $test = [GameBoostPingTest]::new()
    $test.Start(@($gateway, '1.1.1.1'), 10, 800)
    Wait-UiJob $test {
        param($Job)
        $results = $Job.Results
        Set-UiValue $script:pingValues 'Modem' (Format-PingResult $results[0])
        Set-UiValue $script:pingValues 'İnternet' (Format-PingResult $results[1])
        $verdict = Get-PingVerdict $results[0] $results[1]
        $script:pingVerdict.Text = $verdict[1]
        $script:pingVerdict.ForeColor = switch ($verdict[0]) { 'ok' { $script:theme.Accent } 'info' { $script:theme.Blue } 'critical' { $script:theme.Red } default { $script:theme.Amber } }
        $script:pingButton.Enabled = $true
        $script:pingButton.Text = 'Gecikme testi'
        Add-Log "Gecikme testi: modem $(Format-PingResult $results[0]); internet $(Format-PingResult $results[1])."
    }
}

function Format-Mbps {
    param([double]$Mbps)
    if ($Mbps -lt 0) { return 'ölçülemedi' }
    if ($Mbps -ge 100) { return '{0:0} Mbps' -f $Mbps }
    return '{0:0.#} Mbps' -f $Mbps
}

# Pressing again while it runs stops it.
function Start-SpeedTest {
    if ($script:speedTest) { $script:speedTest.Cancel(); return }
    $connection = Get-ConnectionProfileInfo
    if (-not $connection) { $script:pingVerdict.Text = 'İnternet bağlantısı görünmüyor.'; $script:pingVerdict.ForeColor = $script:theme.Red; return }
    $warnings = @()
    if ($connection.Cost -in 'Fixed', 'Variable') { $warnings += "Bağlantı ölçülü ($($connection.Name)): test ~360 MB'a kadar veri harcar." }
    if ($script:boosted) { $warnings += 'BOOST açık: test bağlantını ~15 sn doldurur; çevrim içi oyundaysan gecikme olur.' }
    if ($script:download) { $warnings += 'İndirme modu açık: test sürerken indirmen yavaşlar.' }
    if ($warnings.Count -gt 0 -and (Show-UiMessage "$($warnings -join "`r`n")`r`n`r`nTest başlatılsın mı?" 'Hız testi' 'YesNo' 'Question') -ne 'Yes') { return }

    $test = [GameBoostSpeedTest]::new()
    $test.Start()
    $script:speedTest = $test
    $script:speedButton.Text = 'Durdur'
    Set-UiValue $script:pingValues 'İndirme' 'bekliyor'
    Set-UiValue $script:pingValues 'Yükleme' 'bekliyor'
    $script:pingVerdict.Text = 'Gecikme ölçülüyor...'
    $script:pingVerdict.ForeColor = $script:theme.SubText
    $script:speedTimer = [Windows.Forms.Timer]::new()
    $script:speedTimer.Interval = 400
    $script:speedTimer.Add_Tick({
        $test = $script:speedTest
        if (-not $test) { return }
        switch ($test.Phase) {
            'down' { Set-UiValue $script:pingValues 'İndirme' "$(Format-Mbps $test.LiveMbps) ölçülüyor..." $script:theme.SubText; $script:pingVerdict.Text = 'İndirme ölçülüyor (~8 sn)...' }
            'up' { Set-UiValue $script:pingValues 'Yükleme' "$(Format-Mbps $test.LiveMbps) ölçülüyor..." $script:theme.SubText; $script:pingVerdict.Text = 'Yükleme ölçülüyor (~6 sn)...' }
        }
        if ($test.Phase -eq 'up' -and $test.DownMbps -ge 0) { Set-UiValue $script:pingValues 'İndirme' (Format-Mbps $test.DownMbps) }
    })
    $script:speedTimer.Start()
    Wait-UiJob $test { param($Job) Complete-SpeedTest $Job }
}

function Complete-SpeedTest {
    param($Test)
    $script:speedTimer.Stop(); $script:speedTimer.Dispose(); $script:speedTimer = $null
    $script:speedTest = $null
    $script:speedButton.Text = 'Hız testi'
    $used = Format-ByteSize $Test.BytesUsed
    if ($Test.Error -and $Test.DownMbps -lt 0) {
        $script:pingVerdict.Text = if ($Test.Error -eq 'cancelled') { "Test durduruldu ($used veri)." } else { "Test tamamlanamadı: $($Test.Error)" }
        $script:pingVerdict.ForeColor = $script:theme.Amber
        Set-UiValue $script:pingValues 'İndirme' '—'
        Set-UiValue $script:pingValues 'Yükleme' '—'
        return
    }
    $down = $Test.DownMbps; $up = $Test.UpMbps
    Set-UiValue $script:pingValues 'İndirme' (Format-Mbps $down) $script:theme.Accent
    Set-UiValue $script:pingValues 'Yükleme' (Format-Mbps $up) $(if ($up -ge 0 -and $up -lt 5) { $script:theme.Amber } else { $script:theme.Accent })
    $lines = [Collections.Generic.List[string]]::new()
    $server = if ($Test.Server) { "Cloudflare $($Test.Server)" } else { 'Cloudflare' }
    $lines.Add(('Sunucu: {0} · gecikme {1:0} ms (dalgalanma {2:0.#} ms) · {3} veri' -f $server, $Test.PingMs, $Test.JitterMs, $used))
    if ($down -gt 0) {
        $minutes = 50e9 * 8 / ($down * 1e6) / 60
        $time = if ($minutes -ge 90) { '{0:0.#} saat' -f ($minutes / 60) } else { '{0:0} dk' -f $minutes }
        $wifi = $script:insightCache.Network.Wifi
        $link = if ($wifi -and $wifi.Status -eq 'Up') { [math]::Round($wifi.ReceiveLinkSpeed / 1e6) } else { 0 }
        $limit = if ($link -gt 0 -and $down -ge 0.55 * $link) { " Wi-Fi bağlantı hızına ($link Mbps) yakın: darboğaz Wi-Fi olabilir; 5/6 GHz veya kablo dene." }
            elseif ($link -gt 0) { " Wi-Fi bağlantısı $link Mbps; hızı internet paketin belirliyor." } else { '' }
        $lines.Add("50 GB'lık oyun ≈ $time.$limit")
    }
    if ($up -ge 0 -and $up -lt 5) { $lines.Add('Yükleme düşük: canlı yayın ve büyük dosya yüklemeleri zorlanır.') }
    $script:pingVerdict.Text = $lines -join ' '
    $script:pingVerdict.ForeColor = $script:theme.Text
    $script:lastSpeedResult = [pscustomobject]@{ At = Get-Date; Down = $down; Up = $up; Ping = $Test.PingMs }
    Add-Log "Hız testi: ↓ $(Format-Mbps $down) · ↑ $(Format-Mbps $up) · gecikme $([math]::Round($Test.PingMs)) ms ($server, $used)."
}

function Get-PendingWifiValues {
    $info = $script:insightCache.Network
    $values = [ordered]@{}
    foreach ($row in @($info.Rows | Where-Object { -not $_.Ok })) { $values[$row.Keyword] = $row.RecommendedValue }
    return $values
}

function Invoke-WifiFix {
    $info = $script:insightCache.Network
    if (-not $info -or -not $info.Wifi) { return }
    $pending = @($info.Rows | Where-Object { -not $_.Ok })
    if ($pending.Count -eq 0) { return }
    $list = ($pending | ForEach-Object { "   •  $($_.Label): $($_.Current) → $($_.Recommended)" }) -join "`r`n"
    $message = "Şu Wi-Fi ayarları değiştirilecek:`r`n`r`n$list`r`n`r`nYönetici izni istenecek ve Wi-Fi birkaç saniye kopacak. " +
        "Önceki değerler yedeklenir; Geri al ile dönebilirsin.`r`n`r`nDevam edilsin mi?"
    if ((Show-UiMessage $message 'Wi-Fi ayarları' 'YesNo' 'Question') -ne 'Yes') { return }
    Save-WifiBackup $info
    Remove-Item -LiteralPath (Get-WifiResultPath) -Force -ErrorAction SilentlyContinue
    if (Invoke-AdminScript (Get-WifiScriptLines $info.Wifi.Name (Get-PendingWifiValues) $info.PowerScheme) 'wifi-apply') {
        Add-Log "Wi-Fi ayarları uygulanıyor: $(@($pending.Label) -join ', ')."
        Start-DelayedAction 15000 { Show-WifiResult 'ayarları'; Update-NetworkPage; Update-HomeAlerts }
    }
}

function Invoke-WifiRevert {
    $path = Get-WifiBackupPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { $backup = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return }
    $values = [ordered]@{}
    foreach ($property in $backup.Values.PSObject.Properties) { $values[$property.Name] = [string]$property.Value }
    $message = "Wi-Fi ayarları GameBoost öncesi değerlere döndürülecek ($($backup.SavedAt.Substring(0, 10)) yedeği).`r`nYönetici izni istenecek ve Wi-Fi birkaç saniye kopacak. Devam edilsin mi?"
    if ((Show-UiMessage $message 'Wi-Fi ayarları' 'YesNo' 'Question') -ne 'Yes') { return }
    # The elevated script deletes the backup itself, only after the old values are read back.
    $scheme = if ($backup.PowerScheme) { [string]$backup.PowerScheme } else { $null }
    Remove-Item -LiteralPath (Get-WifiResultPath) -Force -ErrorAction SilentlyContinue
    if (Invoke-AdminScript (Get-WifiScriptLines $backup.Adapter $values $scheme $path) 'wifi-revert') {
        Add-Log 'Wi-Fi ayarları eski değerlerine döndürülüyor.'
        Start-DelayedAction 15000 { Show-WifiResult 'geri alma'; Update-NetworkPage; Update-HomeAlerts }
    }
}

function Copy-WifiCommands {
    $info = $script:insightCache.Network
    if (-not $info -or -not $info.Wifi) { return }
    $values = Get-PendingWifiValues
    if ($values.Count -eq 0) { Add-Log 'Değiştirilecek Wi-Fi ayarı yok.'; return }
    $lines = @('# Yönetici PowerShell''de çalıştır. Wi-Fi birkaç saniye kopar.') + @(Get-WifiScriptLines $info.Wifi.Name $values $info.PowerScheme)
    Copy-UiText ($lines -join "`r`n") 'Wi-Fi komutları'
}

# ---------------------------------------------------------------- Bluetooth ve Kumanda

function Build-DevicesPage {
    $page = New-Page 'devices' 'Bluetooth ve Kumanda' 'Kablosuz bağlantılar, kumanda ve fare hız testleri.' 0xE702 {
        param($Page)
        if (-not $script:insightCache.Devices -or -not $Page.Loaded) { Update-DevicesPage }
    } -Nav 'Bluetooth & Kumanda'
    [void](New-UiButton $page 'Bluetooth ayarları' 680 22 148 32 -OnClick { Start-Process 'ms-settings:bluetooth' })
    [void](New-UiButton $page 'Yenile' 836 22 100 32 -OnClick { Update-DevicesPage })

    $bluetooth = New-UiCard $page 'Bluetooth' 28 88 440 250
    $script:btValues = New-UiKeyValues $bluetooth @('Adaptör', 'Sürüm', 'Durum') 18 46 96 314 26
    $script:btGrid = New-UiGrid $bluetooth 16 128 408 108 @('Eşleşmiş cihaz', 'Tür', 'Pil') @(220, 110, 0)

    $pads = New-UiCard $page 'Oyun kumandası' 484 88 452 250
    $script:padGrid = New-UiGrid $pads 16 46 420 98 @('Kumanda', 'Bağlantı', 'Durum') @(200, 110, 0)
    $script:padTestButton = New-UiButton $pads 'Hız testi (3 sn)' 16 156 160 34 $script:theme.Accent { Start-PadTest }
    $script:padResult = New-UiLabel $pads 'Teste basınca çubuğu 3 saniye sürekli döndür.' 188 152 248 44 -Color $script:theme.SubText -Wrap
    [void](New-UiLabel $pads 'Rapor hızı: kumandanın saniyede kaç kez konum gönderdiği (125 Hz = 8 ms).' 16 204 420 36 `
        -Color $script:theme.Muted -Font $script:fonts.Small -Wrap)

    $mouse = New-UiCard $page 'Fare' 28 352 440 150
    $script:mouseTestButton = New-UiButton $mouse 'Fare hız testi (3 sn)' 16 46 180 34 $script:theme.Accent { Start-MouseTest }
    $script:mouseResult = New-UiLabel $mouse 'Teste basınca fareyi 3 saniye hızlı daireler çizerek oynat.' 208 42 216 48 -Color $script:theme.SubText -Wrap
    [void](New-UiLabel $mouse 'Oyun faresi için 500-1000 Hz idealdir; 125 Hz hareketi daha az akıcı gösterir.' 16 98 408 40 `
        -Color $script:theme.Muted -Font $script:fonts.Small -Wrap)

    $inputs = New-UiCard $page 'Giriş aygıtları' 484 352 452 344
    $script:inputGrid = New-UiGrid $inputs 16 46 420 284 @('Aygıt', 'Tür', 'Bağlantı') @(230, 90, 0)

    $diag = New-UiCard $page 'Teşhis' 28 516 440 180
    $script:deviceAlerts = New-UiAlertView $diag 16 48 408 120
}

function Update-DevicesPage {
    Invoke-UiBusy { $script:insightCache.Devices = Get-DeviceInfo }
    $info = $script:insightCache.Devices
    Set-UiValue $script:btValues 'Adaptör' $(if ($info.Radio) { $info.Radio.FriendlyName } else { 'Bulunamadı' })
    Set-UiValue $script:btValues 'Sürüm' $info.Version
    Set-UiValue $script:btValues 'Durum' $(if ($info.Radio) { if ($info.Radio.Status -eq 'OK') { 'Çalışıyor' } else { [string]$info.Radio.Status } })
    Set-UiGridRows $script:btGrid @($info.Paired | ForEach-Object { New-UiRow @($_.Name, $_.Kind, $_.Battery) }) 'Eşleşmiş cihaz yok'

    $names = @($info.Controllers | Sort-Object { -not $_.XInput } | ForEach-Object Name)
    $rows = foreach ($pad in $info.Pads) {
        $name = if ($names.Count -ge $pad.Slot) { $names[$pad.Slot - 1] } elseif ($names.Count -gt 0) { $names[0] } else { 'XInput kumanda' }
        New-UiRow @("$($pad.Slot).  $name", $(if ($pad.Wireless) { 'Kablosuz' } else { 'Kablolu (USB)' }), (Get-PadBatteryText $pad))
    }
    if (@($info.Pads).Count -eq 0) {
        $rows = foreach ($controller in $info.Controllers) { New-UiRow @($controller.Name, $controller.Bus, 'DirectInput / HID') }
    }
    Set-UiGridRows $script:padGrid $rows 'Kumanda bağlı değil'
    $script:padTestButton.Enabled = @($info.Pads).Count -gt 0
    Set-UiGridRows $script:inputGrid @($info.Inputs | ForEach-Object { New-UiRow @($_.Name, $_.Kind, $_.Bus) }) 'Giriş aygıtı bulunamadı'
    $script:insightCache.DeviceAlerts = @(Get-DeviceAlerts $info)
    Set-UiAlerts $script:deviceAlerts $script:insightCache.DeviceAlerts
}

function Start-PadTest {
    $pads = @([GameBoostXInput]::GetPads())
    if ($pads.Count -eq 0) { $script:padResult.Text = 'Kumanda bulunamadı.'; return }
    $script:padTestButton.Enabled = $false
    $script:padResult.Text = 'Çubuğu sürekli döndür...'
    $script:padResult.ForeColor = $script:theme.Amber
    $test = [GameBoostGamepadRateTest]::new()
    $test.Start($pads[0].Slot, 3000)
    Wait-UiJob $test {
        param($Job)
        $script:padTestButton.Enabled = $true
        if ($Job.Error -eq 'nomotion') {
            $script:padResult.Text = 'Yeterli hareket yok; test boyunca çubuğu döndür.'
            $script:padResult.ForeColor = $script:theme.Amber
            return
        }
        if ($Job.Error) {
            $script:padResult.Text = 'Kumanda bağlantısı kesildi.'
            $script:padResult.ForeColor = $script:theme.Red
            return
        }
        $script:padResult.Text = '~{0} Hz  ({1:0.0} ms)' -f $Job.Hz, (1000 / [math]::Max(1, $Job.Hz))
        $script:padResult.ForeColor = $script:theme.Accent
        $detail = if ($Job.Hz -lt 200) { 'Standart hız. Xbox kumandaları USB''de genelde 125-250 Hz çalışır.' } else { 'Yüksek rapor hızı; giriş gecikmesi düşük.' }
        $script:insightCache.PadResult = New-Alert 'info' ('Kumanda rapor hızı ~{0} Hz' -f $Job.Hz) $detail
        Add-Log ('Kumanda hız testi: ~{0} Hz.' -f $Job.Hz)
        if ($script:insightCache.Devices) {
            $script:insightCache.DeviceAlerts = @(Get-DeviceAlerts $script:insightCache.Devices)
            Set-UiAlerts $script:deviceAlerts $script:insightCache.DeviceAlerts
        }
    }
}

function Start-MouseTest {
    $script:mouseTestButton.Enabled = $false
    $script:mouseResult.Text = 'Fareyi hızlıca oynat...'
    $script:mouseResult.ForeColor = $script:theme.Amber
    $test = [GameBoostMouseRateTest]::new()
    $test.Start(3000)
    Wait-UiJob $test {
        param($Job)
        $script:mouseTestButton.Enabled = $true
        if ($Job.Error) {
            $script:mouseResult.Text = 'Yeterli hareket yok; test boyunca fareyi oynat.'
            $script:mouseResult.ForeColor = $script:theme.Amber
            return
        }
        $verdict = if ($Job.Hz -ge 450) { 'oyun için iyi' } elseif ($Job.Hz -ge 200) { 'orta' } else { 'düşük' }
        $script:mouseResult.Text = '~{0} Hz  ({1})' -f $Job.Hz, $verdict
        $script:mouseResult.ForeColor = if ($Job.Hz -ge 450) { $script:theme.Accent } else { $script:theme.Amber }
        Add-Log ('Fare hız testi: ~{0} Hz.' -f $Job.Hz)
    }
}

# ---------------------------------------------------------------- Sistem Bilgisi

function Build-SystemPage {
    $page = New-Page 'system' 'Sistem Bilgisi' 'Tam özellikler, bağlantılar ve kullanabileceğin özellikler.' 0xE770 {
        param($Page)
        if (-not $Page.Loaded) { Update-SystemPage }
    }
    [void](New-UiButton $page 'Yenile' 520 22 100 32 -OnClick { Update-SystemPage })
    [void](New-UiButton $page 'Tümünü kopyala' 628 22 140 32 $script:theme.Accent { Copy-UiText $script:systemReport 'Sistem bilgisi' })
    [void](New-UiButton $page 'Masaüstüne kaydet' 776 22 160 32 -OnClick { Save-SystemReport })
    $card = New-UiCard $page '' 28 88 908 608
    $script:systemBox = New-UiTextBox $card 18 14 878 582 '' -Mono
    $script:systemBox.BackColor = $script:theme.Card
}

# The report needs CIM, PnP and netsh: 5-20 s, longest the first time and on battery. It is built in its
# own runspace with a fresh copy of the read-only collectors, so the window never waits for it.
# Network and device objects are read again there (their fields depend on modules loaded per runspace).
$script:systemReportScript = @'
param($AppRoot, $State)
$ErrorActionPreference = 'SilentlyContinue'
foreach ($name in 'Boost', 'Insights', 'Score') { . (Join-Path $AppRoot "lib\$name.ps1") }
function Get-SessionHistory { return @($State.History) }
$script:hasNvidiaGpu = $State.HasNvidia
$script:boosted = $State.Boosted
$script:previousPowerScheme = $State.PreviousScheme
$script:overlayEnabled = $State.OverlayEnabled
$script:auditAlerts = @($State.AuditAlerts)
$script:insightCache.UsbC = $State.UsbC
$script:insightCache.UsbCAt = $State.UsbCAt
Get-SystemReportText
'@

function Update-SystemPage {
    if ($script:systemReportJob) { return }
    $script:systemBox.Text = "Bilgiler arka planda okunuyor; ilk seferde 10-20 saniye sürebilir.`r`nBu sırada uygulamayı kullanmaya devam edebilirsin."
    $shell = [powershell]::Create()
    [void]$shell.AddScript($script:systemReportScript)
    [void]$shell.AddParameter('AppRoot', $script:appRoot)
    [void]$shell.AddParameter('State', @{
        History = @(Get-SessionHistory); HasNvidia = $script:hasNvidiaGpu; Boosted = $script:boosted
        PreviousScheme = $script:previousPowerScheme; OverlayEnabled = $script:overlayEnabled; AuditAlerts = @($script:auditAlerts)
        UsbC = $script:insightCache.UsbC; UsbCAt = $script:insightCache.UsbCAt
    })
    $job = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
    $job | Add-Member -MemberType ScriptProperty -Name Done -Value { $this.Handle.IsCompleted }
    $script:systemReportJob = $job
    Wait-UiJob $job {
        param($Job)
        $text = $null
        try { $text = [string](@($Job.Shell.EndInvoke($Job.Handle)) | Select-Object -Last 1) } catch { }
        $Job.Shell.Dispose()
        $script:systemReportJob = $null
        if ($text) {
            $script:systemReport = $text
            $script:systemBox.Text = $text
            $script:systemBox.SelectionStart = 0
            $script:systemBox.ScrollToCaret()
        } else {
            $script:systemBox.Text = 'Sistem bilgisi okunamadı. Yenile ile tekrar dene.'
        }
    }
}

function Save-SystemReport {
    if (-not $script:systemReport) {
        Update-SystemPage
        [void](Show-UiMessage 'Bilgiler okunuyor. Hazır olunca "Masaüstüne kaydet"e tekrar bas.')
        return
    }
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) "GameBoost-Sistem-Bilgisi-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
    try {
        [IO.File]::WriteAllText($path, $script:systemReport, [Text.UTF8Encoding]::new($true))
        Add-Log "Sistem bilgisi kaydedildi: $path"
        [void](Show-UiMessage "Kaydedildi:`r`n$path")
    } catch { [void](Show-UiMessage 'Dosya kaydedilemedi.' 'GameBoost Lite' 'OK' 'Warning') }
}

# ---------------------------------------------------------------- PC Puanı

function Build-ScorePage {
    $page = New-Page 'score' 'PC Puanı' 'Oyun gücü, parça puanları ve kurulumun şu an ne kadar hazır olduğu.' 0xE734 { param($Page) Update-ScorePage }
    [void](New-UiButton $page 'Yenile' 720 22 100 32 -OnClick { Update-ScorePage -Full })
    [void](New-UiButton $page 'Kopyala' 828 22 108 32 $script:theme.Accent { Copy-UiText (Format-PcScoreText $script:pcScore $script:gameEstimate) 'PC puanı' })

    $power = New-UiCard $page 'PC gücü' 28 88 440 196
    $script:scoreOverall = New-UiLabel $power '—' 12 34 -Font $script:fonts.Score
    $script:scoreOverallMax = New-UiLabel $power '/100' 96 74 -Color $script:theme.SubText
    $script:scoreTier = New-UiLabel $power '' 150 40 272 24 -Font $script:fonts.CardTitle
    $script:scoreExpect = New-UiLabel $power '' 150 66 272 56 -Font $script:fonts.Small -Color $script:theme.SubText -Wrap
    $script:scoreBottleneck = New-UiLabel $power '' 18 124 404 42 -Font $script:fonts.Small -Wrap
    [void](New-UiLabel $power 'Model adından ve bilinen test sonuçlarından hesaplanır; yük testi yapılmaz.' 18 168 404 20 `
        -Font $script:fonts.Small -Color $script:theme.Muted)

    $parts = New-UiCard $page 'Bileşenler' 28 300 440 396
    $script:scoreRows = @{}
    $top = 46
    foreach ($row in @('gpu|Ekran kartı', 'cpu|İşlemci', 'ram|RAM', 'storage|Depolama', '-', 'display|Ekran', 'network|Ağ')) {
        if ($row -eq '-') {
            [void](New-UiLabel $parts 'OYUN DENEYİMİ · genel puana katılmaz' 18 ($top + 2) 404 18 -Font $script:fonts.Small -Color $script:theme.Muted)
            $top += 24
            continue
        }
        $key, $label = $row.Split('|')
        [void](New-UiLabel $parts $label 18 $top 108 20 -Font $script:fonts.BodyBold)
        $model = New-UiLabel $parts '' 126 ($top + 1) 250 20 -Font $script:fonts.Small -Color $script:theme.SubText
        $value = New-UiLabel $parts '—' 378 $top 44 20 -Font $script:fonts.BodyBold
        $value.TextAlign = 'MiddleRight'
        $bar = [GameBoostScoreBar]::new()
        $bar.BackColor = $parts.FillColor
        $bar.TrackColor = $script:theme.CardBorder
        $bar.Location = [Drawing.Point]::new(18, $top + 23)
        $bar.Size = [Drawing.Size]::new(404, 6)
        $parts.Controls.Add($bar)
        $detail = New-UiLabel $parts '' 18 ($top + 31) 404 18 -Font $script:fonts.Small -Color $script:theme.SubText
        $script:scoreRows[$key] = @{ Model = $model; Value = $value; Bar = $bar; Detail = $detail }
        $top += 54
    }

    $setup = New-UiCard $page 'Kurulum puanı' 484 88 452 248
    $script:setupScore = New-UiLabel $setup '—' 12 34 -Font $script:fonts.Score
    $script:setupScoreMax = New-UiLabel $setup '/100' 96 74 -Color $script:theme.SubText
    $script:setupSummary = New-UiLabel $setup '' 150 40 284 24 -Font $script:fonts.CardTitle
    [void](New-UiLabel $setup 'Donanım değiştirmeden düzeltilebilenler. Önemli uyarı −20, uyarı −10 puan.' 150 66 284 40 `
        -Font $script:fonts.Small -Color $script:theme.SubText -Wrap)
    $script:setupAlerts = New-UiAlertView $setup 16 112 420 126

    $game = New-UiCard $page 'Oyuna göre tahmin · yayıncı gereksinimlerine göre' 484 352 452 236
    $script:gameCombo = [Windows.Forms.ComboBox]::new()
    $script:gameCombo.DropDownStyle = 'DropDownList'
    $script:gameCombo.FlatStyle = 'Flat'
    $script:gameCombo.BackColor = $script:theme.Inset
    $script:gameCombo.ForeColor = $script:theme.Text
    $script:gameCombo.Font = $script:fonts.Body
    $script:gameCombo.MaxDropDownItems = 16
    $script:gameCombo.Location = [Drawing.Point]::new(18, 44)
    $script:gameCombo.Size = [Drawing.Size]::new(416, 28)
    $script:gameCombo.Add_SelectedIndexChanged({ Update-GameEstimate })
    $game.Controls.Add($script:gameCombo)
    $script:toolTip.SetToolTip($script:gameCombo, '✓ işaretliler bu bilgisayarda yüklü (Steam, Epic, Riot) veya daha önce oynandı.')
    $script:gameVerdict = New-UiLabel $game '' 18 80 416 24 -Font $script:fonts.CardTitle
    $script:toolTip.SetToolTip($script:gameVerdict, 'Yayıncının 1080p en düşük / önerilen gereksinimlerine göre tahmin; FPS ölçümü değildir.')
    $script:gameNotes = New-UiLabel $game '' 18 106 416 124 -Font $script:fonts.Small -Color $script:theme.SubText -Wrap

    $upgrade = New-UiCard $page 'Yükseltirsen' 484 604 452 92
    $script:scoreWhatIf = New-UiLabel $upgrade '' 18 38 416 50 -Font $script:fonts.Small -Wrap
}

function Update-GameChoices {
    $script:gameChoices = @(Get-GameChoices)
    $script:gameCombo.BeginUpdate()
    $script:gameCombo.Items.Clear()
    foreach ($choice in $script:gameChoices) { [void]$script:gameCombo.Items.Add($choice.Text) }
    $script:gameCombo.EndUpdate()
    if ($script:gameCombo.Items.Count -gt 0) { $script:gameCombo.SelectedIndex = 0 }
}

function Update-GameEstimate {
    $index = $script:gameCombo.SelectedIndex
    if ($index -lt 0 -or -not $script:pcScoreData) { return }
    $estimate = Measure-GameEstimate $script:gameChoices[$index].Game $script:pcScoreData
    $script:gameEstimate = $estimate
    $script:gameVerdict.Text = $estimate.Summary
    $script:gameVerdict.ForeColor = switch ($estimate.Level) { 0 { $script:theme.Red } 1 { $script:theme.Red } 2 { $script:theme.Amber } 3 { $script:theme.Blue } default { $script:theme.Accent } }
    $script:gameNotes.Text = ($estimate.Notes | ForEach-Object { "• $_" }) -join "`r`n"
    $script:toolTip.SetToolTip($script:gameNotes, $script:gameNotes.Text)
}

# Parts are read once (Yenile reads them again); screens and the setup checks are fresh on every visit.
function Update-ScorePage {
    param([switch]$Full)
    if ($Full -or -not $script:pcScoreData) { Invoke-UiBusy { $script:pcScoreData = Get-PcScoreData } }
    else { $script:pcScoreData.Monitors = @([GameBoostDisplay]::GetMonitors()) }
    $score = Measure-PcScore $script:pcScoreData
    $script:pcScore = $score

    Set-ScoreNumber $script:scoreOverall $script:scoreOverallMax $score.Overall
    $script:scoreTier.Text = $score.Tier
    $script:scoreTier.ForeColor = Get-ScoreColor $score.Overall
    $script:scoreExpect.Text = $score.Expectation
    $script:scoreBottleneck.Text = $score.Bottleneck
    foreach ($component in $score.Components) {
        $row = $script:scoreRows[$component.Key]
        if (-not $row) { continue }
        $color = Get-ScoreColor $component.Score
        $row.Model.Text = $component.Model
        $row.Value.Text = if ($null -ne $component.Score) { "$($component.Score)" } else { '—' }
        $row.Value.ForeColor = $color
        $row.Bar.FillColor = $color
        $row.Bar.Value = if ($null -ne $component.Score) { $component.Score } else { 0 }
        $row.Detail.Text = $component.Detail
        $script:toolTip.SetToolTip($row.Model, $component.Model)
        $script:toolTip.SetToolTip($row.Detail, $component.Detail)
    }

    Set-ScoreNumber $script:setupScore $script:setupScoreMax $score.Setup.Score (Get-SetupColor $score.Setup.Score)
    $count = $score.Setup.Items.Count
    $script:setupSummary.Text = if ($count -eq 0) { 'Her şey yerinde' } elseif ($count -eq 1) { 'Puanı düşüren 1 şey var' } else { "Puanı düşüren $count şey var" }
    $script:setupSummary.ForeColor = if ($count -eq 0) { $script:theme.Accent } else { $script:theme.Amber }
    Set-UiAlerts $script:setupAlerts $score.Setup.Items
    $script:scoreWhatIf.Text = ($score.WhatIf -join "`r`n")
    $script:toolTip.SetToolTip($script:scoreOverall, $score.Scale)
    $script:toolTip.SetToolTip($script:scoreWhatIf, $script:scoreWhatIf.Text)
    if ($Full -or $script:gameCombo.Items.Count -eq 0) { Update-GameChoices } else { Update-GameEstimate }
}

function Set-ScoreNumber {
    param($Label, $MaxLabel, [int]$Value, $Color = (Get-ScoreColor $Value))
    $Label.Text = "$Value"
    $Label.ForeColor = $Color
    $MaxLabel.Left = $Label.Left + $Label.PreferredWidth - 4
}

# ---------------------------------------------------------------- Akıllı Bakım

function Build-CarePage {
    $page = New-Page 'care' 'Akıllı Bakım' 'Tüm uyarılar tek yerde; güvenli temizlik ve depolama analizi.' 0xE90F { param($Page) Update-HomeAlerts }
    $alerts = New-UiCard $page 'Akıllı uyarılar' 28 88 440 608
    $script:maintenanceAlerts = New-UiAlertView $alerts 16 48 410 546

    $care = New-UiCard $page 'Bakım' 484 88 452 608
    [void](New-UiLabel $care 'Tarama ve temizlik yalnızca düğmeye basınca çalışır. Silmeden önce ne silineceği gösterilir.' 18 44 416 36 `
        -Color $script:theme.SubText -Font $script:fonts.Small -Wrap)
    $script:maintenanceBox = New-UiTextBox $care 16 88 422 380 @'
GÜVENLİ TEMİZLE neyi siler?
  • 24 saatten eski kullanıcı Temp dosyaları
  • 7 günden eski çökme dökümleri ve hata raporları
  • Bir haftadır boş duran Temp klasörleri

Neye dokunmaz?
  • Shader önbelleği (silinirse oyunlar ilk açılışta takılır)
  • Tarayıcı verileri, kişisel dosyalar
  • RAM (zorla boşaltmak oyunu yavaşlatır)

Depolamayı analiz et: büyük klasörleri ve
500 MB üstü dosyaları listeler; bir şey silmez.
'@ -Mono
    $script:maintenanceBox.BackColor = $script:theme.Card
    $script:auditButton = New-UiButton $care 'Arka plan denetimi (10 sn)' 16 480 420 34 $script:theme.Accent { Start-BackgroundAudit } `
        -Tip 'PC''yi yoran veya arka planda tuhaf çalışan uygulamaları 10 saniye izleyip listeler. Hiçbir şeyi kapatmaz.'
    $script:maintenanceScanButton = New-UiButton $care 'Depolamayı analiz et' 16 522 206 34 -OnClick { Update-MaintenanceRecommendations }
    $script:maintenanceCleanButton = New-UiButton $care 'Güvenli temizle' 230 522 206 34 $script:theme.Accent { Invoke-SafeMaintenanceCleanup }
    [void](New-UiButton $care 'Geri Dönüşüm Kutusu' 16 562 206 32 -OnClick { Clear-UserRecycleBin })
    [void](New-UiButton $care 'Windows Depolama' 230 562 206 32 -OnClick { Start-Process 'ms-settings:storage' })
}

$script:auditAlerts = @()

# The scan runs in its own runspace so the window (and a running BOOST) never waits for it.
function Start-BackgroundAudit {
    if ($script:auditRunning) { return }
    $script:auditRunning = $true
    $script:auditButton.Enabled = $false
    $script:auditButton.Text = 'Denetleniyor (10 sn)...'
    $script:maintenanceBox.Text = "ARKA PLAN DENETİMİ`r`n`r`n10 saniye boyunca işlemci, ekran kartı ve başlangıç kayıtları izleniyor.`r`nHiçbir şey kapatılmaz veya değiştirilmez."
    $ignore = @($script:protectedCloseNames) + @('powershell', 'conhost', 'dwm', 'explorer', 'audiodg')
    $shell = [powershell]::Create()
    [void]$shell.AddScript(${function:Invoke-BackgroundAuditScan}.ToString())
    [void]$shell.AddParameter('IgnoreNames', [string[]]$ignore)
    [void]$shell.AddParameter('Seconds', 10)
    $job = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
    $job | Add-Member -MemberType ScriptProperty -Name Done -Value { $this.Handle.IsCompleted }
    Wait-UiJob $job {
        param($Job)
        $result = $null
        try { $result = @($Job.Shell.EndInvoke($Job.Handle)) | Select-Object -First 1 } catch { }
        $Job.Shell.Dispose()
        $script:auditRunning = $false
        $script:auditButton.Enabled = $true
        $script:auditButton.Text = 'Arka plan denetimi (10 sn)'
        Show-BackgroundAudit $result
    }
}

function Show-BackgroundAudit {
    param($Result)
    if (-not $Result) {
        $script:maintenanceBox.Text = 'Arka plan denetimi tamamlanamadı. Hiçbir şey değiştirilmedi.'
        return
    }
    $order = @{ critical = 0; warning = 1; info = 2 }
    $findings = @($Result.Findings | Sort-Object { $order[$_.Severity] }, Name)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("ARKA PLAN DENETİMİ · $((Get-Date).ToString('dd.MM.yyyy HH:mm')) · $($Result.Seconds) sn")
    $lines.Add("$($Result.Scanned) süreç ve $($Result.StartupChecked) başlangıç kaydı incelendi · $($findings.Count) bulgu")
    $lines.Add('')
    foreach ($finding in $findings) {
        $mark = switch ($finding.Severity) { 'critical' { '[!!]' } 'warning' { '[!]' } default { '[i]' } }
        $lines.Add("$mark $($finding.Name)")
        $lines.Add("     $($finding.Detail)")
        $lines.Add("     $($finding.Path)")
        $lines.Add('')
    }
    # Say plainly what was checked and found clean.
    $clean = [Collections.Generic.List[string]]::new()
    if (-not ($findings | Where-Object Kind -in 'proxy', 'proxy-start')) { $clean.Add('internet paylaşım ajanı') }
    if (-not ($findings | Where-Object Kind -in 'miner', 'miner-start')) { $clean.Add('kripto madenci') }
    if (-not ($findings | Where-Object Kind -eq 'cpu')) { $clean.Add('arka planda işlemci yükü') }
    if ($Result.GpuMeasured -and -not ($findings | Where-Object Kind -eq 'gpu')) { $clean.Add('gizli ekran kartı kullanımı') }
    if (-not ($findings | Where-Object Kind -in 'odd', 'start-odd')) { $clean.Add('tuhaf klasörden çalışan imzasız uygulama') }
    if ($clean.Count -gt 0) { $lines.Add("Bulunmadı: $($clean -join ' · ')") }
    if (-not $Result.GpuMeasured) { $lines.Add('Ekran kartı kullanımı bu sefer ölçülemedi.') }
    $lines.Add('Hiçbir şey kapatılmadı veya değiştirilmedi.')
    $script:maintenanceBox.Text = ($lines -join "`r`n")

    # Important findings go to the smart lists too (Infatica already has its own notice).
    $script:auditAlerts = @($findings | Where-Object { $_.Severity -ne 'info' -and $_.Name -notmatch 'infatica' } |
        ForEach-Object { New-Alert $_.Severity "Arka plan: $($_.Name)" $_.Detail })
    Add-Log "Arka plan denetimi: $($findings.Count) bulgu ($($Result.Scanned) süreç)."
    Update-HomeAlerts
}

# ---------------------------------------------------------------- FPS / HUD

function Build-HudPage {
    $page = New-Page 'hud' 'FPS / HUD' 'Oyun içinde FPS, GPU, CPU ve RAM göstergesi. Oyuna müdahale etmez.' 0xEC4A { param($Page) Update-HudPage }
    $card = New-UiCard $page 'Oyun içi gösterge' 28 88 520 420
    $script:overlayToggle = New-UiToggle $card 'Performans göstergesini etkinleştir' 18 48 480 $script:overlayEnabled `
        'Kapalıyken F10 tuşu diğer uygulamalara serbest kalır ve hiçbir ölçüm çalışmaz.'
    $script:overlayToggle.Add_CheckedChanged({
        $script:overlayEnabled = $script:overlayToggle.Checked
        $script:overlayPrompted = $true
        Set-OverlayHotkeys $script:overlayEnabled
        if (-not $script:overlayEnabled) { Stop-ExternalOverlay }
        Save-CustomSettings -Quiet
        Update-HudPage
    })
    $keys = New-UiKeyValues $card @('F10', 'Ctrl + F10', 'Gösterilenler') 18 98 120 362 28
    Set-UiValue $keys 'F10' 'Göstergeyi 10 saniye aç'
    Set-UiValue $keys 'Ctrl + F10' 'Kalıcı aç / kapat'
    Set-UiValue $keys 'Gösterilenler' 'FPS, kare süresi, GPU %, sıcaklık, VRAM, CPU, RAM'
    $script:hudStatus = New-UiLabel $card '' 18 192 480 64 -Wrap
    [void](New-UiButton $card '10 sn test et' 18 268 150 36 -OnClick { Invoke-OverlayCommand 'Show10' })
    [void](New-UiButton $card 'Kalıcı aç / kapat' 178 268 160 36 -OnClick { Invoke-OverlayCommand 'Toggle' })
    $script:hudCopyButton = New-UiButton $card 'FPS yetki komutunu kopyala' 18 318 320 36 $script:theme.Accent {
        Copy-UiText "Add-LocalGroupMember -SID S-1-5-32-559 -Member $env:USERNAME" 'FPS yetki komutu'
    }
    $script:hudCopyHint = New-UiLabel $card 'Komutu bir kez yönetici PowerShell''de çalıştır, sonra oturumu kapatıp aç.' 18 362 480 36 `
        -Color $script:theme.Muted -Font $script:fonts.Small -Wrap

    $how = New-UiCard $page 'Nasıl çalışır' 564 88 372 420
    $text = New-UiTextBox $how 16 46 340 360 @'
• Gösterge ayrı ve tıklamaları engellemeyen bir penceredir. Oyuna DLL enjekte edilmez; anti-cheat ile sorun çıkarmaz.

• Ölçüm yalnızca gösterge açıkken çalışır. Kapanınca tüm ölçüm süreçleri sonlanır.

• Gösterge, oyunun açık olduğu ekranda belirir.

• GPU değerleri tek bir nvidia-smi süreciyle 2 saniyede bir okunur.

• Tam ekran (exclusive) oyunlarda pencere görünmeyebilir; kenarlıksız tam ekran önerilir.
'@
    $text.BackColor = $script:theme.Card
}

function Update-HudPage {
    $hasPresentMon = Test-Path $script:presentMonPath
    $rights = Test-PresentMonRights
    if (-not $script:overlayEnabled) {
        $script:hudStatus.Text = 'Gösterge kapalı. F10 ve Ctrl+F10 diğer uygulamalara serbest.'
        $script:hudStatus.ForeColor = $script:theme.SubText
    } elseif (-not $hasPresentMon) {
        $script:hudStatus.Text = 'FPS kaynağı (NVIDIA FrameView) bulunamadı; FPS dışındaki değerler gösterilir.'
        $script:hudStatus.ForeColor = $script:theme.Amber
    } elseif (-not $rights) {
        $script:hudStatus.Text = 'FPS için Windows yetkisi yok: GPU, CPU ve RAM görünür, FPS "--" kalır. Aşağıdaki komutu bir kez çalıştır.'
        $script:hudStatus.ForeColor = $script:theme.Amber
    } else {
        $script:hudStatus.Text = 'Hazır: FPS, NVIDIA PresentMon ile ölçülür.'
        $script:hudStatus.ForeColor = $script:theme.Accent
    }
    $needsRights = $hasPresentMon -and -not $rights
    $script:hudCopyButton.Visible = $needsRights
    $script:hudCopyHint.Visible = $needsRights
}
