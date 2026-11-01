shader_type canvas_item;
render_mode blend_add, unshaded;
// This pass paints coverage only, not the visible foam texture. Additive blending joins
// neighboring footprints; water.gdshader shades their red channel with native wave foam.

varying vec4 stamp;
// "Stamp" means one small painted piece of the trail. This pass draws it into an
// invisible image, not onto the screen. Red 0 = no foam, brighter red = more foam.

void vertex() {
	// Per-instance data is uploaded by OceanInteractions in the same packed order.
	stamp = INSTANCE_CUSTOM; // normalized age, strength, isolated patch, age in seconds
}

void fragment() {
	// Center each quad on zero. X is across the trail and Y is along its direction.
	vec2 p = UV * 2.0 - 1.0;
	// UV goes from 0 to 1 across the quad; p goes from -1 to +1 around its center.
	float fade = max(0.0, 1.0 - stamp.x) * smoothstep(0.0, 0.08, stamp.w);
	// A brief fade-in prevents popping. Each segment has its own full lifetime afterward.
	float radius = stamp.z > 0.5 ? length(p) : abs(p.x);
	float footprint = exp(-radius * radius * 2.0) * (1.0 - smoothstep(0.75, 1.0, radius));
	if (stamp.z < 0.5) {
		// Fresh churn fills the center. Older foam collects in two spreading shoulders,
		// leaving a softer, clearer channel instead of one uniformly painted ribbon.
		float maturity = smoothstep(0.05, 0.5, stamp.x);
		float center = exp(-radius * radius * mix(3.0, 12.0, maturity)) * mix(1.0, 0.28, maturity);
		float shoulder_distance = (radius - mix(0.3, 0.62, maturity)) / mix(0.28, 0.18, maturity);
		float shoulders = exp(-shoulder_distance * shoulder_distance) * maturity * 1.25;
		footprint = max(center, shoulders) * (1.0 - smoothstep(0.8, 1.0, radius));
	}
	// Isolated gameplay patches retain their round footprint.
	// Adjacent moving-body segments overlap with triangular weights, leaving a soft,
	// continuous footprint. Foam texture and lighting are supplied by the ocean itself.
	float along = stamp.z > 0.5 ? 1.0 : max(0.0, 1.0 - abs(p.y));
	// Other channels stay empty: this effect colors water but never displaces the surface.
	COLOR = vec4(footprint * along * fade * stamp.y, 0.0, 0.0, 1.0);
}
