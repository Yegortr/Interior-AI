# Reroom (working name)

Native iOS app (SwiftUI, iOS 17+) that redesigns a photographed room in a chosen interior style.
No accounts, no web version: designs live on the device (SwiftData) and sync through the user's
private iCloud. A small Supabase backend holds the Runware API key and runs the generations.

## Run it

```bash
./scripts/run-on-iphone.sh        # builds, installs and launches on a connected iPhone (or offers the simulator)
```
The script asks once for the Supabase **anon** key (never the service_role key) and stores it in the
git-ignored `Config/Secrets.xcconfig`. Manual route: `xcodegen generate && open Reroom.xcodeproj`.

## Backend setup (once)

1. Create a new Supabase project.
2. **Authentication → Sign In / Providers → enable "Anonymous sign-ins".**
3. Apply the schema and deploy the function (Supabase CLI):
   ```bash
   supabase link --project-ref <ref>
   supabase db push
   supabase secrets set RUNWARE_API_KEY=<your Runware key>
   supabase functions deploy generate
   ```
   Optional secrets: `RUNWARE_MODEL` (default `google:4@1`, Nano Banana), `DAILY_LIMIT` (default 30).

## How it works

```
Create flow ──► Design (SwiftData, status .submitting) ──► upload photo to Storage "uploads/<uid>/…"
            ──► Edge Function `generate` ──► row in generation_jobs + background Runware call
GenerationCoordinator polls generation_jobs (only while something is pending)
            ──► downloads result_url ──► stores it in the Design ──► iCloud syncs it
```

* **No login:** an invisible anonymous Supabase user per install (session in the Keychain) gives
  the backend a user id for row-level security and the daily limit.
* **Zero layout shift:** 2-column gallery cells are always 3:4; 1-column cells use the design's
  ratio (the photo's, then the real result's), so placeholders already have the final shape.
* **Timeouts:** `stale` after 4 min (still polled, retry offered), `failed` after 10 min.
* **Detail:** before/after slider, UIKit fullscreen viewer (pinch to 5×, double-tap 2.5×,
  drag to dismiss), save to Photos, share, Make Changes (edits the result).

## Layout
```
Reroom/App            entry, model container, root/onboarding gate
Reroom/Core           models (SwiftData Design, options), generation (API, coordinator, prompts), utilities
Reroom/DesignSystem   theme and shared components
Reroom/Features       Onboarding, Gallery, Create, Detail, Settings
supabase/             migration + `generate` edge function
```

## Not yet
Paywall/StoreKit, App Attest, push notification when a design finishes, storage cleanup job.
