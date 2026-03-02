#!/bin/bash

# SyncCloud Build Script
# This script builds and optionally runs the SyncCloud macOS app

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building SyncCloud macOS App...${NC}"

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}Error: xcodebuild not found. Please install Xcode Command Line Tools.${NC}"
    exit 1
fi

# Clean up old build files
rm -rf ./build

# Generate Xcode project
echo -e "${YELLOW}Generating Xcode project...${NC}"
xcodegen generate

# Build the project
echo -e "${YELLOW}Compiling project...${NC}"
xcodebuild -project SyncCloud.xcodeproj -scheme SyncCloud -configuration Debug -derivedDataPath ./build build

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Build successful!${NC}"
    
    if [ "$1" = "--run" ]; then
        echo -e "${YELLOW}Running SyncCloud...${NC}"
        open build/Build/Products/Debug/SyncCloud.app
    else
        echo -e "${YELLOW}To run the app, use: ./build.sh --run${NC}"
    fi
else
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi 