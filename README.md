# photo-video-editor

A free iPad photo and video editor you can drive by name: type or say
"contrast more, more, more" and the Contrast slider moves. Sliders stay for fine-tuning.

Decisions: [DECISIONS.md](DECISIONS.md) · License: [MIT](LICENSE)

## What is where

| Folder | What it does |
|---|---|
| [`ipad-app/`](ipad-app) | The iPad app (SwiftUI): photo canvas, sliders, command bar. `project.yml` is the recipe the cloud build turns into an Xcode project. |
| [`command-engine/`](command-engine) | Turns words into slider changes: the control list (`controls.json`), parser, name matcher. Used by the app; also builds and tests on Linux. |
| [`command-engine/Sources/command-scorer/`](command-engine/Sources/command-scorer) | Scores the parser against the test phrases. |
| [`test-data/photos/`](test-data/photos) | The test photo, used by the app as its default image and by the reports. |
| [`test-data/phrases/`](test-data/phrases) | Test phrases with the commands each should produce (`commands.jsonl`). |
| [`dev-tools/`](dev-tools) | Laptop scripts, e.g. `make_report.py` builds the HTML report. |
| [`.github/workflows/`](.github/workflows) | Cloud build: Linux tests → unsigned `.ipa` + iPad simulator screenshots. |
| `reports/`, `research_notes/` | Local only, git-ignored. |

## How a command flows
```
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

## Install on the iPad (free Apple ID, no App Store)
1. Push to GitHub. Open the latest **Build** run under Actions and download `PhotoVideoEditor-ipa`.
2. Turn on Developer Mode on the iPad: Settings › Privacy & Security › Developer Mode.
3. Install [iloader](https://github.com/nab138/iloader) on Linux, connect the iPad by USB and install SideStore with your Apple ID.
4. Unzip the artifact and install `PhotoVideoEditor.ipa` with iloader, or open it in SideStore.
5. SideStore re-signs the app every 7 days over Wi-Fi.

## Commands
| Say or type | Result |
|---|---|
| `contrast more more more` | Contrast +15 (3 steps) |
| `more` / `less` | Repeats on the last control named or touched |
| `exposure 0.5` · `contrast up by 20` | Set to a value · change by an amount |
| `saturation less exposure more` | Several controls at once |
| `contrast reset` · `reset all` | Back to defaults |
| `contrst more` · `colour down` | Typos and synonyms are matched |
