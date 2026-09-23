.PHONY: generate build test run clean

XCODEBUILD = xcodebuild -project ShotDrop.xcodeproj -scheme ShotDrop -configuration Debug -derivedDataPath build

generate:
	xcodegen generate

build: generate
	$(XCODEBUILD) build

test: generate
	$(XCODEBUILD) -destination 'platform=macOS' test

run: build
	open build/Build/Products/Debug/ShotDrop.app

# Only generated build products in this repository; source and project stay intact.
clean:
	/bin/rm -rf "$(CURDIR)/build"
