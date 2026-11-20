---
version: 1
slug: "sources-fulcrum-contentview-swift"
primary_target: "Sources/Fulcrum/ContentView.swift"
related_targets: []
---

# Editor window

Scope: the main editor window (file list, photo canvas, inspector). Mode: Operate. Explored first as mockups on the design canvas "Fulcrum Style Directions".

Audience and job: the author, editing their own shoots at night in a dim room, judging tone at the desk. Task: reach the intended look in few, deliberate moves; compare before/after; deliver.

Constraints from the user (18 Nov 2026): no colour in the chrome near the photo; native macOS controls; not soft or consumer. Dark chrome, chosen from the use scene (dim room, night).

## Direction contract

THESIS: Fulcrum's controls are engraved like a Leica lens barrel: one fixed index, scales running symmetrically out from it, so the median pivot is something you can see. It refuses the category default of a grey panel of identical blue-filled sliders.

OWN-WORLD: matte black anodised ground in true neutrals (#0B0B0C ground, #141415 panels, #1E1E20 raised), white engraved numerals (#F2F2F0), engraving yellow (#E8B92E) only for a scale's second unit, one red index triangle (#D7261E) only as the brand mark (not a dot: that is Leica's trademark). Fine knurled ribs mark grip surfaces. Numerals in an engraved squared sans (Saira); labels in the system face.

STORY: the photographer sees the photo first, then reads every adjustment as a number on a scale, and understands that contrast pivots on the photo's measured median.

FIRST VIEWPORT: native unified toolbar; source-list sidebar left (220 px); photo centre on the black ground with the split before/after divider; inspector right (320 px): histogram with the median index, Light scales, the Contrast pivot scale, B&W. Primary action Upload sits at the toolbar's trailing edge.

FORM: Leica lens-barrel markings, pinned by the user over the dealt hand (the roll assigned grounded candidate 6, a film data-sheet world; it was not presented). seed:05490e0bb4ea9d0a. The user's words pin the world only: "maybe we can take art direction from the colours and graphics that are on leica lens"; the first surface (editor window) came from their earlier answer. Signature move: the Contrast control drawn as a depth-of-field scale, brackets converging on the median index, driven by a standard slider beneath it.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
