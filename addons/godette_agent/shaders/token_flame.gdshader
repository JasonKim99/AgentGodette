// Direct port of Balatro's flame.fs (resources/shaders/flame.fs in the
// game files). Adapted for the token-counter widget:
//   - Single instance, no per-id randomisation
//   - Uses our existing `body_top_uvy` / `corner_radius_uv` uniforms to
//     restrict the flame to the overflow region and fill the body's
//     transparent rounded-corner cutouts so the silhouette flows
//     seamlessly into the body underneath
//   - `colour_2` (hot tip accent) derived from ColorParameter so we
//     keep the single-colour UX the user already has
//
// Pipeline:
//   1. Pixelise UVs to a coarse grid (`PIXEL_SIZE_FAC`) — Balatro's
//      signature chunky pixel-art look
//   2. Self-distortion (small wave on the pixelised coords)
//   3. `flame_up_vec` — time-scrolling vector that the warp loop
//      pushes off, faking continuous upward flow
//   4. 5-iteration domain warp — the heart of Balatro's organic flame
//      shape. Each iteration accumulates `sv2` from `sv` plus radial
//      length-of-sv terms, then perturbs `sv` via cos/sin of `sv2`.
//      Result: a fluid-sim-flavoured vector field with curls / wisps.
//   5. Smoke density = how far each pixel's warped sv has drifted
//      from the original flow vector. Larger drift → "smoke" (alpha
//      0). Smaller drift → "flame" (alpha 1).
//   6. Two-colour gradient: blend toward the tip-accent colour near
//      the flame's base.
//   7. Coverage mask (overflow region + body corner cutouts).
shader_type canvas_item;
render_mode blend_mix;

uniform vec4 ColorParameter : source_color = vec4(1.0, 0.5, 0.1, 1.0);
uniform float flame_speed : hint_range(0.0, 5.0) = 1.0;
// Balatro's `amount` — controls flame size/density. 0 = no flame,
// 10 = roaring inferno. Affects feature scale and the alpha threshold.
uniform float flame_intensity : hint_range(0.0, 10.0) = 5.0;
uniform float body_top_uvy = 0.7;
uniform vec2 corner_radius_uv = vec2(0.05, 0.05);

// Coarseness of the UV quantisation. Balatro hardcodes 60 for a
// large square sprite; we use 30 because the token widget is much
// smaller in pixels and 60 would produce sub-pixel buckets.
const float PIXEL_SIZE_FAC = 30.0;


void fragment() {
	// Early-return at zero / near-zero intensity. Balatro's original
	// `flame.fs` does the same — when there's no fire to draw, skip
	// the entire warp + colour pipeline. For us this maps to "0 token
	// consumption → no flame" so a fresh install shows just the body
	// card without any wisps.
	if (flame_intensity < 0.1) {
		COLOR = vec4(0.0, 0.0, 0.0, 0.0);
	} else {

	vec2 uv = UV;

	// Centre the coordinate system on the flame's base. uv_centred.y
	// = 0 sits at body_top_uvy (= the line where flame meets body);
	// negative values are ABOVE the base (the overflow region where
	// the flame is visible), positive values are below (inside body).
	vec2 uv_centred = vec2(uv.x - 0.5, uv.y - body_top_uvy);

	// ---- 1. Pixelise -------------------------------------------------
	// floor(uv * grid) / grid — quantise to PIXEL_SIZE_FAC×N buckets.
	// All subsequent maths runs on these stepped coords so the flame
	// has the chunky pixel-art outline Balatro is known for.
	vec2 floored_uv = floor(uv_centred * PIXEL_SIZE_FAC) / PIXEL_SIZE_FAC;

	// ---- 2. Self-distortion -----------------------------------------
	// Small (1%) ripple on the pixelised coords. The sin*cos product
	// gives a slowly-drifting per-pixel offset that breaks up any
	// strict grid alignment without being readable as a separate
	// effect.
	floored_uv += floored_uv * 0.01 * (
		sin(-1.123 * floored_uv.x + 0.2 * TIME * flame_speed) *
		cos(5.3332 * floored_uv.y + TIME * flame_speed * 0.931)
	);

	// ---- 3. Time-scrolling flow vector ------------------------------
	// In Balatro this is `(0, 4*time)` — positive y because LÖVE's
	// texture y is down. We're also y-down in Godot's UV, so keep
	// the sign positive. `mod(..., 10000)` keeps the magnitude
	// bounded so floats stay precise over long sessions.
	vec2 flame_up_vec = vec2(0.0, mod(4.0 * TIME * flame_speed, 10000.0) - 5000.0);

	// ---- 4. 5-iteration domain warp ---------------------------------
	// Initial vector field: pixelised coords scaled up + flow offset.
	// `scale_fac` is Balatro's intensity-dependent zoom — higher
	// intensity → smaller scale_fac → bigger features.
	float scale_fac = 7.5 + 3.0 / (2.0 + 2.0 * flame_intensity);
	vec2 sv = floored_uv * scale_fac + flame_up_vec;
	// Per-instance speed wobble. Balatro derives this from `id` for
	// per-flame variation; we mod the time directly for a single-
	// flame variation rate.
	float warp_speed = 1.0 + sin(TIME * flame_speed) * cos(TIME * flame_speed * 0.151);
	vec2 sv2 = vec2(0.0);

	// Loop unrolled is faster on some GPUs but Godot's compiler
	// handles the unroll, so leave it as a regular loop.
	for (int i = 0; i < 5; i++) {
		// Alternating sign on sv2.yx accumulation gives the warp its
		// counter-rotating "twist" instead of a single shear.
		float i_sign = mod(float(i), 2.0) > 1.0 ? -1.0 : 1.0;
		sv2 += sv + 0.05 * sv2.yx * i_sign +
			0.3 * (cos(length(sv) * 0.411) + 0.3344 * sin(length(sv)) - 0.23 * cos(length(sv)));
		sv += 0.5 * vec2(
			cos(cos(sv2.y) + warp_speed * 0.0812) * sin(3.22 + sv2.x - warp_speed * 0.1531),
			sin(-sv2.x * 1.21222 + 0.113785 * warp_speed) * cos(sv2.y * 0.91213 - 0.13582 * warp_speed)
		);
	}

	// ---- 5. Smoke density -------------------------------------------
	// How far has this pixel's vector drifted from the original
	// flow direction? Pixels whose warp stays close to flame_up_vec
	// remain "in" the flame; pixels swept far away are smoke.
	float smoke_res = max(0.0,
		length((sv - flame_up_vec) / scale_fac * 5.0) +
		0.1 * (length(uv_centred) - 0.5)
	) * (2.0 / (2.0 + flame_intensity * 0.2));

	// Side decay: enforce that the flame doesn't reach the rect's
	// horizontal edges. Balatro caps at ±0.4 from centre; we match.
	if (abs(uv_centred.x) > 0.4) {
		smoke_res += 10.0 * (abs(uv_centred.x) - 0.4);
	}

	// ---- 6. Two-colour gradient -------------------------------------
	// Derive the tip accent from ColorParameter — for warm bases (red /
	// orange) this lerps through yellow toward white; for cool bases
	// (blue / green) it lerps through pale-warm. Keeps the single-
	// colour UX while giving the flame Balatro's hot-tip look.
	vec3 base_col = ColorParameter.rgb;
	vec3 tip_col = mix(base_col, vec3(1.0, 0.95, 0.6), 0.7);
	vec3 flame_rgb = base_col;
	// Balatro applies the blend in the UPPER portion of the flame
	// (the tip side), leaving the base ~38% of flame height as pure
	// `colour_1`. Larger `blend_t` further from base → heavier mix
	// toward the tip accent. We scale the no-blend zone by
	// body_top_uvy so the proportion stays correct regardless of the
	// user's overflow_top setting.
	float no_blend_zone = body_top_uvy * 0.38;
	if (uv_centred.y < -no_blend_zone) {
		float blend_t = -no_blend_zone - uv_centred.y;
		flame_rgb = base_col * (1.0 - 0.5 * blend_t) + 2.5 * blend_t * tip_col;
		// Balatro's intensity-modulated darkening — creates a subtle
		// shadow band before the bright accent peaks at the tip.
		flame_rgb += flame_rgb * (-2.0 + 0.5 * flame_intensity * smoke_res) * blend_t;
	}

	// ---- 7. Coverage mask -------------------------------------------
	// Confine flame to the overflow region above the body. The fade
	// window sits ENTIRELY BELOW body_top_uvy so flame stays opaque
	// up to body's top edge with no faint-red strip.
	float in_overflow = 1.0 - smoothstep(body_top_uvy, body_top_uvy + 0.02, uv.y);

	// Corner-fill: body's transparent rounded-corner cutouts get
	// flame colour so the silhouette transitions seamlessly through
	// them rather than showing dock background.
	float corner_fill = 0.0;
	if (uv.y > body_top_uvy && uv.y < body_top_uvy + corner_radius_uv.y) {
		bool near_left = uv.x < corner_radius_uv.x;
		bool near_right = uv.x > 1.0 - corner_radius_uv.x;
		if (near_left || near_right) {
			corner_fill = 1.0;
		}
	}
	float coverage = max(in_overflow, corner_fill);

	// Final alpha: flame is "on" when smoke_res ≤ 1, off otherwise.
	float flame_alpha = smoke_res > 1.0 ? 0.0 : 1.0;

	COLOR.rgb = flame_rgb;
	COLOR.a = flame_alpha * coverage;

	}  // end of `else` (flame_intensity >= 0.1)
}
