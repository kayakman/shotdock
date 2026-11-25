CONFIG        ?= debug
SIGN_IDENTITY ?= ShotDock Local Signing
APP           := build/ShotDock.app
BIN_DIR        = $(shell swift build -c $(CONFIG) --show-bin-path)

.PHONY: build app run test selftest signing-cert clean

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BIN_DIR)/ShotDock $(APP)/Contents/MacOS/ShotDock
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

signing-cert:
	scripts/make-signing-cert.sh

clean:
	rm -rf build .build
