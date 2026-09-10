shader_type canvas_item;
//
// One MultiMesh, five poses. The instance's custom data carries which cell of
// `assets/soldiers.png` to sample; the instance colour carries the unit's team
// shade, which the default canvas_item fragment already multiplies in.
//
// The sheet stores luminance, not colour — body 0.72, helmet 1.0, weapon 0.15 —
// so one sheet serves both teams, every unit shade and the corpse tint, and the
// rifle stays dark under all of them.
//
uniform float poses = 5.0;

void vertex() {
	UV = vec2((UV.x + INSTANCE_CUSTOM.x) / poses, UV.y);
}
