# clear-history.ps1: the ready state starts with no history of the lab's own setup: the Run
# box's list and Explorer's recent items. setup-ready.sh runs it over SSH (as dev).
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU' -Recurse -Force -ErrorAction SilentlyContinue
$recent = "$env:APPDATA\Microsoft\Windows\Recent"
Get-ChildItem $recent, "$recent\AutomaticDestinations", "$recent\CustomDestinations" -File -Force -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
'history=' + @(Get-ChildItem $recent -File -ErrorAction SilentlyContinue).Count
