SHELL := /bin/bash

PACKAGE_SCHEME := swift-networking-Package
DERIVED_DATA_PATH ?= .build/xcode/$(PLATFORM)

.PHONY: all help tools format lint build test platform-build hooks-install

all: lint build test

help:
	@printf '%s\n' \
		'make all              Run lint, build, and test.' \
		'make format           Apply the pinned SwiftFormat configuration.' \
		'make lint             Verify formatting and run SwiftLint.' \
		'make build            Build the package for the host platform.' \
		'make test             Run all package tests.' \
		'make platform-build   Build for a generic Apple platform destination.' \
		'make hooks-install    Install the tracked pre-commit hook for this checkout.'

tools:
	bash Scripts/swift-tools.sh bootstrap

format: tools
	bash Scripts/swift-tools.sh format

lint: tools
	git diff --check
	bash Scripts/swift-tools.sh lint

build:
	swift build

test:
	swift test

platform-build:
	@test -n "$(PLATFORM)" || (printf '%s\n' 'PLATFORM is required: iOS, macOS, tvOS, watchOS, or visionOS' >&2; exit 2)
	@case "$(PLATFORM)" in iOS|macOS|tvOS|watchOS|visionOS) ;; *) printf '%s\n' 'PLATFORM must be iOS, macOS, tvOS, watchOS, or visionOS' >&2; exit 2 ;; esac
	xcodebuild -scheme "$(PACKAGE_SCHEME)" \
		-destination "generic/platform=$(PLATFORM)" \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		build

hooks-install:
	git config --local core.hooksPath .githooks
	@printf '%s\n' 'Installed .githooks as the local hooks path.'
