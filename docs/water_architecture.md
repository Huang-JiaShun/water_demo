# Aquarium Water Rendering — Architecture (Godot 4.7, Forward+)

Inspired by HPWater (Unity HDRP). This is a redesign built on Godot's rendering, not a port.

---

## 1. What we take from HPWater, and what we leave behind

| HPWater technique | Keep? | Godot redesign |
|---|---|---|
| Wave equation on a GPU heightfield, ping-pong buffers | **Keep** | RD compute, fixed timestep with substeps |
| Obstacles from a top-down scene-vs-water height bake, **Neumann (reflective) boundaries** | **Keep** (a very good fit for tanks: the glass walls reflect) | Orthographic bake with a SubViewport, run once and again when decor changes |
| Sponge-layer edge damping | **Drop** | A tank has real walls. Waves should reflect off them, not get absorbed |
| Caustics: refract the light through the surface normal, march light-space depth, accumulate photons with `InterlockedAdd`, then à-trous denoise | **Keep** | We bake our own light-space depth because Godot does not expose its shadow atlas. `imageAtomicAdd` on an `r32ui` texture |
| RGB dispersion (3 buffers) vs. faked dispersion at sampling time | **Keep the faked mode**, make true RGB optional | Chosen by quality tier |
| Volumetric single scattering: exponential stepping + IGN dither, HG (Mie) + Rayleigh phase blend, Beer–Lambert with the scattering-albedo split | **Keep** (this is the core of the "aquarium look") | CompositorEffect compute at half resolution. The ray is clipped to the tank AABB |
| Temporal reprojection (motion vectors + depth rejection), à-trous, joint bilateral upsample | **Keep** | Compositor passes. Godot supplies the velocity buffer (`needs_motion_vectors`) |
| Screen-space refraction: fast offset by default, optional exponential-step ray march with thickness test | **Keep** | In the water surface spatial shader, using `hint_screen_texture` and `hint_depth_texture` |
| Shadowed god rays | **Keep, re-sourced** | Sample our own light-space depth **multiplied by the caustic texture**. This gives caustic-patterned god rays for free |
| 3-MRT custom water GBuffer, deferred water light loop | **Drop** | Godot is forward. The surface is one forward material, and medium lighting lives in the volume pass |
| HDRP shadow atlas / cascade reuse, cluster light loop, RenderGraph transparent-pass hooks | **Drop** | Not reachable in Godot. Not needed at aquarium scale (one sun or key light, a tank-sized light frustum) |
| Ocean-tuned thin-layer SSS / backlit terms (20 m path scale) | **Drop / optional** | A tank surface is nearly flat and thin. Only a cheap backlit HG lobe is kept, off by default |
| `_DeltaTime = 1/60` hardcoded in the solver | **Fix** | Fixed-dt accumulator with a CFL clamp, so behaviour is independent of frame rate |

---

## 2. Aquarium-specific framing (drives every decision)

- The camera is usually **outside the tank, looking through the glass**. What you see most is the *medium*: fog, colour absorption, god rays and caustics on the decor. The surface is seen mostly **from below**, through the front glass: Snell's window and total internal reflection (TIR).
- The domain is **bounded and small**, a single AABB. That makes ray–box clipping, one orthographic light frustum and one sim grid covering the whole tank all cheap and exact.
- The scene is mostly static (decor), with dynamic fish. Light depth and obstacles can be **baked**, then refreshed only when something changes.

---

## 3. Core principle: one owner per physical effect

Avoid double-counting absorption and scattering between passes:

| Effect | Sole owner |
|---|---|
| Absorption / in-scatter along the camera ray inside the tank | **Volume pass** (Compositor, post-opaque) |
| Air↔water interface: Fresnel, refraction offset, specular, TIR | **Surface shader** |
| Caustic irradiance on underwater surfaces | **Caustics system**. Consumed by decor via a shader include |
| Fog on *transparent* underwater objects (bubbles, particles) | Analytic `water_fog()` include. The volume pass cannot see transparents |

Because the volume composite runs **post-opaque**, the screen texture the surface shader refracts already contains the fogged underwater scene, so the ordering is physically consistent.

---

## 4. Module layout

```
res://addons/water/
  core/
    water_body.gd            # Node3D: tank AABB, owns subsystems, quality tier, publishes globals
    water_optics.gd          # Resource: absorption σa(rgb), scattering σs(rgb), phase g, IOR, dispersion
    water_quality.gd         # Resource: per-tier resolutions / step counts / feature toggles
    water_globals.gd         # Registers + updates RenderingServer global shader params
    rd_util.gd               # Texture/uniform-set helpers, render-thread guards, RID lifetime
  sim/
    wave_sim.gd              # RD compute driver: substeps, splat buffer, ping-pong
    wave_step.glsl           # Wave equation + Neumann obstacles
    wave_splat.glsl          # N gaussian impulses from a storage buffer (fish, mouse, drops)
    wave_derive.glsl         # Height -> RGBA16F (h, ∂h/∂x, ∂h/∂z, curvature/foam)
    obstacle_baker.gd        # Ortho top-down SubViewport: scene height vs water level -> mask
  caustics/
    light_depth_baker.gd     # Ortho light-space depth of tank interior (SubViewport, on demand)
    caustics.gd              # Driver: clear -> photon splat -> à-trous -> resolve to R16F
    caustic_splat.glsl
    caustic_denoise.glsl
  surface/
    water_surface.gdshader   # Interface only: Fresnel, refraction, spec, Snell window / TIR
  volume/
    water_volume_effect.gd   # CompositorEffect (POST_OPAQUE), needs_motion_vectors
    volume_march.glsl        # Half-res march, clipped to tank AABB
    volume_temporal.glsl     # Reprojection + depth/velocity rejection
    volume_composite.glsl    # Joint bilateral upsample, color = scene*T + inscatter
  shared/
    water_common.glsl        # Phase fns, Beer–Lambert, IGN/R2, exp stepping (RD side)
    water_common.gdshaderinc # Same math for spatial shaders
    underwater.gdshaderinc   # caustics() + water_fog() for decor/fish/particle materials
  plugin.cfg, plugin.gd      # EditorPlugin: declares the water_* [shader_globals] on enable

res://demo/                  # Aquarium demo scene and its helper scripts (not part of the addon)
res://tests/                 # Headless verify_p*.gd checks and shot_demo.gd
```

To reuse the water in another project, copy `addons/water/` and enable the **Water** plugin
(Project Settings → Plugins). Enabling it adds the global shader parameters listed in
`WaterGlobals.DECLARATIONS`; disabling it removes them.

Two parallel "common" files are unavoidable: RD GLSL and `.gdshader` cannot include each other. Keep both small and mirror them by hand.

---

## 5. Per-frame data flow

```
Main thread (_process / _physics_process)
  gather interactions (fish, mouse, drops) -> PackedFloat32Array splats
  RenderingServer.call_on_render_thread(frame_update)

Render thread, before scene draw
  [sim]      splat -> step×N (fixed dt) -> derive      => wave_tex (RGBA16F)
  [caustics] clear r32ui -> splat photons -> à-trous  => caustic_tex (R16F, mips)
             (inputs: wave_tex, light_depth_tex [baked])

Scene render (Forward+)
  opaque decor/fish  --samples--> caustic_tex, light_depth_tex (underwater.gdshaderinc)
  sky
  Compositor POST_OPAQUE: volume march (½ res) -> temporal -> upsample+composite into color
  transparents: water_surface (reads screen+depth, wave_tex), glass, bubbles (water_fog())
```

Shared resources reach materials through **`Texture2DRD`** wrappers plus **global shader params**:
`water_wave_tex`, `water_caustic_tex`, `water_light_depth_tex`, `water_light_vp` (mat4), `water_tank_min/max`, `water_level`, `water_sigma_a`, `water_sigma_s`, `water_phase_g`.

---

## 6. Subsystem designs

### 6.1 Wave simulation
- Grid covers the tank's XZ footprint. The texel aspect follows the tank aspect, e.g. 256×128.
- State is `RG32F` = (h_t, h_{t-1}) in one texture, swapped between 2 images. This halves the bindings compared with the current 3-texture scheme.
- `u' = u + (u - u_prev)·(1-damping) + (c·dt/dx)²·∇²u`, with `c·dt/dx ≤ 0.5` enforced in the driver by substepping.
- Neumann boundary: if a neighbour is an obstacle or out of bounds, use the centre value. HPWater does exactly this, and it is correct for glass walls.
- Obstacle mask from `obstacle_baker` (decor that pokes through the surface: rocks, plants, filter intake).
- Splats come from a storage buffer of up to 64 `(uv, radius, strength)` entries. Fish near the surface push impulses scaled by speed.
- `wave_derive` writes central-difference gradients once, so every consumer (surface, caustics, volume) reads normals instead of re-deriving them.

### 6.2 Caustics
- **Light-depth bake:** an orthographic camera aligned to the key light, fitted to the tank AABB, renders tank-interior depth into a SubViewport. It re-bakes only when the light rotates or decor moves.
- **Photon splat (per caustic texel = per surface sample):**
  1. Take the surface point and its normal from `wave_tex`, then `refract(L, n, 1/1.33)`.
  2. Subtract the flat-surface refraction and add `L`. This is HPWater's trick: the pattern stays registered with the ordinary shadow projection, so a calm surface gives uniform light.
  3. Run a 12–16 step exponential march in light-space NDC against `light_depth_tex`, with an R2 dither.
  4. `imageAtomicAdd(caustic_u32, hit_texel, fixed_point_energy)`.
- **Denoise:** 1–2 à-trous iterations using LDS, then resolve to R16F and generate mips.
- **Sampling** (`underwater.gdshaderinc`): project the world position with `water_light_vp`. Choose the mip level from the scattering coefficient × depth below the surface, as HPWater does: deeper means blurrier. Faked dispersion offsets the R and B lookups along the wave gradient.
- **Consumption:** decor materials apply the caustic in `light()` for the directional light: `DIFFUSE_LIGHT += caustic * ATTENUATION * LIGHT_COLOR * NdotL * albedo_term`. This respects Godot's own shadows.

### 6.3 Volume (CompositorEffect, POST_OPAQUE)
- **March at ½ resolution** (¼ on low tier):
  1. Intersect the camera ray with the tank AABB and clip it to the scene depth.
  2. Use N = 12–24 exponential steps with an IGN dither jittered per frame.
- **At each sample:**
  - visibility = light-depth test × caustic sample (this produces the god rays)
  - sun path length = distance to the surface along -L (analytic, because the surface is a plane)
  - Beer–Lambert on the sun path and the view segment
  - phase = 0.95 HG(g) + 0.05 Rayleigh
  - HPWater's "albedo → isotropic" blend as an approximation of multiple scattering
  - an ambient in-scatter term from the ambient light colour
- **Output:** (inscatter.rgb, luminance(transmittance)), with per-channel T packed in a second target if needed.
- **Temporal:** reproject with Godot's velocity buffer. Reject history on depth mismatch. Blend weight about 0.9, reduced when velocity is high.
- **Composite:** a joint bilateral upsample guided by full-resolution depth, then `color = scene * T + inscatter`. The depth guide prevents fog bleeding onto the glass or foreground edges.

### 6.4 Surface shader (interface only)
- `cull_disabled`. `FRONT_FACING` selects the air→water or water→air path.
- **Normal:** geometric normal plus the gradient from `wave_tex`, plus 1–2 scrolling micro-detail normal maps (small amplitude).
- **Refraction:** screen UV offset by the normal. Reject the sample if the refracted depth is *in front of* the surface; this fixes foreground bleeding. An optional 8-step exponential depth march is available as the high-precision mode (from HPWater).
- **From below:** Fresnel with eta 1.33, and TIR beyond about 48.6°. The reflection comes from a tank-interior ReflectionProbe, because Godot has no SSR on transparents. This produces Snell's window naturally.
- **From above:** reflection from sky/probe radiance, GGX specular from the light.
- No absorption here; the volume pass owns absorption.

---

## 7. Quality tiers (target: 1080p, mid-range GPU)

| Tier | Sim | Caustics | Volume | Refraction | Budget |
|---|---|---|---|---|---|
| Low | 128², 1 substep | analytic scrolling texture (no compute) | ¼ res, 8 steps, no temporal | offset only | ~0.3 ms |
| Medium | 256², 2 substeps | 512² photon splat, mono + fake dispersion | ½ res, 16 steps, temporal | offset + depth reject | ~1.0 ms |
| High | 512², 2 substeps | 1024² splat, true RGB | ½ res, 24 steps, temporal + à-trous | 8-step march | ~2.0 ms |

Forward+ is required for compute and the Compositor. On Compatibility/Mobile, fall back to the Low tier with `water_fog()` used everywhere.

---

## 8. Roadmap

1. **P0 Foundation:** `WaterBody`, optics/quality resources, globals, RD utilities. Refactor the sim: tank-sized grid, RG32F state, fixed dt, Neumann walls, splat buffer, derive pass.
2. **P1 Surface:** interface shader with refraction depth-reject and Snell window/TIR, and the tank ReflectionProbe.
3. **P2 Volume:** CompositorEffect march + composite (no temporal yet), plus `water_fog()` for transparents.
4. **P3 Caustics:** light-depth bake, photon splat, denoise, `underwater.gdshaderinc`, caustic god rays in the volume.
5. **P4 Polish:** temporal + à-trous for the volume, true-RGB caustics, a meniscus/foam line at the glass, bubbles, and tier switching.
   - Done: `volume_temporal.glsl` (reprojects through tank space, rejects on depth mismatch, 3×3 neighbourhood clamp) and `volume_denoise.glsl` (depth-aware à-trous). True-RGB caustics use one r32ui photon image with three stacked bands resolved to RGBA32F. The meniscus and foam line live in `water_surface.gdshader`. `addons/water/bubbles/` has a GPUParticles3D stream shaded with `water_fog()`. `WaterBody.set_tier()` handles tier switching (keys 1/2/3 in the demo). Check with `tests/verify_p4.gd`.

## 9. Issues in the current demo code (addressed by P0)
- `if (new_v < 0.0) new_v = 0.0;` clips every trough, so the physics is wrong (only positive waves survive).
- The impulse is a single texel. It should be a Gaussian splat, as HPWater does, to avoid high-frequency ringing.
- There is no timestep control: the sim runs one step per rendered frame, so wave speed changes with frame rate.
- The plane size `5.0` is hard-coded in the mouse mapping.
- Normals are re-derived in the fragment shader, with the Z component used as height on a Y-up plane.
