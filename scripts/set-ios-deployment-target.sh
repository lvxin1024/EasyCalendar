#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="${1:?iOS project directory is required}"
PROJECT_FILE="${IOS_DIR}/Runner.xcodeproj/project.pbxproj"
PODFILE="${IOS_DIR}/Podfile"

test -f "${PROJECT_FILE}"

sed -i.bak -E 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 14.0;/g' "${PROJECT_FILE}"
rm -f "${PROJECT_FILE}.bak"

if [[ -f "${PODFILE}" ]]; then
    sed -i.bak -E "s/^# ?platform :ios, '[^']+'/platform :ios, '14.0'/; s/^platform :ios, '[^']+'/platform :ios, '14.0'/" "${PODFILE}"
    rm -f "${PODFILE}.bak"
fi
