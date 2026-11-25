CONFIG        ?= debug
SIGN_IDENTITY ?= ShotDock Local Signing
APP           := build/ShotDock.app
BIN_DIR        = $(shell swift build -c $(CONFIG) --show-bin-path)

.PHONY: build app run test selftest selftest-upload selftest-cli install signing-cert icons clean

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Helpers
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BIN_DIR)/ShotDock $(APP)/Contents/MacOS/ShotDock
	cp $(BIN_DIR)/shotdock-cli $(APP)/Contents/Helpers/shotdock
	xcrun actool Resources/Assets.xcassets --compile $(APP)/Contents/Resources \
		--platform macosx --minimum-deployment-target 15.0 \
		--app-icon AppIcon --accent-color AccentColor \
		--output-partial-info-plist build/assets-info.plist --errors --warnings >/dev/null
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier app.shotdock.ShotDock.cli $(APP)/Contents/Helpers/shotdock
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
	rm -f build/selftest*.png build/selftest.log build/selftest.sock
	open -W -n $(APP) --args --selftest $(TEST) $(CURDIR)/build/selftest.png
	@cat build/selftest.log
	@! grep -q '^FAIL' build/selftest.log

icons:
	swift design/make-icons.swift

# Release build copied to /Applications (launch at login works best from there),
# with `shotdock` linked into /usr/local/bin (or ~/.local/bin).
CLI_LINK_DIR ?= $(shell [ -w /usr/local/bin ] && echo /usr/local/bin || echo $(HOME)/.local/bin)
install:
	$(MAKE) app CONFIG=release
	-pkill -x ShotDock
	rm -rf /Applications/ShotDock.app
	cp -R $(APP) /Applications/ShotDock.app
	mkdir -p $(CLI_LINK_DIR)
	ln -sf /Applications/ShotDock.app/Contents/Helpers/shotdock $(CLI_LINK_DIR)/shotdock
	@echo "shotdock -> $(CLI_LINK_DIR)/shotdock"
	open /Applications/ShotDock.app

signing-cert:
	scripts/make-signing-cert.sh

clean:
	rm -rf build .build

# Upload selftest against the local mock S3 server.
selftest-upload: app
	@python3 -I scripts/mock-s3.py --port 9555 > build/mock-s3.log 2>&1 & echo $$! > build/mock-s3.pid; sleep 1; \
	$(MAKE) selftest TEST=upload; status=$$?; kill `cat build/mock-s3.pid`; rm -f build/mock-s3.pid; exit $$status

# Every CLI and MCP selftest with the real `shotdock` binary. cli-capture needs
# the Screen Recording permission and an unlocked screen.
CLI_TESTS ?= cli mcp cli-history cli-edit cli-inspect cli-share cli-prefs cli-redact cli-capture
selftest-cli: app
	@failed=""; for t in $(CLI_TESTS); do \
		$(MAKE) --no-print-directory selftest TEST=$$t >/dev/null 2>&1; \
		echo "$$t: $$(grep -c '^OK' build/selftest.log) OK, $$(grep -c '^FAIL' build/selftest.log) FAIL"; \
		grep '^FAIL' build/selftest.log | sed 's/^/    /'; \
		grep -q '^FAIL' build/selftest.log && failed="$$failed $$t"; \
	done; [ -z "$$failed" ] || { echo "failed:$$failed"; exit 1; }
