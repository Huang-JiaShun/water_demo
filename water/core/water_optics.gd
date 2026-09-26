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
