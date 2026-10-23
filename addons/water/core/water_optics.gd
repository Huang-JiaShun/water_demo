@tool
class_name WaterOptics
extends Resource
## Physical description of the water medium. Coefficients are per meter.
## Consumed by the surface shader (IOR), the volume pass (σa, σs, g) and
## caustics (IOR, dispersion). Published as global shader params by WaterGlobals.

@export_group("Look")
## What is in the water: 0 = sea water (fine mineral silt, scatters blue),
## 1 = algal bloom (chlorophyll absorbs blue and red, cells scatter green).
@export_range(0.0, 1.0, 0.01) var algae := 0.0:
	set(v):
		algae = v
		emit_changed()

## Concentration of that matter. 0 = pure water, 1 = a typical tank, higher =
## murkier. More matter absorbs more light, so the water also gets darker.
@export_range(0.0, 4.0, 0.01) var turbidity := 1.0:
	set(v):
		turbidity = v
		emit_changed()

@export_group("Medium")
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
## Scales the view-tint extinction: the effective path length the glass and
## surface pretend the light travels (the tank is small, real water is deep).
@export_range(0.0, 50.0, 0.01) var view_density := 8.0:
	set(v):
		view_density = v
		emit_changed()

## Longest water path (m) the view tint accounts for.
@export_range(0.0, 10.0, 0.01, "suffix:m") var view_max_path := 3.0:
	set(v):
		view_max_path = v
		emit_changed()


# --- Effective values (pure water + suspended matter) ------------------------
# Consumers read these, never the base fields directly. Coefficients per meter
# per unit turbidity; the absorption of pure water itself is always present.

const _PURE_WATER := Vector3(0.45, 0.07, 0.02)
const _SEA_ABSORB := Vector3(0.03, 0.04, 0.06)  # dissolved matter, mild
const _SEA_SCATTER := Vector3(0.04, 0.05, 0.07) # fine silt: Rayleigh-ish, bluish
const _ALGAE_ABSORB := Vector3(0.30, 0.08, 0.55) # chlorophyll: blue and red bands
const _ALGAE_SCATTER := Vector3(0.08, 0.14, 0.06) # cells look green

## Ambient light the view tint in-scatters, and the depth (m) at which it is
## sampled: deeper or murkier water receives less of it, so it darkens.
const _AMBIENT := 1.2
const _TINT_DEPTH := 0.25


func _matter_absorption() -> Vector3:
	return _SEA_ABSORB.lerp(_ALGAE_ABSORB, algae) * turbidity


func _matter_scattering() -> Vector3:
	return _SEA_SCATTER.lerp(_ALGAE_SCATTER, algae) * turbidity


func get_absorption() -> Vector3:
	return absorption + _matter_absorption()


func get_scattering() -> Vector3:
	return scattering + _matter_scattering()


## Extinction of the view tint: pure water plus the suspended matter. The
## pure-water term fades out below turbidity 1 so that 0 is fully clear (the
## view density exaggerates the tank's depth, which would keep a cyan cast).
func get_view_extinction() -> Vector3:
	return _PURE_WATER * minf(turbidity, 1.0) + _matter_absorption() + _matter_scattering()


func get_view_density() -> float:
	return view_density


## Colour the water converges to: single-scatter albedo σs/σt times the ambient
## light left after travelling down to _TINT_DEPTH. Clear water has no
## scatterers and stays transparent; more matter tints first, then darkens.
func get_view_color() -> Color:
	var ext := get_view_extinction()
	var s := _matter_scattering()
	var c := Vector3.ZERO
	for i in 3:
		c[i] = 0.0 if ext[i] <= 0.0 else _AMBIENT * s[i] / ext[i] * exp(-view_density * _TINT_DEPTH * ext[i])
	return Color(c.x, c.y, c.z)
