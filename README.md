# Water Demo

Real-time aquarium water for Godot 4.7 (Forward+): a GPU wave simulation with reflective
obstacles, light caustics, volumetric in-water scattering, and glass and surface shaders.

Language: GDScript

Renderer: Forward+

## Layout

- `addons/water/`: the reusable water addon (the `WaterBody` node, the simulation, caustics,
  volume pass and shaders).
- `demo/`: the aquarium demo scene (`aquarium_demo.tscn`, the main scene) and its helpers.
- `tests/`: headless checks and a screenshot script.
- `docs/water_architecture.md`: design and data flow.

## Using the addon in another project

1. Copy `addons/water/` into the project.
2. Enable **Water** under Project Settings → Plugins. This declares the `water_*` global
   shader parameters in `project.godot`, which the water shaders need in order to compile.
3. Add a `WaterBody` node and give it a `WaterOptics` and a `WaterQuality` resource.
   `demo/aquarium_demo.tscn` shows a complete setup.

## Tests

```
godot --path . --script res://tests/verify_p0.gd
godot --path . --script res://tests/verify_p3.gd
godot --path . --script res://tests/verify_p4.gd
```

These need a GPU (RenderingDevice), so they cannot run with `--headless`.

## Licenses

Files in `assets/polyhaven/` are downloaded from <https://polyhaven.com/> and are
licensed under CC0 1.0 Universal.
