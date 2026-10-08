# Tartelette — build, test and package the macOS companion app for Tart.

PROJECT        := Tartelette.xcodeproj
SCHEME         := Tartelette
CONFIGURATION ?= Release
DERIVED_DATA   := build/DerivedData
APP            := build/Tartelette.app
INSTALL_DIR   ?= /Applications

.PHONY: all assets test build run install uninstall clean open

all: test build

## Regenerate the app icon, menu bar icons, accent colour and brand mark.
assets:
	swift Tools/BrandKit/render.swift "$(CURDIR)"

## Run the TarteletteKit unit tests.
test:
	cd TarteletteKit && swift test

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

## Copy the app into $(INSTALL_DIR) (default /Applications).
install: build
	rm -rf "$(INSTALL_DIR)/Tartelette.app"
	ditto "$(APP)" "$(INSTALL_DIR)/Tartelette.app"
	@echo "Installed to $(INSTALL_DIR)/Tartelette.app"

uninstall:
	rm -rf "$(INSTALL_DIR)/Tartelette.app"

## Open the project in Xcode.
open:
	open $(PROJECT)

clean:
	rm -rf build TarteletteKit/.build
