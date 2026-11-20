# photo-video-editor

A free iPad photo and video editor you can drive by name: type or say
"contrast more, more, more" and the Contrast slider moves. Sliders stay for fine-tuning.

License: [MIT](LICENSE)

## What is where

| Folder | What it does |
|---|---|
| [`ipad-app/`](ipad-app) | The iPad app (SwiftUI): photo canvas, sliders, command bar. `project.yml` is the recipe the cloud build turns into an Xcode project. |
| [`command-engine/`](command-engine) | Turns words into slider changes: the control list (`controls.json`), parser, name matcher. Used by the app; also builds and tests on Linux. |
| [`command-engine/Sources/command-scorer/`](command-engine/Sources/command-scorer) | Scores the parser against the test phrases. |
| [`voice-server/`](voice-server) | Laptop server for development: the iPad sends a voice clip, Whisper returns the text. Reached through ngrok. |
| [`test-data/photos/`](test-data/photos) | The test photo, used by the app as its default image and by the reports. |
| [`test-data/phrases/`](test-data/phrases) | Test phrases with the commands each should produce (`commands.jsonl`). |
| [`test-data/gallery/`](test-data/gallery) | Render test cases (`gallery.json`): a command per operation and the change it must cause. |
| [`docs/FEATURES.md`](docs/FEATURES.md) | Feature checklist: every planned photo operation, ticked when built. |
| [`dev-tools/`](dev-tools) | Laptop scripts: `make_report.py` (parser report), `voice_test.py` (speech → server → parser report), `ci_results.py` (cloud render checks). |
| [`.github/workflows/`](.github/workflows) | Cloud build: Linux tests → unsigned `.ipa` + iPad simulator render gallery and screenshots (feature branches publish them to `ci-renders`). |
| `reports/`, `research_notes/` | Local only, git-ignored. |

## How a command flows
```
voice (iPad mic) → voice-server on the laptop (Whisper) → text   ┐
typed text ──────────────────────────────────────────────────────┴→
"contrast more more more"
   → parser (command-engine)  → {"op":"nudge","control":"contrast","steps":3}
   → applier (command-engine) → Contrast 0 → 15
   → PhotoRenderer (ipad-app) → Core Image redraws the photo
```

## Test on the laptop
```sh
# unit tests + parser score (Swift in Docker)
docker run --rm -v "$PWD":/src -w /src swift:6.2 bash -c \
  "swift test --package-path command-engine && \
   swift run --package-path command-engine command-scorer test-data/phrases/commands.jsonl --out reports/parser/results.json"
# HTML report with before/after photos
python3 dev-tools/make_report.py reports/parser/results.json
```

## Test the photo operations (cloud renders)
Every push of a feature branch renders each case in `test-data/gallery/gallery.json` on an iPad
simulator (`-renderGallery`) and publishes the pictures to the `ci-renders` branch.
```sh
python3 dev-tools/ci_results.py --wait   # waits for HEAD's build, checks every case → "reports/Operation test report.html"
```

## Voice server (laptop)
```sh
uv run --project voice-server voice-server/server.py      # first run creates the token in voice-server/.env
ngrok http 8765 --url=<your ngrok domain>                 # in another terminal
uv run --project voice-server pytest voice-server -q      # API tests
uv run --project voice-server dev-tools/voice_test.py     # synthetic voices → "reports/Voice test report.html"
uv run --project voice-server dev-tools/voice_test.py --record --mic plughw:2,0   # your own voice
```
On the iPad: Settings (gear) → paste the ngrok address and the token → Test connection.

## Install on the iPad (free Apple ID, no App Store)
1. Push to GitHub. Open the latest **Build** run under Actions and download `PhotoVideoEditor-ipa`; unzip it.
2. Connect the iPad by USB and open [iloader](https://github.com/nab138/iloader) on Linux (signed in with the free Apple ID).
3. iloader → **Import IPA** → `PhotoVideoEditor.ipa`.
4. First time only: on the iPad, trust the Apple ID (Settings › General › VPN & Device Management) and turn on Developer Mode (Settings › Privacy & Security).
5. The app expires after 7 days: re-import it with iloader once a week.

## Commands
| Say or type | Result |
|---|---|
| `contrast more more more` | Contrast +15 (3 steps) |
| `more` / `less` | Repeats on the last control named or touched |
| `exposure 0.5` · `contrast up by 20` | Set to a value · change by an amount |
| `saturation less exposure more` | Several controls at once |
| `contrast reset` · `reset all` | Back to defaults |
| `contrst more` · `colour down` | Typos and synonyms are matched |
