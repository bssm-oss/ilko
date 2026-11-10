PROJECT        = LiveWallpaper.xcodeproj
SCHEME         = LiveWallpaper
CONFIG         = Debug
CONFIG_RELEASE = Release
BUILD_DIR      = $(PWD)/.build
APP            = $(BUILD_DIR)/Build/Products/$(CONFIG)/ILKO.app
APP_RELEASE    = $(BUILD_DIR)/Build/Products/$(CONFIG_RELEASE)/ILKO.app
VERSION       ?= 1.3.3
DMG_NAME       = ILKO-$(VERSION).dmg
DMG_DIR        = $(PWD)/dist

XCODE_FLAGS = \
	CODE_SIGN_IDENTITY="-" \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGNING_ALLOWED=NO

.PHONY: build run log clean submodule release dmg test-lockscreen typecheck

## 서브모듈 초기화 (최초 1회)
submodule:
	git submodule update --init --recursive

## 빌드만 (Debug)
build: submodule
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		$(XCODE_FLAGS) \
		build

## 빌드 후 바로 실행 (메뉴바에 아이콘 뜨면 성공)
run: build
	open "$(APP)"

## 빌드 후 터미널에서 직접 실행 (로그 출력)
log: build
	"$(APP)/Contents/MacOS/ILKO"

## 릴리즈 빌드 (Release, 서명 없음)
release: submodule
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG_RELEASE) \
		-derivedDataPath $(BUILD_DIR) \
		$(XCODE_FLAGS) \
		build

## DMG 패키징 (make dmg VERSION=2.3)
dmg: release
	mkdir -p "$(DMG_DIR)"
	rm -rf /tmp/dmg-staging
	mkdir -p /tmp/dmg-staging
	cp -R "$(APP_RELEASE)" "/tmp/dmg-staging/ILKO.app"
	ln -s /Applications "/tmp/dmg-staging/Applications"
	hdiutil create \
		-volname "ILKO" \
		-srcfolder /tmp/dmg-staging \
		-ov \
		-format UDZO \
		"$(DMG_DIR)/$(DMG_NAME)"
	rm -rf /tmp/dmg-staging
	@echo "✅ DMG 생성 완료: $(DMG_DIR)/$(DMG_NAME)"

## 잠금화면(Aerial) 코어 테스트 — Xcode 없이 swiftc 로 빌드·실행
SWIFT_SDK      = $(shell xcrun --show-sdk-path)
SWIFT_FLAGS    = -sdk $(SWIFT_SDK) -target arm64-apple-macos26.1 -swift-version 6 -default-isolation MainActor
LOCKSCREEN_SRC = LockScreen/AerialCatalog.swift LockScreen/AerialEncoder.swift LockScreen/LockScreenSlot.swift
TEST_BIN       = build/lockscreen-tests/runner

test-lockscreen:
	mkdir -p build/lockscreen-tests
	swiftc $(SWIFT_FLAGS) -O $(wildcard $(LOCKSCREEN_SRC)) LockScreenTests/*.swift -o $(TEST_BIN)
	./$(TEST_BIN)

## 앱 Swift 소스 타입체크 (VideoGridView 의 SwiftUIMacros 오류는 CLT 한계로 무시)
typecheck:
	swiftc -typecheck $(SWIFT_FLAGS) -cxx-interoperability-mode=default \
		-import-objc-header LiveWallpaper-Bridging-Header.h -I . *.swift LockScreen/*.swift 2>&1 \
		| grep -E "error:" | grep -v "SwiftUIMacros\|VideoGridView.swift" ; \
		test $$? -eq 1 && echo "typecheck OK (baseline VideoGridView macro errors ignored)"

## 빌드 결과물 삭제
clean:
	rm -rf $(BUILD_DIR)
