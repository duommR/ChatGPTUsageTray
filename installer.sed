[Version]
Class=IEXPRESS
SEDVersion=3

[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=Install ChatGPT Usage Widget?
DisplayLicense=
FinishMessage=ChatGPT Usage Widget installed successfully.
TargetName=C:\Users\git\AppData\Local\Temp\ChatGPTUsageWidget-Setup.exe
FriendlyName=ChatGPT Usage Widget Setup
AppLaunched=install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=install.cmd
UserQuietInstCmd=install.cmd
SourceFiles=SourceFiles

[SourceFiles]
SourceFiles0=.

[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=

[Strings]
FILE0=ChatGPTUsageWidget.ps1
FILE1=LaunchWidget.ps1
FILE2=config.example.json
FILE3=install.cmd
