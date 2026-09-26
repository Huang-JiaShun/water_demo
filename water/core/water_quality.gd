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


static func preset(p_tier: Tier) -> WaterQuality:
	var q := WaterQuality.new()
	q.tier = p_tier
	match p_tier:
		Tier.LOW:
			q.sim_resolution = 128
			q.max_substeps = 2
		Tier.MEDIUM:
			q.sim_resolution = 256
			q.max_substeps = 4
		Tier.HIGH:
			q.sim_resolution = 512
			q.max_substeps = 8
	return q
