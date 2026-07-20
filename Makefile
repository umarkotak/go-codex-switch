BIN_NAME := go-codex-switch
INSTALL_DIR := /usr/local/bin
BAR_DIR := go-codex-bar
BAR_APP_NAME := Go Codex Bar

.PHONY: run bin install uninstall reinstall \
	bar-run bar-test bar-build bar-package bar-install bar-uninstall bar-reinstall bar-clean

run:
	go run .

bin:
	go build -o $(BIN_NAME)

install: bin
	cp $(BIN_NAME) $(INSTALL_DIR)/$(BIN_NAME)

uninstall:
	rm -f $(INSTALL_DIR)/$(BIN_NAME)

reinstall:
	$(MAKE) uninstall
	$(MAKE) install

bar-run:
	cd $(BAR_DIR) && ./Scripts/swift.sh run GoCodexBar --disable-sandbox

bar-test:
	cd $(BAR_DIR) && ./Scripts/swift.sh build --disable-sandbox

bar-build:
	cd $(BAR_DIR) && ./Scripts/swift.sh build -c release --disable-sandbox

bar-package:
	cd $(BAR_DIR) && ./Scripts/package_app.sh

bar-install: bar-package
	cd $(BAR_DIR) && ./Scripts/install.sh

bar-uninstall:
	cd $(BAR_DIR) && ./Scripts/uninstall.sh

bar-reinstall:
	$(MAKE) bar-uninstall
	$(MAKE) bar-install

bar-clean:
	cd $(BAR_DIR) && ./Scripts/swift.sh package clean --disable-sandbox
	rm -rf "$(BAR_DIR)/dist/$(BAR_APP_NAME).app"
