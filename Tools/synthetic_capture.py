"""
Developer tool: render a fake "photo walk-around" of a detailed object with Blender,
so the Mac HQ builder and the Blender scene step can be tested without an iPhone.

    blender -b --factory-startup --python Tools/synthetic_capture.py -- \
        --out /path/to/ScanFolder [--views 36] [--rings 2] [--size 1600]

Writes JPEG photos into <out>/Images/ (like an Object Capture scan folder).
The subject is a stone-like, colorful sculpted head on a textured floor — lots of
detail for photogrammetry to lock onto.
"""

import argparse
import math
import os
import sys

import bpy
from mathutils import Vector


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--views", type=int, default=36, help="photos per ring")
    parser.add_argument("--rings", type=int, default=2)
    parser.add_argument("--size", type=int, default=1600, help="photo width (4:3)")
    parser.add_argument("--samples", type=int, default=24)
    return parser.parse_args(argv)


def material_stone(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    coords = nt.nodes.new("ShaderNodeTexCoord")
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 18
    noise.inputs["Detail"].default_value = 12
    voronoi = nt.nodes.new("ShaderNodeTexVoronoi")
    voronoi.inputs["Scale"].default_value = 30
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.10, 0.06, 0.04, 1)
    ramp.color_ramp.elements[1].color = (0.85, 0.62, 0.35, 1)
    mid = ramp.color_ramp.elements.new(0.5)
    mid.color = (0.25, 0.45, 0.55, 1)
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["Factor"].default_value = 0.35
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.4
    nt.links.new(coords.outputs["Object"], noise.inputs["Vector"])
    nt.links.new(coords.outputs["Object"], voronoi.inputs["Vector"])
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], mix.inputs["A"])
    nt.links.new(voronoi.outputs["Color"], mix.inputs["B"])
    nt.links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
    nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Roughness"].default_value = 0.7
    return mat


def material_floor():
    mat = bpy.data.materials.new("Floor")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    checker = nt.nodes.new("ShaderNodeTexChecker")
    checker.inputs["Scale"].default_value = 40
    checker.inputs["Color1"].default_value = (0.55, 0.5, 0.45, 1)
    checker.inputs["Color2"].default_value = (0.3, 0.28, 0.25, 1)
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 60
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["Factor"].default_value = 0.5
    nt.links.new(checker.outputs["Color"], mix.inputs["A"])
    nt.links.new(noise.outputs["Color"], mix.inputs["B"])
    nt.links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
    return mat


def build_subject():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.ops.mesh.primitive_monkey_add(size=0.25, location=(0, 0, 0.17))
    head = bpy.context.active_object
    head.rotation_euler = (math.radians(-10), 0, 0)
    sub = head.modifiers.new("Subdivision", "SUBSURF")
    sub.levels = sub.render_levels = 2
    head.data.materials.append(material_stone("Stone"))
    bpy.ops.object.shade_smooth()

    bpy.ops.mesh.primitive_cylinder_add(radius=0.12, depth=0.06, location=(0, 0, 0.03))
    base = bpy.context.active_object
    base.data.materials.append(material_stone("Base"))

    bpy.ops.mesh.primitive_plane_add(size=3, location=(0, 0, 0))
    bpy.context.active_object.data.materials.append(material_floor())


def setup_render(args):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
        scene.cycles.device = "GPU"
    except Exception:
        pass
    scene.render.resolution_x = args.size
    scene.render.resolution_y = args.size * 3 // 4
    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.quality = 92
    world = bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
    light = bpy.data.lights.new("Sun", "SUN")
    light.energy = 3
    sun = bpy.data.objects.new("Sun", light)
    sun.rotation_euler = (math.radians(40), 0, math.radians(30))
    scene.collection.objects.link(sun)


def render_views(args):
    scene = bpy.context.scene
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 35
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    target = Vector((0, 0, 0.15))
    images = os.path.join(args.out, "Images")
    os.makedirs(images, exist_ok=True)
    index = 0
    for ring in range(args.rings):
        elevation = math.radians(12 + ring * 28)
        distance = 0.85
        for step in range(args.views):
            azimuth = 2 * math.pi * step / args.views
            cam.location = target + Vector((
                math.sin(azimuth) * math.cos(elevation),
                -math.cos(azimuth) * math.cos(elevation),
                math.sin(elevation),
            )) * distance
            cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
            index += 1
            scene.render.filepath = os.path.join(images, f"IMG_{index:04d}.jpg")
            bpy.ops.render.render(write_still=True)
    print(f"L23D_SYNTHETIC {index} photos in {images}", flush=True)


def main():
    args = parse_args()
    build_subject()
    setup_render(args)
    render_views(args)


if __name__ == "__main__":
    main()
