APP_NAME = HushType
BUILD_DIR = .build/release
BUNDLE_DIR = $(APP_NAME).app

# OpenCC paths (Homebrew on Apple Silicon)
OPENCC_BIN = /opt/homebrew/bin/opencc
OPENCC_LIB_DIR = /opt/homebrew/lib
OPENCC_DATA_DIR = /opt/homebrew/share/opencc
MARISA_LIB_DIR = /opt/homebrew/opt/marisa/lib

.PHONY: build run bundle bundle-opencc install uninstall dmg clean

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
	@cp Resources/HushType.icns "$(BUNDLE_DIR)/Contents/Resources/" 2>/dev/null || true
	@cp scripts/ios_server.py "$(BUNDLE_DIR)/Contents/Resources/" 2>/dev/null || true
	@$(MAKE) bundle-opencc
	@echo "Bundle created: $(BUNDLE_DIR)"

bundle-opencc:
	@echo "Bundling OpenCC..."
	@mkdir -p "$(BUNDLE_DIR)/Contents/MacOS/opencc_data"
	@# Copy opencc binary
	@cp "$(OPENCC_BIN)" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@# Copy dylibs
	@cp "$(OPENCC_LIB_DIR)/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/"
	@cp "$(MARISA_LIB_DIR)/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/"
	@# Copy data files (dictionaries + configs)
	@cp "$(OPENCC_DATA_DIR)"/*.json "$(BUNDLE_DIR)/Contents/MacOS/opencc_data/"
	@cp "$(OPENCC_DATA_DIR)"/*.ocd2 "$(BUNDLE_DIR)/Contents/MacOS/opencc_data/"
	@# Rewrite dylib paths to use @executable_path
	@install_name_tool -change "@rpath/libopencc.1.2.dylib" "@executable_path/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@install_name_tool -change "/opt/homebrew/opt/marisa/lib/libmarisa.0.dylib" "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@install_name_tool -change "/opt/homebrew/opt/marisa/lib/libmarisa.0.dylib" "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@# Fix libopencc's own id
	@install_name_tool -id "@executable_path/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@install_name_tool -id "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libmarisa.0.dylib"
	@# Re-sign after install_name_tool — modifying load commands invalidates the
	@# original Homebrew adhoc signature, and macOS Sequoia kills processes with
	@# invalid signatures (SIGKILL, no error). Without this step, the bundled
	@# opencc fails silently and ChineseConverter falls back to returning the
	@# input unchanged. Both `make install` and `make dmg` need this.
	@codesign --force --sign - "$(BUNDLE_DIR)/Contents/MacOS/libmarisa.0.dylib"
	@codesign --force --sign - "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@codesign --force --sign - "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@echo "OpenCC bundled (binary + dylibs + data files, re-signed)"

install: bundle
	@killall $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(BUNDLE_DIR)
	@cp -R "$(BUNDLE_DIR)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE_DIR)"
	@echo "You can now launch HushType from Spotlight (Cmd+Space → HushType)"

uninstall:
	@killall $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(BUNDLE_DIR)
	@echo "Uninstalled from /Applications"

dmg: bundle
	@# OpenCC binaries are already signed in bundle-opencc; just sign the outer bundle.
	@echo "Signing app bundle..."
	@codesign --force --deep --sign - "$(BUNDLE_DIR)"
	@rm -f $(APP_NAME).dmg
	@mkdir -p dmg_staging
	@cp -R "$(BUNDLE_DIR)" dmg_staging/
	@ln -s /Applications dmg_staging/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder dmg_staging -ov -format UDZO "$(APP_NAME).dmg"
	@rm -rf dmg_staging
	@echo "Created $(APP_NAME).dmg"

clean:
	swift package clean
	rm -rf $(BUNDLE_DIR) $(APP_NAME).dmg
