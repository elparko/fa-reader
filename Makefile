build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open "build/FA Reader.app"

install: app
	rm -rf "/Applications/FA Reader.app"
	ditto "build/FA Reader.app" "/Applications/FA Reader.app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$(CURDIR)/build/FA Reader.app"; \
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/FA Reader.app"

dist: app
	rm -f "build/FA Reader.zip"
	ditto -c -k --keepParent "build/FA Reader.app" "build/FA Reader.zip"
	@echo "build/FA Reader.zip"

clean:
	rm -rf build .build

.PHONY: build test app run install dist clean
