.PHONY: build run clean

# Debug build
build:
	swift build

# Debug build + run
run:
	swift run

# Clean build artifacts
clean:
	swift package clean
	rm -rf build/
