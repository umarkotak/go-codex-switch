APP_NAME := Go Codex Bar

.PHONY: run test build package install uninstall reinstall clean

run:
	./Scripts/swift.sh run GoCodexBar --disable-sandbox

test:
	./Scripts/swift.sh build --disable-sandbox

build:
	./Scripts/swift.sh build -c release --disable-sandbox

package:
	./Scripts/package_app.sh

install: package
	./Scripts/install.sh

uninstall:
	./Scripts/uninstall.sh

reinstall: uninstall install

clean:
	./Scripts/swift.sh package clean --disable-sandbox
	rm -rf "dist/$(APP_NAME).app"
