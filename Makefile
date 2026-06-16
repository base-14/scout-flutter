.PHONY: ci analyze test format-check fmt get release

ci: get analyze format-check test

# Tag the current pubspec version and push it to trigger the
# "Publish to pub.dev" GitHub Actions workflow (.github/workflows/publish.yml).
release:
	@VERSION=$$(grep '^version:' pubspec.yaml | awk '{print $$2}'); \
	TAG="v$$VERSION"; \
	if [ -n "$$(git status --porcelain)" ]; then \
		echo "Working tree is dirty; commit or stash changes before releasing."; exit 1; \
	fi; \
	if git rev-parse "$$TAG" >/dev/null 2>&1; then \
		echo "Tag $$TAG already exists."; exit 1; \
	fi; \
	echo "Creating and pushing tag $$TAG ..."; \
	git tag -a "$$TAG" -m "Release $$TAG"; \
	git push origin "$$TAG"; \
	echo "Pushed $$TAG. Watch the publish workflow at https://github.com/base-14/scout-flutter/actions"

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
