param([switch]$Install,[switch]$Uninstall)
$ErrorActionPreference='Stop'
$appName='ChatGPT Usage Widget'
$appDir=Join-Path $env:LOCALAPPDATA 'ChatGPTUsageWidget'
$configPath=Join-Path $appDir 'config.json'
$startupPath=Join-Path ([Environment]::GetFolderPath('Startup')) 'ChatGPT Usage Widget.lnk'
function T([string]$v){[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v))}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Install-App {
 New-Item -ItemType Directory -Force $appDir|Out-Null
 Copy-Item $PSCommandPath (Join-Path $appDir 'ChatGPTUsageWidget.ps1') -Force
 if(-not(Test-Path $configPath)){Copy-Item (Join-Path $PSScriptRoot 'config.example.json') $configPath}
 $s=(New-Object -ComObject WScript.Shell).CreateShortcut($startupPath)
 Copy-Item (Join-Path $PSScriptRoot 'LaunchWidget.ps1') (Join-Path $appDir 'LaunchWidget.ps1') -Force
 $s.TargetPath='powershell.exe';$s.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $appDir 'LaunchWidget.ps1')+'"';$s.WorkingDirectory=$appDir;$s.Save()
}
function Uninstall-App {Remove-Item $startupPath -Force -ErrorAction SilentlyContinue}
if($Install){Install-App;exit};if($Uninstall){Uninstall-App;exit}
New-Item -ItemType Directory -Force $appDir|Out-Null
if(-not(Test-Path $configPath)){Copy-Item (Join-Path $PSScriptRoot 'config.example.json') $configPath}
function Read-Config {Get-Content $configPath -Raw -Encoding UTF8|ConvertFrom-Json}
function Save-Setting($name,$value){$c=Read-Config;$c|Add-Member -NotePropertyName $name -NotePropertyValue $value -Force;$c|ConvertTo-Json|Set-Content $configPath -Encoding UTF8}

function Get-CodexRateLimits {
 $psi=New-Object Diagnostics.ProcessStartInfo
 $psi.FileName='cmd.exe';$psi.Arguments='/d /s /c "codex app-server"';$psi.UseShellExecute=$false
 $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
 $p=New-Object Diagnostics.Process;$p.StartInfo=$psi
 try {
  [void]$p.Start();$p.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"usage-widget","version":"1.0"}}}');$p.StandardInput.Flush()
  $r=$p.StandardOutput.ReadLineAsync();if(-not $r.Wait(10000)){throw 'timeout'};$m=$r.Result|ConvertFrom-Json;if($m.id -ne 1 -or $m.error){throw 'init'}
  $p.StandardInput.WriteLine('{"method":"initialized"}');$p.StandardInput.WriteLine('{"id":2,"method":"account/read","params":{"refreshToken":false}}');$p.StandardInput.WriteLine('{"id":3,"method":"account/rateLimits/read","params":null}');$p.StandardInput.Flush()
  $end=(Get-Date).AddSeconds(10)
  $username='-'
  while((Get-Date) -lt $end){$r=$p.StandardOutput.ReadLineAsync();$ms=[Math]::Max(1,[int](($end-(Get-Date)).TotalMilliseconds));if(-not $r.Wait($ms)){throw 'timeout'};$line=$r.Result;if(-not $line){break};$m=$line|ConvertFrom-Json;if($m.id -eq 2 -and $m.result.account.email){$username=([string]$m.result.account.email).Split('@')[0]};if($m.id -eq 3){if($m.error){throw $m.error.message};return @{rateLimits=$m.result.rateLimits;username=$username}}}
  throw 'no data'
 } finally {if($p -and -not $p.HasExited){$p.Kill()};if($p){$p.Dispose()}}
}
function Get-Usage {
 $data=Get-CodexRateLimits;$l=$data.rateLimits;$w=$l.primary;if(-not $w){throw 'no limit'}
 $reset=if($w.resetsAt){[DateTimeOffset]::FromUnixTimeSeconds([long]$w.resetsAt).LocalDateTime}else{$null}
 @{used=[int]$w.usedPercent;expires=$reset;username=$data.username}
}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="175" Height="170" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize">
 <Grid>
  <Border Name="CardBackground" CornerRadius="12" Background="#16191F" Opacity="0.9"/>
  <Grid Name="DetailView" Margin="12,9,12,9">
   <Grid.RowDefinitions><RowDefinition Height="25"/><RowDefinition Height="48"/><RowDefinition Height="10"/><RowDefinition Height="24"/><RowDefinition Height="22"/><RowDefinition Height="20"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="Title" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="User" HorizontalAlignment="Right" VerticalAlignment="Center" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></Grid>
   <TextBlock Name="Percent" Grid.Row="1" FontFamily="Segoe UI" FontWeight="Bold" FontSize="32" HorizontalAlignment="Center" VerticalAlignment="Center"/>
   <Border Grid.Row="2" Background="#59606E" CornerRadius="3"><Border Name="Bar" Background="#32EB87" CornerRadius="3" HorizontalAlignment="Left"/></Border>
   <TextBlock Name="Usage" Grid.Row="3" FontFamily="Microsoft YaHei UI" FontSize="11" Foreground="White" VerticalAlignment="Center"/>
   <TextBlock Name="Expiry" Grid.Row="4" FontFamily="Microsoft YaHei UI" FontSize="10" Foreground="#E0E4EA" VerticalAlignment="Center"/>
   <TextBlock Name="Updated" Grid.Row="5" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#B8C0CC" VerticalAlignment="Center"/>
  </Grid>
  <Grid Name="RingView" Margin="5" Visibility="Collapsed">
   <Ellipse Width="148" Height="148" Stroke="#59606E" StrokeThickness="8"/>
   <Ellipse Name="RingArc" Width="148" Height="148" Stroke="#32EB87" StrokeThickness="8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform></Ellipse>
   <StackPanel Width="120" HorizontalAlignment="Center" VerticalAlignment="Center">
    <TextBlock Name="RingTitle" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="11" Foreground="White"/>
    <TextBlock Name="RingUser" TextAlignment="Center" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White"/>
    <TextBlock Name="RingPercent" TextAlignment="Center" FontFamily="Segoe UI" FontWeight="Bold" FontSize="25" Foreground="#32EB87"/>
    <TextBlock Name="RingUsage" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/>
    <TextBlock Name="RingExpiry" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White"/>
    <TextBlock Name="RingUpdated" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White"/>
   </StackPanel>
  </Grid>
  <Grid Name="EdgeView" Margin="2,10" Visibility="Collapsed">
   <Border Background="#59606E" CornerRadius="4">
    <Border Name="EdgeFill" Background="#32EB87" CornerRadius="4" VerticalAlignment="Bottom"/>
   </Border>
  </Grid>
 </Grid>
</Window>
'@
$reader=New-Object Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$bg=$window.FindName('CardBackground');$detailView=$window.FindName('DetailView');$ringView=$window.FindName('RingView');$edgeView=$window.FindName('EdgeView');$edgeFill=$window.FindName('EdgeFill');$title=$window.FindName('Title');$user=$window.FindName('User');$percent=$window.FindName('Percent');$bar=$window.FindName('Bar');$usage=$window.FindName('Usage');$expiry=$window.FindName('Expiry');$updated=$window.FindName('Updated');$ringArc=$window.FindName('RingArc');$ringTitle=$window.FindName('RingTitle');$ringUser=$window.FindName('RingUser');$ringPercent=$window.FindName('RingPercent');$ringUsage=$window.FindName('RingUsage');$ringExpiry=$window.FindName('RingExpiry');$ringUpdated=$window.FindName('RingUpdated')
$title.Text='ChatGPT '+(T '5Ymp5L2Z')
$ringTitle.Text='ChatGPT '+(T '5Ymp5L2Z')
$area=[Windows.SystemParameters]::WorkArea;$window.Left=$area.Right-$window.Width-24;$window.Top=$area.Bottom-$window.Height-24

function Apply-Background([string]$path){
 if($path -and (Test-Path -LiteralPath $path)){$img=New-Object Windows.Media.Imaging.BitmapImage;$img.BeginInit();$img.CacheOption='OnLoad';$img.UriSource=New-Object Uri $path;$img.EndInit();$brush=New-Object Windows.Media.ImageBrush $img;$brush.Stretch='UniformToFill';$bg.Background=$brush}
 else{$bg.Background=New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(22,25,31))}
}
function Apply-Opacity([int]$value){$bg.Opacity=$value/100.0;Save-Setting 'backgroundOpacity' $value}
function Apply-FontColor([string]$value){
 try{$brush=(New-Object Windows.Media.BrushConverter).ConvertFromString($value)}catch{$brush=[Windows.Media.Brushes]::White}
 $title.Foreground=$brush;$user.Foreground=$brush;$usage.Foreground=$brush;$expiry.Foreground=$brush;$updated.Foreground=$brush;$ringTitle.Foreground=$brush;$ringUser.Foreground=$brush;$ringUsage.Foreground=$brush;$ringExpiry.Foreground=$brush;$ringUpdated.Foreground=$brush
}
$cfg=Read-Config;$opacity=if($null -ne $cfg.backgroundOpacity){[int]$cfg.backgroundOpacity}else{90};$bg.Opacity=$opacity/100.0;Apply-Background ([string]$cfg.backgroundImage)
$alwaysOnTop=if($null -ne $cfg.alwaysOnTop){[bool]$cfg.alwaysOnTop}else{$true};$window.Topmost=$alwaysOnTop
$fontColor=if($cfg.fontColor){[string]$cfg.fontColor}else{'#FFFFFF'};Apply-FontColor $fontColor
$script:displayStyle=if($cfg.displayStyle){[string]$cfg.displayStyle}else{'detail'}
$script:isEdgeHidden=$false;$script:temporaryExpanded=$false;$script:edgeSide='right';$script:expandedWidth=175
function Apply-DisplayStyle {
 if($script:isEdgeHidden){$detailView.Visibility='Collapsed';$ringView.Visibility='Collapsed';$edgeView.Visibility='Visible'}elseif($script:displayStyle -eq 'ring'){$detailView.Visibility='Collapsed';$ringView.Visibility='Visible';$edgeView.Visibility='Collapsed'}else{$detailView.Visibility='Visible';$ringView.Visibility='Collapsed';$edgeView.Visibility='Collapsed'}
}
function Toggle-DisplayStyle {$script:displayStyle=if($script:displayStyle -eq 'ring'){'detail'}else{'ring'};Apply-DisplayStyle;Save-Setting 'displayStyle' $script:displayStyle}
function Collapse-ToEdge([string]$side){
 $script:isEdgeHidden=$true;$script:temporaryExpanded=$false;$script:edgeSide=$side;$window.Width=14
 $work=[Windows.SystemParameters]::WorkArea;if($side -eq 'left'){$window.Left=$work.Left}else{$window.Left=$work.Right-$window.Width}
 Apply-DisplayStyle
}
function Expand-FromEdge([bool]$temporary=$false) {
 $work=[Windows.SystemParameters]::WorkArea;$script:isEdgeHidden=$false;$script:temporaryExpanded=$temporary;$window.Width=$script:expandedWidth
 if($script:edgeSide -eq 'left'){$window.Left=$work.Left}else{$window.Left=$work.Right-$window.Width}
 Apply-DisplayStyle
 if($edgeReturnTimer){$edgeReturnTimer.Stop();if($temporary){$edgeReturnTimer.Start()}}
}
function Test-SnapToEdge {
 $work=[Windows.SystemParameters]::WorkArea
 if($window.Left -le ($work.Left+12)){Collapse-ToEdge 'left';return $true}
 if(($window.Left+$window.Width) -ge ($work.Right-12)){Collapse-ToEdge 'right';return $true}
 return $false
}
Apply-DisplayStyle
$script:hasUsageData=$false
$percent.Text='-';$bar.Width=0;$usage.Text=(T '5Ymp5L2Z')+': -';$expiry.Text=(T '5Yiw5pyfL+mHjee9rg==')+': -';$updated.Text=(T '5pu05paw5pe26Ze0')+': -'
$user.Text=(T '55So5oi3')+': -';$ringUser.Text=(T '55So5oi3')+': -';$ringPercent.Text='-';$ringUsage.Text=(T '5Ymp5L2Z')+': -';$ringExpiry.Text=(T '5Yiw5pyfL+mHjee9rg==')+': -';$ringUpdated.Text=(T '5pu05paw5pe26Ze0')+': -'

function Update-Widget {
 try{$u=Get-Usage;$remain=100-$u.used;$percent.Text="$remain%";$bar.Width=151*$remain/100
  $color=if($remain -le 5){'#FF3737'}elseif($remain -le 20){'#FFD22D'}else{'#32EB87'};$percent.Foreground=$color;$bar.Background=$color
  $usage.Text=(T '5Ymp5L2Z')+": $remain%    "+(T '5bey55So')+": $($u.used)%";$expiry.Text=(T '5Yiw5pyfL+mHjee9rg==')+': '+$u.expires.ToString('yyyy-MM-dd');$updated.Text=(T '5pu05paw5pe26Ze0')+': '+(Get-Date).ToString('HH:mm:ss')
  $user.Text=(T '55So5oi3')+': '+$u.username;$ringUser.Text=(T '55So5oi3')+': '+$u.username
  $ringPercent.Text="$remain%";$ringPercent.Foreground=$color;$ringArc.Stroke=$color;$dash=51.05*$remain/100;$gap=[Math]::Max(0.01,51.05-$dash);$ringArc.StrokeDashArray=(New-Object Windows.Media.DoubleCollectionConverter).ConvertFromString(('{0:F2},{1:F2}' -f $dash,$gap))
  $edgeFill.Height=150*$remain/100;$edgeFill.Background=$color
  $ringUsage.Text=(T '5Ymp5L2Z')+": $remain%  "+(T '5bey55So')+": $($u.used)%";$ringExpiry.Text=(T '5Yiw5pyfL+mHjee9rg==')+': '+$u.expires.ToString('yyyy-MM-dd');$ringUpdated.Text=(T '5pu05paw5pe26Ze0')+': '+(Get-Date).ToString('HH:mm:ss')
  $script:hasUsageData=$true;if($timer){$timer.Interval=[TimeSpan]::FromMinutes(1)}
 }catch{if(-not $script:hasUsageData -and $timer){$timer.Interval=[TimeSpan]::FromSeconds(10)}}
}

$menu=New-Object Windows.Controls.ContextMenu
function Item($text){$i=New-Object Windows.Controls.MenuItem;$i.Header=$text;[void]$menu.Items.Add($i);$i}
$refresh=Item (T '56uL5Y2z5Yi35paw');$image=Item (T '5L+u5pS56IOM5pmv5Zu+54mH');$clear=Item (T '5riF6Zmk6IOM5pmv5Zu+54mH');$fontColorItem=Item (T '5a2X5L2T6aKc6Imy')
$opacityMenu=Item (T '6IOM5pmv6YCP5piO5bqm');foreach($v in @(30,50,70,80,90,100)){$i=New-Object Windows.Controls.MenuItem;$i.Header="$v%";$i.Tag=$v;$i.IsCheckable=$true;$i.IsChecked=($v -eq $opacity);$i.Add_Click({$selected=[int]$this.Tag;Apply-Opacity $selected;foreach($child in $opacityMenu.Items){$child.IsChecked=([int]$child.Tag -eq $selected)}});[void]$opacityMenu.Items.Add($i)}
$top=Item (T '572u6aG25pi+56S6');$top.IsCheckable=$true;$top.IsChecked=$alwaysOnTop;$exit=Item (T '6YCA5Ye6')
$refresh.Add_Click({Update-Widget});$top.Add_Click({$window.Topmost=$top.IsChecked;Save-Setting 'alwaysOnTop' ([bool]$top.IsChecked)});$exit.Add_Click({$window.Close()})
$image.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif';if($d.ShowDialog()-eq'OK'){Save-Setting 'backgroundImage' $d.FileName;Apply-Background $d.FileName};$d.Dispose()})
$clear.Add_Click({Save-Setting 'backgroundImage' '';Apply-Background ''})
$fontColorItem.Add_Click({$d=New-Object Windows.Forms.ColorDialog;$d.FullOpen=$true;if($d.ShowDialog()-eq'OK'){$hex='#{0:X2}{1:X2}{2:X2}' -f $d.Color.R,$d.Color.G,$d.Color.B;Save-Setting 'fontColor' $hex;Apply-FontColor $hex};$d.Dispose()})
$edgeReturnTimer=New-Object Windows.Threading.DispatcherTimer;$edgeReturnTimer.Interval=[TimeSpan]::FromSeconds(5);$edgeReturnTimer.Add_Tick({$edgeReturnTimer.Stop();if(-not $script:isEdgeHidden){Collapse-ToEdge $script:edgeSide}})
$window.ContextMenu=$menu;$window.Add_MouseLeftButtonDown({
 $wasTemporary=$script:temporaryExpanded;if($wasTemporary){$edgeReturnTimer.Stop()}
 $start=[Windows.Forms.Cursor]::Position;try{$window.DragMove()}catch{};$finish=[Windows.Forms.Cursor]::Position
 $moved=([Math]::Abs($finish.X-$start.X) -gt 3 -or [Math]::Abs($finish.Y-$start.Y) -gt 3)
 if($moved){$script:temporaryExpanded=$false;if($script:isEdgeHidden){Expand-FromEdge $false}else{[void](Test-SnapToEdge)}}elseif($script:isEdgeHidden){Expand-FromEdge $true}else{if($wasTemporary){$edgeReturnTimer.Start()};Toggle-DisplayStyle}
})
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(10);$timer.Add_Tick({Update-Widget});Update-Widget;$timer.Start();[void]$window.ShowDialog()
