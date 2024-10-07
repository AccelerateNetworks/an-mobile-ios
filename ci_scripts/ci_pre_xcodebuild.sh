#!/bin/sh

export POD_HOME=/Volumes/workspace/repository/Pods

echo "brew install cocoapods"
brew install cocoapods
echo "pod repo update"
pod repo update
echo "pod install"
pod install

#  ci_pre_xcodebuild.sh
#  linphone
#
#  Created by Kenny Stimson on 10/7/24.
#  
