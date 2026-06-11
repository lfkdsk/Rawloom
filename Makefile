# Rawloom — developer tasks.
#
# The Simulator/Xcode targets reach Xcode.app through DEVELOPER_DIR so they work even when
# `xcode-select` points at the Command Line Tools (no sudo, no global switch).

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

SCHEME    ?= Rawloom
SIM_NAME  ?= iPhone 17

.PHONY: help build test test-sim test-sim-gpu boot-sim shutdown-sim screenshots xcgen app devices device clean

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

devices: ## List connected iPhones/iPads (copy a UDID for `make device DEVICE_ID=…`)
	@xcrun xctrace list devices 2>/dev/null | sed -n '/== Devices ==/,/== Simulators ==/p' \
		| grep -Ev 'Simulator|MacBook|^== |^$$' || true

# Build, install & launch on a REAL iPhone (raw capture needs a device). Uses DEVICE_ID if set,
# else the first connected device. Needs your Team in signing (DEVELOPMENT_TEAM is set in project.yml).
device: xcgen ## Build+install+launch on a connected iPhone (optional DEVICE_ID=<udid>)
	@ID="$(DEVICE_ID)"; \
	if [ -z "$$ID" ]; then ID=$$(xcrun xctrace list devices 2>/dev/null \
		| grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' | head -1); fi; \
	if [ -z "$$ID" ]; then echo "No device found — plug in & unlock an iPhone, then \`make devices\`."; exit 1; fi; \
	echo "▸ device: $$ID"; \
	xcodebuild -scheme RawloomApp -destination "platform=iOS,id=$$ID" \
		-derivedDataPath .build/device-dd -allowProvisioningUpdates build; \
	APP=$$(/usr/bin/find .build/device-dd/Build/Products -maxdepth 3 -name 'RawloomApp.app' | head -1); \
	echo "▸ installing $$APP"; \
	xcrun devicectl device install app --device "$$ID" "$$APP"; \
	xcrun devicectl device process launch --device "$$ID" com.rawloom.app

clean: ## Remove build artifacts
	swift package clean
	rm -rf .build/sim-tests.xcresult .build/screenshots Rawloom.xcodeproj
