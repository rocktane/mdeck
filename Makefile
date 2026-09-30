APP_NAME = mdeck
BUNDLE_ID = com.yohan.mdeck
APP_BUNDLE = build/$(APP_NAME).app
INSTALL_DIR = /Applications
CODESIGN_ID ?= mdeck Signing

.PHONY: all build debug cert icon install uninstall clean

all: build

## Native, signed build.
build:
	@CODESIGN_ID="$(CODESIGN_ID)" ./build.sh

## Native build with the debug flags compiled in.
debug:
	@CODESIGN_ID="$(CODESIGN_ID)" ./build.sh --debug

## One-time: the self-signed certificate that keeps the Accessibility grant across rebuilds.
cert:
	@./scripts/make-cert.sh "$(CODESIGN_ID)"

icon:
	@swift scripts/make-icon.swift Assets/icon-1024.png

install: build
	@pkill -x $(APP_NAME) 2>/dev/null && sleep 1 || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@"$(INSTALL_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" --restore 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@defaults delete $(BUNDLE_ID) >/dev/null 2>&1 || true
	@rm -rf "$(HOME)/Library/Application Support/mdeck"
	@tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true
	@echo "Uninstalled (app, preferences, Accessibility grant)."

clean:
	@rm -rf build
