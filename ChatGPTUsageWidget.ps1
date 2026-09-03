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
  while((Get-Date) -lt $end){$r=$p.StandardOutput.ReadLineAsync();$ms=[Math]::Max(1,[int](($end-(Get-Date)).TotalMilliseconds));if(-not $r.Wait($ms)){throw 'timeout'};$line=$r.Result;if(-not $line){break};$m=$line|ConvertFrom-Json;if($m.id -eq 2 -and $m.result.account.email){$username=([string]$m.result.account.email).Split('@')[0]};if($m.id -eq 3){if($m.error){throw $m.error.message};return @{rateLimits=$m.result.rateLimits;rateLimitsByLimitId=$m.result.rateLimitsByLimitId;resetCredits=$m.result.rateLimitResetCredits;username=$username}}}
  throw 'no data'
 } finally {if($p -and -not $p.HasExited){$p.Kill()};if($p){$p.Dispose()}}
}
function Convert-Window($window) {
 if(-not $window){return $null}
 $reset=if($window.resetsAt){[DateTimeOffset]::FromUnixTimeSeconds([long]$window.resetsAt).LocalDateTime}else{$null}
 @{used=[int]$window.usedPercent;remaining=(100-[int]$window.usedPercent);reset=$reset;minutes=[long]$window.windowDurationMins}
}
function Get-Usage {
 $data=Get-CodexRateLimits;$l=$data.rateLimits;if($data.rateLimitsByLimitId -and $data.rateLimitsByLimitId.codex){$l=$data.rateLimitsByLimitId.codex}
 $primary=Convert-Window $l.primary;if(-not $primary){throw 'no limit'};$secondary=Convert-Window $l.secondary
 $tightest=$primary;if($secondary -and $secondary.remaining -lt $primary.remaining){$tightest=$secondary}
 @{primary=$primary;secondary=$secondary;tightest=$tightest;username=$data.username;plan=$l.planType;resetCredits=if($data.resetCredits){[int]$data.resetCredits.availableCount}else{0}}
}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="175" Height="190" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize">
 <Grid>
  <Border Name="CardBackground" CornerRadius="12" Background="#16191F" Opacity="0.9"/>
  <Grid Name="DetailView" Margin="12,9,12,9">
   <Grid.RowDefinitions><RowDefinition Height="25"/><RowDefinition Height="22"/><RowDefinition Height="9"/><RowDefinition Height="22"/><RowDefinition Height="9"/><RowDefinition Height="38"/><RowDefinition Height="24"/><RowDefinition Height="19"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="Title" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="User" HorizontalAlignment="Right" VerticalAlignment="Center" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></Grid>
   <TextBlock Name="PrimaryLabel" Grid.Row="1" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="11" Foreground="White" VerticalAlignment="Center"/>
   <Border Grid.Row="2" Background="#59606E" CornerRadius="3"><Border Name="PrimaryBar" Background="#32EB87" CornerRadius="3" HorizontalAlignment="Left"/></Border>
   <TextBlock Name="SecondaryLabel" Grid.Row="3" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="11" Foreground="White" VerticalAlignment="Center"/>
   <Border Grid.Row="4" Background="#59606E" CornerRadius="3"><Border Name="SecondaryBar" Background="#32EB87" CornerRadius="3" HorizontalAlignment="Left"/></Border>
   <TextBlock Name="ResetInfo" Grid.Row="5" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#E0E4EA" VerticalAlignment="Center" TextWrapping="Wrap"/>
   <Grid Grid.Row="6"><TextBlock Name="ResetCredits" HorizontalAlignment="Left" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/><Button Name="OpenUsageButton" HorizontalAlignment="Right" Width="42" Height="19" Padding="2,0" FontFamily="Microsoft YaHei UI" FontSize="9" FontWeight="SemiBold" Foreground="White" Background="#2F80ED" BorderThickness="0" Content="Reset" Cursor="Hand" RenderTransformOrigin="0.5,0.5"><Button.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Button.RenderTransform><Button.Triggers><EventTrigger RoutedEvent="Button.Click"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.84" Duration="0:0:0.09" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.84" Duration="0:0:0.09" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="Opacity" To="0.55" Duration="0:0:0.09" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Button.Triggers><Button.Template><ControlTemplate TargetType="Button"><Border Name="ButtonSurface" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="#56A0FF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="#1D64C8"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Button.Template></Button></Grid>
   <TextBlock Name="Updated" Grid.Row="7" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#B8C0CC" VerticalAlignment="Center"/>
  </Grid>
  <Grid Name="RingView" Margin="6" Visibility="Collapsed">
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="102"/><RowDefinition Height="34"/><RowDefinition Height="18"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="RingTitle" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="11" Foreground="White"/><TextBlock Name="RingUser" HorizontalAlignment="Right" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White"/></Grid>
   <Grid Grid.Row="1">
    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Grid Grid.Column="0">
     <Ellipse Width="76" Height="76" Stroke="#59606E" StrokeThickness="6" StrokeDashArray="27.49,9.16" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Ellipse Name="RingPrimaryArc" Width="76" Height="76" Stroke="#32EB87" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Canvas Name="PrimaryGaugeCanvas" Width="76" Height="76" IsHitTestVisible="False"><Line Name="PrimaryNeedle" X1="38" Y1="38" X2="65" Y2="38" Stroke="#22D3EE" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Width="7" Height="7" Fill="#F8FAFC" Canvas.Left="34.5" Canvas.Top="34.5"/></Canvas>
     <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center"><TextBlock Name="RingPrimaryPercent" TextAlignment="Center" FontFamily="Segoe UI" FontWeight="Bold" FontSize="20" Foreground="#32EB87"/><TextBlock Name="RingPrimaryName" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></StackPanel>
    </Grid>
    <Grid Grid.Column="1">
     <Ellipse Width="76" Height="76" Stroke="#59606E" StrokeThickness="6" StrokeDashArray="27.49,9.16" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Ellipse Name="RingSecondaryArc" Width="76" Height="76" Stroke="#32EB87" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Canvas Name="SecondaryGaugeCanvas" Width="76" Height="76" IsHitTestVisible="False"><Line Name="SecondaryNeedle" X1="38" Y1="38" X2="65" Y2="38" Stroke="#32EB87" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Width="7" Height="7" Fill="#F8FAFC" Canvas.Left="34.5" Canvas.Top="34.5"/></Canvas>
     <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center"><TextBlock Name="RingSecondaryPercent" TextAlignment="Center" FontFamily="Segoe UI" FontWeight="Bold" FontSize="20" Foreground="#32EB87"/><TextBlock Name="RingSecondaryName" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></StackPanel>
    </Grid>
   </Grid>
   <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Name="RingPrimaryReset" Grid.Column="0" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White" TextWrapping="Wrap"/><TextBlock Name="RingSecondaryReset" Grid.Column="1" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White" TextWrapping="Wrap"/></Grid>
   <Grid Grid.Row="3"><TextBlock Name="RingUpdated" HorizontalAlignment="Left" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White"/><Button Name="RingResetButton" HorizontalAlignment="Right" Width="40" Height="16" Padding="2,0" FontFamily="Microsoft YaHei UI" FontSize="8" FontWeight="SemiBold" Foreground="White" Background="#2F80ED" BorderThickness="0" Content="Reset" Cursor="Hand" RenderTransformOrigin="0.5,0.5"><Button.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Button.RenderTransform><Button.Triggers><EventTrigger RoutedEvent="Button.Click"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.84" Duration="0:0:0.09" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.84" Duration="0:0:0.09" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="Opacity" To="0.55" Duration="0:0:0.09" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Button.Triggers><Button.Template><ControlTemplate TargetType="Button"><Border Name="ButtonSurface" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="#56A0FF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="#1D64C8"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Button.Template></Button></Grid>
  </Grid>
  <Grid Name="EdgeView" Margin="2,10" Visibility="Collapsed">
   <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="2"/><ColumnDefinition/></Grid.ColumnDefinitions>
   <Grid Grid.Column="0"><Border Background="#59606E" CornerRadius="3"><Border Name="EdgePrimaryFill" Background="#22D3EE" CornerRadius="3" VerticalAlignment="Bottom"/></Border><Canvas IsHitTestVisible="False"><Border Name="EdgePrimaryBubble" Width="12" Height="12" Canvas.Left="0" Background="Transparent" BorderThickness="0"><TextBlock Name="EdgePrimaryPercent" FontFamily="Microsoft YaHei UI" FontSize="6.5" FontWeight="Bold" Foreground="White" TextAlignment="Center" VerticalAlignment="Center"/></Border></Canvas></Grid>
   <Grid Grid.Column="2"><Border Background="#59606E" CornerRadius="3"><Border Name="EdgeSecondaryFill" Background="#32EB87" CornerRadius="3" VerticalAlignment="Bottom"/></Border><Canvas IsHitTestVisible="False"><Border Name="EdgeSecondaryBubble" Width="12" Height="12" Canvas.Left="0" Background="Transparent" BorderThickness="0"><TextBlock Name="EdgeSecondaryPercent" FontFamily="Microsoft YaHei UI" FontSize="6.5" FontWeight="Bold" Foreground="White" TextAlignment="Center" VerticalAlignment="Center"/></Border></Canvas></Grid>
  </Grid>
 </Grid>
</Window>
'@
$reader=New-Object Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$bg=$window.FindName('CardBackground');$detailView=$window.FindName('DetailView');$ringView=$window.FindName('RingView');$edgeView=$window.FindName('EdgeView');$edgePrimaryFill=$window.FindName('EdgePrimaryFill');$edgeSecondaryFill=$window.FindName('EdgeSecondaryFill');$edgePrimaryBubble=$window.FindName('EdgePrimaryBubble');$edgeSecondaryBubble=$window.FindName('EdgeSecondaryBubble');$edgePrimaryPercent=$window.FindName('EdgePrimaryPercent');$edgeSecondaryPercent=$window.FindName('EdgeSecondaryPercent');$title=$window.FindName('Title');$user=$window.FindName('User');$primaryLabel=$window.FindName('PrimaryLabel');$primaryBar=$window.FindName('PrimaryBar');$secondaryLabel=$window.FindName('SecondaryLabel');$secondaryBar=$window.FindName('SecondaryBar');$resetInfo=$window.FindName('ResetInfo');$resetCredits=$window.FindName('ResetCredits');$openUsageButton=$window.FindName('OpenUsageButton');$updated=$window.FindName('Updated');$ringTitle=$window.FindName('RingTitle');$ringUser=$window.FindName('RingUser');$ringPrimaryArc=$window.FindName('RingPrimaryArc');$primaryGaugeCanvas=$window.FindName('PrimaryGaugeCanvas');$primaryNeedle=$window.FindName('PrimaryNeedle');$ringPrimaryPercent=$window.FindName('RingPrimaryPercent');$ringPrimaryName=$window.FindName('RingPrimaryName');$ringPrimaryReset=$window.FindName('RingPrimaryReset');$ringSecondaryArc=$window.FindName('RingSecondaryArc');$secondaryGaugeCanvas=$window.FindName('SecondaryGaugeCanvas');$secondaryNeedle=$window.FindName('SecondaryNeedle');$ringSecondaryPercent=$window.FindName('RingSecondaryPercent');$ringSecondaryName=$window.FindName('RingSecondaryName');$ringSecondaryReset=$window.FindName('RingSecondaryReset');$ringUpdated=$window.FindName('RingUpdated');$ringResetButton=$window.FindName('RingResetButton')
$title.Text='ChatGPT '+(T '5Ymp5L2Z')
$ringTitle.Text='ChatGPT '+(T '5Ymp5L2Z')
$openUsageButton.Content=T '6YeN572u'
$ringResetButton.Content=T '6YeN572u'
$area=[Windows.SystemParameters]::WorkArea;$window.Left=$area.Right-$window.Width-24;$window.Top=$area.Bottom-$window.Height-24

function Add-GaugeTicks($canvas) {
 for($i=0;$i -le 10;$i++){$angle=(-135+($i*27))*[Math]::PI/180;$line=New-Object Windows.Shapes.Line;$line.X1=38+[Math]::Cos($angle)*30;$line.Y1=38+[Math]::Sin($angle)*30;$line.X2=38+[Math]::Cos($angle)*35;$line.Y2=38+[Math]::Sin($angle)*35;$line.Stroke=[Windows.Media.Brushes]::White;$line.Opacity=0.75;$line.StrokeThickness=if($i%5 -eq 0){2}else{1};[void]$canvas.Children.Insert(0,$line)}
}
function Set-GaugeNeedle($needle,[int]$remaining,[string]$color) {$needle.Stroke=$color;$transform=New-Object Windows.Media.RotateTransform;$transform.Angle=-135+($remaining*2.7);$transform.CenterX=38;$transform.CenterY=38;$needle.RenderTransform=$transform}
function Set-GaugeProgress($arc,$needle,[int]$remaining,[string]$color) {
 $remaining=[Math]::Max(0,[Math]::Min(100,$remaining));$circle=36.65;$span=27.49;$dash=[Math]::Max(0.01,$span*$remaining/100);$gap=[Math]::Max(0.01,$circle-$dash)
 $arc.Stroke=$color;$arc.StrokeDashArray=(New-Object Windows.Media.DoubleCollectionConverter).ConvertFromString(('{0:F3},{1:F3}' -f $dash,$gap));Set-GaugeNeedle $needle $remaining $color
}
function Update-EdgeBar($fill,$bubble,$label,$remaining,[string]$color) {
 $trackHeight=170.0
 if($null -eq $remaining){$fill.Height=0;$label.Text='-';$top=158.0}else{$value=[Math]::Max(0,[Math]::Min(100,[int]$remaining));$fill.Height=$trackHeight*$value/100;$fill.Background=$color;$label.Text="$value";$top=$trackHeight-$fill.Height+1}
 $top=[Math]::Max(1,[Math]::Min(158,$top));[Windows.Controls.Canvas]::SetTop($bubble,[double]$top)
}
Add-GaugeTicks $primaryGaugeCanvas;Add-GaugeTicks $secondaryGaugeCanvas

function Apply-Background([string]$path){
 if($path -and (Test-Path -LiteralPath $path)){$img=New-Object Windows.Media.Imaging.BitmapImage;$img.BeginInit();$img.CacheOption='OnLoad';$img.UriSource=New-Object Uri $path;$img.EndInit();$brush=New-Object Windows.Media.ImageBrush $img;$brush.Stretch='UniformToFill';$bg.Background=$brush}
 else{$bg.Background=New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(22,25,31))}
}
function Apply-Opacity([int]$value){$bg.Opacity=$value/100.0;Save-Setting 'backgroundOpacity' $value}
function Apply-FontColor([string]$value){
 try{$brush=(New-Object Windows.Media.BrushConverter).ConvertFromString($value)}catch{$brush=[Windows.Media.Brushes]::White}
 $title.Foreground=$brush;$user.Foreground=$brush;$resetInfo.Foreground=$brush;$resetCredits.Foreground=$brush;$updated.Foreground=$brush;$ringTitle.Foreground=$brush;$ringUser.Foreground=$brush;$ringPrimaryName.Foreground=$brush;$ringPrimaryReset.Foreground=$brush;$ringSecondaryName.Foreground=$brush;$ringSecondaryReset.Foreground=$brush;$ringUpdated.Foreground=$brush
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
 $script:isEdgeHidden=$true;$script:temporaryExpanded=$false;$script:edgeSide=$side;$window.Width=30
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
$primaryLabel.Text=(T '55+t5ZGo5pyf')+': -';$primaryBar.Width=0;$secondaryLabel.Text=(T '6ZW/5ZGo5pyf')+': -';$secondaryBar.Width=0;$resetInfo.Text=(T '6YeN572u')+': -';$resetCredits.Text='-';$updated.Text=(T '5pu05paw5pe26Ze0')+': -';Update-EdgeBar $edgePrimaryFill $edgePrimaryBubble $edgePrimaryPercent $null '#22D3EE';Update-EdgeBar $edgeSecondaryFill $edgeSecondaryBubble $edgeSecondaryPercent $null '#32EB87'
$user.Text=(T '55So5oi3')+': -';$ringUser.Text=(T '55So5oi3')+': -';$ringPrimaryPercent.Text='-';$ringPrimaryName.Text=(T '55+t5ZGo5pyf');$ringPrimaryReset.Text=(T '6YeN572u')+': -';$ringSecondaryPercent.Text='-';$ringSecondaryName.Text=(T '6ZW/5ZGo5pyf');$ringSecondaryReset.Text=(T '6YeN572u')+': -';$ringUpdated.Text=(T '5pu05paw5pe26Ze0')+': -'

function Update-Widget {
 try{$u=Get-Usage;$remain=$u.tightest.remaining
  $primaryColor=if($u.primary.remaining -le 5){'#FF3737'}elseif($u.primary.remaining -le 20){'#FFD22D'}else{'#22D3EE'}
  $primaryName=if($u.primary.minutes -lt 1440){$n=[int]($u.primary.minutes/60);$n.ToString()+(T '5bCP5pe2')}else{$n=[int]($u.primary.minutes/1440);$n.ToString()+(T '5aSp')}
  $primaryLabel.Text="$primaryName  "+(T '5Ymp5L2Z')+": $($u.primary.remaining)%";$primaryLabel.Foreground=$primaryColor;$primaryBar.Width=151*$u.primary.remaining/100;$primaryBar.Background=$primaryColor
  if($u.secondary){$secondaryColor=if($u.secondary.remaining -le 5){'#FF3737'}elseif($u.secondary.remaining -le 20){'#FFD22D'}else{'#32EB87'};$secondaryName=if($u.secondary.minutes -lt 1440){$n=[int]($u.secondary.minutes/60);$n.ToString()+(T '5bCP5pe2')}else{$n=[int]($u.secondary.minutes/1440);$n.ToString()+(T '5aSp')};$secondaryLabel.Text="$secondaryName  "+(T '5Ymp5L2Z')+": $($u.secondary.remaining)%";$secondaryLabel.Foreground=$secondaryColor;$secondaryBar.Width=151*$u.secondary.remaining/100;$secondaryBar.Background=$secondaryColor}else{$secondaryName=(T '6ZW/5ZGo5pyf');$secondaryLabel.Text=$secondaryName+': -';$secondaryBar.Width=0}
  $reset1=if($u.primary.reset){$u.primary.reset.ToString('MM-dd HH:mm')}else{'-'};$reset2=if($u.secondary -and $u.secondary.reset){$u.secondary.reset.ToString('MM-dd HH:mm')}else{'-'}
  $resetInfo.Text="$primaryName "+(T '6YeN572u')+": $reset1`n$secondaryName "+(T '6YeN572u')+": $reset2"
  $resetCredits.Text="$($u.resetCredits) "+(T '5qyh6YeN572u5py65Lya')
  $updated.Text=(T '5pu05paw5pe26Ze0')+': '+(Get-Date).ToString('HH:mm:ss')
  $user.Text=(T '55So5oi3')+': '+$u.username;$ringUser.Text=(T '55So5oi3')+': '+$u.username
  $ringPrimaryPercent.Text="$($u.primary.remaining)%";$ringPrimaryPercent.Foreground=$primaryColor;$ringPrimaryName.Text=$primaryName;$ringPrimaryReset.Text=(T '6YeN572u')+"`n"+$reset1;Set-GaugeProgress $ringPrimaryArc $primaryNeedle $u.primary.remaining $primaryColor
  if($u.secondary){$ringSecondaryPercent.Text="$($u.secondary.remaining)%";$ringSecondaryPercent.Foreground=$secondaryColor;$ringSecondaryName.Text=$secondaryName;$ringSecondaryReset.Text=(T '6YeN572u')+"`n"+$reset2;Set-GaugeProgress $ringSecondaryArc $secondaryNeedle $u.secondary.remaining $secondaryColor}else{$ringSecondaryPercent.Text='-';$ringSecondaryName.Text=(T '6ZW/5ZGo5pyf');$ringSecondaryReset.Text=(T '6YeN572u')+': -'}
  $color=if($remain -le 5){'#FF3737'}elseif($remain -le 20){'#FFD22D'}else{'#32EB87'}
  Update-EdgeBar $edgePrimaryFill $edgePrimaryBubble $edgePrimaryPercent $u.primary.remaining $primaryColor
  if($u.secondary){Update-EdgeBar $edgeSecondaryFill $edgeSecondaryBubble $edgeSecondaryPercent $u.secondary.remaining $secondaryColor}else{Update-EdgeBar $edgeSecondaryFill $edgeSecondaryBubble $edgeSecondaryPercent $null '#32EB87'}
  $ringUpdated.Text=(T '5pu05paw5pe26Ze0')+': '+(Get-Date).ToString('HH:mm:ss')
  $script:hasUsageData=$true;if($timer){$timer.Interval=[TimeSpan]::FromMinutes(1)}
 }catch{
  $errorPath=Join-Path $appDir 'widget-error.log'
  ("{0:yyyy-MM-dd HH:mm:ss} | {1}`r`n{2}" -f (Get-Date),$_.Exception.Message,$_.ScriptStackTrace)|Set-Content -LiteralPath $errorPath -Encoding UTF8
  if(-not $script:hasUsageData -and $timer){$timer.Interval=[TimeSpan]::FromSeconds(10)}
 }
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
$script:navigationTimers=New-Object Collections.ArrayList
function Open-UsagePageAfterFeedback {
 $navigationTimer=New-Object Windows.Threading.DispatcherTimer;$navigationTimer.Interval=[TimeSpan]::FromMilliseconds(220);[void]$script:navigationTimers.Add($navigationTimer)
 $navigationTimer.Add_Tick({$this.Stop();[void]$script:navigationTimers.Remove($this);Start-Process 'https://chatgpt.com/codex/settings/usage'});$navigationTimer.Start()
}
$openUsageButton.Add_Click({Open-UsagePageAfterFeedback})
$ringResetButton.Add_Click({Open-UsagePageAfterFeedback})
$edgeReturnTimer=New-Object Windows.Threading.DispatcherTimer;$edgeReturnTimer.Interval=[TimeSpan]::FromSeconds(5);$edgeReturnTimer.Add_Tick({$edgeReturnTimer.Stop();if(-not $script:isEdgeHidden){Collapse-ToEdge $script:edgeSide}})
$window.ContextMenu=$menu;$window.Add_MouseLeftButtonDown({
 $wasTemporary=$script:temporaryExpanded;if($wasTemporary){$edgeReturnTimer.Stop()}
 $start=[Windows.Forms.Cursor]::Position;try{$window.DragMove()}catch{};$finish=[Windows.Forms.Cursor]::Position
 $moved=([Math]::Abs($finish.X-$start.X) -gt 3 -or [Math]::Abs($finish.Y-$start.Y) -gt 3)
 if($moved){$script:temporaryExpanded=$false;if($script:isEdgeHidden){Expand-FromEdge $false}else{[void](Test-SnapToEdge)}}elseif($script:isEdgeHidden){Expand-FromEdge $true}else{if($wasTemporary){$edgeReturnTimer.Start()};Toggle-DisplayStyle}
})
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(10);$timer.Add_Tick({Update-Widget});Update-Widget;$timer.Start();[void]$window.ShowDialog()
