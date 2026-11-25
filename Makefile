CONFIG        ?= debug
SIGN_IDENTITY ?= ShotDock Local Signing
APP           := build/ShotDock.app
BIN_DIR        = $(shell swift build -c $(CONFIG) --show-bin-path)

.PHONY: build app run test selftest selftest-upload signing-cert icons clean

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BIN_DIR)/ShotDock $(APP)/Contents/MacOS/ShotDock
	xcrun actool Resources/Assets.xcassets --compile $(APP)/Contents/Resources \
		--platform macosx --minimum-deployment-target 15.0 \
		--app-icon AppIcon --accent-color AccentColor \
		--output-partial-info-plist build/assets-info.plist --errors --warnings >/dev/null
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier app.shotdock.ShotDock $(APP)
	@echo "Built $(APP)"

run: app
	-pkill -x ShotDock
	open $(APP)

test:
	swift test

# Runs a non-interactive check in the real app: capture (needs the Screen
# Recording permission), area or editor. Fails if the log has a FAIL line.
TEST ?= capture
selftest: app
	-pkill -x ShotDock
	rm -f build/selftest*.png build/selftest.log
	open -W -n $(APP) --args --selftest $(TEST) $(CURDIR)/build/selftest.png
	@cat build/selftest.log
	@! grep -q '^FAIL' build/selftest.log

icons:
	swift design/make-icons.swift

signing-cert:
	scripts/make-signing-cert.sh

clean:
	rm -rf build .build

# Upload selftest against the local mock S3 server.
selftest-upload: app
	@python3 -I scripts/mock-s3.py --port 9555 > build/mock-s3.log 2>&1 & echo $$! > build/mock-s3.pid; sleep 1; \
	$(MAKE) selftest TEST=upload; status=$$?; kill `cat build/mock-s3.pid`; rm -f build/mock-s3.pid; exit $$status
