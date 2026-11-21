# photo-video-editor

A free iPad photo and video editor you can drive by name: type or say
"contrast more, more, more" and the Contrast slider moves. Sliders stay for fine-tuning.

License: [MIT](LICENSE). The lens profiles in `command-engine/Sources/CommandEngine/Resources/lens-profiles.json`
come from the [lensfun](https://github.com/lensfun/lensfun) database and keep its licence (CC BY-SA 3.0).

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
| [`dev-tools/`](dev-tools) | Laptop scripts: `make_report.py` (parser report), `voice_test.py` (speech → server → parser report), `ci_results.py` (cloud render checks), `make_luts.py` (the sample LUTs). |
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
| `contrst more` · `vividness down` | Typos and synonyms are matched |
| `colour more` | Fits Vibrance and Saturation: the app asks which |
| `reset highlights` · `more contrast` | Verb first works too |
| `tone curve shadows 20` · `curve 50 60` · `red curve 75 up` | Multi-word names; point curve: point 50 → output 60 |
| `input black 20` · `gamma 1.5` | Levels |
| `hdr on` · `turn off equalize` | Toggles |
| `auto` | Runs an action (Auto sets the light sliders, Temperature, Tint and Vibrance) |
| `white balance cloudy` · `temperature more` · `tint -20` | White balance preset (a choice), then sliders on top |
| `white balance picker` · `point color picker` | Arms a picker: tap the photo (a neutral spot, or the colour to change) |
| `red saturation -40` · `shadows hue 220` · `reds cyan 20` · `red from green 30` | Color mixer, Color grading, Selective color, Channel mixer |
| `black and white` · `toning sepia` · `lut warm film` · `profile vivid` · `match color sunset` | Switches and choices of the Color panel |
| `texture 40` · `clarity up` · `dehaze 50` · `glow 30` · `solarize 50` | Effects sliders |
| `vignette -60` · `vignette midpoint 30` · `grain 30` · `grain size 60` · `posterize` · `threshold level 90` | Effects sections and switches |
| `sharpening 60` · `sharpening masking 70` · `noise reduction 40` · `chroma noise 50` · `moire 60` · `high pass 50` | Detail panel (`noise` alone asks which) |
| `lens profile correction on` · `remove chromatic aberration` · `defringe 60` · `distortion 30` · `vignetting up` · `fisheye correction 50` | Optics panel (`vignette` is the Effects one, `vignetting` the lens one) |
| `brush mask` · `linear gradient from top` · `radial gradient center` · `color range blue` · `luminance range shadows` | Makes a mask and selects it (then draw, drag or tap on the photo) |
| `exposure -1` · `mask 2 contrast 30` · `mask exposure more` · `done` | While a mask is selected, the sliders masks allow (light, colour, effects, detail, colour grading) change it; `done` or `mask 0` goes back to the global sliders |
| `subtract luminance range` · `intersect linear gradient from left` · `invert mask` · `outside` · `duplicate mask` · `component 2` · `delete component` | Mask math: parts add, subtract or intersect; invert a mask or one part |
| `mask feather 50` · `expand mask 20` · `refine edge 60` · `mask amount 150` · `show mask overlay` | Refine the selected mask, scale its sliders, show it in red |
| `lasso` · `polygon lasso` · `marquee left` · `magic wand` · `quick select` · `brush size 20` · `eraser` | Selection tools and brush settings |
| `remove brush` · `heal` · `clone` · `patch` · `content aware move` | Retouch tools: then paint, tap, or draw around an area and drag it, on the photo (`brush size`, `brush feather` are shared with the mask brush) |
| `clone source` · `spot 2` · `spot opacity 50` · `delete spot 2` · `undo last spot` | Choose where the selected spot copies from (then tap), select a spot, change or delete it |
| `red eye` · `pet eye` · `pupil size 70` · `pupil darken 80` · `catchlight off` | Eye fixes: tap the eye or draw around it; the settings change the selected eye |
| `liquify pucker` · `liquify mode bloat` · `tool strength 80` | Liquify: push, twirl, pucker, bloat, reconstruct |
| `dodge midtones` · `burn shadows` · `sponge desaturate` · `blur brush` · `sharpen brush` · `smudge` | Toning and touch-up brushes (Apple Pencil pressure counts) |
| `show spots` · `visualize threshold 70` | Visualize Spots: dust and specks white on black (preview only) |
| `crop 16 by 9` · `crop square` · `crop left 10` · `reset crop` · `crop tool` | Crop: aspect presets, the edges, or the box to drag on the photo (`done` when finished) |
| `straighten 3` · `auto straighten` · `straighten tool` | Straighten by angle, from the photo's lines, or along a line drawn on the photo |
| `rotate left` · `rotate 180` · `flip horizontal` · `flip vertical` | Quarter turns and flips (the crop turns with the photo) |
| `upright auto` · `auto upright` · `upright vertical` · `guided upright` · `clear guides` | Upright from the photo's lines (no AI), or from up to four guides drawn on the photo |
| `vertical 30` · `horizontal -20` · `transform rotate 2` · `aspect 20` · `scale 110` · `offset x 10` | Manual transform |
| `perspective crop` · `clear perspective crop` | Square up a tilted page, picture or wall (drag its four corners) |
| `resize 50` · `long edge 2000 pixels` · `resolution 300` | Saved size and resolution (the Geometry panel shows the saved size) |
| `canvas size 10` · `canvas aspect square` · `canvas color blur` | Space around the photo |
| `content aware width 80` · `content aware height 90` | Content-aware scale (seam carving: the subject keeps its shape) |
| `warp` · `puppet warp` · `reset warp` | Bend the picture: drag a grid's handles, or tap to pin and drag a pin |
