build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open "build/FA Reader.app"

clean:
	rm -rf build .build

.PHONY: build test app run clean
