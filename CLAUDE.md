# Reroom (iOS)

SwiftUI app, iOS 17+. The Xcode project is generated from `project.yml` — never edit `.xcodeproj`.
Designs are SwiftData models synced via CloudKit: every stored property needs a default, no unique
constraints, relationships optional.

## Commands (macOS)
- Generate project: `xcodegen generate`
- Build, run and look at the simulator:
  ```bash
  SIM=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$SIM" 2>/dev/null; open -a Simulator
  xcodebuild -project Reroom.xcodeproj -scheme Reroom -destination "id=$SIM" -derivedDataPath build/DerivedData build -quiet
  xcrun simctl install "$SIM" build/DerivedData/Build/Products/Debug-iphonesimulator/Reroom.app
  xcrun simctl launch "$SIM" com.yegortr.reroom
  xcrun simctl io "$SIM" screenshot /tmp/reroom.png   # then read the PNG to see the screen
  ```
- Tests: `xcodebuild test -project Reroom.xcodeproj -scheme Reroom -destination "id=$SIM"`
- Physical iPhone: `./scripts/run-on-iphone.sh`
- Edge function typecheck: `deno check supabase/functions/generate/index.ts`

## Notes
- Supabase anon key lives in `Config/Secrets.xcconfig` (git-ignored). Never put the service_role or Runware key in the app.
- Backend: `supabase/migrations`, `supabase/functions/generate`.
