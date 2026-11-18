# photo-video-editor

A free iPad photo and video editor you can drive by name: type (and soon say)
"contrast more, more, more", and the Contrast slider moves. Sliders stay for fine-tuning.

Decisions: [DECISIONS.md](DECISIONS.md) · License: [MIT](LICENSE)

## Layout
- `EditorCore/`: Swift package with the control list (`controls.json`), command interpreter and name matcher. Builds and tests on Linux.
- `App/`: the SwiftUI iPad app (Core Image sliders + command bar).
- `project.yml`: XcodeGen spec; the cloud build generates the Xcode project from it.
- `.github/workflows/build.yml`: Linux core tests → unsigned `.ipa` + iPad simulator screenshots.

## Test the core on Linux
```sh
docker run --rm -v "$PWD":/src -w /src swift:6.2 swift test --package-path EditorCore
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
