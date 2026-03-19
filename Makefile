.PHONY: dev test release-artifacts xcodeproj clean version bump-build bump-patch bump-minor bump-major set-version set-build

dev: FreeFlow.xcodeproj
	./scripts/build_dev.sh

test: FreeFlow.xcodeproj
	xcodebuild \
		-project FreeFlow.xcodeproj \
		-scheme "FreeFlow Dev" \
		-configuration Debug \
		-derivedDataPath build/DerivedDataTests \
		test

release-artifacts: FreeFlow.xcodeproj
	./scripts/archive_release.sh
	./scripts/package_dmg.sh

version:
	./scripts/version.sh

bump-build:
	./scripts/bump_version.sh build

bump-patch:
	./scripts/bump_version.sh patch

bump-minor:
	./scripts/bump_version.sh minor

bump-major:
	./scripts/bump_version.sh major

set-version:
ifndef VERSION
	$(error VERSION is required, for example: make set-version VERSION=0.2.0)
endif
	./scripts/bump_version.sh set-version $(VERSION)

set-build:
ifndef BUILD
	$(error BUILD is required, for example: make set-build BUILD=42)
endif
	./scripts/bump_version.sh set-build $(BUILD)

xcodeproj: project.yml scripts/generate_xcodeproj.rb
	./scripts/generate_xcodeproj.rb

clean:
	rm -rf build
