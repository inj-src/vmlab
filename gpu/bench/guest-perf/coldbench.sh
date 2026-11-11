#!/bin/sh
# coldbench.sh: cold launches (file cache emptied before each), warm launches, uncached random reads
cd "$HOME"
F=$(ls /Applications/Google\ Chrome.app/Contents/Frameworks/*/Versions/*/Google\ Chrome\ Framework | head -1)
for a in /System/Applications/Calculator.app /Applications/Safari.app "/Applications/Google Chrome.app" "/Applications/Visual Studio Code.app" "/System/Applications/System Settings.app"; do
  sudo purge; sleep 1; echo "cold $(./launchtime "$a" 1)"
done
echo "warm $(./launchtime /Applications/Safari.app 3)"
sudo purge; python3 randread.py "$F"
cat "$F" > /dev/null; /usr/bin/time sha256sum "$F" 2>&1 | tail -1
