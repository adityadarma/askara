## Install

1. Download `Askara-<version>-universal.zip` (works on Apple Silicon and Intel).
2. Unzip it and move `Askara.app` to the Applications folder.

## First launch

Askara is not notarized by Apple, so macOS blocks the first launch. Do one of these once:

- **System Settings:** open Askara and click Done on the warning. Then open System Settings > Privacy & Security, scroll down, and click Open Anyway.
- **Terminal:** `xattr -dr com.apple.quarantine /Applications/Askara.app`

In-app updates are not affected.

