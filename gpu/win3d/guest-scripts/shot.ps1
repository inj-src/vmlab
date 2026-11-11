# shot.ps1: save the desktop to C:\vmlab\gpu\shot.png. Run it in the desktop session (run-interactive.ps1).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
[System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen(0, 0, 0, 0, $bmp.Size)
$bmp.Save('C:\vmlab\gpu\shot.png')
"$($b.Width)x$($b.Height)"
