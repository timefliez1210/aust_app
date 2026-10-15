#!/bin/sh
# Raise the generated iOS project from Capacitor's default (15) to 16, which
# RoomPlan needs. Run after `npx cap add ios` and before `npx cap sync ios`:
# sync writes CapApp-SPM/Package.swift with the major version it reads from
# project.pbxproj, and a plugin package at .v16 fails against an app at .v15.
set -eu
pbx=ios/App/App.xcodeproj/project.pbxproj
perl -pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 16.0;/g' "$pbx"
grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;' "$pbx"
