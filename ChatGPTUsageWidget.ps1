param([switch]$Install,[switch]$Uninstall,[switch]$SelfTest)
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
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WidgetWindowStyle {
    [DllImport("user32.dll", EntryPoint="GetWindowLong")]
    public static extern int GetWindowLong(IntPtr handle, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLong")]
    public static extern int SetWindowLong(IntPtr handle, int index, int value);
}
'@

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
function Get-CodexDisplayName([string]$fallback) {
 try {
  $authPath=Join-Path $env:USERPROFILE '.codex\auth.json';if(-not(Test-Path -LiteralPath $authPath)){return $fallback}
  $auth=Get-Content -Raw -LiteralPath $authPath -Encoding UTF8|ConvertFrom-Json;$token=[string]$auth.tokens.id_token;if(-not $token){return $fallback}
  $part=$token.Split('.')[1].Replace('-','+').Replace('_','/');while(($part.Length%4)-ne 0){$part+='='}
  $payload=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part))|ConvertFrom-Json;$name=[string]$payload.name;if(-not[String]::IsNullOrWhiteSpace($name)){return $name.Trim()}
 }catch{}
 return $fallback
}

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
  while((Get-Date) -lt $end){$r=$p.StandardOutput.ReadLineAsync();$ms=[Math]::Max(1,[int](($end-(Get-Date)).TotalMilliseconds));if(-not $r.Wait($ms)){throw 'timeout'};$line=$r.Result;if(-not $line){break};$m=$line|ConvertFrom-Json;if($m.id -eq 2 -and $m.result.account.email){$username=([string]$m.result.account.email).Split('@')[0]};if($m.id -eq 3){if($m.error){throw $m.error.message};return @{rateLimits=$m.result.rateLimits;rateLimitsByLimitId=$m.result.rateLimitsByLimitId;resetCredits=$m.result.rateLimitResetCredits;displayName=(Get-CodexDisplayName $username)}}}
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
 @{primary=$primary;secondary=$secondary;tightest=$tightest;displayName=$data.displayName;plan=$l.planType;resetCredits=if($data.resetCredits){[int]$data.resetCredits.availableCount}else{0}}
}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="175" Height="190" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize">
 <Window.Resources>
  <SolidColorBrush x:Key="MenuSurfaceBrush" Color="#F2262931"/><SolidColorBrush x:Key="MenuTextBrush" Color="#F5F5F7"/><SolidColorBrush x:Key="MenuBorderBrush" Color="#28FFFFFF"/><SolidColorBrush x:Key="MenuHoverBrush" Color="#26FFFFFF"/>
  <Style x:Key="AltResetButton" TargetType="Button">
   <Setter Property="Width" Value="38"/><Setter Property="Height" Value="19"/><Setter Property="Padding" Value="2,0"/><Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="FontSize" Value="9"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#0A84FF"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
   <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1" ScaleY="1"/></Setter.Value></Setter>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Name="ButtonSurface" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="#240A84FF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="#3A0A84FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
   <Style.Triggers><EventTrigger RoutedEvent="Button.Click"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.84" Duration="0:0:0.09" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.84" Duration="0:0:0.09" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="Opacity" To="0.55" Duration="0:0:0.09" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Style.Triggers>
  </Style>
  <Style x:Key="RoundedContextMenu" TargetType="ContextMenu">
   <Setter Property="Background" Value="{DynamicResource MenuSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource MenuTextBrush}"/><Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="FontSize" Value="11"/><Setter Property="Padding" Value="6"/><Setter Property="HasDropShadow" Value="True"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContextMenu"><Border Background="{TemplateBinding Background}" BorderBrush="{DynamicResource MenuBorderBrush}" BorderThickness="1" CornerRadius="12" Padding="{TemplateBinding Padding}"><StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/></Border></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="RoundedMenuItem" TargetType="MenuItem">
   <Setter Property="Foreground" Value="{DynamicResource MenuTextBrush}"/><Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="FontSize" Value="11"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="MinWidth" Value="150"/><Setter Property="Margin" Value="0,1"/><Setter Property="Padding" Value="9,7"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem"><Grid><Border Name="ItemSurface" Background="Transparent" CornerRadius="8" Padding="{TemplateBinding Padding}"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/></Grid.ColumnDefinitions><TextBlock Name="CheckMark" Text="&#x2713;" Visibility="Hidden" VerticalAlignment="Center" Foreground="#0A84FF" FontWeight="Bold"/><ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center"/><Path Name="SubmenuArrow" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Fill="{DynamicResource MenuTextBrush}" Opacity="0.65" Data="M 0 0 L 4 4 L 0 8 Z"/></Grid></Border><Popup Name="PART_Popup" AllowsTransparency="True" Focusable="False" Placement="Right" HorizontalOffset="3" IsOpen="{Binding IsSubmenuOpen,RelativeSource={RelativeSource TemplatedParent}}" PopupAnimation="Fade"><Border Background="{DynamicResource MenuSurfaceBrush}" BorderBrush="{DynamicResource MenuBorderBrush}" BorderThickness="1" CornerRadius="12" Padding="6"><StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/></Border></Popup></Grid><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="{DynamicResource MenuHoverBrush}"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="ItemSurface" Property="Opacity" Value="0.72"/></Trigger><Trigger Property="IsChecked" Value="True"><Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="HasItems" Value="False"><Setter TargetName="SubmenuArrow" Property="Visibility" Value="Collapsed"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Grid>
  <Border Name="CardBackground" CornerRadius="14" Background="#161A22" BorderThickness="0" Opacity="0.9"/>
  <Grid Name="DetailView" Margin="12,9,12,9">
   <Grid.RowDefinitions><RowDefinition Height="25"/><RowDefinition Height="22"/><RowDefinition Height="9"/><RowDefinition Height="22"/><RowDefinition Height="9"/><RowDefinition Height="38"/><RowDefinition Height="24"/><RowDefinition Height="19"/></Grid.RowDefinitions>
   <Border Name="PrimaryPanel" Grid.Row="1" Grid.RowSpan="2" Margin="-4,0" CornerRadius="9" Visibility="Collapsed"/>
   <Border Name="SecondaryPanel" Grid.Row="3" Grid.RowSpan="2" Margin="-4,0" CornerRadius="9" Visibility="Collapsed"/>
   <Grid Grid.Row="0"><TextBlock Name="Title" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="User" HorizontalAlignment="Right" VerticalAlignment="Center" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></Grid>
   <Grid Grid.Row="1"><TextBlock Name="PrimaryLabel" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White" VerticalAlignment="Center"/><TextBlock Name="PrimaryValue" HorizontalAlignment="Right" FontFamily="Segoe UI" FontWeight="Bold" FontSize="16" Foreground="#22D3EE" VerticalAlignment="Center"/></Grid>
   <Border Name="PrimaryTrack" Grid.Row="2" Background="#59606E" CornerRadius="3"><Border Name="PrimaryBar" Background="#32EB87" CornerRadius="3" HorizontalAlignment="Left"/></Border>
   <Grid Grid.Row="3"><TextBlock Name="SecondaryLabel" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White" VerticalAlignment="Center"/><TextBlock Name="SecondaryValue" HorizontalAlignment="Right" FontFamily="Segoe UI" FontWeight="Bold" FontSize="16" Foreground="#32EB87" VerticalAlignment="Center"/></Grid>
   <Border Name="SecondaryTrack" Grid.Row="4" Background="#59606E" CornerRadius="3"><Border Name="SecondaryBar" Background="#32EB87" CornerRadius="3" HorizontalAlignment="Left"/></Border>
   <TextBlock Name="ResetInfo" Grid.Row="5" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#E0E4EA" VerticalAlignment="Center" TextWrapping="Wrap"/>
   <Grid Grid.Row="6"><TextBlock Name="ResetCredits" HorizontalAlignment="Left" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/><Button Name="OpenUsageButton" HorizontalAlignment="Right" Style="{StaticResource AltResetButton}"/></Grid>
   <TextBlock Name="Updated" Grid.Row="7" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#B8C0CC" VerticalAlignment="Center"/>
  </Grid>
  <Grid Name="HarmonyDetailView" Margin="12,9,12,9" Visibility="Collapsed">
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="72"/><RowDefinition Height="32"/><RowDefinition Height="16"/><RowDefinition Height="24"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="HarmonyTitle" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="HarmonyUser" HorizontalAlignment="Right" VerticalAlignment="Center" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></Grid>
   <Border Grid.Row="1" CornerRadius="14" Padding="9,6">
    <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#3D6DF2" Offset="0"/><GradientStop Color="#7757E8" Offset="1"/></LinearGradientBrush></Border.Background>
    <Grid><Grid.RowDefinitions><RowDefinition Height="17"/><RowDefinition Height="34"/><RowDefinition Height="9"/></Grid.RowDefinitions><Grid Grid.Row="0"><TextBlock Name="HarmonyPrimaryName" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/><TextBlock Name="HarmonyPrimaryReset" HorizontalAlignment="Right" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#E8FFFFFF"/></Grid><TextBlock Name="HarmonyPrimaryPercent" Grid.Row="1" FontFamily="Segoe UI" FontWeight="Bold" FontSize="24" Foreground="#22D3EE"/><Border Grid.Row="2" Background="#45FFFFFF" CornerRadius="4"><Border Name="HarmonyPrimaryBar" Background="#22D3EE" CornerRadius="4" HorizontalAlignment="Left"/></Border></Grid>
   </Border>
   <Grid Grid.Row="2" Margin="3,1,3,0"><Grid.RowDefinitions><RowDefinition Height="13"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Name="HarmonySecondaryName" Grid.Row="0" HorizontalAlignment="Left" VerticalAlignment="Top" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#C9CDD5"/><TextBlock Name="HarmonySecondaryPercent" Grid.Row="1" HorizontalAlignment="Left" VerticalAlignment="Center" FontFamily="Segoe UI" FontWeight="Bold" FontSize="17" Foreground="#A99BFF"/><TextBlock Name="HarmonySecondaryReset" Grid.Row="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/></Grid>
   <TextBlock Name="HarmonyResetCredits" Grid.Row="3" Margin="3,0" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/>
   <Grid Grid.Row="4" Margin="3,0"><TextBlock Name="HarmonyUpdated" HorizontalAlignment="Left" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/><Button Name="HarmonyResetButton" HorizontalAlignment="Right" Style="{StaticResource AltResetButton}"/></Grid>
  </Grid>
  <Grid Name="AppleControlView" Margin="12,9,12,9" Visibility="Collapsed">
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="102"/><RowDefinition Height="20"/><RowDefinition Height="22"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="AppleControlTitle" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="AppleControlUser" HorizontalAlignment="Right" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#A7AAB1"/></Grid>
   <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="7"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Border Name="AppleControlPrimarySurface" Grid.Column="0" CornerRadius="14" Background="#18FFFFFF" Padding="9"><Grid><Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="27"/><RowDefinition/></Grid.RowDefinitions><Ellipse Width="25" Height="25" HorizontalAlignment="Left" Fill="#4CCADD"/><TextBlock Name="AppleControlPrimaryPercent" Grid.Row="1" FontFamily="Segoe UI" FontWeight="Bold" FontSize="18" Foreground="#64D7E8"/><TextBlock Name="AppleControlPrimaryInfo" Grid.Row="2" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#AEB1B8" TextWrapping="Wrap"/></Grid></Border>
    <Border Name="AppleControlSecondarySurface" Grid.Column="2" CornerRadius="14" Background="#18FFFFFF" Padding="9"><Grid><Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="27"/><RowDefinition/></Grid.RowDefinitions><Ellipse Width="25" Height="25" HorizontalAlignment="Left" Fill="#42C96F"/><TextBlock Name="AppleControlSecondaryPercent" Grid.Row="1" FontFamily="Segoe UI" FontWeight="Bold" FontSize="18" Foreground="#52D77E"/><TextBlock Name="AppleControlSecondaryInfo" Grid.Row="2" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#AEB1B8" TextWrapping="Wrap"/></Grid></Border>
   </Grid>
   <TextBlock Name="AppleControlCredits" Grid.Row="2" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/>
   <Grid Grid.Row="3"><TextBlock Name="AppleControlUpdated" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/><Button Name="AppleControlResetButton" HorizontalAlignment="Right" Style="{StaticResource AltResetButton}"/></Grid>
  </Grid>
  <Grid Name="AppleLiveView" Margin="9" Visibility="Collapsed">
   <TextBlock Name="AppleLiveTitle" Visibility="Collapsed"/><TextBlock Name="AppleLiveUser" Visibility="Collapsed"/>
   <Border Name="AppleLiveSurface" Height="94" CornerRadius="25" Background="#050505" Padding="12,10" VerticalAlignment="Center"><Grid><Grid.RowDefinitions><RowDefinition Height="18"/><RowDefinition/></Grid.RowDefinitions><Grid Grid.Row="0"><TextBlock Name="AppleLiveMeta" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#AAADB4" TextTrimming="CharacterEllipsis"/><TextBlock Name="AppleLiveTime" HorizontalAlignment="Right" FontFamily="Segoe UI" FontSize="8" Foreground="#AAADB4"/></Grid><Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel Grid.Column="0"><TextBlock Name="AppleLivePrimaryPercent" FontFamily="Segoe UI" FontWeight="Bold" FontSize="19" Foreground="#64D7E8"/><TextBlock Name="AppleLivePrimaryInfo" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#9DA0A7" TextWrapping="Wrap"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Name="AppleLiveSecondaryPercent" FontFamily="Segoe UI" FontWeight="Bold" FontSize="19" Foreground="#52D77E"/><TextBlock Name="AppleLiveSecondaryInfo" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#9DA0A7" TextWrapping="Wrap"/></StackPanel></Grid></Grid></Border>
   <TextBlock Name="AppleLiveCredits" Visibility="Collapsed"/><TextBlock Name="AppleLiveUpdated" Visibility="Collapsed"/><Button Name="AppleLiveResetButton" Visibility="Collapsed" Style="{StaticResource AltResetButton}"/>
  </Grid>
  <Grid Name="HarmonyGridView" Margin="12,9,12,9" Visibility="Collapsed">
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="102"/><RowDefinition Height="20"/><RowDefinition Height="22"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="HarmonyGridTitle" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="HarmonyGridUser" HorizontalAlignment="Right" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#A7AAB1"/></Grid>
   <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="7"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Border Name="HarmonyGridPrimarySurface" Grid.Column="0" CornerRadius="17" Background="#18FFFFFF" Padding="9"><Grid><Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition Height="28"/><RowDefinition/></Grid.RowDefinitions><Border Width="28" Height="28" HorizontalAlignment="Left" CornerRadius="10"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#45C7F2"/><GradientStop Color="#3973ED" Offset="1"/></LinearGradientBrush></Border.Background><TextBlock Name="HarmonyGridPrimaryIcon" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe UI" FontSize="8" Foreground="White"/></Border><TextBlock Name="HarmonyGridPrimaryPercent" Grid.Row="1" FontFamily="Segoe UI" FontWeight="Bold" FontSize="18" Foreground="#22D3EE"/><TextBlock Name="HarmonyGridPrimaryInfo" Grid.Row="2" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#AEB1B8" TextWrapping="Wrap"/></Grid></Border>
    <Border Name="HarmonyGridSecondarySurface" Grid.Column="2" CornerRadius="17" Background="#18FFFFFF" Padding="9"><Grid><Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition Height="28"/><RowDefinition/></Grid.RowDefinitions><Border Width="28" Height="28" HorizontalAlignment="Left" CornerRadius="10"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#9A72F1"/><GradientStop Color="#6055DC" Offset="1"/></LinearGradientBrush></Border.Background><TextBlock Name="HarmonyGridSecondaryIcon" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe UI" FontSize="8" Foreground="White"/></Border><TextBlock Name="HarmonyGridSecondaryPercent" Grid.Row="1" FontFamily="Segoe UI" FontWeight="Bold" FontSize="18" Foreground="#32EB87"/><TextBlock Name="HarmonyGridSecondaryInfo" Grid.Row="2" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#AEB1B8" TextWrapping="Wrap"/></Grid></Border>
   </Grid>
   <TextBlock Name="HarmonyGridCredits" Grid.Row="2" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/>
   <Grid Grid.Row="3"><TextBlock Name="HarmonyGridUpdated" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/><Button Name="HarmonyGridResetButton" HorizontalAlignment="Right" Style="{StaticResource AltResetButton}"/></Grid>
  </Grid>
  <Grid Name="HarmonyCapsuleView" Margin="12,9,12,9" Visibility="Collapsed">
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="112"/><RowDefinition Height="10"/><RowDefinition Height="22"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="HarmonyCapsuleTitle" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="HarmonyCapsuleUser" HorizontalAlignment="Right" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#A7AAB1"/></Grid>
   <Grid Grid.Row="1"><Grid.RowDefinitions><RowDefinition/><RowDefinition Height="8"/><RowDefinition/></Grid.RowDefinitions>
    <Border Name="HarmonyCapsulePrimarySurface" Grid.Row="0" CornerRadius="18" Background="#18FFFFFF" Padding="8,5"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/><ColumnDefinition Width="39"/></Grid.ColumnDefinitions><Grid Width="28" Height="28"><Ellipse Name="HarmonyCapsulePrimaryPieTrack" Fill="#474A53"/><Path Name="HarmonyCapsulePrimarySlice" Fill="#3F83F8"/><TextBlock Name="HarmonyCapsulePrimaryIcon" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe UI" FontSize="8" FontWeight="SemiBold" Foreground="White"/></Grid><StackPanel Grid.Column="1" VerticalAlignment="Center"><TextBlock Name="HarmonyCapsulePrimaryName" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/><TextBlock Name="HarmonyCapsulePrimaryReset" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/></StackPanel><TextBlock Name="HarmonyCapsulePrimaryPercent" Grid.Column="2" VerticalAlignment="Center" TextAlignment="Right" FontFamily="Segoe UI" FontWeight="Bold" FontSize="16" Foreground="#22D3EE"/></Grid></Border>
    <Border Name="HarmonyCapsuleSecondarySurface" Grid.Row="2" CornerRadius="18" Background="#18FFFFFF" Padding="8,5"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/><ColumnDefinition Width="39"/></Grid.ColumnDefinitions><Grid Width="28" Height="28"><Ellipse Name="HarmonyCapsuleSecondaryPieTrack" Fill="#474A53"/><Path Name="HarmonyCapsuleSecondarySlice" Fill="#8C6BE8"/><TextBlock Name="HarmonyCapsuleSecondaryIcon" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe UI" FontSize="8" FontWeight="SemiBold" Foreground="White"/></Grid><StackPanel Grid.Column="1" VerticalAlignment="Center"><TextBlock Name="HarmonyCapsuleSecondaryName" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/><TextBlock Name="HarmonyCapsuleSecondaryReset" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/></StackPanel><TextBlock Name="HarmonyCapsuleSecondaryPercent" Grid.Column="2" VerticalAlignment="Center" TextAlignment="Right" FontFamily="Segoe UI" FontWeight="Bold" FontSize="16" Foreground="#32EB87"/></Grid></Border>
   </Grid>
   <TextBlock Name="HarmonyCapsuleCredits" Visibility="Collapsed"/><Border Name="HarmonyCapsuleDivider" Grid.Row="2" Height="1" VerticalAlignment="Center" Background="#454852"/>
   <Grid Grid.Row="3"><TextBlock Name="HarmonyCapsuleUpdated" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/><Button Name="HarmonyCapsuleResetButton" HorizontalAlignment="Right" Style="{StaticResource AltResetButton}"/></Grid>
  </Grid>
  <Grid Name="HarmonyArcView" Margin="12,9,12,9" Visibility="Collapsed">
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="100"/><RowDefinition Height="14"/><RowDefinition Height="1"/><RowDefinition Height="29"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="HarmonyArcTitle" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="12" Foreground="White"/><TextBlock Name="HarmonyArcUser" HorizontalAlignment="Right" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#A7AAB1"/></Grid>
   <Canvas Grid.Row="1" Width="151" Height="88"><Path Name="HarmonyArcTrack" Data="M 20,76 A 55,55 0 0 1 131,76" Stroke="#454852" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Path Name="HarmonyArcProgress" Stroke="#4D7EF1" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Flat"/><TextBlock Name="HarmonyArcPercent" Width="151" Canvas.Top="48" TextAlignment="Center" FontFamily="Segoe UI" FontWeight="Bold" FontSize="22" Foreground="#22D3EE"/></Canvas>
   <Grid Grid.Row="2"><TextBlock Name="HarmonyArcPrimaryInfo" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/><TextBlock Name="HarmonyArcSecondaryInfo" HorizontalAlignment="Right" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/></Grid>
   <TextBlock Name="HarmonyArcCredits" Visibility="Collapsed"/><Border Name="HarmonyArcDivider" Grid.Row="3" Height="1" Background="#454852"/>
   <Grid Grid.Row="4"><TextBlock Name="HarmonyArcUpdated" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="#A7AAB1"/><Button Name="HarmonyArcResetButton" HorizontalAlignment="Right" VerticalAlignment="Bottom" Style="{StaticResource AltResetButton}"/></Grid>
  </Grid>
  <Grid Name="RingView" Margin="6" Visibility="Collapsed">
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="102"/><RowDefinition Height="34"/><RowDefinition Height="18"/></Grid.RowDefinitions>
   <Grid Grid.Row="0"><TextBlock Name="RingTitle" HorizontalAlignment="Left" FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="11" Foreground="White"/><TextBlock Name="RingUser" HorizontalAlignment="Right" MaxWidth="75" TextTrimming="CharacterEllipsis" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White"/></Grid>
   <Grid Grid.Row="1">
    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Grid Grid.Column="0">
     <Ellipse Name="RingPrimaryTrack" Width="76" Height="76" Stroke="#59606E" StrokeThickness="6" StrokeDashArray="27.49,9.16" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Ellipse Name="RingPrimaryArc" Width="76" Height="76" Stroke="#32EB87" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Canvas Name="PrimaryGaugeCanvas" Width="76" Height="76" IsHitTestVisible="False"><Line Name="PrimaryNeedle" X1="38" Y1="38" X2="65" Y2="38" Stroke="#22D3EE" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Width="5" Height="5" Fill="#F8FAFC" Canvas.Left="35.5" Canvas.Top="35.5"/></Canvas>
     <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center"><TextBlock Name="RingPrimaryPercent" TextAlignment="Center" FontFamily="Segoe UI" FontWeight="Bold" FontSize="20" Foreground="#32EB87"/><TextBlock Name="RingPrimaryName" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></StackPanel>
    </Grid>
    <Grid Grid.Column="1">
     <Ellipse Name="RingSecondaryTrack" Width="76" Height="76" Stroke="#59606E" StrokeThickness="6" StrokeDashArray="27.49,9.16" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Ellipse Name="RingSecondaryArc" Width="76" Height="76" Stroke="#32EB87" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-135"/></Ellipse.RenderTransform></Ellipse>
     <Canvas Name="SecondaryGaugeCanvas" Width="76" Height="76" IsHitTestVisible="False"><Line Name="SecondaryNeedle" X1="38" Y1="38" X2="65" Y2="38" Stroke="#32EB87" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Width="5" Height="5" Fill="#F8FAFC" Canvas.Left="35.5" Canvas.Top="35.5"/></Canvas>
     <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center"><TextBlock Name="RingSecondaryPercent" TextAlignment="Center" FontFamily="Segoe UI" FontWeight="Bold" FontSize="20" Foreground="#32EB87"/><TextBlock Name="RingSecondaryName" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="White"/></StackPanel>
    </Grid>
   </Grid>
   <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Name="RingPrimaryReset" Grid.Column="0" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White" TextWrapping="Wrap"/><TextBlock Name="RingSecondaryReset" Grid.Column="1" TextAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White" TextWrapping="Wrap"/></Grid>
   <Grid Grid.Row="3"><TextBlock Name="RingUpdated" HorizontalAlignment="Left" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI" FontSize="8" Foreground="White"/><Button Name="RingResetButton" HorizontalAlignment="Right" VerticalAlignment="Center" Style="{StaticResource AltResetButton}"/></Grid>
  </Grid>
  <Grid Name="EdgeView" Margin="2,10" Visibility="Collapsed">
   <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="2"/><ColumnDefinition/></Grid.ColumnDefinitions>
   <Grid Grid.Column="0"><Border Name="EdgePrimaryTrack" Background="#59606E" CornerRadius="3"><Border Name="EdgePrimaryFill" Background="#22D3EE" CornerRadius="3" VerticalAlignment="Bottom"/></Border><Canvas IsHitTestVisible="False"><Border Name="EdgePrimaryBubble" Width="12" Height="12" Canvas.Left="0" Background="#73000000" BorderThickness="0" CornerRadius="2"><TextBlock Name="EdgePrimaryPercent" FontFamily="Segoe UI" FontSize="6.5" FontWeight="Bold" Foreground="White" TextAlignment="Center" VerticalAlignment="Center"/></Border></Canvas></Grid>
   <Grid Grid.Column="2"><Border Name="EdgeSecondaryTrack" Background="#59606E" CornerRadius="3"><Border Name="EdgeSecondaryFill" Background="#32EB87" CornerRadius="3" VerticalAlignment="Bottom"/></Border><Canvas IsHitTestVisible="False"><Border Name="EdgeSecondaryBubble" Width="12" Height="12" Canvas.Left="0" Background="#73000000" BorderThickness="0" CornerRadius="2"><TextBlock Name="EdgeSecondaryPercent" FontFamily="Segoe UI" FontSize="6.5" FontWeight="Bold" Foreground="White" TextAlignment="Center" VerticalAlignment="Center"/></Border></Canvas></Grid>
  </Grid>
 </Grid>
</Window>
'@
$reader=New-Object Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$window.Add_SourceInitialized({
 $handle=(New-Object Windows.Interop.WindowInteropHelper($window)).Handle;$index=-20;$toolWindow=0x00000080;$appWindow=0x00040000
 $style=[WidgetWindowStyle]::GetWindowLong($handle,$index);$style=($style-bor$toolWindow)-band(-bnot$appWindow);[void][WidgetWindowStyle]::SetWindowLong($handle,$index,$style)
})
$bg=$window.FindName('CardBackground');$detailView=$window.FindName('DetailView');$ringView=$window.FindName('RingView');$edgeView=$window.FindName('EdgeView');$edgePrimaryFill=$window.FindName('EdgePrimaryFill');$edgeSecondaryFill=$window.FindName('EdgeSecondaryFill');$edgePrimaryBubble=$window.FindName('EdgePrimaryBubble');$edgeSecondaryBubble=$window.FindName('EdgeSecondaryBubble');$edgePrimaryPercent=$window.FindName('EdgePrimaryPercent');$edgeSecondaryPercent=$window.FindName('EdgeSecondaryPercent');$title=$window.FindName('Title');$user=$window.FindName('User');$primaryLabel=$window.FindName('PrimaryLabel');$primaryValue=$window.FindName('PrimaryValue');$primaryBar=$window.FindName('PrimaryBar');$secondaryLabel=$window.FindName('SecondaryLabel');$secondaryValue=$window.FindName('SecondaryValue');$secondaryBar=$window.FindName('SecondaryBar');$resetInfo=$window.FindName('ResetInfo');$resetCredits=$window.FindName('ResetCredits');$openUsageButton=$window.FindName('OpenUsageButton');$updated=$window.FindName('Updated');$ringTitle=$window.FindName('RingTitle');$ringUser=$window.FindName('RingUser');$ringPrimaryArc=$window.FindName('RingPrimaryArc');$primaryGaugeCanvas=$window.FindName('PrimaryGaugeCanvas');$primaryNeedle=$window.FindName('PrimaryNeedle');$ringPrimaryPercent=$window.FindName('RingPrimaryPercent');$ringPrimaryName=$window.FindName('RingPrimaryName');$ringPrimaryReset=$window.FindName('RingPrimaryReset');$ringSecondaryArc=$window.FindName('RingSecondaryArc');$secondaryGaugeCanvas=$window.FindName('SecondaryGaugeCanvas');$secondaryNeedle=$window.FindName('SecondaryNeedle');$ringSecondaryPercent=$window.FindName('RingSecondaryPercent');$ringSecondaryName=$window.FindName('RingSecondaryName');$ringSecondaryReset=$window.FindName('RingSecondaryReset');$ringUpdated=$window.FindName('RingUpdated');$ringResetButton=$window.FindName('RingResetButton')
$primaryPanel=$window.FindName('PrimaryPanel');$secondaryPanel=$window.FindName('SecondaryPanel');$primaryTrack=$window.FindName('PrimaryTrack');$secondaryTrack=$window.FindName('SecondaryTrack');$ringPrimaryTrack=$window.FindName('RingPrimaryTrack');$ringSecondaryTrack=$window.FindName('RingSecondaryTrack');$edgePrimaryTrack=$window.FindName('EdgePrimaryTrack');$edgeSecondaryTrack=$window.FindName('EdgeSecondaryTrack')
$harmonyDetailView=$window.FindName('HarmonyDetailView');$harmonyTitle=$window.FindName('HarmonyTitle');$harmonyUser=$window.FindName('HarmonyUser');$harmonyPrimaryName=$window.FindName('HarmonyPrimaryName');$harmonyPrimaryReset=$window.FindName('HarmonyPrimaryReset');$harmonyPrimaryPercent=$window.FindName('HarmonyPrimaryPercent');$harmonyPrimaryBar=$window.FindName('HarmonyPrimaryBar');$harmonySecondaryName=$window.FindName('HarmonySecondaryName');$harmonySecondaryPercent=$window.FindName('HarmonySecondaryPercent');$harmonySecondaryReset=$window.FindName('HarmonySecondaryReset');$harmonyResetCredits=$window.FindName('HarmonyResetCredits');$harmonyUpdated=$window.FindName('HarmonyUpdated');$harmonyResetButton=$window.FindName('HarmonyResetButton')
$appleControlView=$window.FindName('AppleControlView');$appleControlTitle=$window.FindName('AppleControlTitle');$appleControlUser=$window.FindName('AppleControlUser');$appleControlPrimarySurface=$window.FindName('AppleControlPrimarySurface');$appleControlPrimaryPercent=$window.FindName('AppleControlPrimaryPercent');$appleControlPrimaryInfo=$window.FindName('AppleControlPrimaryInfo');$appleControlSecondarySurface=$window.FindName('AppleControlSecondarySurface');$appleControlSecondaryPercent=$window.FindName('AppleControlSecondaryPercent');$appleControlSecondaryInfo=$window.FindName('AppleControlSecondaryInfo');$appleControlCredits=$window.FindName('AppleControlCredits');$appleControlUpdated=$window.FindName('AppleControlUpdated');$appleControlResetButton=$window.FindName('AppleControlResetButton')
$appleLiveView=$window.FindName('AppleLiveView');$appleLiveTitle=$window.FindName('AppleLiveTitle');$appleLiveUser=$window.FindName('AppleLiveUser');$appleLiveMeta=$window.FindName('AppleLiveMeta');$appleLiveTime=$window.FindName('AppleLiveTime');$appleLivePrimaryPercent=$window.FindName('AppleLivePrimaryPercent');$appleLivePrimaryInfo=$window.FindName('AppleLivePrimaryInfo');$appleLiveSecondaryPercent=$window.FindName('AppleLiveSecondaryPercent');$appleLiveSecondaryInfo=$window.FindName('AppleLiveSecondaryInfo');$appleLiveCredits=$window.FindName('AppleLiveCredits');$appleLiveUpdated=$window.FindName('AppleLiveUpdated');$appleLiveResetButton=$window.FindName('AppleLiveResetButton')
$harmonyGridView=$window.FindName('HarmonyGridView');$harmonyGridTitle=$window.FindName('HarmonyGridTitle');$harmonyGridUser=$window.FindName('HarmonyGridUser');$harmonyGridPrimarySurface=$window.FindName('HarmonyGridPrimarySurface');$harmonyGridPrimaryIcon=$window.FindName('HarmonyGridPrimaryIcon');$harmonyGridPrimaryPercent=$window.FindName('HarmonyGridPrimaryPercent');$harmonyGridPrimaryInfo=$window.FindName('HarmonyGridPrimaryInfo');$harmonyGridSecondarySurface=$window.FindName('HarmonyGridSecondarySurface');$harmonyGridSecondaryIcon=$window.FindName('HarmonyGridSecondaryIcon');$harmonyGridSecondaryPercent=$window.FindName('HarmonyGridSecondaryPercent');$harmonyGridSecondaryInfo=$window.FindName('HarmonyGridSecondaryInfo');$harmonyGridCredits=$window.FindName('HarmonyGridCredits');$harmonyGridUpdated=$window.FindName('HarmonyGridUpdated');$harmonyGridResetButton=$window.FindName('HarmonyGridResetButton')
$harmonyCapsuleView=$window.FindName('HarmonyCapsuleView');$harmonyCapsuleTitle=$window.FindName('HarmonyCapsuleTitle');$harmonyCapsuleUser=$window.FindName('HarmonyCapsuleUser');$harmonyCapsulePrimarySurface=$window.FindName('HarmonyCapsulePrimarySurface');$harmonyCapsulePrimaryPieTrack=$window.FindName('HarmonyCapsulePrimaryPieTrack');$harmonyCapsulePrimarySlice=$window.FindName('HarmonyCapsulePrimarySlice');$harmonyCapsulePrimaryIcon=$window.FindName('HarmonyCapsulePrimaryIcon');$harmonyCapsulePrimaryName=$window.FindName('HarmonyCapsulePrimaryName');$harmonyCapsulePrimaryReset=$window.FindName('HarmonyCapsulePrimaryReset');$harmonyCapsulePrimaryPercent=$window.FindName('HarmonyCapsulePrimaryPercent');$harmonyCapsuleSecondarySurface=$window.FindName('HarmonyCapsuleSecondarySurface');$harmonyCapsuleSecondaryPieTrack=$window.FindName('HarmonyCapsuleSecondaryPieTrack');$harmonyCapsuleSecondarySlice=$window.FindName('HarmonyCapsuleSecondarySlice');$harmonyCapsuleSecondaryIcon=$window.FindName('HarmonyCapsuleSecondaryIcon');$harmonyCapsuleSecondaryName=$window.FindName('HarmonyCapsuleSecondaryName');$harmonyCapsuleSecondaryReset=$window.FindName('HarmonyCapsuleSecondaryReset');$harmonyCapsuleSecondaryPercent=$window.FindName('HarmonyCapsuleSecondaryPercent');$harmonyCapsuleCredits=$window.FindName('HarmonyCapsuleCredits');$harmonyCapsuleDivider=$window.FindName('HarmonyCapsuleDivider');$harmonyCapsuleUpdated=$window.FindName('HarmonyCapsuleUpdated');$harmonyCapsuleResetButton=$window.FindName('HarmonyCapsuleResetButton')
$harmonyArcView=$window.FindName('HarmonyArcView');$harmonyArcTitle=$window.FindName('HarmonyArcTitle');$harmonyArcUser=$window.FindName('HarmonyArcUser');$harmonyArcTrack=$window.FindName('HarmonyArcTrack');$harmonyArcProgress=$window.FindName('HarmonyArcProgress');$harmonyArcPercent=$window.FindName('HarmonyArcPercent');$harmonyArcPrimaryInfo=$window.FindName('HarmonyArcPrimaryInfo');$harmonyArcSecondaryInfo=$window.FindName('HarmonyArcSecondaryInfo');$harmonyArcCredits=$window.FindName('HarmonyArcCredits');$harmonyArcDivider=$window.FindName('HarmonyArcDivider');$harmonyArcUpdated=$window.FindName('HarmonyArcUpdated');$harmonyArcResetButton=$window.FindName('HarmonyArcResetButton')
$title.Text='ChatGPT '+(T '5Ymp5L2Z')
$ringTitle.Text='ChatGPT '+(T '5Ymp5L2Z')
$harmonyTitle.Text='ChatGPT '+(T '55So6YeP')
$appleControlTitle.Text=T '5Ymp5L2Z6aKd5bqm';$appleLiveTitle.Text=T '5a6e5pe25rS75Yqo';$harmonyGridTitle.Text=T '6aKd5bqm5Lit5b+D';$harmonyCapsuleTitle.Text='ChatGPT '+(T '5Ymp5L2Z');$harmonyArcTitle.Text=T '6aKd5bqm5oC76KeI'
$openUsageButton.Content=T '6YeN572u'
$ringResetButton.Content=T '6YeN572u'
$harmonyResetButton.Content=T '6YeN572u'
foreach($resetButton in @($appleControlResetButton,$appleLiveResetButton,$harmonyGridResetButton,$harmonyCapsuleResetButton,$harmonyArcResetButton)){$resetButton.Content=T '6YeN572u'}
$area=[Windows.SystemParameters]::WorkArea;$window.Left=$area.Right-$window.Width-24;$window.Top=$area.Bottom-$window.Height-24

function Add-GaugeTicks($canvas) {
 for($i=0;$i -le 10;$i++){$angle=(-135+($i*27))*[Math]::PI/180;$line=New-Object Windows.Shapes.Line;$line.Tag='GaugeTick';$line.X1=38+[Math]::Cos($angle)*30;$line.Y1=38+[Math]::Sin($angle)*30;$line.X2=38+[Math]::Cos($angle)*35;$line.Y2=38+[Math]::Sin($angle)*35;$line.Stroke=[Windows.Media.Brushes]::White;$line.Opacity=0.45;$line.StrokeThickness=if($i%5 -eq 0){1.5}else{1};[void]$canvas.Children.Insert(0,$line)}
}
function Set-GaugeNeedle($needle,[int]$remaining,[string]$color) {$needle.Stroke=$color;$transform=New-Object Windows.Media.RotateTransform;$transform.Angle=-135+($remaining*2.7);$transform.CenterX=38;$transform.CenterY=38;$needle.RenderTransform=$transform}
function Set-GaugeProgress($arc,$needle,[int]$remaining,[string]$color) {
 $remaining=[Math]::Max(0,[Math]::Min(100,$remaining));$circle=36.65;$span=27.49;$dash=[Math]::Max(0.01,$span*$remaining/100);$gap=[Math]::Max(0.01,$circle-$dash)
 $arc.Stroke=$color;$arc.StrokeDashArray=(New-Object Windows.Media.DoubleCollectionConverter).ConvertFromString(('{0:F3},{1:F3}' -f $dash,$gap));Set-GaugeNeedle $needle $remaining $color
}
function Set-PieProgress($slice,[int]$remaining,[string]$color){
 $remaining=[Math]::Max(0,[Math]::Min(100,$remaining));$slice.Fill=New-Brush $color
 if($remaining -eq 0){$slice.Data=$null;return}
 if($remaining -eq 100){$slice.Data=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new(14,14),14,14);return}
 $angle=(-90+(3.6*$remaining))*[Math]::PI/180;$end=[Windows.Point]::new(14+14*[Math]::Cos($angle),14+14*[Math]::Sin($angle));$figure=[Windows.Media.PathFigure]::new();$figure.StartPoint=[Windows.Point]::new(14,14);$figure.IsClosed=$true;[void]$figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new(14,0),$true));$arc=[Windows.Media.ArcSegment]::new();$arc.Point=$end;$arc.Size=[Windows.Size]::new(14,14);$arc.IsLargeArc=($remaining -gt 50);$arc.SweepDirection=[Windows.Media.SweepDirection]::Clockwise;$arc.IsStroked=$true;[void]$figure.Segments.Add($arc);$geometry=[Windows.Media.PathGeometry]::new();[void]$geometry.Figures.Add($figure);$slice.Data=$geometry
}
function Set-HarmonyArcProgress([int]$remaining,[string]$color){
 $remaining=[Math]::Max(0,[Math]::Min(100,$remaining));$harmonyArcProgress.Stroke=New-Brush $color
 if($remaining -eq 0){$harmonyArcProgress.Data=$null;return}
 $start=[Windows.Point]::new(20,76);if($remaining -eq 100){$end=[Windows.Point]::new(131,76)}else{$angle=([Math]::PI*(1-$remaining/100));$end=[Windows.Point]::new(75.5+55.5*[Math]::Cos($angle),76-55*[Math]::Sin($angle))}
 $figure=[Windows.Media.PathFigure]::new();$figure.StartPoint=$start;$arc=[Windows.Media.ArcSegment]::new();$arc.Point=$end;$arc.Size=[Windows.Size]::new(55.5,55);$arc.IsLargeArc=$false;$arc.SweepDirection=[Windows.Media.SweepDirection]::Clockwise;$arc.IsStroked=$true;[void]$figure.Segments.Add($arc);$geometry=[Windows.Media.PathGeometry]::new();[void]$geometry.Figures.Add($figure);$harmonyArcProgress.Data=$geometry
}
function Update-EdgeBar($fill,$bubble,$label,$remaining,[string]$color) {
 $trackHeight=170.0
 if($null -eq $remaining){$fill.Height=0;$label.Text='-';$top=158.0}else{$value=[Math]::Max(0,[Math]::Min(100,[int]$remaining));$fill.Height=$trackHeight*$value/100;$fill.Background=$color;$label.Text="$value";$top=$trackHeight-$fill.Height+1}
 $top=[Math]::Max(1,[Math]::Min(158,$top));[Windows.Controls.Canvas]::SetTop($bubble,[double]$top)
}
Add-GaugeTicks $primaryGaugeCanvas;Add-GaugeTicks $secondaryGaugeCanvas

function New-Brush([string]$value){(New-Object Windows.Media.BrushConverter).ConvertFromString($value)}
function Get-SystemDarkMode {try{return ((Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0)}catch{return $true}}
function Resolve-DarkMode {if($script:colorMode -eq 'dark'){return $true};if($script:colorMode -eq 'light'){return $false};return Get-SystemDarkMode}
function Get-ThemeBackgroundBrush {
 $dark=$script:isDarkMode
 switch($script:appearanceStyle){
  'apple' {return New-Brush $(if($dark){'#222328'}else{'#F4F5F8'})}
  'harmony' {return New-Brush $(if($dark){'#202229'}else{'#F7F8FC'})}
  default {return New-Brush $(if($dark){'#16191F'}else{'#F0F2F5'})}
 }
}
function Apply-Background([string]$path){
 if($path -and (Test-Path -LiteralPath $path)){$img=New-Object Windows.Media.Imaging.BitmapImage;$img.BeginInit();$img.CacheOption='OnLoad';$img.UriSource=New-Object Uri $path;$img.EndInit();$brush=New-Object Windows.Media.ImageBrush $img;$brush.Stretch='UniformToFill';$bg.Background=$brush}
 else{$bg.Background=Get-ThemeBackgroundBrush}
}
function Apply-Opacity([int]$value){$bg.Opacity=$value/100.0;Save-Setting 'backgroundOpacity' $value}
function Apply-FontColor([string]$value){
 try{$brush=(New-Object Windows.Media.BrushConverter).ConvertFromString($value)}catch{$brush=[Windows.Media.Brushes]::White}
 foreach($textElement in @($title,$user,$primaryLabel,$secondaryLabel,$resetInfo,$resetCredits,$updated,$ringTitle,$ringUser,$ringPrimaryName,$ringPrimaryReset,$ringSecondaryName,$ringSecondaryReset,$ringUpdated,$harmonyTitle,$harmonyUser,$harmonySecondaryName,$harmonySecondaryReset,$harmonyResetCredits,$harmonyUpdated,$appleControlTitle,$appleControlUser,$appleControlPrimaryInfo,$appleControlSecondaryInfo,$appleControlCredits,$appleControlUpdated,$appleLiveTitle,$appleLiveUser,$appleLiveCredits,$appleLiveUpdated,$harmonyGridTitle,$harmonyGridUser,$harmonyGridPrimaryInfo,$harmonyGridSecondaryInfo,$harmonyGridCredits,$harmonyGridUpdated,$harmonyCapsuleTitle,$harmonyCapsuleUser,$harmonyCapsulePrimaryName,$harmonyCapsulePrimaryReset,$harmonyCapsuleSecondaryName,$harmonyCapsuleSecondaryReset,$harmonyCapsuleCredits,$harmonyCapsuleUpdated,$harmonyArcTitle,$harmonyArcUser,$harmonyArcPrimaryInfo,$harmonyArcSecondaryInfo,$harmonyArcCredits,$harmonyArcUpdated)){$textElement.Foreground=$brush}
}
function Apply-ThemeColors {
 $dark=$script:isDarkMode;$text=New-Brush $(if($dark){'#F5F5F7'}else{'#1D1E23'});$muted=New-Brush $(if($dark){'#A7AAB1'}else{'#6E7480'});$track=New-Brush $(if($dark){'#454852'}else{'#D8DCE5'});$surface=New-Brush $(if(-not $dark){'#FFFFFFFF'}elseif($script:appearanceStyle -eq 'apple'){'#37383C'}else{'#34363C'})
 $window.Resources['MenuSurfaceBrush']=New-Brush $(if($dark){'#F2262931'}else{'#FCFFFFFF'});$window.Resources['MenuTextBrush']=$text;$window.Resources['MenuBorderBrush']=New-Brush $(if($dark){'#28FFFFFF'}else{'#22000000'});$window.Resources['MenuHoverBrush']=New-Brush $(if($dark){'#26FFFFFF'}else{'#10000000'})
 foreach($surfaceElement in @($appleControlPrimarySurface,$appleControlSecondarySurface,$harmonyGridPrimarySurface,$harmonyGridSecondarySurface,$harmonyCapsulePrimarySurface,$harmonyCapsuleSecondarySurface)){$surfaceElement.Background=$surface}
 foreach($textElement in @($title,$user,$primaryLabel,$secondaryLabel,$resetCredits,$ringTitle,$ringUser,$ringPrimaryName,$ringSecondaryName,$harmonyTitle,$harmonyUser,$harmonySecondaryName,$harmonyResetCredits,$appleControlTitle,$appleControlUser,$appleLiveTitle,$appleLiveUser,$harmonyGridTitle,$harmonyGridUser,$harmonyCapsuleTitle,$harmonyCapsuleUser,$harmonyCapsulePrimaryName,$harmonyCapsuleSecondaryName,$harmonyArcTitle,$harmonyArcUser)){$textElement.Foreground=$text}
 foreach($textElement in @($resetInfo,$updated,$ringPrimaryReset,$ringSecondaryReset,$ringUpdated,$harmonySecondaryReset,$harmonyUpdated,$appleControlPrimaryInfo,$appleControlSecondaryInfo,$appleControlCredits,$appleControlUpdated,$appleLiveCredits,$appleLiveUpdated,$harmonyGridPrimaryInfo,$harmonyGridSecondaryInfo,$harmonyGridCredits,$harmonyGridUpdated,$harmonyCapsulePrimaryReset,$harmonyCapsuleSecondaryReset,$harmonyCapsuleCredits,$harmonyCapsuleUpdated,$harmonyArcPrimaryInfo,$harmonyArcSecondaryInfo,$harmonyArcCredits,$harmonyArcUpdated)){$textElement.Foreground=$muted}
 $harmonyCapsulePrimaryIcon.Foreground=$text;$harmonyCapsuleSecondaryIcon.Foreground=$text;foreach($gaugeCanvas in @($primaryGaugeCanvas,$secondaryGaugeCanvas)){foreach($shape in $gaugeCanvas.Children){if($shape.Tag -eq 'GaugeTick'){$shape.Stroke=$text}elseif($shape -is [Windows.Shapes.Ellipse]){$shape.Fill=$text}}}
 $primaryTrack.Background=$track;$secondaryTrack.Background=$track;$ringPrimaryTrack.Stroke=$track;$ringSecondaryTrack.Stroke=$track;$harmonyCapsulePrimaryPieTrack.Fill=$track;$harmonyCapsuleSecondaryPieTrack.Fill=$track;$harmonyArcTrack.Stroke=$track;$harmonyCapsuleDivider.Background=$track;$harmonyArcDivider.Background=$track;$edgePrimaryTrack.Background=$track;$edgeSecondaryTrack.Background=$track
 $bg.BorderBrush=New-Brush $(if($dark){'#2AFFFFFF'}else{'#24000000'});if($script:appearanceStyle -eq 'default'){$bg.BorderThickness=[Windows.Thickness]::new(0)}
 $buttonAccent=if($script:appearanceStyle -eq 'default'){'#2F80ED'}else{'#0A84FF'};foreach($resetButton in @($openUsageButton,$ringResetButton,$harmonyResetButton,$appleControlResetButton,$appleLiveResetButton,$harmonyGridResetButton,$harmonyCapsuleResetButton,$harmonyArcResetButton)){$resetButton.Background=[Windows.Media.Brushes]::Transparent;$resetButton.Foreground=New-Brush $buttonAccent}
 if($script:fontColorCustomized){Apply-FontColor $script:fontColor}
}
$cfg=Read-Config;$script:appearanceStyle=if(@('default','apple','harmony') -contains [string]$cfg.appearanceStyle){[string]$cfg.appearanceStyle}else{'default'};$script:colorMode=if(@('system','light','dark') -contains [string]$cfg.colorMode){[string]$cfg.colorMode}else{'system'};$script:isDarkMode=Resolve-DarkMode;$script:fontColor=if($cfg.fontColor){[string]$cfg.fontColor}else{'#FFFFFF'};$script:fontColorCustomized=if($null -ne $cfg.fontColorCustomized){[bool]$cfg.fontColorCustomized}else{$false}
$opacity=if($null -ne $cfg.backgroundOpacity){[int]$cfg.backgroundOpacity}else{90};$bg.Opacity=$opacity/100.0
function Apply-AppearanceStyle {
 $backgroundPath=[string](Read-Config).backgroundImage
 switch($script:appearanceStyle){
  'apple' {
   $bg.CornerRadius=[Windows.CornerRadius]::new(22);$bg.BorderThickness=[Windows.Thickness]::new(1);$bg.BorderBrush=New-Brush '#30FFFFFF'
   $primaryPanel.Visibility='Collapsed';$secondaryPanel.Visibility='Collapsed';$primaryPanel.Opacity=1;$secondaryPanel.Opacity=1
   $primaryTrack.Background=New-Brush '#3A3C42';$secondaryTrack.Background=New-Brush '#3A3C42';$ringPrimaryTrack.Stroke=New-Brush '#3A3C42';$ringSecondaryTrack.Stroke=New-Brush '#3A3C42'
   $edgePrimaryTrack.Background=New-Brush '#3A3C42';$edgeSecondaryTrack.Background=New-Brush '#3A3C42';$edgePrimaryTrack.CornerRadius=[Windows.CornerRadius]::new(3);$edgeSecondaryTrack.CornerRadius=[Windows.CornerRadius]::new(3);$edgePrimaryFill.CornerRadius=[Windows.CornerRadius]::new(3);$edgeSecondaryFill.CornerRadius=[Windows.CornerRadius]::new(3);$edgePrimaryBubble.Background=New-Brush '#8A000000';$edgeSecondaryBubble.Background=New-Brush '#8A000000'
   $primaryGaugeCanvas.Visibility='Collapsed';$secondaryGaugeCanvas.Visibility='Collapsed';$openUsageButton.Background=New-Brush '#0A84FF';$ringResetButton.Background=New-Brush '#0A84FF'
  }
  'harmony' {
   $bg.CornerRadius=[Windows.CornerRadius]::new(24);$bg.BorderThickness=[Windows.Thickness]::new(1);$bg.BorderBrush=New-Brush '#24FFFFFF'
   $primaryPanel.Visibility='Collapsed';$secondaryPanel.Visibility='Collapsed';$primaryPanel.Opacity=1;$secondaryPanel.Opacity=1
   $primaryTrack.Background=New-Brush '#48FFFFFF';$secondaryTrack.Background=New-Brush '#41444D';$ringPrimaryTrack.Stroke=New-Brush '#454852';$ringSecondaryTrack.Stroke=New-Brush '#454852'
   $edgePrimaryTrack.Background=New-Brush '#474B56';$edgeSecondaryTrack.Background=New-Brush '#474B56';$edgePrimaryTrack.CornerRadius=[Windows.CornerRadius]::new(3);$edgeSecondaryTrack.CornerRadius=[Windows.CornerRadius]::new(3);$edgePrimaryFill.CornerRadius=[Windows.CornerRadius]::new(3);$edgeSecondaryFill.CornerRadius=[Windows.CornerRadius]::new(3);$edgePrimaryBubble.Background=New-Brush '#A03973ED';$edgeSecondaryBubble.Background=New-Brush '#A06055DC'
   $primaryGaugeCanvas.Visibility='Collapsed';$secondaryGaugeCanvas.Visibility='Collapsed';$openUsageButton.Background=New-Brush '#3973ED';$ringResetButton.Background=New-Brush '#3973ED';$harmonyResetButton.Background=New-Brush '#3973ED'
  }
  default {
   $bg.CornerRadius=[Windows.CornerRadius]::new(14);$bg.BorderThickness=[Windows.Thickness]::new(0);$bg.BorderBrush=$null
   $primaryPanel.Visibility='Collapsed';$secondaryPanel.Visibility='Collapsed';$primaryPanel.Opacity=1;$secondaryPanel.Opacity=1
   $primaryTrack.Background=New-Brush '#59606E';$secondaryTrack.Background=New-Brush '#59606E';$ringPrimaryTrack.Stroke=New-Brush '#59606E';$ringSecondaryTrack.Stroke=New-Brush '#59606E'
   $edgePrimaryTrack.Background=New-Brush '#59606E';$edgeSecondaryTrack.Background=New-Brush '#59606E';$edgePrimaryTrack.CornerRadius=[Windows.CornerRadius]::new(3);$edgeSecondaryTrack.CornerRadius=[Windows.CornerRadius]::new(3);$edgePrimaryFill.CornerRadius=[Windows.CornerRadius]::new(3);$edgeSecondaryFill.CornerRadius=[Windows.CornerRadius]::new(3);$edgePrimaryBubble.Background=New-Brush '#73000000';$edgeSecondaryBubble.Background=New-Brush '#73000000'
   $primaryGaugeCanvas.Visibility='Visible';$secondaryGaugeCanvas.Visibility='Visible';$openUsageButton.Background=New-Brush '#2F80ED';$ringResetButton.Background=New-Brush '#2F80ED'
  }
 }
 Apply-Background $backgroundPath;Apply-ThemeColors
}
Apply-AppearanceStyle
$alwaysOnTop=if($null -ne $cfg.alwaysOnTop){[bool]$cfg.alwaysOnTop}else{$true};$window.Topmost=$alwaysOnTop
$script:cardIndex=if($null -ne $cfg.cardIndex){[int]$cfg.cardIndex}elseif([string]$cfg.displayStyle -eq 'ring'){1}else{0}
$script:isEdgeHidden=$false;$script:temporaryExpanded=$false;$script:edgeSide='right';$script:expandedWidth=175
function Get-CardCount {if($script:appearanceStyle -eq 'default'){2}else{4}}
function Apply-DisplayStyle {
 $bg.Visibility='Visible'
 foreach($view in @($detailView,$appleControlView,$appleLiveView,$harmonyDetailView,$harmonyGridView,$harmonyCapsuleView,$harmonyArcView,$ringView,$edgeView)){$view.Visibility='Collapsed'}
 if($script:isEdgeHidden){$bg.CornerRadius=[Windows.CornerRadius]::new(14);$bg.BorderThickness=[Windows.Thickness]::new(0);$edgeView.Visibility='Visible';return}
 $count=Get-CardCount;if($script:cardIndex -lt 0 -or $script:cardIndex -ge $count){$script:cardIndex=0}
 if($script:appearanceStyle -eq 'apple'){switch($script:cardIndex){0{$detailView.Visibility='Visible'}1{$appleControlView.Visibility='Visible'}2{$ringView.Visibility='Visible'}3{$bg.Visibility='Collapsed';$appleLiveView.Visibility='Visible'}}}
 elseif($script:appearanceStyle -eq 'harmony'){switch($script:cardIndex){0{$harmonyDetailView.Visibility='Visible'}1{$harmonyGridView.Visibility='Visible'}2{$harmonyCapsuleView.Visibility='Visible'}3{$harmonyArcView.Visibility='Visible'}}}
 else{if($script:cardIndex -eq 1){$ringView.Visibility='Visible'}else{$detailView.Visibility='Visible'}}
}
function Toggle-DisplayStyle {$script:cardIndex=($script:cardIndex+1)%(Get-CardCount);Apply-DisplayStyle;Save-Setting 'cardIndex' $script:cardIndex;if($script:appearanceStyle -eq 'default'){Save-Setting 'displayStyle' $(if($script:cardIndex -eq 1){'ring'}else{'detail'})}}
function Collapse-ToEdge([string]$side){
 $script:isEdgeHidden=$true;$script:temporaryExpanded=$false;$script:edgeSide=$side;$window.Width=30
 $work=[Windows.SystemParameters]::WorkArea;if($side -eq 'left'){$window.Left=$work.Left}else{$window.Left=$work.Right-$window.Width}
 Apply-DisplayStyle
}
function Expand-FromEdge([bool]$temporary=$false) {
 $work=[Windows.SystemParameters]::WorkArea;$script:isEdgeHidden=$false;$script:temporaryExpanded=$temporary;$window.Width=$script:expandedWidth
 if($script:edgeSide -eq 'left'){$window.Left=$work.Left}else{$window.Left=$work.Right-$window.Width}
 Apply-AppearanceStyle;Apply-DisplayStyle
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
$primaryLabel.Text=(T '55+t5ZGo5pyf');$primaryValue.Text='-';$primaryBar.Width=0;$secondaryLabel.Text=(T '6ZW/5ZGo5pyf');$secondaryValue.Text='-';$secondaryBar.Width=0;$resetInfo.Text=(T '6YeN572u')+': -';$resetCredits.Text='-';$updated.Text='- '+(T '5pu05paw');Update-EdgeBar $edgePrimaryFill $edgePrimaryBubble $edgePrimaryPercent $null '#22D3EE';Update-EdgeBar $edgeSecondaryFill $edgeSecondaryBubble $edgeSecondaryPercent $null '#32EB87'
$user.Text='-';$ringUser.Text='-';$ringPrimaryPercent.Text='-';$ringPrimaryName.Text=(T '55+t5ZGo5pyf');$ringPrimaryReset.Text=(T '6YeN572u')+': -';$ringSecondaryPercent.Text='-';$ringSecondaryName.Text=(T '6ZW/5ZGo5pyf');$ringSecondaryReset.Text=(T '6YeN572u')+': -';$ringUpdated.Text='- '+(T '5pu05paw')
$harmonyUser.Text='-';$harmonyPrimaryName.Text=(T '55+t5ZGo5pyf');$harmonyPrimaryReset.Text=(T '6YeN572u')+': -';$harmonyPrimaryPercent.Text='-';$harmonyPrimaryBar.Width=0;$harmonySecondaryName.Text=(T '6ZW/5ZGo5pyf');$harmonySecondaryPercent.Text='-';$harmonySecondaryReset.Text=(T '6YeN572u')+': -';$harmonyResetCredits.Text='-';$harmonyUpdated.Text='- '+(T '5pu05paw')
$appleControlUser.Text='-';$appleControlPrimaryPercent.Text='-';$appleControlPrimaryInfo.Text=(T '55+t5ZGo5pyf')+"`n-";$appleControlSecondaryPercent.Text='-';$appleControlSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+"`n-";$appleControlCredits.Text='-';$appleControlUpdated.Text='- '+(T '5pu05paw')
$appleLiveUser.Text='-';$appleLiveMeta.Text='ChatGPT '+[char]0x00B7+' -';$appleLiveTime.Text='- '+(T '5pu05paw');$appleLivePrimaryPercent.Text='-';$appleLivePrimaryInfo.Text=(T '55+t5ZGo5pyf')+' / -';$appleLiveSecondaryPercent.Text='-';$appleLiveSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+' / -';$appleLiveCredits.Text='-';$appleLiveUpdated.Text='- '+(T '5pu05paw')
$harmonyGridUser.Text='-';$harmonyGridPrimaryIcon.Text='-';$harmonyGridPrimaryPercent.Text='-';$harmonyGridPrimaryInfo.Text=(T '55+t5ZGo5pyf')+"`n-";$harmonyGridSecondaryIcon.Text='-';$harmonyGridSecondaryPercent.Text='-';$harmonyGridSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+"`n-";$harmonyGridCredits.Text='-';$harmonyGridUpdated.Text='- '+(T '5pu05paw')
$harmonyCapsuleUser.Text='-';$harmonyCapsulePrimaryIcon.Text='-';$harmonyCapsulePrimaryName.Text=T '55+t5ZGo5pyf';$harmonyCapsulePrimaryReset.Text=(T '6YeN572u')+': -';$harmonyCapsulePrimaryPercent.Text='-';$harmonyCapsuleSecondaryIcon.Text='-';$harmonyCapsuleSecondaryName.Text=T '6ZW/5ZGo5pyf';$harmonyCapsuleSecondaryReset.Text=(T '6YeN572u')+': -';$harmonyCapsuleSecondaryPercent.Text='-';$harmonyCapsuleCredits.Text='-';$harmonyCapsuleUpdated.Text='- '+(T '5pu05paw')
$null=Set-PieProgress $harmonyCapsulePrimarySlice 0 '#3F83F8';$null=Set-PieProgress $harmonyCapsuleSecondarySlice 0 '#8C6BE8';$null=Set-HarmonyArcProgress 0 '#4D7EF1'
$harmonyArcUser.Text='-';$harmonyArcPercent.Text='-';$harmonyArcPrimaryInfo.Text=(T '55+t5ZGo5pyf')+' / -';$harmonyArcSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+' / -';$harmonyArcCredits.Text='-';$harmonyArcUpdated.Text='- '+(T '5pu05paw')

function Update-Widget {
 try{$u=Get-Usage;$remain=$u.tightest.remaining
  $primaryColor=if($u.primary.remaining -le 5){'#FF3737'}elseif($u.primary.remaining -le 20){'#FFD22D'}else{'#22D3EE'}
  $primaryName=if($u.primary.minutes -lt 1440){$n=[int]($u.primary.minutes/60);$n.ToString()+(T '5bCP5pe2')}else{$n=[int]($u.primary.minutes/1440);$n.ToString()+(T '5aSp')}
  $primaryLabel.Text=$primaryName;$primaryValue.Text="$($u.primary.remaining)%";$primaryValue.Foreground=$primaryColor;$primaryBar.Width=151*$u.primary.remaining/100;$primaryBar.Background=$primaryColor
  if($u.secondary){$secondaryColor=if($u.secondary.remaining -le 5){'#FF3737'}elseif($u.secondary.remaining -le 20){'#FFD22D'}else{'#32EB87'};$secondaryName=if($u.secondary.minutes -lt 1440){$n=[int]($u.secondary.minutes/60);$n.ToString()+(T '5bCP5pe2')}else{$n=[int]($u.secondary.minutes/1440);$n.ToString()+(T '5aSp')};$secondaryLabel.Text=$secondaryName;$secondaryValue.Text="$($u.secondary.remaining)%";$secondaryValue.Foreground=$secondaryColor;$secondaryBar.Width=151*$u.secondary.remaining/100;$secondaryBar.Background=$secondaryColor}else{$secondaryName=(T '6ZW/5ZGo5pyf');$secondaryLabel.Text=$secondaryName;$secondaryValue.Text='-';$secondaryBar.Width=0}
  $reset1=if($u.primary.reset){$u.primary.reset.ToString('MM-dd HH:mm')}else{'-'};$reset2=if($u.secondary -and $u.secondary.reset){$u.secondary.reset.ToString('MM-dd HH:mm')}else{'-'};$secondaryResetShort=if($u.secondary -and $u.secondary.reset){$u.secondary.reset.Month.ToString()+(T '5pyI')+$u.secondary.reset.Day.ToString()+(T '5pel')}else{'-'}
  $resetInfo.Text="$primaryName "+(T '6YeN572u')+": $reset1`n$secondaryName "+(T '6YeN572u')+": $reset2"
  $resetCredits.Text="$($u.resetCredits) "+(T '5qyh6YeN572u5py65Lya')
  $updated.Text=(Get-Date).ToString('HH:mm')+' '+(T '5pu05paw')
  $user.Text=$u.displayName;$ringUser.Text=$u.displayName
  $harmonyPrimaryColor=if($u.primary.remaining -le 20){$primaryColor}else{'#0A84FF'};$harmonyPrimaryRingColor=if($u.primary.remaining -le 20){$primaryColor}else{'#3F83F8'};$harmonyOverviewColor=if($u.primary.remaining -le 20){$primaryColor}else{'#4D7EF1'};$harmonyHeroColor=if($u.primary.remaining -le 20){$primaryColor}else{'#FFFFFF'}
  $harmonyUser.Text=$u.displayName;$harmonyPrimaryName.Text=$primaryName;$harmonyPrimaryReset.Text=if($u.primary.reset){$u.primary.reset.ToString('HH:mm')+' '+(T '6YeN572u')}else{(T '6YeN572u')+': -'};$harmonyPrimaryPercent.Text="$($u.primary.remaining)%";$harmonyPrimaryPercent.Foreground=$harmonyHeroColor;$harmonyPrimaryBar.Width=133*$u.primary.remaining/100;$harmonyPrimaryBar.Background=$harmonyHeroColor
  if($u.secondary){$harmonySecondaryColor=if($u.secondary.remaining -le 20){$secondaryColor}else{'#A99BFF'};$harmonySecondaryRingColor=if($u.secondary.remaining -le 20){$secondaryColor}else{'#8C6BE8'};$harmonySecondaryName.Text=$secondaryName;$harmonySecondaryPercent.Text="$($u.secondary.remaining)%";$harmonySecondaryPercent.Foreground=$harmonySecondaryColor;$harmonySecondaryReset.Text=$secondaryResetShort+(T '6YeN572u')}else{$harmonySecondaryName.Text=(T '6ZW/5ZGo5pyf');$harmonySecondaryPercent.Text='-';$harmonySecondaryReset.Text=(T '6YeN572u')+': -'}
  $harmonyResetCredits.Text="$($u.resetCredits) "+(T '5qyh6YeN572u5py65Lya');$harmonyUpdated.Text=(Get-Date).ToString('HH:mm')+' '+(T '5pu05paw')
  $primaryCompact=if($u.primary.minutes -lt 1440){([int]($u.primary.minutes/60)).ToString()+'h'}else{([int]($u.primary.minutes/1440)).ToString()+'d'};$primaryResetCompact=if($u.primary.reset){$u.primary.reset.ToString('HH:mm')}else{'-'}
  $secondaryCompact=if($u.secondary){if($u.secondary.minutes -lt 1440){([int]($u.secondary.minutes/60)).ToString()+'h'}else{([int]($u.secondary.minutes/1440)).ToString()+'d'}}else{'-'};$secondaryResetCompact=$secondaryResetShort;$creditsText="$($u.resetCredits) "+(T '5qyh6YeN572u5py65Lya');$updateTime=(Get-Date).ToString('HH:mm')
  $appleControlUser.Text=$u.displayName;$appleControlPrimaryPercent.Text="$($u.primary.remaining)%";$appleControlPrimaryPercent.Foreground=$primaryColor;$appleControlPrimaryInfo.Text=$primaryName+"`n"+$primaryResetCompact
  $appleLiveUser.Text=$u.displayName;$appleLiveMeta.Text='ChatGPT '+[char]0x00B7+' '+$u.displayName;$appleLiveTime.Text=$updateTime+' '+(T '5pu05paw');$appleLivePrimaryPercent.Text="$($u.primary.remaining)%";$appleLivePrimaryPercent.Foreground=$primaryColor;$appleLivePrimaryInfo.Text=$primaryName+' / '+$primaryResetCompact
  $harmonyGridUser.Text=$u.displayName;$harmonyGridPrimaryIcon.Text=$primaryCompact;$harmonyGridPrimaryPercent.Text="$($u.primary.remaining)%";$harmonyGridPrimaryPercent.Foreground=$harmonyPrimaryColor;$harmonyGridPrimaryInfo.Text=$primaryName+"`n"+$primaryResetCompact
  $harmonyCapsuleUser.Text=$u.displayName;$harmonyCapsulePrimaryIcon.Text=$primaryCompact;$harmonyCapsulePrimaryName.Text=T '55+t5ZGo5pyf';$harmonyCapsulePrimaryReset.Text=$primaryResetCompact+' '+(T '6YeN572u');$harmonyCapsulePrimaryPercent.Text="$($u.primary.remaining)%";$harmonyCapsulePrimaryPercent.Foreground=$harmonyPrimaryColor;Set-PieProgress $harmonyCapsulePrimarySlice $u.primary.remaining $harmonyPrimaryRingColor
  $harmonyArcUser.Text=$u.displayName;$harmonyArcPercent.Text="$($u.primary.remaining)%";$harmonyArcPercent.Foreground=$harmonyPrimaryColor;$harmonyArcPrimaryInfo.Text=$primaryName+' '+[char]0x00B7+' '+$u.primary.remaining+'%';Set-HarmonyArcProgress $u.primary.remaining $harmonyOverviewColor
  if($u.secondary){
   $appleControlSecondaryPercent.Text="$($u.secondary.remaining)%";$appleControlSecondaryPercent.Foreground=$secondaryColor;$appleControlSecondaryInfo.Text=$secondaryName+"`n"+$secondaryResetCompact;$appleLiveSecondaryPercent.Text="$($u.secondary.remaining)%";$appleLiveSecondaryPercent.Foreground=$secondaryColor;$appleLiveSecondaryInfo.Text=$secondaryName+' / '+$secondaryResetCompact
   $harmonyGridSecondaryIcon.Text=$secondaryCompact;$harmonyGridSecondaryPercent.Text="$($u.secondary.remaining)%";$harmonyGridSecondaryPercent.Foreground=$harmonySecondaryColor;$harmonyGridSecondaryInfo.Text=$secondaryName+"`n"+$secondaryResetCompact
   $harmonyCapsuleSecondaryIcon.Text=$secondaryCompact;$harmonyCapsuleSecondaryName.Text=T '6ZW/5ZGo5pyf';$harmonyCapsuleSecondaryReset.Text=$secondaryResetCompact;$harmonyCapsuleSecondaryPercent.Text="$($u.secondary.remaining)%";$harmonyCapsuleSecondaryPercent.Foreground=$harmonySecondaryColor;Set-PieProgress $harmonyCapsuleSecondarySlice $u.secondary.remaining $harmonySecondaryRingColor;$harmonyArcSecondaryInfo.Text=$secondaryName+' '+[char]0x00B7+' '+$u.secondary.remaining+'%'
  }else{$appleControlSecondaryPercent.Text='-';$appleControlSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+"`n-";$appleLiveSecondaryPercent.Text='-';$appleLiveSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+' / -';$harmonyGridSecondaryIcon.Text='-';$harmonyGridSecondaryPercent.Text='-';$harmonyGridSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+"`n-";$harmonyCapsuleSecondaryIcon.Text='-';$harmonyCapsuleSecondaryName.Text=T '6ZW/5ZGo5pyf';$harmonyCapsuleSecondaryReset.Text=(T '6YeN572u')+': -';$harmonyCapsuleSecondaryPercent.Text='-';Set-PieProgress $harmonyCapsuleSecondarySlice 0 '#8C6BE8';$harmonyArcSecondaryInfo.Text=(T '6ZW/5ZGo5pyf')+' / -'}
  foreach($creditsElement in @($appleControlCredits,$appleLiveCredits,$harmonyGridCredits,$harmonyCapsuleCredits,$harmonyArcCredits)){$creditsElement.Text=$creditsText};foreach($updatedElement in @($appleControlUpdated,$appleLiveUpdated,$harmonyGridUpdated,$harmonyCapsuleUpdated,$harmonyArcUpdated)){$updatedElement.Text=$updateTime+' '+(T '5pu05paw')}
  $ringPrimaryPercent.Text="$($u.primary.remaining)%";$ringPrimaryPercent.Foreground=$primaryColor;$ringPrimaryName.Text=$primaryName;$ringPrimaryReset.Text=(T '6YeN572u')+"`n"+$reset1;Set-GaugeProgress $ringPrimaryArc $primaryNeedle $u.primary.remaining $primaryColor
  if($u.secondary){$ringSecondaryPercent.Text="$($u.secondary.remaining)%";$ringSecondaryPercent.Foreground=$secondaryColor;$ringSecondaryName.Text=$secondaryName;$ringSecondaryReset.Text=(T '6YeN572u')+"`n"+$reset2;Set-GaugeProgress $ringSecondaryArc $secondaryNeedle $u.secondary.remaining $secondaryColor}else{$ringSecondaryPercent.Text='-';$ringSecondaryName.Text=(T '6ZW/5ZGo5pyf');$ringSecondaryReset.Text=(T '6YeN572u')+': -'}
  $color=if($remain -le 5){'#FF3737'}elseif($remain -le 20){'#FFD22D'}else{'#32EB87'}
  Update-EdgeBar $edgePrimaryFill $edgePrimaryBubble $edgePrimaryPercent $u.primary.remaining $primaryColor
  if($u.secondary){Update-EdgeBar $edgeSecondaryFill $edgeSecondaryBubble $edgeSecondaryPercent $u.secondary.remaining $secondaryColor}else{Update-EdgeBar $edgeSecondaryFill $edgeSecondaryBubble $edgeSecondaryPercent $null '#32EB87'}
  $ringUpdated.Text=(Get-Date).ToString('HH:mm')+' '+(T '5pu05paw')
  $script:hasUsageData=$true;if($timer){$timer.Interval=[TimeSpan]::FromMinutes(1)}
 }catch{
  $errorPath=Join-Path $appDir 'widget-error.log'
  ("{0:yyyy-MM-dd HH:mm:ss} | {1}`r`n{2}" -f (Get-Date),$_.Exception.Message,$_.ScriptStackTrace)|Set-Content -LiteralPath $errorPath -Encoding UTF8
  if(-not $script:hasUsageData -and $timer){$timer.Interval=[TimeSpan]::FromSeconds(10)}
 }
}

$menu=New-Object Windows.Controls.ContextMenu
$menu.Style=$window.FindResource('RoundedContextMenu')
function Item($text){$i=New-Object Windows.Controls.MenuItem;$i.Header=$text;$i.Style=$window.FindResource('RoundedMenuItem');[void]$menu.Items.Add($i);$i}
$refresh=Item (T '56uL5Y2z5Yi35paw')
$styleMenu=Item (T '6aOO5qC8');$styleChoices=@(@{key='default';label='1 '+(T '6buY6K6k')},@{key='apple';label='2 '+(T '6Iu55p6c')},@{key='harmony';label='3 '+(T '6bi/6JKZ')})
foreach($choice in $styleChoices){$i=New-Object Windows.Controls.MenuItem;$i.Header=$choice.label;$i.Style=$window.FindResource('RoundedMenuItem');$i.Tag=$choice.key;$i.IsCheckable=$true;$i.IsChecked=($choice.key -eq $script:appearanceStyle);$i.Add_Click({$selected=[string]$this.Tag;$script:appearanceStyle=$selected;$script:cardIndex=0;Save-Setting 'appearanceStyle' $selected;Save-Setting 'cardIndex' 0;Apply-AppearanceStyle;Apply-DisplayStyle;foreach($child in $styleMenu.Items){$child.IsChecked=([string]$child.Tag -eq $selected)}});[void]$styleMenu.Items.Add($i)}
$colorModeMenu=Item (T '5piO5pqX5qih5byP');$colorModeChoices=@(@{key='system';label=(T '6Lef6ZqP57O757uf')},@{key='light';label=(T '5rWF6Imy')},@{key='dark';label=(T '5rex6Imy')})
foreach($choice in $colorModeChoices){$i=New-Object Windows.Controls.MenuItem;$i.Header=$choice.label;$i.Style=$window.FindResource('RoundedMenuItem');$i.Tag=$choice.key;$i.IsCheckable=$true;$i.IsChecked=($choice.key -eq $script:colorMode);$i.Add_Click({$selected=[string]$this.Tag;$script:colorMode=$selected;$script:isDarkMode=Resolve-DarkMode;Save-Setting 'colorMode' $selected;Apply-AppearanceStyle;foreach($child in $colorModeMenu.Items){$child.IsChecked=([string]$child.Tag -eq $selected)}});[void]$colorModeMenu.Items.Add($i)}
$image=Item (T '5L+u5pS56IOM5pmv5Zu+54mH');$clear=Item (T '5riF6Zmk6IOM5pmv5Zu+54mH');$fontColorItem=Item (T '5a2X5L2T6aKc6Imy')
$opacityMenu=Item (T '6IOM5pmv6YCP5piO5bqm');foreach($v in @(30,50,70,80,90,100)){$i=New-Object Windows.Controls.MenuItem;$i.Header="$v%";$i.Style=$window.FindResource('RoundedMenuItem');$i.Tag=$v;$i.IsCheckable=$true;$i.IsChecked=($v -eq $opacity);$i.Add_Click({$selected=[int]$this.Tag;Apply-Opacity $selected;foreach($child in $opacityMenu.Items){$child.IsChecked=([int]$child.Tag -eq $selected)}});[void]$opacityMenu.Items.Add($i)}
$top=Item (T '572u6aG25pi+56S6');$top.IsCheckable=$true;$top.IsChecked=$alwaysOnTop;$exit=Item (T '6YCA5Ye6')
$refresh.Add_Click({Update-Widget});$top.Add_Click({$window.Topmost=$top.IsChecked;Save-Setting 'alwaysOnTop' ([bool]$top.IsChecked)});$exit.Add_Click({$window.Close()})
$image.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif';if($d.ShowDialog()-eq'OK'){Save-Setting 'backgroundImage' $d.FileName;Apply-Background $d.FileName};$d.Dispose()})
$clear.Add_Click({Save-Setting 'backgroundImage' '';Apply-Background ''})
$fontColorItem.Add_Click({$d=New-Object Windows.Forms.ColorDialog;$d.FullOpen=$true;if($d.ShowDialog()-eq'OK'){$hex='#{0:X2}{1:X2}{2:X2}' -f $d.Color.R,$d.Color.G,$d.Color.B;$script:fontColor=$hex;$script:fontColorCustomized=$true;Save-Setting 'fontColor' $hex;Save-Setting 'fontColorCustomized' $true;Apply-FontColor $hex};$d.Dispose()})
$script:navigationTimers=New-Object Collections.ArrayList
function Open-UsagePageAfterFeedback {
 $navigationTimer=New-Object Windows.Threading.DispatcherTimer;$navigationTimer.Interval=[TimeSpan]::FromMilliseconds(220);[void]$script:navigationTimers.Add($navigationTimer)
 $navigationTimer.Add_Tick({$this.Stop();[void]$script:navigationTimers.Remove($this);Start-Process 'https://chatgpt.com/codex/settings/usage'});$navigationTimer.Start()
}
$openUsageButton.Add_Click({Open-UsagePageAfterFeedback})
$ringResetButton.Add_Click({Open-UsagePageAfterFeedback})
$harmonyResetButton.Add_Click({Open-UsagePageAfterFeedback})
foreach($resetButton in @($appleControlResetButton,$appleLiveResetButton,$harmonyGridResetButton,$harmonyCapsuleResetButton,$harmonyArcResetButton)){$resetButton.Add_Click({Open-UsagePageAfterFeedback})}
$edgeReturnTimer=New-Object Windows.Threading.DispatcherTimer;$edgeReturnTimer.Interval=[TimeSpan]::FromSeconds(5);$edgeReturnTimer.Add_Tick({$edgeReturnTimer.Stop();if(-not $script:isEdgeHidden){Collapse-ToEdge $script:edgeSide}})
$themeTimer=New-Object Windows.Threading.DispatcherTimer;$themeTimer.Interval=[TimeSpan]::FromSeconds(2);$themeTimer.Add_Tick({if($script:colorMode -eq 'system'){$detected=Get-SystemDarkMode;if($detected -ne $script:isDarkMode){$script:isDarkMode=$detected;Apply-AppearanceStyle}}});$themeTimer.Start()
$window.ContextMenu=$menu;$window.Add_MouseLeftButtonDown({
 $wasTemporary=$script:temporaryExpanded;if($wasTemporary){$edgeReturnTimer.Stop()}
 $start=[Windows.Forms.Cursor]::Position;try{$window.DragMove()}catch{};$finish=[Windows.Forms.Cursor]::Position
 $moved=([Math]::Abs($finish.X-$start.X) -gt 3 -or [Math]::Abs($finish.Y-$start.Y) -gt 3)
 if($moved){$script:temporaryExpanded=$false;if($script:isEdgeHidden){Expand-FromEdge $false}else{[void](Test-SnapToEdge)}}elseif($script:isEdgeHidden){Expand-FromEdge $true}else{if($wasTemporary){$edgeReturnTimer.Start()};Toggle-DisplayStyle}
})
if($SelfTest){
 $results=@()
 $allCardViews=@($detailView,$appleControlView,$ringView,$appleLiveView,$harmonyDetailView,$harmonyGridView,$harmonyCapsuleView,$harmonyArcView)
 foreach($testStyle in @('default','apple','harmony')){
  $script:appearanceStyle=$testStyle;Apply-AppearanceStyle
  $expectedViews=if($testStyle -eq 'default'){@($detailView,$ringView)}elseif($testStyle -eq 'apple'){@($detailView,$appleControlView,$ringView,$appleLiveView)}else{@($harmonyDetailView,$harmonyGridView,$harmonyCapsuleView,$harmonyArcView)}
  $cardsPassed=$true;for($index=0;$index -lt $expectedViews.Count;$index++){$script:cardIndex=$index;Apply-DisplayStyle;$visible=@($allCardViews|Where-Object{$_.Visibility -eq 'Visible'});if($visible.Count -ne 1 -or $expectedViews[$index].Visibility -ne 'Visible'){$cardsPassed=$false}}
  $expectedRadius=switch($testStyle){'apple'{22}'harmony'{24}default{14}}
  $expectedGauge=if($testStyle -eq 'default'){$primaryGaugeCanvas.Visibility -eq 'Visible'}else{$primaryGaugeCanvas.Visibility -eq 'Collapsed'}
  $results+=[PSCustomObject]@{style=$testStyle;cardCount=$expectedViews.Count;cards=$cardsPassed;gaugeMode=$expectedGauge;cornerRadius=($bg.CornerRadius.TopLeft -eq $expectedRadius)}
 }
 $script:appearanceStyle='apple';Apply-AppearanceStyle;$script:cardIndex=3;$script:isEdgeHidden=$false;Apply-DisplayStyle;$a4BlackOnly=($bg.Visibility -eq 'Collapsed')
 $script:isEdgeHidden=$true;Apply-DisplayStyle;$edgeFramePassed=($bg.Visibility -eq 'Visible')-and($bg.CornerRadius.TopLeft -eq 14)-and($bg.BorderThickness.Left -eq 0)-and($edgePrimaryTrack.CornerRadius.TopLeft -eq 3);$script:isEdgeHidden=$false
 $script:colorMode='light';$script:isDarkMode=$false;Apply-AppearanceStyle;$lightText=$title.Foreground.ToString();$script:colorMode='dark';$script:isDarkMode=$true;Apply-AppearanceStyle;$darkText=$title.Foreground.ToString();Set-PieProgress $harmonyCapsulePrimarySlice 53 '#3F83F8';Set-HarmonyArcProgress 83 '#4D7EF1'
 $pieArc=$harmonyCapsulePrimarySlice.Data.Figures[0].Segments[1];$overviewArc=$harmonyArcProgress.Data.Figures[0].Segments[0];$expectedAngle=[Math]::PI*.17;$expectedX=75.5+55.5*[Math]::Cos($expectedAngle);$expectedY=76-55*[Math]::Sin($expectedAngle);$progressPassed=$pieArc.IsLargeArc-and([Math]::Abs($overviewArc.Point.X-$expectedX)-lt .01)-and([Math]::Abs($overviewArc.Point.Y-$expectedY)-lt .01)-and($harmonyArcProgress.StrokeDashArray.Count -eq 0);$timePassed=$updated.Text.EndsWith((T '5pu05paw'))
 if($env:CHATGPT_WIDGET_PREVIEW_DIR){
  New-Item -ItemType Directory -Force -Path $env:CHATGPT_WIDGET_PREVIEW_DIR|Out-Null;$script:appearanceStyle='harmony'
  $user.Text='Demo';$primaryLabel.Text='5'+(T '5bCP5pe2');$primaryValue.Text='83%';$primaryValue.Foreground=New-Brush '#22D3EE';$primaryBar.Width=125;$primaryBar.Background=New-Brush '#22D3EE';$secondaryLabel.Text='7'+(T '5aSp');$secondaryValue.Text='53%';$secondaryValue.Foreground=New-Brush '#32EB87';$secondaryBar.Width=80;$secondaryBar.Background=New-Brush '#32EB87';$resetInfo.Text='5'+(T '5bCP5pe2')+' '+(T '6YeN572u')+': 09-03 13:59'+"`n"+'7'+(T '5aSp')+' '+(T '6YeN572u')+': 09-08 11:14';$resetCredits.Text='1 '+(T '5qyh6YeN572u5py65Lya');$updated.Text='09:53 '+(T '5pu05paw')
  $ringUser.Text='Demo';$ringPrimaryPercent.Text='83%';$ringPrimaryPercent.Foreground=New-Brush '#22D3EE';$ringPrimaryName.Text='5'+(T '5bCP5pe2');$ringPrimaryReset.Text=(T '6YeN572u')+"`n09-03 13:59";$ringSecondaryPercent.Text='53%';$ringSecondaryPercent.Foreground=New-Brush '#32EB87';$ringSecondaryName.Text='7'+(T '5aSp');$ringSecondaryReset.Text=(T '6YeN572u')+"`n09-08 11:14";$ringUpdated.Text='09:53 '+(T '5pu05paw');Set-GaugeProgress $ringPrimaryArc $primaryNeedle 83 '#22D3EE';Set-GaugeProgress $ringSecondaryArc $secondaryNeedle 53 '#32EB87'
  $appleControlUser.Text='Demo';$appleControlPrimaryPercent.Text='83%';$appleControlPrimaryInfo.Text='5'+(T '5bCP5pe2')+"`n13:59";$appleControlSecondaryPercent.Text='53%';$appleControlSecondaryInfo.Text='7'+(T '5aSp')+"`n9"+(T '5pyI')+'8'+(T '5pel');$appleControlCredits.Text='1 '+(T '5qyh6YeN572u5py65Lya');$appleControlUpdated.Text='09:53 '+(T '5pu05paw')
  $harmonyUser.Text='Demo';$harmonyPrimaryName.Text='5 '+(T '5bCP5pe2')+(T '5Ymp5L2Z');$harmonyPrimaryReset.Text='13:59 '+(T '6YeN572u');$harmonyPrimaryPercent.Text='83%';$harmonyPrimaryPercent.Foreground=New-Brush '#FFFFFF';$harmonyPrimaryBar.Width=110;$harmonyPrimaryBar.Background=New-Brush '#FFFFFF';$harmonySecondaryName.Text='7 '+(T '5aSp')+(T '5Ymp5L2Z');$harmonySecondaryPercent.Text='53%';$harmonySecondaryPercent.Foreground=New-Brush '#A99BFF';$harmonySecondaryReset.Text='9'+(T '5pyI')+'8'+(T '5pel')+(T '6YeN572u');$harmonyResetCredits.Text='1 '+(T '5qyh6YeN572u5py65Lya');$harmonyUpdated.Text='09:53 '+(T '5pu05paw')
  $harmonyGridUser.Text='Demo';$harmonyGridPrimaryIcon.Text='5h';$harmonyGridPrimaryPercent.Text='83%';$harmonyGridPrimaryPercent.Foreground=New-Brush '#0A84FF';$harmonyGridPrimaryInfo.Text='5'+(T '5bCP5pe2')+"`n13:59";$harmonyGridSecondaryIcon.Text='7d';$harmonyGridSecondaryPercent.Text='53%';$harmonyGridSecondaryPercent.Foreground=New-Brush '#A99BFF';$harmonyGridSecondaryInfo.Text='7'+(T '5aSp')+"`n9"+(T '5pyI')+'8'+(T '5pel');$harmonyGridCredits.Text='1 '+(T '5qyh6YeN572u5py65Lya');$harmonyGridUpdated.Text='09:53 '+(T '5pu05paw')
  $harmonyCapsuleUser.Text='Demo';$harmonyCapsulePrimaryIcon.Text='5h';$harmonyCapsulePrimaryName.Text=T '55+t5ZGo5pyf';$harmonyCapsulePrimaryReset.Text='13:59 '+(T '6YeN572u');$harmonyCapsulePrimaryPercent.Text='83%';$harmonyCapsuleSecondaryIcon.Text='7d';$harmonyCapsuleSecondaryName.Text=T '6ZW/5ZGo5pyf';$harmonyCapsuleSecondaryReset.Text='9'+(T '5pyI')+'8'+(T '5pel');$harmonyCapsuleSecondaryPercent.Text='53%';$harmonyCapsuleUpdated.Text='09:53 '+(T '5pu05paw')
  $harmonyArcUser.Text='Demo';$harmonyArcPercent.Text='83%';$harmonyArcPrimaryInfo.Text='5'+(T '5bCP5pe2')+' '+[char]0x00B7+' 83%';$harmonyArcSecondaryInfo.Text='7'+(T '5aSp')+' '+[char]0x00B7+' 53%';$harmonyArcUpdated.Text='09:53 '+(T '5pu05paw')
  $appleLiveMeta.Text='ChatGPT '+[char]0x00B7+' Demo';$appleLiveTime.Text='09:53 '+(T '5pu05paw');$appleLivePrimaryPercent.Text='83%';$appleLivePrimaryInfo.Text='5'+(T '5bCP5pe2')+' / 13:59';$appleLiveSecondaryPercent.Text='53%';$appleLiveSecondaryInfo.Text='7'+(T '5aSp')+' / 9'+(T '5pyI')+'8'+(T '5pel')
  $harmonyCapsulePrimaryPercent.Foreground=New-Brush '#0A84FF';$harmonyCapsuleSecondaryPercent.Foreground=New-Brush '#A99BFF';$harmonyArcPercent.Foreground=New-Brush '#0A84FF';Set-PieProgress $harmonyCapsulePrimarySlice 83 '#3F83F8';Set-PieProgress $harmonyCapsuleSecondarySlice 53 '#8C6BE8';Set-HarmonyArcProgress 83 '#4D7EF1';$bg.Opacity=1;[void]$window.Show()
  $previewDefinitions=@(@{style='default';index=0;name='default-d1'},@{style='default';index=1;name='default-d2'},@{style='apple';index=0;name='apple-a1'},@{style='apple';index=1;name='apple-a2'},@{style='apple';index=2;name='apple-a3'},@{style='apple';index=3;name='apple-a4'},@{style='harmony';index=0;name='harmony-h1'},@{style='harmony';index=1;name='harmony-h2'},@{style='harmony';index=2;name='harmony-h3'},@{style='harmony';index=3;name='harmony-h4'})
  foreach($previewMode in @('light','dark')){foreach($preview in $previewDefinitions){$script:appearanceStyle=$preview.style;$script:colorMode=$previewMode;$script:isDarkMode=($previewMode -eq 'dark');Apply-AppearanceStyle;$script:cardIndex=$preview.index;Apply-DisplayStyle;$window.UpdateLayout();$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap 175,190,96,96,([Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($window);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;[void]$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$previewName=$preview.name+'-'+$previewMode+'.png';$stream=[IO.File]::Open((Join-Path $env:CHATGPT_WIDGET_PREVIEW_DIR $previewName),[IO.FileMode]::Create);try{$encoder.Save($stream)}finally{$stream.Dispose()}}};$window.Hide()
 }
 $failed=@($results|Where-Object{-not($_.cards-and$_.gaugeMode-and$_.cornerRadius)});$passed=($styleMenu.Items.Count -eq 3)-and($colorModeMenu.Items.Count -eq 3)-and($menu.Style -eq $window.FindResource('RoundedContextMenu'))-and($lightText -ne $darkText)-and$progressPassed-and$timePassed-and$a4BlackOnly-and$edgeFramePassed-and($failed.Count -eq 0)
 [PSCustomObject]@{passed=$passed;styleMenuItems=$styleMenu.Items.Count;colorModeItems=$colorModeMenu.Items.Count;roundedMenu=$true;lightDark=($lightText-ne$darkText);progress=$progressPassed;timeFormat=$timePassed;a4BlackOnly=$a4BlackOnly;edgeFrame=$edgeFramePassed;styles=$results}|ConvertTo-Json -Depth 4
 $window.Close();if($passed){exit 0}else{exit 1}
}
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(10);$timer.Add_Tick({Update-Widget});Update-Widget;$timer.Start();[void]$window.ShowDialog()
