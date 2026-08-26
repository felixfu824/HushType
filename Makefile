PRODUCT_NAME = HushType
APP_NAME = Lamitype
EXECUTABLE_NAME = Lamitype
ICON_NAME = Lamitype
BUILD_DIR = .build/release
BUNDLE_DIR = $(APP_NAME).app
SIGN_IDENTITY ?= -
DEVELOPER_IDENTITY = Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)
ENTITLEMENTS = Resources/Lamitype.entitlements

# OpenCC paths (Homebrew on Apple Silicon)
OPENCC_BIN = /opt/homebrew/bin/opencc
OPENCC_LIB_DIR = /opt/homebrew/lib
OPENCC_DATA_DIR = /opt/homebrew/share/opencc
MARISA_LIB_DIR = /opt/homebrew/opt/marisa/lib

.PHONY: build run bundle bundle-app bundle-dev bundle-release bundle-opencc \
	check-release-signing install install-bundle install-dev install-release \
	uninstall dmg dmg-dev dmg-release create-dmg clean l10n-verify l10n-verify-dest

L10N_LOCALES = en.lproj zh-Hant-TW.lproj
L10N_LEGACY_LOCALES = zh-Hant.lproj
L10N_SOURCE_MANIFEST = .build/l10n_source_manifest.json

l10n-verify:
	bash scripts/check_localizations.sh --source-manifest "$(L10N_SOURCE_MANIFEST)"

l10n-verify-dest:
	bash scripts/check_localizations.sh --dest "$(BUNDLE_DIR)/Contents/Resources" --source-manifest "$(L10N_SOURCE_MANIFEST)"

build:
	swift build -c release --disable-sandbox
	bash scripts/build_mlx_metallib.sh release
	@echo "Build complete: $(BUILD_DIR)/$(PRODUCT_NAME)"

run: build
	$(BUILD_DIR)/$(PRODUCT_NAME)

# Backward-compatible developer entry point. Release artifacts must use
# bundle-release with the explicitly pinned Developer ID identity.
bundle: bundle-dev

bundle-dev:
	@$(MAKE) bundle-app SIGN_IDENTITY=-

check-release-signing:
	@if [ -z "$(SIGN_IDENTITY)" ] || [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo "error: release signing requires SIGN_IDENTITY='$(DEVELOPER_IDENTITY)'" >&2; \
		exit 1; \
	fi
	@if [ "$(SIGN_IDENTITY)" != "$(DEVELOPER_IDENTITY)" ]; then \
		echo "error: refusing unpinned signing identity: $(SIGN_IDENTITY)" >&2; \
		exit 1; \
	fi

bundle-release: check-release-signing
	@$(MAKE) bundle-app SIGN_IDENTITY="$(SIGN_IDENTITY)"

# Assemble first, perform every binary mutation, then sign nested code and
# finally the app. Nothing may modify the bundle after the outer signature.
bundle-app: build l10n-verify
	@rm -rf "$(BUNDLE_DIR)"
	@mkdir -p "$(BUNDLE_DIR)/Contents/MacOS"
	@mkdir -p "$(BUNDLE_DIR)/Contents/Frameworks"
	@mkdir -p "$(BUNDLE_DIR)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(PRODUCT_NAME)" "$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)"
	@cp "$(BUILD_DIR)/mlx.metallib" "$(BUNDLE_DIR)/Contents/MacOS/"
	@cp Resources/Info.plist "$(BUNDLE_DIR)/Contents/"
	@cp "Resources/$(ICON_NAME).icns" "$(BUNDLE_DIR)/Contents/Resources/"
	@cp scripts/ios_server.py "$(BUNDLE_DIR)/Contents/Resources/"
	@for d in $(L10N_LOCALES) $(L10N_LEGACY_LOCALES); do rm -rf "$(BUNDLE_DIR)/Contents/Resources/$$d"; done
	@for d in $(L10N_LOCALES); do cp -R "Sources/HushType/Resources/$$d" "$(BUNDLE_DIR)/Contents/Resources/"; done
	@$(MAKE) l10n-verify-dest
	@# Strip and scrub developer paths before any signature is applied.
	@strip -S "$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)"
	@python3 -c "import pathlib; \
binary = pathlib.Path('$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)'); \
prefix = b'$(PWD)'; \
data = binary.read_bytes(); \
count = data.count(prefix); \
replacement = b'/redacted' + b'\x00' * (len(prefix) - 9); \
binary.write_bytes(data.replace(prefix, replacement)) if count else None; \
print(f'  Scrubbed {count} dev-path occurrence(s) from binary')"
	@# Embed the weak-linked Swift compatibility runtime for clean Macs.
	@xcrun swift-stdlib-tool --copy \
		--scan-executable "$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)" \
		--platform macosx \
		--destination "$(BUNDLE_DIR)/Contents/Frameworks"
	@install_name_tool -add_rpath "@executable_path/../Frameworks" "$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)"
	@otool -l "$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)" | \
		awk '/cmd LC_RPATH/{getline; getline; print $$2}' | \
		while IFS= read -r rpath; do \
			case "$$rpath" in *Xcode.app*) install_name_tool -delete_rpath "$$rpath" "$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)" ;; esac; \
		done
	@test -f "$(BUNDLE_DIR)/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
	@if otool -l "$(BUNDLE_DIR)/Contents/MacOS/$(EXECUTABLE_NAME)" | grep -q 'Xcode.app'; then \
		echo "error: Xcode runtime path leaked into bundled executable" >&2; \
		exit 1; \
	fi
	@$(MAKE) bundle-opencc
	@test -f "$(BUNDLE_DIR)/Contents/Resources/$(ICON_NAME).icns"
	@chmod -R u+w "$(BUNDLE_DIR)"
	@xattr -cr "$(BUNDLE_DIR)"
	@# Sign nested code with unique stable identifiers, then the app LAST.
	@for dylib in "$(BUNDLE_DIR)"/Contents/Frameworks/*.dylib; do \
		id="com.felix.hushtype.swift.$$(basename "$$dylib" .dylib)"; \
		if [ "$(SIGN_IDENTITY)" = "-" ]; then \
			codesign --force --sign - --identifier "$$id" "$$dylib"; \
		else \
			codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$$id" --options runtime --timestamp "$$dylib"; \
		fi; \
	done
	@for spec in \
		"libmarisa.0.dylib:com.felix.hushtype.libmarisa" \
		"libopencc.1.2.dylib:com.felix.hushtype.libopencc" \
		"opencc:com.felix.hushtype.opencc"; do \
		file=$${spec%%:*}; id=$${spec#*:}; path="$(BUNDLE_DIR)/Contents/MacOS/$$file"; \
		if [ "$(SIGN_IDENTITY)" = "-" ]; then \
			codesign --force --sign - --identifier "$$id" "$$path"; \
		else \
			codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$$id" --options runtime --timestamp "$$path"; \
		fi; \
	done
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		codesign --force --sign - --identifier "com.felix.hushtype" "$(BUNDLE_DIR)"; \
	else \
		codesign --force --sign "$(SIGN_IDENTITY)" --identifier "com.felix.hushtype" \
			--options runtime --timestamp --entitlements "$(ENTITLEMENTS)" "$(BUNDLE_DIR)"; \
	fi
	@for code in "$(BUNDLE_DIR)"/Contents/Frameworks/*.dylib \
		"$(BUNDLE_DIR)/Contents/MacOS/libmarisa.0.dylib" \
		"$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib" \
		"$(BUNDLE_DIR)/Contents/MacOS/opencc"; do \
		codesign --verify --strict "$$code"; \
	done
	@codesign --verify --deep --strict "$(BUNDLE_DIR)"
	@$(MAKE) l10n-verify-dest
	@echo "Bundle created: $(BUNDLE_DIR) (executable $(EXECUTABLE_NAME), identity $(SIGN_IDENTITY))"

bundle-opencc:
	@echo "Bundling OpenCC..."
	@mkdir -p "$(BUNDLE_DIR)/Contents/MacOS/opencc_data"
	@cp "$(OPENCC_BIN)" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@cp "$(OPENCC_LIB_DIR)/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/"
	@cp "$(MARISA_LIB_DIR)/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/"
	@cp "$(OPENCC_DATA_DIR)"/*.json "$(BUNDLE_DIR)/Contents/MacOS/opencc_data/"
	@cp "$(OPENCC_DATA_DIR)"/*.ocd2 "$(BUNDLE_DIR)/Contents/MacOS/opencc_data/"
	@install_name_tool -change "@rpath/libopencc.1.2.dylib" "@executable_path/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@install_name_tool -change "/opt/homebrew/opt/marisa/lib/libmarisa.0.dylib" "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@install_name_tool -change "/opt/homebrew/opt/marisa/lib/libmarisa.0.dylib" "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@install_name_tool -id "@executable_path/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@install_name_tool -id "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libmarisa.0.dylib"
	@echo "OpenCC bundled (binary + dylibs + data files; signing deferred)"

install: install-dev

install-dev:
	@$(MAKE) bundle-dev
	@$(MAKE) install-bundle

install-release: check-release-signing
	@$(MAKE) bundle-release SIGN_IDENTITY="$(SIGN_IDENTITY)"
	@$(MAKE) install-bundle

install-bundle:
	@killall HushType 2>/dev/null || true
	@killall Lamitype 2>/dev/null || true
	@rm -rf /Applications/HushType.app /Applications/Lamitype.app
	@cp -R "$(BUNDLE_DIR)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE_DIR)"
	@echo "You can now launch Lamitype from Spotlight (Cmd+Space -> Lamitype)"

uninstall:
	@killall HushType 2>/dev/null || true
	@killall Lamitype 2>/dev/null || true
	@rm -rf /Applications/HushType.app /Applications/Lamitype.app
	@echo "Uninstalled HushType and Lamitype from /Applications"

dmg: dmg-dev

dmg-dev:
	@$(MAKE) bundle-dev
	@$(MAKE) create-dmg

dmg-release: check-release-signing
	@$(MAKE) bundle-release SIGN_IDENTITY="$(SIGN_IDENTITY)"
	@$(MAKE) create-dmg

# Packaging only: the app's final signature is never modified here.
create-dmg:
	@rm -f "$(APP_NAME).dmg"
	@rm -rf dmg_staging
	@mkdir -p dmg_staging
	@cp -R "$(BUNDLE_DIR)" dmg_staging/
	@ln -s /Applications dmg_staging/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder dmg_staging -ov -format UDZO "$(APP_NAME).dmg"
	@rm -rf dmg_staging
	@echo "Created $(APP_NAME).dmg"

clean:
	swift package clean
	rm -rf HushType.app Lamitype.app HushType.dmg Lamitype.dmg dmg_staging
