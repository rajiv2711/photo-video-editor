# Decisions

Locked 2026-11-18.

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
- Token for the voice server: entered once in the app's Settings (Keychain); never in the repo or the build.
- Logic core (matcher, slider steps): Swift package `CommandEngine` in `command-engine/`, built and tested on Linux.
- Python: laptop tooling only (voice server, test harnesses, later model training).
- FilmCraft / PhotoCraft (storytold): design references, not code dependencies.

## Build and install
- Hardware: this Linux laptop + the iPad. Nothing else.
- Flow: laptop → push to GitHub → cloud Apple build server → unsigned `.ipa` → iloader (or Sideloader) on Linux signs with a free Apple ID → USB → iPad.
- SideStore on the iPad re-signs the app every 7 days over Wi-Fi.
- Account: free Apple ID only. No App Store, no paid developer account.
- The Apple ID never goes to GitHub; signing happens on the laptop.

## Limits accepted
- Free-ID apps expire after 7 days; SideStore re-signs them.
- About 3 sideloaded apps at once and about 10 new app IDs per week (commonly cited, not confirmed).
- Each change needs a cloud build of a few minutes.
- Developer Mode stays on (iPad Settings › Privacy & Security).

## Repo
- github.com/rajiv2711/photo-video-editor: public, for unlimited free cloud builds.
- License: MIT.
- Reports are HTML only, short, and git-ignored (`reports/`, `research_notes/`).
