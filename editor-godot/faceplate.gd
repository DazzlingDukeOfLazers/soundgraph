# The finish on a panel.
#
# A theme names a colour and a *finish*, and until now only the colour was drawn — which
# is why five very different-sounding descriptions all came out as the same flat
# rectangle in five hues. Worn edges, a halftone, a photocopy and a machined face are not
# adjectives; they are the difference between a colour swatch and a panel.
#
# Each finish is a small tileable RGBA image, generated once and kept. The pixels are
# deviations rather than colours: a light fleck is white with some alpha, a dark one is
# black with some alpha, and the panel underneath shows through everywhere else. That way
# one texture works over teal, mustard and ivory alike, and the strength is a single
# modulate at draw time rather than eleven hand-tuned overlays.
#
# Generated rather than shipped as files. They are noise — a PNG of noise is a PNG that
# somebody has to look at in a diff and cannot check, and it would be the only binary
# asset in the editor.
#
# Deterministic on purpose: a fixed seed per finish, so the same panel has the same
# blemishes every run. A screenshot test that has to tolerate different dirt each time is
# not a test, and a panel that reshuffles its wear when the window resizes reads as
# static rather than as a surface.
extends RefCounted

## Every finish the themes can ask for. `matte` is the quiet default.
const FINISHES := ["matte", "worn", "dirty", "halftone", "machined", "industrial",
	"photocopy"]

## Tile size. Big enough that the eye does not find the repeat on a 120px panel, small
## enough that eleven of them cost nothing to hold.
const TILE := 96

## Built once each, on first use. A rack redraws constantly and none of this may happen
## more than once per finish for the life of the editor.
static var _cache: Dictionary = {}


## The texture for a finish, generated on first ask.
static func texture(finish: String) -> Texture2D:
	var key := finish if FINISHES.has(finish) else "matte"
	if _cache.has(key):
		return _cache[key]
	var image := _render(key)
	var made := ImageTexture.create_from_image(image)
	_cache[key] = made
	return made


## How strongly a finish is laid over the panel, before the theme's own grain scales it.
## A photocopy is meant to be seen; a machined face is meant to be felt.
static func strength(finish: String) -> float:
	match finish:
		"photocopy": return 1.0
		"halftone": return 0.75
		"dirty": return 0.8
		"worn": return 0.7
		"machined": return 0.5
		"industrial": return 0.45
		_: return 0.6


static func _render(finish: String) -> Image:
	var image := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	# One seed per finish, so each is its own surface and each is the same every run.
	rng.seed = hash(finish)

	match finish:
		"halftone":
			_halftone(image)
		"machined":
			_streaks(image, rng, true, 0.5)
		"industrial":
			_streaks(image, rng, false, 0.35)
		"dirty":
			_blotches(image, rng)
		"photocopy":
			_photocopy(image, rng)
		"worn":
			_speckle(image, rng, 0.35, 0.55)
		_:
			_speckle(image, rng, 0.18, 0.5)
	return image


## A deviation, as a pixel: light above the middle, dark below, nothing at it.
static func _put(image: Image, x: int, y: int, value: float) -> void:
	var deviation := clampf(value, -1.0, 1.0)
	if deviation >= 0.0:
		image.set_pixel(x, y, Color(1.0, 1.0, 1.0, deviation))
	else:
		image.set_pixel(x, y, Color(0.0, 0.0, 0.0, -deviation))


## Fine even grain. The default, and what "matte" and "soft grain" mean.
static func _speckle(image: Image, rng: RandomNumberGenerator, amount: float,
		bias: float) -> void:
	for y in TILE:
		for x in TILE:
			# Two draws averaged: one uniform sample is too even and reads as television
			# static rather than as a surface.
			var value := (rng.randf() + rng.randf()) * 0.5
			_put(image, x, y, (value - bias) * 2.0 * amount)


## Brushed metal: long scratches along one axis, of varying darkness.
static func _streaks(image: Image, rng: RandomNumberGenerator, horizontal: bool,
		amount: float) -> void:
	# Each line gets its own tone, so the surface is banded rather than noisy - that is
	# the whole difference between machined and sandblasted.
	#
	# Most lines are nearly nothing. Giving every one a full-range tone drew even stripes
	# at even spacing, which is a venetian blind rather than a brushed face; a machined
	# surface is mostly flat with the occasional deeper score in it.
	var lines: Array = []
	for i in TILE:
		var tone := (rng.randf() - 0.5) * 2.0
		# Cubed: keeps the sign, crushes the middle, leaves the rare strong line alone.
		lines.append(tone * tone * tone * amount)
	for y in TILE:
		for x in TILE:
			var along: float = lines[y if horizontal else x]
			# A little per-pixel jitter, or the lines look printed.
			var jitter := (rng.randf() - 0.5) * amount * 0.5
			_put(image, x, y, along + jitter)


## A regular dot grid, the way a cheap print screen puts one down.
static func _halftone(image: Image) -> void:
	var pitch := 8            # divides TILE, so the tile repeats without a seam
	var radius := 2.1
	image.fill(Color(0, 0, 0, 0))
	for cy in range(0, TILE, pitch):
		for cx in range(0, TILE, pitch):
			for y in range(cy - 3, cy + 4):
				for x in range(cx - 3, cx + 4):
					var distance := Vector2(x - cx, y - cy).length()
					if distance > radius:
						continue
					# Soft edge on the dot, so it is a printed dot and not a pixel.
					var fade := clampf(1.0 - distance / radius, 0.0, 1.0)
					_put(image, posmod(x, TILE), posmod(y, TILE), -fade * 0.5)


## Uneven staining: low-frequency patches, the way a lab panel ages badly.
static func _blotches(image: Image, rng: RandomNumberGenerator) -> void:
	# A coarse grid of values, smoothly interpolated up. Value noise, by hand, because
	# it is nine lines and the alternative is a dependency.
	#
	# The grid *wraps*: the cell after the last is the first, so the tile has no seam.
	# Without that, every 96 pixels showed a hard edge where one patch stopped and
	# another started, and a wall of modules read as a tiled bathroom rather than as
	# staining. Sixteen cells rather than twelve for the same reason - smaller patches
	# make the repeat harder to find.
	var coarse := 16
	var grid: Array = []
	for i in coarse * coarse:
		grid.append(rng.randf())
	var step := float(TILE) / float(coarse)
	for y in TILE:
		for x in TILE:
			var gx := float(x) / step
			var gy := float(y) / step
			var x0 := int(gx)
			var y0 := int(gy)
			var fx := gx - x0
			var fy := gy - y0
			# Smoothstep the weights, or the patches show their grid.
			fx = fx * fx * (3.0 - 2.0 * fx)
			fy = fy * fy * (3.0 - 2.0 * fy)
			var x1 := (x0 + 1) % coarse
			var y1 := (y0 + 1) % coarse
			var a: float = grid[y0 * coarse + x0]
			var b: float = grid[y0 * coarse + x1]
			var c: float = grid[y1 * coarse + x0]
			var d: float = grid[y1 * coarse + x1]
			var value: float = lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)
			# Weighted downwards: dirt darkens, it does not polish. Gently - the first
			# version put a mean alpha of 0.29 over the panel, which is not a finish,
			# it is a second colour.
			_put(image, x, y, (value - 0.58) * 0.55 + (rng.randf() - 0.5) * 0.08)


## A photocopy: crushed to two tones, with the speckle that comes off a drum.
static func _photocopy(image: Image, rng: RandomNumberGenerator) -> void:
	for y in TILE:
		for x in TILE:
			var value := rng.randf()
			# Mostly clean, with occasional hard flecks both ways. The long tail is the
			# point - an even grain reads as noise, a sparse one reads as a bad copy.
			if value > 0.965:
				_put(image, x, y, 0.85)
			elif value < 0.05:
				_put(image, x, y, -0.75)
			else:
				_put(image, x, y, (value - 0.5) * 0.16)
