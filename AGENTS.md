# AGENTS.md

## Project layout

- `addons/water/`: the reusable water addon. Keep it self-contained: no references to `demo/` or `tests/`.
- `demo/`: the aquarium demo (main scene). `tests/`: GPU verify scripts (`godot --path . --script res://tests/verify_p0.gd`).
- New `water_*` global shader parameters go in `WaterGlobals.DECLARATIONS` and in `project.godot` `[shader_globals]`.

## GodotPrompter

Before implementing any Godot system, check for a matching `godot-prompter:*` skill and invoke it
(for example `shader-basics`, `addon-development`, `3d-essentials`, `godot-testing`).
Before building, say which pattern you picked, which alternative you rejected, and why.
