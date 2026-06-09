# Rawloom — developer tasks.
#
# The Simulator/Xcode targets reach Xcode.app through DEVELOPER_DIR so they work even when
# `xcode-select` points at the Command Line Tools (no sudo, no global switch).

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

SCHEME    ?= Rawloom
SIM_NAME  ?= iPhone 17

.PHONY: help build test test-sim test-sim-gpu boot-sim shutdown-sim screenshots xcgen app clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Build the algorithm core (macOS, fast sanity check — no Metal compile needed)
	swift build

test: ## Run unit tests on the host via SwiftPM (needs full Xcode toolchain for XCTest)
	swift test

test-sim: ## Run the FULL test suite on the iOS Simulator (primary correctness gate)
	SIM_NAME="$(SIM_NAME)" SCHEME="$(SCHEME)" scripts/test-sim.sh

test-sim-gpu: ## Run only the Metal/GPU pipeline tests on the Simulator
	SIM_NAME="$(SIM_NAME)" SCHEME="$(SCHEME)" scripts/test-sim.sh -only RawloomCoreTests/PipelineGPUTests

boot-sim: ## Boot the simulator (keeps it warm between runs)
	- xcrun simctl boot "$(SIM_NAME)" 2>/dev/null || true
	open -a Simulator

shutdown-sim: ## Shut the simulator down
	- xcrun simctl shutdown "$(SIM_NAME)" 2>/dev/null || true

screenshots: ## Capture pipeline-output screenshots from the app on the simulator
	SIM_NAME="$(SIM_NAME)" scripts/screenshots.sh

xcgen: ## Generate Rawloom.xcodeproj from project.yml (needs `brew install xcodegen`)
	xcodegen generate

app: xcgen ## Build the iOS app for the simulator
	xcodebuild build -scheme RawloomApp -destination 'platform=iOS Simulator,name=$(SIM_NAME)'

clean: ## Remove build artifacts
	swift package clean
	rm -rf .build/sim-tests.xcresult .build/screenshots Rawloom.xcodeproj
