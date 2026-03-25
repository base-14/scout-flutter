.PHONY: ci analyze test format-check fmt get

ci: get analyze format-check test

get:
	flutter pub get

analyze:
	flutter analyze

fmt:
	dart format .

format-check:
	dart format --set-exit-if-changed .

test:
	flutter test
