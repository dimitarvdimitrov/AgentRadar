# Agent Instructions

## Repo Overview

- Native macOS menu bar app built with Xcode and SwiftUI.
- Main target: `AgentRadar`
- Project file: `AgentRadar.xcodeproj`

## Git Workflow

- The fork remote is `fork` and points at `dimitarvdimitrov/AgentRadar`.
- The default branch is `main`.
- When feature work should be merged into the fork, merge or fast-forward it into `fork/main`, push that branch, and leave the local checkout on `main`.
- After merging feature work, continue working from the default branch unless the user asks for a separate branch.

## Build

- Requires full Xcode, not just Command Line Tools.
- If Xcode has not been initialized yet, run:
  - `xcodebuild -runFirstLaunch`

- Build a local unsigned release app from the repo root:

```bash
xcodebuild -project AgentRadar.xcodeproj \
  -scheme AgentRadar \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

- Output app bundle:
  - `build/Build/Products/Release/AgentRadar.app`

## Run

- Launch the local build:
  - `open build/Build/Products/Release/AgentRadar.app`

## Install

- Install the local build into `/Applications`:

```bash
ditto build/Build/Products/Release/AgentRadar.app /Applications/AgentRadar.app
open /Applications/AgentRadar.app
```

## Notes

- No paid Apple developer account is required for the local build above.
- The project currently builds with `CODE_SIGNING_ALLOWED=NO`.
