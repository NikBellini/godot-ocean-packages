shader_type spatial;
render_mode cull_back, unshaded, shadows_disabled;
/**
 * Draws the shared sea-spray texture as camera-facing sheets.
 * Native waves use the original distance/dissolve behavior. Object spray uses its
 * reduced opacity, so it remains readable near the camera without dominating.
 * Shading is intentionally unlit; the foam tint supplies a consistent spray color.
 */

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;

uniform float max_alpha : hint_range(0, 1) = 0.666; // Native wave spray only.
uniform sampler2D albedo_texture : source_color, repeat_enable;
uniform sampler2D dissolve_texture : source_color, repeat_enable;
uniform float contact_spray_opacity : hint_range(0, 1) = 0.65;

varying float dissolve_factor;
varying float alpha_fade;
varying float contact_spray;

void vertex() {
	// Face the camera while preserving world-space size set by the particle simulation.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz),0,0,0), vec4(0,length(MODEL_MATRIX[1].xyz),0,0), vec4(0,0,length(MODEL_MATRIX[2].xyz),0), vec4(0,0,0,1));
	// The particle shader writes z = dissolve seed, w = opacity envelope, COLOR.a = source flag.
	dissolve_factor = INSTANCE_CUSTOM.z;
	alpha_fade = INSTANCE_CUSTOM.w;
	contact_spray = COLOR.a;
	// This alpha is a source label, not opacity: 0 means wave spray, 1 means object spray.
}

void fragment() {
	// Both sources share the original splash image and the ocean's foam color.
	vec4 albedo_tex = texture(albedo_texture, UV);
	ALBEDO = albedo_tex.rgb * foam_color.rgb*vec3(1.65,1.75,1.65);
	ALBEDO = mix(ALBEDO, albedo_tex.rgb * foam_color.rgb, contact_spray);

	float distance_fade = 1.0 - exp(-length(VERTEX.xz)*0.04);
	// Native spray keeps the original gradual near-camera suppression.
	ALPHA = albedo_tex.a * max_alpha;
	ALPHA *= distance_fade; // Fade
	ALPHA *= max((alpha_fade + dissolve_factor)*0.5 - texture(dissolve_texture, UV + vec2(TIME*0.35)).x, 0.0); // Dissolve
	// Contact splashes stay visible near the player, with their own smooth lifetime fade.
	float breakup = texture(dissolve_texture, UV * 1.3 + vec2(TIME * 0.18)).r;
	// Moving noise removes parts of the sheet so it looks like scattered water,
	// rather than a solid rectangular image floating above the surface.
	float contact_alpha = albedo_tex.a * contact_spray_opacity * alpha_fade;
	contact_alpha *= smoothstep(0.02, 0.35, alpha_fade - breakup * 0.35);
	ALPHA = mix(ALPHA, contact_alpha, contact_spray);
}
