APP_NAME = VoxKey
BUILD_DIR = .build/release
BUNDLE_DIR = $(APP_NAME).app

.PHONY: build run bundle install uninstall clean

build:
	swift build -c release --disable-sandbox
	bash scripts/build_mlx_metallib.sh release
	@echo "Build complete: $(BUILD_DIR)/$(APP_NAME)"

run: build
	$(BUILD_DIR)/$(APP_NAME)

bundle: build
	@mkdir -p "$(BUNDLE_DIR)/Contents/MacOS"
	@mkdir -p "$(BUNDLE_DIR)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(BUNDLE_DIR)/Contents/MacOS/"
	@cp "$(BUILD_DIR)/mlx.metallib" "$(BUNDLE_DIR)/Contents/MacOS/" 2>/dev/null || true
	@cp Resources/Info.plist "$(BUNDLE_DIR)/Contents/"
	@cp scripts/ios_server.py "$(BUNDLE_DIR)/Contents/Resources/" 2>/dev/null || true
	@echo "Bundle created: $(BUNDLE_DIR)"

install: bundle
	@killall $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(BUNDLE_DIR)
	@cp -R "$(BUNDLE_DIR)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE_DIR)"
	@echo "You can now launch VoxKey from Spotlight (Cmd+Space → VoxKey)"

uninstall:
	@killall $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(BUNDLE_DIR)
	@echo "Uninstalled from /Applications"

clean:
	swift package clean
	rm -rf $(BUNDLE_DIR)
