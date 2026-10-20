extends Node
## Demo helper: keys 1 / 2 / 3 switch the WaterBody quality tier (Low / Medium / High).

@export var body: WaterBody


func _unhandled_input(event: InputEvent) -> void:
	if body == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var tiers := {KEY_1: WaterQuality.Tier.LOW, KEY_2: WaterQuality.Tier.MEDIUM, KEY_3: WaterQuality.Tier.HIGH}
	var key: Key = (event as InputEventKey).keycode
	if tiers.has(key):
		body.set_tier(tiers[key])
		print("Water quality: ", WaterQuality.Tier.keys()[tiers[key]])
