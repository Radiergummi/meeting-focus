# Canonical tasks. The core and its tests are SwiftPM; the app is an Xcode target — this file is
# the one place both live.
#
# Steps are cached: each records what it verified, and re-running with no source change does
# nothing. `make -B <target>` forces a step anyway, and `make clean` discards every record.

# -destination names the Mac explicitly. Without it xcodebuild finds three matching destinations
# (arm64 / x86_64 / Any Mac), prints "WARNING: Using the first of multiple matching destinations"
# on every build, and picks arm64 — which is what this pins, so the flag silences the notice
# without changing what gets built.
#
# -derivedDataPath keeps products inside the repo. The default location is a per-project hashed
# directory, which every script then has to glob for; here the path is simply known.
XCODEBUILD_FLAGS = -project MeetingFocus.xcodeproj \
	-configuration Debug -derivedDataPath ./.build-xcode \
	-destination 'platform=macOS,arch=arm64' \
	-skipMacroValidation -skipPackagePluginValidation

# App Store Connect API key, if one is configured. Without it xcodebuild can only reach Apple
# through a logged-in Xcode GUI session, which lapses silently. .authkey.mk is gitignored and
# absent on a fresh clone, so -include keeps that clone building exactly as before.
-include .authkey.mk
ifdef ASC_KEY_ID
XCODEBUILD_FLAGS += -authenticationKeyPath $(ASC_KEY_PATH) \
	-authenticationKeyID $(ASC_KEY_ID) \
	-authenticationKeyIssuerID $(ASC_ISSUER_ID)
endif

# The declared languages, read from project.yml rather than restated here — the same rule the
# xcstrings tool and the localization tests follow, so there is one authority for the list.
LANGUAGES := $(shell awk '/knownRegions:/{f=1;next} f&&/^[[:space:]]*- /{print $$2;next} f{exit}' project.yml)

PRODUCTS = ./.build-xcode/Build/Products/Debug
APP = $(PRODUCTS)/MeetingFocus.app
BINARY = $(APP)/Contents/MacOS/MeetingFocus
PBXPROJ = MeetingFocus.xcodeproj/project.pbxproj

# The accessibility probe: a development tool, deliberately outside Sources/ because BUILD_SOURCES
# globs that directory — a probe there would trigger a full app rebuild on every probe edit.
AXPROBE = ./.build/axprobe
# BundleIdentifierResolver is compiled in rather than copied: CoreAudio reports Teams' helper
# process, and correlate's whole job is comparing the two tiers' idea of *which* app is capturing.
# A second copy of that normalisation would be free to drift from the one detection actually uses.
AXPROBE_SOURCES := $(shell find Tools/axprobe -type f -name '*.swift') \
	Sources/MeetingFocusApp/Detectors/BundleIdentifierResolver.swift

# The String Catalogue editor. LOCALIZATION_RULES lives under Tests/ and is compiled into BOTH this
# tool and the test target: reading project.yml's language lists and counting a catalogue's keys as
# the file spells them are rules the two must agree on, and one file is cheaper than the drift.
XCSTRINGS = ./.build/xcstrings
LOCALIZATION_RULES = Tests/LocalizationTests/LocalizationRules.swift
XCSTRINGS_SOURCES := $(shell find Tools/xcstrings -type f -name '*.swift') $(LOCALIZATION_RULES)

# Accessibility permission is granted per path *and* code signature, so a build run from
# .build-xcode needs its own grant and loses it on the next rebuild. Running the installed copy is
# what makes one grant hold, which is why `run` installs rather than launching in place.
INSTALLED_APP = /Applications/MeetingFocus.app

# Inputs, recomputed every invocation: a find over a few hundred paths costs milliseconds.
#
# Directories are prerequisites alongside files, because a stamp compares mtimes and a deleted file
# has none — but removing or adding one does bump its directory's mtime. That is what makes
# `make build` notice a file-set change and regenerate the project, whose failure mode is a stale
# .xcodeproj reporting "cannot find X in scope" and reading as a code error.
SWIFT_SOURCES := $(shell find Sources Tests Tools -type f -name '*.swift')
# Sources/MeetingFocusApp is an input even though `swift test` never COMPILES it: the localization
# tests read that tree and its .xcstrings to check that every rendered literal has a catalogue key and
# vice versa. Without it here, adding a literal to a view leaves this record valid and `make test`
# reports cached-green over a real failure. The cost is small for the same reason the trap is subtle —
# app sources are not compiled by the suite, so an app-only edit re-runs the tests without rebuilding.
TEST_INPUTS := Package.swift $(shell find Sources/MeetingFocusCore Tests ! -name '.*') \
	$(shell find Sources/MeetingFocusApp ! -name '.*')
# Resources/ is a signing and behaviour input: teams-markers.json is what detection matches on, so
# an edit there must invalidate the build even though no Swift file changed.
BUILD_SOURCES := $(shell find Sources/MeetingFocusApp Resources ! -name '.*')

.PHONY: help all test lint generate build axprobe xcstrings smoke install run release publish clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) \
		| sed 's/:.*##/\t/' \
		| awk -F'\t' '{ printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2 }'

all: lint test build smoke ## Check, test, build and verify the bundle — what CI checks, in CI's order

# A filtered run proves one test rather than the suite, so it deliberately records nothing:
# otherwise `make test FILTER=x && make test` would report a green suite that nobody ran.
test: ## Run the MeetingFocusCore suite (make test FILTER=testIdleToInMeeting)
ifeq ($(strip $(FILTER)),)
test: .make/test
else
test:
	@swift test --filter $(FILTER)
endif

lint: .make/lint ## Run SwiftLint as CI runs it

generate: $(PBXPROJ) ## Regenerate MeetingFocus.xcodeproj from project.yml

build: $(BINARY) ## Build MeetingFocus.app

axprobe: $(AXPROBE) ## Build the accessibility probe (dump / ids / watch / correlate)

xcstrings: $(XCSTRINGS) ## Build the String Catalogue editor (add/set/remove/rename/audit/fmt)

smoke: .make/smoke ## Verify the built bundle is intact and starts monitoring

$(AXPROBE): $(AXPROBE_SOURCES)
	@mkdir -p $(dir $@)
	@swiftc -O $(AXPROBE_SOURCES) -o $@
	@echo "ok: $@"

$(XCSTRINGS): $(XCSTRINGS_SOURCES)
	@mkdir -p $(dir $@)
	@swiftc -O $(XCSTRINGS_SOURCES) -o $@
	@echo "ok: $@"

.make/test: $(TEST_INPUTS) | .make
	@swift test
	@touch $@

.make/lint: $(SWIFT_SOURCES) .swiftlint.yml | .make
	@swiftlint lint --strict
	@touch $@

# XcodeGen skips the write when the generated project would be identical, so the touch is what
# stops every later make from regenerating it again.
$(PBXPROJ): project.yml Package.swift $(shell find Sources Resources -type d)
	@xcodegen generate
	@touch $@

# Touched for the same reason: an incremental build that changes only a resource leaves the binary
# alone, and without the touch that would never settle. Mtime is not part of a code signature, so
# this does not disturb signing.
$(BINARY): $(BUILD_SOURCES) $(PBXPROJ)
	@xcodebuild $(XCODEBUILD_FLAGS) -scheme MeetingFocus build
	@touch $@

# The app target has no unit tests — the logic worth testing is in the SwiftPM core — so proving
# the bundle is complete and actually reaches "monitoring started" is the only automated signal
# that the wiring is intact. Checks the two things that have silently broken before: Sparkle's SU*
# keys (dropped when they were INFOPLIST_KEY_* settings) and the markers resource (which failed to
# decode and fell back to hardcoded ids).
.make/smoke: $(BINARY) | .make
	@plist="$(APP)/Contents/Info.plist"; \
	for key in SUFeedURL SUPublicEDKey LSUIElement NSAppleEventsUsageDescription; do \
		/usr/libexec/PlistBuddy -c "Print :$$key" "$$plist" >/dev/null 2>&1 \
			|| { echo "missing Info.plist key: $$key"; exit 1; }; \
	done
	@test -f "$(APP)/Contents/Resources/teams-markers.json" || { echo "missing teams-markers.json"; exit 1; }
	@plutil -convert json -o /dev/null "$(APP)/Contents/Resources/teams-markers.json"
	@for lang in $(LANGUAGES); do \
		strings="$(APP)/Contents/Resources/$$lang.lproj/Localizable.strings"; \
		test -f "$$strings" \
			|| { echo "missing $$lang.lproj/Localizable.strings — the String Catalogue did not compile in"; exit 1; }; \
		plutil -convert json -o /dev/null "$$strings" || exit 1; \
	done
	@codesign --verify --strict "$(APP)"
	@"$(BINARY)" & pid=$$!; \
	sleep 6; \
	kill $$pid 2>/dev/null || true; \
	logged=$$(/usr/bin/log show --last 20s --info \
		--predicate 'subsystem == "me.mazetti.meetingfocus"' 2>/dev/null); \
	printf '%s' "$$logged" | grep -q "monitoring started" \
		|| { echo "the app did not report monitoring started"; exit 1; }; \
	if printf '%s' "$$logged" | grep -q "teams-markers.json missing or unreadable"; then \
		echo "the app fell back to built-in markers — the bundled catalogue did not load"; exit 1; \
	fi
	@echo "ok: bundle intact, markers and $(words $(LANGUAGES)) language(s) loaded, monitoring starts"
	@touch $@

# Order-only (the `|`): writing a record inside .make bumps the directory's own mtime, and as a
# normal prerequisite that would invalidate every other record.
.make:
	@mkdir -p $@

# Depends on the build rather than on all: reinstalling after a rebuild is a frequent chore, and
# making it run the whole suite first would get it avoided. Always copies — what sits in
# /Applications is not ours to cache.
install: $(BINARY) ## Replace /Applications/MeetingFocus.app with the built bundle
	@if pgrep -qx MeetingFocus; then \
		echo "MeetingFocus is running — run 'make run' instead, which quits it first."; \
		exit 1; \
	fi
	@rm -rf "$(INSTALLED_APP)"
	@ditto "$(APP)" "$(INSTALLED_APP)"
	@echo "installed: $(INSTALLED_APP)"

# The opposite prerequisite choice from install, on purpose: install is the frequent chore, run is
# the deliberate "look at the real thing" gesture, and the step cache makes a no-change run free.
#
# install is invoked from the recipe rather than listed as a prerequisite because the quit has to
# happen first, and prerequisites have no order among themselves. The quit is graceful and guarded
# by pgrep — asking a *non*-running app to quit launches it first, which would leave a copy of the
# old bundle running.
run: all ## Build, install and launch /Applications/MeetingFocus.app
	@if pgrep -qx MeetingFocus; then \
		echo "quitting the running MeetingFocus…"; \
		osascript -e 'quit app id "me.mazetti.meetingfocus"' >/dev/null 2>&1 || pkill -x MeetingFocus || true; \
		for _ in $$(seq 1 20); do pgrep -qx MeetingFocus || break; sleep 0.25; done; \
	fi
	@$(MAKE) --no-print-directory install
	@open "$(INSTALLED_APP)"
	@echo "launched. it is a menu bar app — look for the video icon."

release: ## Build a signed, notarized, stapled DMG and the signed appcast
	@./Scripts/release.sh

publish: ## Deploy the appcast, after verifying every advertised download resolves
	@./Scripts/publish-feed.sh

# Build products and step records only. Never touches $(INSTALLED_APP): `install` is the only path
# that writes it, and the Accessibility grant is attached to what lives there.
clean: ## Remove .build, .build-xcode and the cached step records
	@rm -rf .build .build-xcode .make
