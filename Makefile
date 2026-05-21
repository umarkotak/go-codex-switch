BIN_NAME := go-codex-switch
INSTALL_DIR := /usr/local/bin

.PHONY: run bin install uninstall

run:
	go run .

bin:
	go build -o $(BIN_NAME)

install: bin
	cp $(BIN_NAME) $(INSTALL_DIR)/$(BIN_NAME)

uninstall:
	rm -f $(INSTALL_DIR)/$(BIN_NAME)
