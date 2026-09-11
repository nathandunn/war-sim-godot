extends RefCounted
##
## The palette. Every colour this app draws lives here and nowhere else —
## `ui/field.gd`, `ui/main.gd` and `scripts/sprites.gd` all read from it, and
## `_test_palette_contrast` greps them for a literal `Color(…)` and fails on one.
##
## The rule the file exists to enforce is legibility on a phone in daylight. The
## build shipped a near-black field with slate-blue sandbags on it and a cyan
## team that read as the same object as the cover it was standing behind. Every
## element a viewer has to pick out now clears **WCAG 3:1** against the field —
## the bar for non-text graphical objects — and the suite asserts it:
##
##   team A body    warm red      3.68 : 1      helmet  6.95 : 1
##   team B body    blue          3.64 : 1      helmet  6.87 : 1
##   sandbags       light tan     7.18 : 1      lit top 10.35 : 1
##   corpse         neutral grey  5.12 : 1
##   bullets        pale amber   11.43 : 1
##
## The "body" rows are the number that matters and the one that is easy to miss:
## a soldier is drawn from a luminance sheet and the team colour is multiplied
## in, so the torso is only 0.72 of the team colour and the limbs 0.45. Checking
## the team colour alone would pass a sprite whose body fails.
##
## **Team A is red and team B is blue, in this order, and `war-sim` matches.**
## The two builds had drifted — this one had A blue and B red, the canvas one
## had A ember and B cyan — which is a bad thing for two implementations of one
## spec that are meant to be read side by side. Red and blue rather than red and
## cyan because they are the standard colour-blind-safe opposition; the two are
## deliberately at nearly equal luminance so neither side reads as the heavier.
##

## Field.
const FIELD := Color("#2b3140")
const GRID := Color("#3a4257")
const BORDER := Color("#525c76")

## Teams: 0 is red, 1 is blue.
const TEAM := [Color("#ffa88c"), Color("#8cc0ff")]
## The spawn strips, which are a hint and not an element — hence the alpha.
const SPAWN_ALPHA := 0.06

## Bodies.
## Slightly transparent, as it was, so a field of dead settles into the ground
## rather than shouting over the men still standing on it.
const CORPSE := Color(Color("#9aa3b5"), 0.9)

## Fire.
const BULLET := Color(Color("#fff0c0"), 0.95)
const FLASH := [Color(Color("#ffd0a8"), 0.95), Color(Color("#bcd8ff"), 0.95)]

## Sandbag cover: a slab, alternating bags, a lit top edge and a shadowed foot,
## so the wall reads as having a height instead of being a hole in the floor.
const COVER_FILL := Color("#a88d57")
const COVER_BAG := [Color("#d9bd8a"), Color("#c4a875")]
const COVER_TOP := Color("#f5e4bf")
const COVER_FOOT := Color("#6b5735")

## The luminance sheet's levels, which is where a team colour becomes a body.
## `scripts/sprites.gd` bakes these and `war-sim/src/render.ts` mirrors them.
const LUM_BODY := 0.72
const LUM_HELMET := 1.0
const LUM_LIMB := 0.45

## UI chrome.
const UI_TEXT := Color("#e3e7ef")
const UI_MUTED := Color("#93a0b8")
const UI_PANEL := Color("#1b2130")
const UI_BUTTON := Color("#2f374a")
const UI_BUTTON_HOVER := Color("#3f4a63")
const UI_BUTTON_PRESSED := Color("#4e77b8")
const UI_BORDER := Color(1, 1, 1, 0.14)
const UI_BORDER_SOFT := Color(1, 1, 1, 0.11)
const UI_SCRIM := Color(0, 0, 0, 0.45)
const UI_BAR := Color("#141a26")
const TRANSPARENT := Color(0, 0, 0, 0)
const WHITE := Color(1, 1, 1)


## A team colour at one of the sheet's luminance levels — what the eye actually
## receives once the shader has multiplied the tint into the sprite.
static func at_luminance(c: Color, lum: float) -> Color:
	return Color(c.r * lum, c.g * lum, c.b * lum, c.a)


## The BBCode form of a palette colour, for the RichTextLabels.
static func tag(c: Color) -> String:
	return c.to_html(false)


## sRGB -> relative luminance, WCAG 2.x.
static func luminance(c: Color) -> float:
	var ch := [c.r, c.g, c.b]
	var w := [0.2126, 0.7152, 0.0722]
	var l := 0.0
	for i in range(3):
		var v: float = ch[i]
		l += w[i] * (v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4))
	return l


## WCAG contrast ratio between two colours, 1.0 .. 21.0.
static func contrast(a: Color, b: Color) -> float:
	var la := luminance(a)
	var lb := luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)
