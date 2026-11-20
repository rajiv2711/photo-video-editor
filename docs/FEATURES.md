# Photo feature checklist

Every photo operation to build, top to bottom. Sources: Lightroom (incl. paid features), Photoshop / PhotoCraft, Apple Photos, other apps (Nov 2026).

- `[x]` built · `[ ]` to do · **AI · later**: needs an AI model, not built in this iteration
- Dropped (generative AI): Generative remove, Generative fill, Generative expand, Open eyes, Relight


## A. Global adjustments

### Light

- [x] 1. **Exposure** — overall brightness, in stops
- [x] 2. **Contrast** — spread between darks and lights
- [x] 3. **Highlights** — recover or brighten the bright areas
- [x] 4. **Shadows** — lift or deepen the dark areas
- [x] 5. **Whites** — set the brightest point
- [x] 6. **Blacks** — set the darkest point
- [x] 7. **Brightness** — midtone lightness without clipping the ends
- [x] 8. **Brilliance** — lift shadows, tame highlights, add local contrast
- [x] 9. **Fade** — lift the blacks for a matte look
- [x] 10. **Tone curve (parametric)** — highlights / lights / darks / shadows region sliders
- [x] 11. **Tone curve (point)** — drag points on a curve, per RGB channel
- [x] 12. **Levels** — input/output black, white and gamma
- [x] 13. **Equalize** — spread brightness evenly over the histogram
- [x] 14. **Auto** — one-tap automatic light and colour
- [x] 15. **HDR editing** — edit and export with extended brightness (iPad XDR screen)

### Color

- [x] 16. **White balance presets** — As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash
- [x] 17. **Temperature** — blue ↔ yellow
- [x] 18. **Tint** — green ↔ magenta
- [x] 19. **White balance picker** — tap something that should be neutral grey
- [x] 20. **Vibrance** — boost muted colours, protect skin
- [x] 21. **Saturation** — intensity of all colours
- [x] 22. **Hue** — rotate all colours around the colour wheel
- [x] 23. **Color mixer (HSL)** — hue, saturation, luminance for 8 colour bands
- [x] 24. **Point color** — pick one exact colour and shift it, with a range
- [x] 25. **Variance** — even out uneven shades of one colour (e.g. skin)
- [x] 26. **Color grading** — tint shadows, midtones, highlights; blending and balance
- [x] 27. **Calibration** — shift the red/green/blue primaries and shadow tint
- [x] 28. **Black & white** — monochrome with a per-colour brightness mix
- [x] 29. **Toning** — sepia, duotone, tritone
- [x] 30. **Channel mixer** — rebuild each RGB channel from the others
- [x] 31. **Selective color** — CMYK shifts inside one colour family
- [x] 32. **Photo filter** — warming or cooling coloured filter
- [x] 33. **Gradient map** — map dark→light tones onto a colour gradient
- [x] 34. **Match color** — copy the colour mood of another photo
- [x] 35. **LUT** — apply .cube / .3dl colour lookup tables
- [x] 36. **Profiles** — base look (Standard, Vivid, Portrait, Landscape, Mono…) with Amount
- [ ] 37. **Adaptive profile** — AI picks a base look for this scene **AI · later**
- [x] 38. **Invert** — photo negative
- [x] 39. **Film negative conversion** — turn scanned film negatives into positives

### Effects

- [ ] 40. **Texture** — enhance or smooth medium-size detail
- [ ] 41. **Clarity** — midtone local contrast
- [ ] 42. **Dehaze** — remove or add haze
- [ ] 43. **Vignette** — darken/lighten edges; midpoint, roundness, feather
- [ ] 44. **Grain** — film grain: amount, size, roughness
- [ ] 45. **Glow / halation** — soft bloom and film halation around bright areas
- [ ] 46. **Lens blur** — AI depth-based background blur, bokeh shapes, focus point **AI · later**
- [ ] 47. **Posterize** — reduce to a few tone levels
- [ ] 48. **Threshold** — pure black & white at a cut-off
- [ ] 49. **Solarize** — partial tone inversion

### Detail

- [ ] 50. **Sharpening** — amount, radius, detail, masking
- [ ] 51. **Noise reduction** — luminance and colour noise sliders
- [ ] 52. **AI denoise** — ML noise removal, mainly for raw **AI · later**
- [ ] 53. **Raw details** — better raw demosaicing for fine detail **AI · later**
- [ ] 54. **Super resolution** — 2× AI upscale **AI · later**
- [ ] 55. **AI deblur** — recover soft or shaken photos **AI · later**
- [ ] 56. **Moiré removal** — remove fabric / screen colour patterns
- [ ] 57. **High pass** — edge-detail layer for sharpening

### Optics

- [ ] 58. **Lens profile correction** — auto-fix distortion and vignetting for the lens used
- [ ] 59. **Chromatic aberration** — remove coloured edges
- [ ] 60. **Defringe** — remove purple/green fringes by hue range
- [ ] 61. **Manual distortion** — barrel ↔ pincushion
- [ ] 62. **Manual lens vignetting** — amount and midpoint
- [ ] 63. **Wide-angle / fisheye correction** — straighten curved lines

## B. Masking & retouching

### Masks

- [ ] 64. **Brush mask** — paint an area; size, feather, flow, density, auto-edge
- [ ] 65. **Linear gradient mask** — fade an edit across the photo
- [ ] 66. **Radial gradient mask** — oval area with feather, inside or outside
- [ ] 67. **Select subject** — AI selects the main subject **AI · later**
- [ ] 68. **Select sky** — AI selects the sky **AI · later**
- [ ] 69. **Select background** — AI selects everything but the subject **AI · later**
- [ ] 70. **Select objects** — rough-draw around an object; AI refines it **AI · later**
- [ ] 71. **Select people** — per person: face/body skin, hair, eyes, iris, brows, lips, teeth, clothes **AI · later**
- [ ] 72. **Select landscape** — water, mountains, vegetation, architecture, ground, sky **AI · later**
- [ ] 73. **Color range mask** — select by sampled colour
- [ ] 74. **Luminance range mask** — select by brightness range
- [ ] 75. **Depth range mask** — select by distance (depth map) **AI · later**
- [ ] 76. **Mask math** — add, subtract, intersect, invert, duplicate masks
- [ ] 77. **Mask refine** — feather, edge, smooth, expand/contract; hair-fine edges
- [ ] 78. **Mask overlay** — show the mask as a coloured overlay
- [ ] 79. **Local adjustments** — any slider (incl. colour grading) inside a mask
- [ ] 80. **Selection tools** — lasso, polygon lasso, marquee, magic wand, quick select

### Retouch & remove

- [ ] 81. **Remove brush** — paint over a distraction; content-aware fill
- [ ] 82. **Heal** — fix a spot by blending texture from nearby
- [ ] 83. **Clone** — copy pixels exactly from a source spot
- [ ] 84. **Patch / content-aware move** — move an object and fill the hole
- [ ] 85. **Remove people** — auto-detect and remove background people **AI · later**
- [ ] 86. **Remove wires & cables** — auto-detect and remove power lines **AI · later**
- [ ] 87. **Remove reflections** — clear reflections from glass **AI · later**
- [ ] 88. **Dust removal** — auto-detect and remove sensor dust **AI · later**
- [ ] 89. **Visualize spots** — high-contrast view to find dust
- [ ] 90. **Red eye / pet eye** — fix flash eyes
- [ ] 91. **Blemish removal** — AI auto-detects and removes acne and spots **AI · later**
- [ ] 92. **Skin smoothing** — soften skin, keep pores and freckles **AI · later**
- [ ] 93. **Teeth whitening / eye brightening** — quick portrait fixes **AI · later**
- [ ] 94. **Liquify** — push/pull pixels; face-aware reshaping
- [ ] 95. **Dodge & burn** — brush to lighten or darken
- [ ] 96. **Sponge** — brush to add or remove saturation
- [ ] 97. **Blur / sharpen / smudge brushes** — local touch-up brushes
- [ ] 98. **Remove background** — cut the subject out to transparency **AI · later**
- [ ] 99. **Sky replacement** — swap in a new sky with matched light **AI · later**

## C. Geometry, merge & creative

### Geometry

- [ ] 100. **Crop** — free or fixed aspect ratio
- [ ] 101. **Straighten** — level by angle, auto, or draw the horizon
- [ ] 102. **Rotate 90° / flip** — rotate; flip horizontal or vertical
- [ ] 103. **Upright** — auto perspective: auto, level, vertical, full
- [ ] 104. **Guided upright** — draw lines that should be straight
- [ ] 105. **Manual transform** — vertical, horizontal, rotate, aspect, scale, offset
- [ ] 106. **Perspective crop** — crop and square up a tilted plane
- [ ] 107. **Resize** — pixel size and resolution
- [ ] 108. **Canvas size** — add space or borders around the photo
- [ ] 109. **Content-aware scale** — resize while protecting the subject
- [ ] 110. **Warp / puppet warp** — bend parts of the image with a grid or pins

### Merge

- [ ] 111. **HDR merge** — combine bracketed exposures, remove ghosts
- [ ] 112. **Panorama merge** — stitch photos; projection, boundary warp, fill edges
- [ ] 113. **HDR panorama** — HDR merge and stitch in one step
- [ ] 114. **Focus stacking** — combine focus slices into one sharp photo
- [ ] 115. **Stack averaging** — median/mean of a burst: remove crowds, fake long exposure
- [ ] 116. **Double exposure** — blend two photos
- [ ] 117. **Live Photo effects** — key frame, loop, bounce, long exposure
- [ ] 118. **Portrait depth editing** — change aperture, focus and lighting of iPhone portraits

### Creative filters

- [ ] 119. **Blur filters** — Gaussian, motion, radial / zoom / spin
- [ ] 120. **Tilt-shift / iris / field blur** — miniature and selective-focus effects
- [ ] 121. **Distort filters** — twirl, wave, ripple, pinch, spherize, polar
- [ ] 122. **Stylize filters** — oil paint, emboss, find edges, wind
- [ ] 123. **Pixelate filters** — mosaic, crystallize, halftone
- [ ] 124. **Artistic filters** — watercolour, sketch, cartoon, cutout
- [ ] 125. **Lens flare** — add a light flare
- [ ] 126. **Lighting effects** — spot and omni lights over the image
- [ ] 127. **Film effects** — light leaks, dust and scratch overlays
- [ ] 128. **Frames / borders** — add a border or frame

### Layers & graphics

- [ ] 129. **Layers** — stack images; opacity, reorder, duplicate
- [ ] 130. **Blend modes** — multiply, screen, overlay, etc.
- [ ] 131. **Adjustment layers** — non-destructive edits, each with its own mask
- [ ] 132. **Text** — add styled text
- [ ] 133. **Shapes & vectors** — rectangles, ellipses, pen paths
- [ ] 134. **Layer styles** — shadow, glow, stroke, bevel
- [ ] 135. **Paint brush** — draw with Pencil pressure and tilt
- [ ] 136. **Gradient & fill** — fill an area with colour or a gradient
- [ ] 137. **Stickers / overlays** — place images or graphics on top
- [ ] 138. **Collage** — arrange several photos in a layout
- [ ] 139. **Watermark** — text or logo stamp on export

## D. Workflow

### Presets & batch

- [ ] 140. **Presets** — save/apply a bundle of settings, with Amount
- [ ] 141. **Premium preset packs** — built-in looks: film, portrait, travel…
- [ ] 142. **Adaptive presets** — presets that auto-mask sky, subject or portrait **AI · later**
- [ ] 143. **Recommended presets** — AI suggests looks for this photo **AI · later**
- [ ] 144. **Copy / paste edits** — choose which settings to copy
- [ ] 145. **Batch edit** — apply edits to many photos at once
- [ ] 146. **Match exposures** — even out brightness across a set
- [ ] 147. **Previous** — apply the last photo's edits

### History & viewing

- [ ] 148. **Undo / redo** — step back and forward
- [ ] 149. **History** — list of steps; jump back to any
- [ ] 150. **Versions / snapshots** — save named states of an edit
- [ ] 151. **Virtual copies** — several edits of one photo
- [ ] 152. **Before / after** — compare split, side-by-side, or hold
- [ ] 153. **Reset** — one slider, one panel, or everything
- [ ] 154. **Histogram** — live tone graph
- [ ] 155. **Clipping warnings** — show lost highlights and shadows
- [ ] 156. **Vectorscope** — colour and skin-tone scope
- [ ] 157. **Color sampler** — RGB/LAB readout at a point
- [ ] 158. **Zoom / 1:1 loupe** — inspect fine detail
- [ ] 159. **Grid & guides** — thirds, golden ratio, grid overlay
- [ ] 160. **Targeted adjustment** — drag on the photo to change the tone/colour under your finger
- [ ] 161. **Soft proofing** — preview print or web colour

### Library

- [ ] 162. **Import** — from Photos, Files, camera or SD card
- [ ] 163. **Raw support** — DNG, ProRAW, CR3, NEF, ARW and others
- [ ] 164. **Rate / flag / label** — stars, pick/reject, colour labels
- [ ] 165. **Albums** — group photos
- [ ] 166. **Keywords & metadata** — view and edit EXIF/IPTC
- [ ] 167. **AI search** — find photos by content ("dog on beach") **AI · later**
- [ ] 168. **People** — group photos by face **AI · later**
- [ ] 169. **Assisted culling** — score sharpness, eyes open, duplicates **AI · later**
- [ ] 170. **Stacks** — group bursts and brackets
- [ ] 171. **Map** — browse by location
- [ ] 172. **Tethered capture** — shoot from a connected camera
- [ ] 173. **Pro camera** — capture with manual controls and raw

### Export

- [ ] 174. **Export** — JPEG, PNG, HEIC, TIFF, DNG, AVIF; quality, size, metadata
- [ ] 175. **Export presets** — saved export settings
- [ ] 176. **Save / share** — to Photos, Files, share sheet
- [ ] 177. **Print** — AirPrint with layout
- [ ] 178. **Color management** — sRGB, Display P3, ProPhoto, 16-bit
