#!/usr/bin/env bash
# Installs the eks-lab script, builds EKS Lab.app into ~/Applications and adds it to the Dock.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin" "$HOME/.config/eks-lab"
install -m 755 bin/eks-lab "$HOME/.local/bin/eks-lab"
if [ ! -f "$HOME/.config/eks-lab/config" ]; then
  install -m 600 config.example "$HOME/.config/eks-lab/config"
  echo "Created ~/.config/eks-lab/config: fill in your profile, cluster and URLs."
fi
./build.sh
APP="$HOME/Applications/EKS Lab.app"
if ! defaults read com.apple.dock persistent-apps | grep -q "EKS%20Lab"; then
  defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://${APP// /%20}/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
  killall Dock
  echo "Added EKS Lab to the Dock."
fi
