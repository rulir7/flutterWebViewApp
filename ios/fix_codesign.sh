#!/bin/bash

# Clean the build directory
rm -rf ../build/ios

# Clean Xcode's derived data (this helps resolve many Xcode build issues)
rm -rf ~/Library/Developer/Xcode/DerivedData

# Kill any stuck Xcode processes
killall -9 Xcode
killall -9 com.apple.dt.Xcode.InstallService
killall -9 com.apple.dt.Xcode.BuildService

# Wait a moment for processes to terminate
sleep 2

# Run Flutter clean
cd ..
/Users/williamwarwenczack/flutter/bin/flutter clean

# Get dependencies
/Users/williamwarwenczack/flutter/bin/flutter pub get

# Install pods
cd ios
pod install

# Build using xcodebuild with manual signing
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  DEVELOPMENT_TEAM=3RHG2Z36NY \
  CODE_SIGN_IDENTITY="Apple Development: warwenczack@live.com (3RHG2Z36NY)" \
  CODE_SIGN_STYLE=Manual \
  PROVISIONING_PROFILE_SPECIFIER="" \
  -allowProvisioningUpdates 

echo "✅ Cleanup complete. Please open Xcode now with:"
echo "open Runner.xcworkspace"
echo "Then try building again." 