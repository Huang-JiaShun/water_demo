@tool
class_name WaterOptics
extends Resource
## Physical description of the water medium. Coefficients are per meter.
## Consumed by the surface shader (IOR), the volume pass (σa, σs, g) and
## caustics (IOR, dispersion). Published as global shader params by WaterGlobals.

## Absorption coefficient σa (1/m). Pure water absorbs red strongly, blue weakly.
@export var absorption := Vector3(0.45, 0.07, 0.03):
	set(v):
		absorption = v
		emit_changed()

## Scattering coefficient σs (1/m). Suspended particles; low for a clean tank.
@export var scattering := Vector3(0.04, 0.05, 0.06):
	set(v):
		scattering = v
		emit_changed()

## Henyey-Greenstein anisotropy. Water particles are strongly forward-scattering.
@export_range(-0.99, 0.99, 0.01) var phase_g := 0.85:
	set(v):
		phase_g = v
		emit_changed()

@export_range(1.0, 2.0, 0.001) var ior := 1.333:
	set(v):
		ior = v
		emit_changed()

## IOR spread between red and blue used for caustic / refraction dispersion.
@export_range(0.0, 0.05, 0.001) var dispersion := 0.01:
	set(v):
		dispersion = v
		emit_changed()

@export_group("View tint")
## Colour the water fades toward when seen through the glass or from above.
## An artistic stand-in for in-scatter, separate from the volume pass.
@export var view_color := Color(0.05, 0.32, 0.36):
	set(v):
		view_color = v
		emit_changed()

## Extinction (absorption + scattering, 1/m) for the view tint. Independent of
## the physical coefficients above, so the volume pass can be off (σ = 0) while
## the glass and surface still read as tinted water.
@export var view_extinction := Vector3(0.49, 0.12, 0.09):
	set(v):
		view_extinction = v
		emit_changed()

## Multiplier on view_extinction.
@export_range(0.0, 50.0, 0.01) var view_density := 8.0:
	set(v):
		view_density = v
		emit_changed()

## Longest water path (m) the view tint accounts for.
@export_range(0.0, 10.0, 0.01, "suffix:m") var view_max_path := 3.0:
	set(v):
		view_max_path = v
		emit_changed()
