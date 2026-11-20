---
name: Fulcrum
description: An opinionated photo editor whose controls are engraved like a lens barrel, pivoting on the photo's measured median.
colors:
  anodised: "#0B0B0C"
  barrel: "#141415"
  raised: "#1E1E20"
  control-fill: "#232326"
  hairline: "#242427"
  hairline-faint: "#1C1C1E"
  ring: "#2E2E31"
  track: "#3A3A3D"
  ghost-mark: "#4A4A4E"
  rib: "#6A6A6E"
  metadata: "#9A9A9E"
  figure: "#A8A8AC"
  on-fill: "#A0A09E"
  label: "#C0C0BE"
  knob: "#B6B6B4"
  engraving: "#F2F2F0"
  second-scale: "#E8B92E"
  index-red: "#D7261E"
typography:
  wordmark:
    fontFamily: "Saira, sans-serif"
    fontSize: "88px"
    fontWeight: 500
    lineHeight: 0.82
    letterSpacing: "-0.02em"
  value:
    fontFamily: "Saira, sans-serif"
    fontSize: "14px"
    fontWeight: 500
    fontFeature: "\"tnum\" 1"
  value-index:
    fontFamily: "Saira, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    fontFeature: "\"tnum\" 1"
  scale-figure:
    fontFamily: "Saira, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    fontFeature: "\"tnum\" 1"
  scale-zone:
    fontFamily: "Saira, sans-serif"
    fontSize: "11px"
    fontWeight: 500
  status-figure:
    fontFamily: "Saira, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    fontFeature: "\"tnum\" 1"
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.25
  label:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  explainer:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.45
  caption:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 400
rounded:
  thumb: "2px"
  tag: "4px"
  control: "6px"
  row: "7px"
  switch: "9px"
  window: "12px"
spacing:
  hair: "2px"
  tight: "5px"
  sm: "8px"
  md: "10px"
  lg: "12px"
  gutter: "16px"
components:
  toolbar-button:
    backgroundColor: "transparent"
    rounded: "{rounded.control}"
    width: "36px"
    height: "28px"
  toolbar-button-pressed:
    backgroundColor: "{colors.ring}"
    textColor: "{colors.engraving}"
    rounded: "{rounded.control}"
    width: "36px"
    height: "28px"
  button-upload:
    backgroundColor: "{colors.control-fill}"
    textColor: "{colors.engraving}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0 12px 0 10px"
    height: "28px"
  source-row:
    backgroundColor: "transparent"
    textColor: "{colors.label}"
    typography: "{typography.body}"
    rounded: "{rounded.row}"
    padding: "6px 8px"
  source-row-selected:
    backgroundColor: "{colors.ring}"
    textColor: "{colors.engraving}"
    rounded: "{rounded.row}"
    padding: "6px 8px"
  slider-track:
    backgroundColor: "{colors.track}"
    height: "2px"
  slider-fill:
    backgroundColor: "{colors.on-fill}"
    height: "2px"
  slider-knob:
    backgroundColor: "{colors.knob}"
    size: "14px"
  switch-on:
    backgroundColor: "{colors.on-fill}"
    rounded: "{rounded.switch}"
    width: "32px"
    height: "18px"
  overlay-tag:
    textColor: "{colors.engraving}"
    typography: "{typography.caption}"
    rounded: "{rounded.tag}"
    padding: "3px 8px"
  inspector-section:
    backgroundColor: "{colors.barrel}"
    padding: "12px 16px 10px"
    width: "320px"
---

# Design System: Fulcrum

## Overview

**Creative North Star: "The Engraved Barrel"**

Fulcrum's controls are marked the way a lens barrel is marked: one fixed index, and scales that run symmetrically out from it, so the median that the contrast curve pivots on is something you can see. The chrome is matte black anodised metal in neutral greys. White figures are engraved into it. A second scale in engraving yellow appears only where a scale carries a second unit. The single red mark is the brand. The mark and the mechanism share a shape: the index triangle is the pivot.

It is a native macOS window first. The marking language lives on top of standard controls (unified toolbar, source-list sidebar, inspector, NSSlider, switch). It never replaces them. Density is a pro-tool inspector's density, with 12–13px labels and 11px figures. The photo sits on the darkest ground, with nothing coloured near it, so the chrome never sways a judgement of tone or colour. The visual rejection confirmed by the direction is the category default: a grey panel of identical blue-filled sliders.

**Key Characteristics:**
- Neutral black chrome, stepping from photo ground (#0B0B0C) through panels (#141415) to pressed states (#2E2E31).
- Every number on a scale is set in Saira with tabular figures. Every word is set in the system face.
- Sliders carry tick figures and an index dot at their default value.
- Contrast is drawn as a depth-of-field pivot scale above a standard slider.
- Colour carries meaning only: yellow is the second unit, red is the mark.

## Colors

The palette is engraved metal: black ground, white figures, and two accents, each with exactly one job.

### Primary
- **Engraving White** (`engraving`): the index mark and its line (pivot, histogram median, slider index dot), the median readouts, selected row text, pressed toolbar glyphs, the before/after divider. It is the voice of the system, so it is kept for marks and readouts that point at the photo, not for the controls you handle.

### Secondary
- **Engraving Yellow** (`second-scale`): used only for a scale's second unit. In the build that means the zone numerals (I–IX) under the pivot scale's tone values (14–222). It is never used for state, selection, warnings or emphasis.

### Tertiary
- **Index Red** (`index-red`): used only for the brand mark, an upward triangle (the Fulcrum mark, and the index under a ruler on the system board). It does not appear inside the editor chrome.

### Neutral
- **Anodised** (`anodised`): the photo ground behind the canvas. It is the darkest surface, reserved for where the image sits.
- **Barrel** (`barrel`): toolbar, sidebar and inspector panels.
- **Raised** (`raised`): floating grip surfaces drawn on the photo.
- **Control Fill** (`control-fill`): the bordered toolbar button (Upload), with a `track` stroke.
- **Hairline** (`hairline`): panel dividers and section rules. **Hairline Faint** (`hairline-faint`) sits above the canvas status bar.
- **Ring** (`ring`): the selected source row, pressed toolbar buttons and the toolbar separator.
- **Track** (`track`): slider tracks, histogram fill and button strokes.
- **Ghost Mark** (`ghost-mark`): the unlit brackets of the pivot scale and minor ruler ticks.
- **Rib** (`rib`): knurl lines on grip surfaces.
- **Metadata** (`metadata`): tertiary text (file type, group header, status bar, unit suffixes, slider tick figures).
- **Figure** (`figure`): tone values on the pivot scale and explanatory text under a control.
- **Label** (`label`): slider labels and unselected source rows.
- **On Fill** (`on-fill`): the one on-colour. It is used for slider fills from the index to the knob, the switch track when it is on, and toolbar glyphs at rest.
- **Knob** (`knob`): slider thumbs, one step below `label` brightness so the engraved index stays the brightest mark in the inspector. The switch knob is pure white (#FFFFFF), as on the native control.

### Named Rules
**The One Job Rule.** Yellow means "second unit on this scale" and red means "Fulcrum". If a use of either colour can't be read that way, it is wrong.

**The Red Triangle Rule.** The brand index is always a triangle, never a dot. A red dot is Leica's trademark, and Fulcrum does not borrow it.

**The Graphite On-State Rule.** Every "on" or "filled" state uses `on-fill` (#A0A09E). That covers slider fills and switch tracks. Neither the system accent colour nor any blue is used.

**The Quiet Controls Rule.** Controls you handle (knobs, fills, slider values, section titles, lit tick figures) top out at `label` (#C0C0BE) and `knob` (#B6B6B4). Only marks that point at the photo (indices, the pivot, medians, the divider) reach `engraving`. In a dim room the controls should recede and the index should lead.

**The Neutral Chrome Rule.** Chrome uses greys only. The photo is the only coloured thing on screen, apart from yellow zones, the mark, and the histogram's red, green and blue channel lines, which are data (clipping and casts), not decoration.

## Typography

**Numeral Font:** Saira (500 for values, 400 for scale figures, 600 for the figure at the index), with a sans-serif fallback
**Label Font:** SF Pro, the system face (`.system` in SwiftUI)

**Character:** Saira's squared, open figures read as engraved numerals on metal. The system face keeps every word reading as a Mac app. The split is strict: numbers on scales use Saira, and words use SF.

### Hierarchy
- **Wordmark** (Saira 500, 88px, line-height 0.82, −0.02em): the name "Fulcrum" beside the red triangle. Brand surfaces only.
- **Value** (Saira 500, 14px, tabular): the current value at the trailing edge of a slider header (+0.35, +22, 40), in `label`. The unit suffix is set at 11px in `metadata` (EV).
- **Value at Index** (Saira 600, 15px): the median tone under the pivot index (118). The histogram's median readout uses the same face at 13px/600.
- **Scale Figure** (Saira 400, 11px, tabular): slider tick figures and histogram end figures (0, 255).
- **Scale Zone** (Saira 500, 11px, `second-scale`): the second-unit zone numerals.
- **Status Figure** (Saira 400, 12px, tabular): canvas status bar figures (Fit 13%, 6000 × 4000).
- **Title** (SF 600, 13px): inspector section titles (Light, Contrast, Black & White) and the document title in the toolbar. Section titles are in `label`; the toolbar title stays `engraving`.
- **Body** (SF 400/500, 13px): source row names (500 when selected) and the Upload button (500).
- **Label** (SF 400, 12px, `label`): slider labels.
- **Explainer** (SF 400, 12px, line-height 1.45, `figure`): one plain sentence explaining the mechanism, under a control.
- **Caption** (SF 400/600, 11px, `metadata`): file type, toolbar subtitle, sidebar group header (600), and Before/After overlay tags (600, `engraving`).

### Named Rules
**The Engraved Figures Rule.** Every number that lives on a scale or readout uses Saira with tabular figures, so values never jitter while you drag. Words are never set in Saira, except the wordmark.

## Layout

The layout is a fixed three-column editor window inside a native unified toolbar (52px tall). It has a source-list sidebar on the left (220px), the canvas in the middle (flexible, `anodised` ground, photo centred), and an inspector on the right (320px). The canvas has a 30px status bar along its bottom edge. The primary action, Upload, sits at the trailing edge of the toolbar after a separator (1×18px, `ring`). Toolbar icon buttons are grouped with 4px gaps.

The inspector is one scrolling column in processing order, so anything above feeds everything below and each control has exactly one home. Under the histogram, a segmented **Colour | Black & White** switch (V) sets the mode. Then come White Balance, RAW Decode (RAW only), Light, Contrast and Local Contrast. In Colour mode, Vibrance & Saturation, Colour Mixer and Colour Grading follow. In B&W mode, Black & White, B&W Mix (the mixer feeding the conversion) and Toning follow. Detail and Grain finish the column in both modes. Sections collapse, and each remembers whether it was open. Variations live in a toolbar menu, not the inspector. Section titles are never numbered.

Spacing rhythm: the inspector uses a 16px gutter (content width 288px), with sections at 10–12px vertical padding, divided by `hairline`. Inside a section, controls are 10px apart. Within a slider, header, track and figures are 5px apart. Sidebar padding is 12px × 10px. Rows are 2px apart with 6px × 8px padding, and the gap from thumbnail to text is 10px. The source thumbnails are 36×24px.

## Elevation & Depth

Depth comes from tonal steps in the metal, not from shadows. The ground is darkest, the panels sit one step up, and pressed or selected states sit higher again. Chrome surfaces have no shadows. Shadows appear only where something sits on or over the photo, or where a native control would draw one.

### Shadow Vocabulary
- **Print lift** (`0 18px 50px rgba(0,0,0,0.65)`): the photo on the anodised ground.
- **Grip lift** (`0 2px 8px rgba(0,0,0,0.55)`, with a 1px `track` inner stroke): reserved for any grip block drawn on the photo.
- **Knob** (`0 1px 3px rgba(0,0,0,0.35)`): slider thumb. The switch knob uses `0 1px 2px rgba(0,0,0,0.4)`.

### Named Rules
**The Flat Metal Rule.** Panels, sections and rows are flat. If a shadow isn't lifting the photo or a thumb or handle, remove it.

## Shapes

The form language is precise and small-radiused, as on machined parts. Controls use 6px, list rows 7px, overlay tags 4px, thumbnails 2px, and the window 12px (native). Marks are hairline strokes. Scale ticks and brackets are 1px. The lit bracket is 1.8px, and the index line is 1.2–1.5px. Indices are triangles, apex pointing at the value they mark. Grip surfaces carry knurled ribs: five 1px vertical lines in `rib`, 2px apart.

## Components

### Toolbar
A native unified toolbar, with neutral glyphs and no tint.
- **Icon buttons:** borderless, 36×28px, 6px radius. Glyphs are stroked at 1.4px in `on-fill`. When pressed or toggled on (Split, Y), the button fills with `ring` and the glyph turns `engraving`. Use SF Symbols natively.
- **Primary (Upload):** a bordered button with a 1px `track` stroke on `control-fill`, label in SF 500 13px, `engraving`, with a leading upload glyph. Natively: a bordered `NSButton` / `.bordered` with a neutral tint.
- **Document title:** SF 600 13px, with an 11px `metadata` subtitle ("RAW · edited").

### Source List
- **Style:** a native source-list sidebar. Rows hold a 36×24 thumbnail, the name (13px), and the file type (11px, `metadata`). Trailing status glyphs are a filled `engraving` heart for favourites and an outline sliders glyph in `metadata` for edited photos.
- **Selected:** `ring` fill, 7px radius, `engraving` text at weight 500. The unselected text is `label`. Do not use the system blue selection. Set the selection to a neutral highlight.
- **Group header:** SF 600 11px `metadata`, with a count in Saira on the trailing edge.

### Engraved Slider
A standard `NSSlider` with tick marks, a value readout and an index.
- **Header:** label (`label`, 12px) leading, value (Saira 14px) trailing.
- **Track:** 2px, `track`. The fill runs from the index to the knob in `on-fill`. For bipolar controls it fills from the centre, and for unipolar controls from the leading end.
- **Index dot:** a 4px `engraving` dot above the track at the default value. A double-click on the slider returns the value there.
- **Knob:** 14px, `knob`, with the knob shadow.
- **Figures:** Saira 11px `metadata` below the track, evenly spaced. The figure at the default is lit in `label`.

### Switch
- A native `NSSwitch`, 32×18px. When on, the track is `on-fill` and the knob is white. Override the system accent colour so the on-state is graphite, not blue.

### Contrast Pivot Scale (signature)
A depth-of-field scale drawn above a standard engraved slider that drives it.
- **Index:** a vertical `engraving` line at the centre with an upward triangle beneath it. Below sits the photo's measured median tone (Value at Index, 15px/600).
- **Ruler:** tone values (14 … 222) in `figure` either side of the median, and zone numerals I–IX in `second-scale` beneath them.
- **Brackets:** eight fixed bracket paths in `ghost-mark` (1px), each dropping vertically from the top and then angling out to a tone value. The live bracket pair is drawn in `engraving` at 1.8px. Positive contrast opens the pair outward from the index. Negative contrast draws it dashed (4/3) and closes it inward toward the median. At zero, only the index is lit.
- **Explainer:** one sentence in `explainer` under the slider, naming the pivot ("Pivots on this photo's median, tone 118…").
- **Interaction:** drag the scale sideways to move the pivot (right = brighter tone). The index stays centred and the tone ruler slides under it, like a lens ring past its index. Double-click returns the pivot to the median. It shows a left–right resize cursor, and is adjustable with VoiceOver (±1 tone). Natively: a custom drawn view (SwiftUI `Canvas`); the Amount slider beneath it still sets contrast.

### Histogram
- A luminance histogram filled in `track` (288×56), with 1px red, green and blue channel lines over it (#E0645A, #5FBF73, #5B8CF0 at 85–90% opacity), and the median marked by a 1.2px `engraving` line and a downward triangle at the top. The header shows "Luminance" leading and "median" plus the value (Saira 13px/600) trailing. End figures 0 and 255 are in Saira 11px.

### Status Bar
- A 30px strip under the photo on `anodised`, with a `hairline-faint` rule above. Leading: zoom in Saira 12px `metadata` ("Fit 26%" while fitted, "100%" at one photo pixel per screen pixel), then the exported size after the crop ("6000 × 4000"). Trailing: the shortcuts that work in the current state in SF 12px ("Drag the divider · Y split · \ before · hold Space" in split view). Hidden while cropping.

### App Icon
- Anodised black body on the macOS icon grid, with a knurled band across the top, a depth-of-field scale whose live bracket pair and index are `engraving`, unlit brackets in `ghost-mark`, and the red index triangle pointing up at the index. Drawn by `scripts/make-icon.swift`.

### Vignette
- An inspector section (in Finish, before Grain) with a segmented **Centre | Manual | Subject** control, then Amount (−100…100), Size, Roundness and Feather sliders, and one explainer line naming where it is centred. Subject mode centres on the main face (or between faces of a similar size), falling back to the subject mask's centre when there is no face; "No face or subject found" is said plainly, falling back to the frame's centre.
- **Centre handle:** in Manual and Subject modes, a 32pt engraved ring on the photo (20pt circle, four 4pt ticks, 3pt centre dot, 1.5px `engraving` stroke with a soft dark shadow), constant size at any zoom. Around it, the vignette's boundary is drawn as hairlines clipped to the photo: a solid `engraving` ring at 75% where the effect is half strength, and dashed (4/4) rings at 40% where it starts and where it reaches full strength; they follow Size, Roundness and Feather. Dragging it places the centre (and switches Subject to Manual); double-click returns it to the frame's centre. Open-hand cursor over it.
- The vignette is an exposure falloff after colour and B&W, before grain, on an ellipse fitted to the cropped frame, so it follows the crop.

### Split Divider
- A 2px `engraving` line across the photo, with no handle block: the whole line is the grip (a 24pt-wide hit area and a left–right cursor). Before and After tags are set on `anodised` at 72% opacity, with a 4px radius, in caption 600.

## Do's and Don'ts

### Do:
- **Do** keep every chrome surface in the neutral ladder (#0B0B0C → #141415 → #1E1E20 → #2E2E31), with the photo on `anodised`.
- **Do** set every number on a scale in Saira with tabular figures, and every word in the system face.
- **Do** give each slider an index dot at its default and light the figure at the default in `engraving`.
- **Do** use `on-fill` (#A0A09E) for every on-state and fill: slider fills and switch tracks.
- **Do** draw indices as triangles pointing at the value they mark.
- **Do** build on native controls (NSSlider with tick marks, NSSwitch, source list, unified toolbar), with neutral tints that override the system accent colour.
- **Do** put one plain sentence under a control when its mechanism is not obvious.

### Don't:
- **Don't** use engraving yellow (#E8B92E) for anything except a scale's second unit.
- **Don't** use index red (#D7261E) anywhere but the brand mark, and never as a dot.
- **Don't** use the system accent blue or any tint for fills, selection or switches.
- **Don't** build the category default: a grey panel of identical blue-filled sliders.
- **Don't** add shadows to panels, sections or rows.
- **Don't** set labels or prose in Saira.
