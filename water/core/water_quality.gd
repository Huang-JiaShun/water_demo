@tool
class_name WaterQuality
extends Resource
## Per-tier budgets. Only simulation fields are used in P0; later phases add
## caustic / volume / refraction settings here (see docs/water_architecture.md §7).

enum Tier { LOW, MEDIUM, HIGH }

@export var tier := Tier.MEDIUM

@export_group("Simulation")
## Texel count along the tank's longest horizontal axis. The other axis
## follows the tank aspect so texels stay square.
@export_range(32, 1024, 1) var sim_resolution := 256
## Fixed simulation tick rate. Decoupled from render frame rate.
@export_range(30.0, 240.0, 1.0) var sim_hz := 60.0
## Upper bound on CFL substeps per tick. If wave speed needs more, it is clamped.
@export_range(1, 16, 1) var max_substeps := 8

@export_group("Volume")
## Resolution divisor for the volume march (2 = half res, 4 = quarter res).
@export_range(1, 4, 1) var volume_downsample := 2
## Exponential march steps per volume pixel.
@export_range(4, 64, 1) var volume_steps := 16

@export_group("Caustics")
## Caustic grid texels along the tank's longest horizontal axis.
@export_range(32, 1024, 1) var caustic_resolution := 256
## Photons per texel along each axis (n*n photons per texel).
@export_range(1, 4, 1) var caustic_photons := 2
## March steps per photon against the light-depth map.
@export_range(1, 64, 1) var caustic_steps := 12
## A-trous denoise iterations.
@export_range(0, 4, 1) var caustic_denoise := 2
## Caustic-patterned god rays and light-depth shadows in the volume march.
@export var caustic_god_rays := true


static func preset(p_tier: Tier) -> WaterQuality:
	var q := WaterQuality.new()
	q.tier = p_tier
	match p_tier:
		Tier.LOW:
			q.sim_resolution = 128
			q.max_substeps = 2
			q.volume_downsample = 4
			q.volume_steps = 8
			q.caustic_resolution = 128
			q.caustic_photons = 1
			q.caustic_steps = 6
			q.caustic_denoise = 1
			q.caustic_god_rays = false
		Tier.MEDIUM:
			q.sim_resolution = 256
			q.max_substeps = 4
			q.volume_downsample = 2
			q.volume_steps = 16
		Tier.HIGH:
			q.sim_resolution = 512
			q.max_substeps = 8
			q.volume_downsample = 2
			q.volume_steps = 24
			q.caustic_resolution = 512
			q.caustic_steps = 16
	return q
