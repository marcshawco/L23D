"""
L23D → Blender: build a photoreal, ready-to-render scene from a scanned model.

Run headless (what the L23D HQ Mac app does):
    blender -b --factory-startup --python l23d_scene.py -- \
        --model model.usdz --out scene.blend [--render preview.png] [--samples 128]

Or inside Blender: Scripting tab → Open this file → edit MODEL_PATH below → Run Script.

What it sets up:
  * Imports USDZ / USD / GLB / glTF / OBJ (meters, Z-up), centers it on the floor.
  * Fixes materials: color maps sRGB, data maps (normal/roughness/metallic) Non-Color,
    normal map wired, physically plausible specular.
  * Cycles on the GPU (Metal/OptiX/CUDA when available) with denoising, AgX color.
  * Lighting: an HDRI that ships with Blender for realistic reflections, plus a soft key
    light; a neutral studio floor that catches shadows; matching background.
  * Camera framed at a three-quarter view (50 mm).
  * Packs all textures into the .blend so it is one self-contained file.
Prints one line starting with "L23D_RESULT " followed by JSON (for the Mac app and tests).
"""

import argparse
import json
import math
import os
import sys
import warnings

import bpy
from mathutils import Vector

# Blender 5 warns that use_nodes is going away; we only set it for older versions.
warnings.filterwarnings("ignore", category=DeprecationWarning)

# Used when run from Blender's Scripting tab (no command-line arguments).
MODEL_PATH = ""


# ---------------------------------------------------------------- arguments

def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(description="Build a photoreal Blender scene from an L23D scan.")
    parser.add_argument("--model", default=MODEL_PATH, help="USDZ/USD/GLB/glTF/OBJ file")
    parser.add_argument("--out", default="", help="Where to save the .blend (optional)")
    parser.add_argument("--render", default="", help="Where to save a preview PNG (optional)")
    parser.add_argument("--samples", type=int, default=128, help="Cycles samples for the saved scene")
    parser.add_argument("--preview-samples", type=int, default=64, help="Cycles samples for the preview render")
    parser.add_argument("--resolution", type=int, default=1920, help="Render width (16:9)")
    parser.add_argument("--preview-scale", type=int, default=50, help="Preview size in percent")
    parser.add_argument("--hdri", default="", help="HDRI file (default: one that ships with Blender)")
    parser.add_argument("--cpu", action="store_true", help="Render on the CPU")
    return parser.parse_args(argv)


# ---------------------------------------------------------------- scene

def clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for collection in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras, bpy.data.lights, bpy.data.images):
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)


def import_model(path):
    """Imports the file and returns the new mesh objects."""
    before = set(bpy.data.objects)
    ext = os.path.splitext(path)[1].lower()
    if ext in (".usdz", ".usd", ".usdc", ".usda"):
        try:
            bpy.ops.wm.usd_import(filepath=path, import_materials=True)
        except TypeError:
            bpy.ops.wm.usd_import(filepath=path)
    elif ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        if hasattr(bpy.ops.wm, "obj_import"):
            bpy.ops.wm.obj_import(filepath=path, forward_axis="NEGATIVE_Z", up_axis="Y")
        else:
            bpy.ops.import_scene.obj(filepath=path)
    else:
        raise SystemExit(f"Unsupported model type: {ext}")
    new_objects = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new_objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("The file had no meshes.")
    return new_objects, meshes


def world_bounds(objects):
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    bpy.context.view_layer.update()
    for obj in objects:
        for corner in obj.bound_box:
            p = obj.matrix_world @ Vector(corner)
            lo = Vector(map(min, lo, p))
            hi = Vector(map(max, hi, p))
    return lo, hi


def place_on_floor(new_objects, meshes):
    """Parents everything to one empty and moves it so the model sits centered on z = 0."""
    root = bpy.data.objects.new("L23D_Model", None)
    bpy.context.scene.collection.objects.link(root)
    top_level = [o for o in new_objects if o.parent is None]
    for obj in top_level:
        obj.parent = root
    lo, hi = world_bounds(meshes)
    root.location = Vector((-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z))
    bpy.context.view_layer.update()
    for mesh in meshes:
        for poly in mesh.data.polygons:
            poly.use_smooth = True
    return root, world_bounds(meshes)


# ---------------------------------------------------------------- materials

DATA_HINTS = ("normal", "rough", "metal", "occlusion", "_ao", "ao_", "displacement", "height", "bump")


def fix_materials(meshes):
    """Makes every scanned material physically sensible for Cycles."""
    fixed = 0
    textures = 0
    for mesh in meshes:
        for slot in mesh.material_slots:
            mat = slot.material
            if mat is None or not mat.use_nodes:
                continue
            nodes, links = mat.node_tree.nodes, mat.node_tree.links
            bsdf = next((n for n in nodes if n.type == "BSDF_PRINCIPLED"), None)
            if bsdf is None:
                continue
            for node in nodes:
                if node.type == "TEX_IMAGE" and node.image is not None:
                    textures += 1
                    name = (node.image.name + " " + (node.image.filepath or "")).lower()
                    feeds_color = any(l.to_socket == bsdf.inputs["Base Color"] for l in node.outputs["Color"].links)
                    is_data = not feeds_color and any(h in name for h in DATA_HINTS)
                    try:
                        node.image.colorspace_settings.name = "Non-Color" if is_data else "sRGB"
                    except TypeError:
                        pass
                    node.interpolation = "Cubic" if feeds_color else "Linear"
            # Normal map: make sure an image named like a normal map is wired through a Normal Map node.
            if not bsdf.inputs["Normal"].is_linked:
                normal_tex = next((n for n in nodes if n.type == "TEX_IMAGE" and n.image
                                   and "normal" in n.image.name.lower()), None)
                if normal_tex is not None:
                    nmap = nodes.new("ShaderNodeNormalMap")
                    links.new(normal_tex.outputs["Color"], nmap.inputs["Color"])
                    links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
            # Scans are dielectric (skin, cloth, wood, plastic): sensible specular, no metal unless mapped.
            if "Specular IOR Level" in bsdf.inputs:
                bsdf.inputs["Specular IOR Level"].default_value = 0.5
            if not bsdf.inputs["Metallic"].is_linked:
                bsdf.inputs["Metallic"].default_value = 0.0
            fixed += 1
    return fixed, textures


# ---------------------------------------------------------------- lighting, floor, camera

def builtin_hdri():
    """Picks an HDRI that ships with Blender (no download needed)."""
    folder = bpy.utils.system_resource("DATAFILES", path="studiolights/world")
    if folder and os.path.isdir(folder):
        files = sorted(f for f in os.listdir(folder) if f.lower().endswith((".exr", ".hdr")))
        for preferred in ("interior.exr", "courtyard.exr", "forest.exr", "city.exr"):
            if preferred in files:
                return os.path.join(folder, preferred)
        if files:
            return os.path.join(folder, files[0])
    return ""


def setup_world(hdri_path, background=(0.42, 0.42, 0.42)):
    """HDRI for lighting and reflections; a soft studio gray where the camera looks at the sky."""
    world = bpy.data.worlds.new("L23D_World")
    bpy.context.scene.world = world
    world.use_nodes = True
    nt = world.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    mix = nt.nodes.new("ShaderNodeMixShader")
    light_path = nt.nodes.new("ShaderNodeLightPath")
    lighting = nt.nodes.new("ShaderNodeBackground")
    lighting.inputs["Strength"].default_value = 0.5
    backdrop = nt.nodes.new("ShaderNodeBackground")
    backdrop.inputs["Color"].default_value = (*background, 1.0)
    backdrop.inputs["Strength"].default_value = 1.0
    if hdri_path and os.path.exists(hdri_path):
        env = nt.nodes.new("ShaderNodeTexEnvironment")
        env.image = bpy.data.images.load(hdri_path, check_existing=True)
        nt.links.new(env.outputs["Color"], lighting.inputs["Color"])
    else:
        lighting.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1.0)
    nt.links.new(light_path.outputs["Is Camera Ray"], mix.inputs["Fac"])
    nt.links.new(lighting.outputs["Background"], mix.inputs[1])
    nt.links.new(backdrop.outputs["Background"], mix.inputs[2])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])
    return os.path.basename(hdri_path) if hdri_path else "none"


def add_floor(size, color=(0.42, 0.42, 0.42)):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, 0))
    floor = bpy.context.active_object
    floor.name = "L23D_Floor"
    mat = bpy.data.materials.new("L23D_Floor")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.85
    floor.data.materials.append(mat)
    return floor


def add_key_light(center, radius):
    data = bpy.data.lights.new("L23D_Key", type="AREA")
    data.shape = "DISK"
    data.size = max(radius * 2.5, 0.3)
    key = bpy.data.objects.new("L23D_Key", data)
    bpy.context.scene.collection.objects.link(key)
    distance = max(radius * 4, 0.6)
    # Same brightness on the subject at any size (inverse-square falloff).
    data.energy = 45 * distance ** 2
    key.location = center + Vector((-distance * 0.7, -distance * 0.8, distance * 1.1))
    aim(key, center)
    return key


def aim(obj, target):
    direction = target - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def add_camera(center, radius, lens=50.0, aspect=16 / 9):
    data = bpy.data.cameras.new("L23D_Camera")
    data.lens = lens
    data.clip_start = max(radius * 0.01, 0.001)
    data.clip_end = max(radius * 200, 100)
    camera = bpy.data.objects.new("L23D_Camera", data)
    bpy.context.scene.collection.objects.link(camera)
    # Distance that fits a sphere of `radius` in the narrower (vertical) field of view, with margin.
    sensor = data.sensor_width
    hfov = 2 * math.atan(sensor / (2 * lens))
    vfov = 2 * math.atan(math.tan(hfov / 2) / aspect)
    distance = radius / math.sin(min(hfov, vfov) / 2) * 1.15
    azimuth, elevation = math.radians(35), math.radians(15)
    offset = Vector((math.sin(azimuth) * math.cos(elevation), -math.cos(azimuth) * math.cos(elevation), math.sin(elevation)))
    camera.location = center + offset * distance
    aim(camera, center)
    bpy.context.scene.camera = camera
    return camera


# ---------------------------------------------------------------- render settings

def setup_render(samples, resolution, use_cpu):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    cycles = scene.cycles
    cycles.samples = samples
    cycles.use_denoising = True
    cycles.use_adaptive_sampling = True
    cycles.max_bounces = 12
    device = "CPU"
    if not use_cpu:
        try:
            prefs = bpy.context.preferences.addons["cycles"].preferences
            for backend in ("METAL", "OPTIX", "CUDA", "HIP", "ONEAPI"):
                try:
                    prefs.compute_device_type = backend
                except TypeError:
                    continue
                prefs.get_devices()
                gpus = [d for d in prefs.devices if d.type != "CPU"]
                if gpus:
                    for d in prefs.devices:
                        d.use = True
                    device = "GPU"
                    break
        except Exception:
            device = "CPU"
    cycles.device = device
    scene.render.resolution_x = resolution
    scene.render.resolution_y = int(round(resolution * 9 / 16))
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    view = scene.view_settings
    for transform in ("AgX", "Filmic"):
        try:
            view.view_transform = transform
            break
        except TypeError:
            continue
    try:
        view.look = "AgX - Medium High Contrast" if view.view_transform == "AgX" else "Medium High Contrast"
    except TypeError:
        pass
    return device


# ---------------------------------------------------------------- main

def main():
    args = parse_args()
    if not args.model:
        raise SystemExit("Pass --model path/to/model.usdz (or set MODEL_PATH in the script).")
    model = os.path.abspath(args.model)

    clear_scene()
    new_objects, meshes = import_model(model)
    root, (lo, hi) = place_on_floor(new_objects, meshes)
    materials_fixed, textures = fix_materials(meshes)

    size = hi - lo
    center = (lo + hi) / 2
    radius = max(size.length / 2, 0.01)

    hdri = setup_world(args.hdri or builtin_hdri())
    add_floor(size=max(radius * 40, 4))
    add_key_light(center, radius)
    add_camera(center, radius)
    device = setup_render(args.samples, args.resolution, args.cpu)

    triangles = sum(sum(len(p.vertices) - 2 for p in m.data.polygons) for m in meshes)
    result = {
        "model": os.path.basename(model),
        "meshes": len(meshes),
        "triangles": triangles,
        "materials": materials_fixed,
        "textures": textures,
        "size_m": [round(size.x, 4), round(size.y, 4), round(size.z, 4)],
        "device": device,
        "hdri": hdri,
    }

    if args.out:
        out = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        try:
            bpy.ops.file.pack_all()
        except RuntimeError as error:
            result["pack_warning"] = str(error)
        bpy.context.preferences.filepaths.save_version = 0  # no .blend1 backups
        bpy.ops.wm.save_as_mainfile(filepath=out, compress=True)
        result["blend"] = out

    if args.render:
        scene = bpy.context.scene
        full_samples = scene.cycles.samples
        scene.cycles.samples = args.preview_samples
        scene.render.resolution_percentage = args.preview_scale
        scene.render.image_settings.file_format = "PNG"
        scene.render.filepath = os.path.abspath(args.render)
        bpy.ops.render.render(write_still=True)
        scene.cycles.samples = full_samples
        scene.render.resolution_percentage = 100
        result["preview"] = os.path.abspath(args.render)

    print("L23D_RESULT " + json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
