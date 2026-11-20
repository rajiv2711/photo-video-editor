# Decisions

Locked 2026-11-18 · updated 2026-11-20 (iloader only; voice server address built in).

## Product
- iPad-only photo and video editor; iPad is non-negotiable.
- Free, with every feature unlocked.
- Agent-native: every touch or Pencil action can also be done by voice or typing.
- Commands name the control ("contrast more, more, more"); no intent-guessing ("make it warmer").
- Near-miss names are matched fuzzily; if two controls tie, the user picks one.
- Models stay lightweight and on-device: start bigger, shrink later.
- Sliders remain for trial-and-error fine-tuning.

## Stack
- Language and UI: Swift + SwiftUI (native app; no web app).
- Photo engine: Core Image (each filter lists its slider names and ranges).
- Video: AVFoundation + VideoToolbox.
- Pencil: PencilKit + Apple's touch APIs.
- Voice (development phase): iPad records a WAV clip → `voice-server/` on the laptop (Whisper large-v3-turbo, GPU) via ngrok → text → CommandEngine on the iPad. Plain HTTPS + bearer token, not MCP.
- Voice (long term): fully offline on the iPad: Apple on-device speech or a small trained model.
- Voice server address: the fixed ngrok domain is built into the app (`VoiceServerClient.defaultURL`), editable in Settings.
- Voice server security: token check off during development (`REQUIRE_TOKEN=false` in the local `.env`); to be added back later. A token, when used, lives in the app's Keychain, never in the repo or the build.
- Logic core (matcher, slider steps): Swift package `CommandEngine` in `command-engine/`, built and tested on Linux.
- Python: laptop tooling only (voice server, test harnesses, later model training).
- FilmCraft / PhotoCraft (storytold): design references, not code dependencies.

## Build and install
- Hardware: this Linux laptop + the iPad. Nothing else.
- Flow: laptop → push to GitHub → cloud Apple build server → unsigned `.ipa` → download on the laptop → iloader signs it with a free Apple ID and installs it over USB.
- iloader only; no SideStore (dropped 2026-11-20: its LocalDevVPN helper conflicts with other VPNs). Installs and updates happen with the iPad on the cable.
- Account: free Apple ID only. No App Store, no paid developer account.
- The Apple ID never goes to GitHub; signing happens on the laptop.

## Limits accepted
- Free-ID apps expire after 7 days; re-import the `.ipa` with iloader over USB once a week.
- About 3 sideloaded apps at once and about 10 new app IDs per week (commonly cited, not confirmed).
- Each change needs a cloud build of a few minutes.
- Developer Mode stays on (iPad Settings › Privacy & Security).

## Repo
- github.com/rajiv2711/photo-video-editor: public, for unlimited free cloud builds.
- License: MIT.
- Reports are HTML only, short, and git-ignored (`reports/`, `research_notes/`).

## Way of working
- Every iteration: one clear instruction → research and implementation structure → approval → implement → test on the laptop with visuals → commit, push and cloud build (only with approval).
- Feature work on a branch; merged to `main` once it works on the iPad.

## Decision log
- 2026-11-18 · iPad-only, free, agent-native editor; native Swift app; cloud build on GitHub; free Apple ID; public repo, MIT.
- 2026-11-18 · Commands name the control; lightweight models, start bigger and shrink later; reports are short HTML.
- 2026-11-19 · Repo layout by purpose (`ipad-app/`, `command-engine/`, `voice-server/`, `test-data/`, `dev-tools/`).
- 2026-11-19 · One JSON command format; parse (text → commands) and apply (commands → values) are separate; 134 test phrases, rule-parser baseline 81%.
- 2026-11-19 · Voice in development: iPad → laptop Whisper server over ngrok (plain HTTPS, not MCP); voice test 80% vs 85% typed, ~100 ms.
- 2026-11-20 · Signing uses a second free Apple ID, not the main one; iloader v2.4.2+ (Apple login change broke older versions).
- 2026-11-20 · SideStore dropped; iloader only, over USB.
- 2026-11-20 · ngrok address built into the app; voice-server token check off during development.
- 2026-11-20 · Pipeline verified end-to-end on the iPad (sliders, typing, voice). `setup-swift-app` merged into `main`. Focus moves to features.
