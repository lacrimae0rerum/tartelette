# Tartelette — build, test and package the macOS companion app for Tart.

PROJECT        := Tartelette.xcodeproj
SCHEME         := Tartelette
CONFIGURATION ?= Release
DERIVED_DATA   := build/DerivedData
APP            := build/Tartelette.app
INSTALL_DIR   ?= /Applications
INSTALLED_APP  := $(INSTALL_DIR)/Tartelette.app

BRAND_ASSETS   := AppIcon.icon Assets.xcassets/Contents.json Assets.xcassets/AccentColor.colorset \
                  Assets.xcassets/MenuBarIcon.imageset Assets.xcassets/MenuBarIconActive.imageset \
                  Assets.xcassets/BrandMark.imageset

.PHONY: all assets check-assets test test-kit test-app build run install uninstall check-install-dir clean open

all: test build

## Regenerate the app icon, menu bar icons, accent colour and brand mark.
assets:
	swift Tools/BrandKit/render.swift "$(CURDIR)"

## Re-render the brand assets into a temporary folder and fail if they differ from the committed
## ones (the project itself is never touched).
check-assets:
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	swift Tools/BrandKit/render.swift "$$tmp" >/dev/null || exit 1; \
	status=0; \
	for item in $(BRAND_ASSETS); do \
		diff -r -q "$$tmp/Tartelette/$$item" "Tartelette/$$item" || status=1; \
	done; \
	if [ $$status -ne 0 ]; then \
		echo "Brand assets differ from Tools/BrandKit/render.swift: run 'make assets' and commit."; exit 1; \
	fi; \
	echo "Brand assets match Tools/BrandKit/render.swift."

## Run every test suite: the TarteletteKit package and the app target.
test: test-kit test-app

## Run the TarteletteKit unit tests.
test-kit:
	cd TarteletteKit && swift test

## Run the app target's unit tests.
test-app:
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) -quiet

## Build the app bundle into build/Tartelette.app.
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) -quiet build
	rm -rf $(APP)
	ditto "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Tartelette.app" "$(APP)"
	@echo "Built $(APP)"

## Build and launch.
run: build
	open "$(APP)"

## Refuse an empty or missing INSTALL_DIR (an empty value would target /Tartelette.app).
check-install-dir:
	@if [ -z "$(strip $(INSTALL_DIR))" ] || [ ! -d "$(INSTALL_DIR)" ]; then \
		echo "INSTALL_DIR must be an existing directory (got '$(INSTALL_DIR)')." >&2; exit 1; \
	fi

## Copy the app into $(INSTALL_DIR) (default /Applications). The new copy is staged next to the
## installed one and swapped in by rename, so a failed copy never leaves you without the app.
install: build check-install-dir
	@set -e; \
	staged="$(INSTALL_DIR)/.Tartelette.app.installing"; \
	previous="$(INSTALL_DIR)/.Tartelette.app.previous"; \
	rm -rf "$$staged" "$$previous"; \
	ditto "$(APP)" "$$staged"; \
	if [ -e "$(INSTALLED_APP)" ]; then mv "$(INSTALLED_APP)" "$$previous"; fi; \
	if mv "$$staged" "$(INSTALLED_APP)"; then \
		rm -rf "$$previous"; \
	else \
		[ -e "$$previous" ] && mv "$$previous" "$(INSTALLED_APP)"; \
		rm -rf "$$staged"; exit 1; \
	fi
	@echo "Installed to $(INSTALLED_APP)"

uninstall: check-install-dir
	rm -rf "$(INSTALLED_APP)"

## Open the project in Xcode.
open:
	open $(PROJECT)

clean:
	rm -rf build TarteletteKit/.build
