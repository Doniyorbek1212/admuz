"""UZARO v2 show: fireworks (tier 1, 96 f = 4 s). Four shells climb and burst with trails, crackle and falling embers."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import show_common as sh  # noqa: E402
import spark_trails as st  # noqa: E402
import stage  # noqa: E402

ID = "fireworks"
TOTAL = 96
# (burst frame, burst point, launch x, rgb, rise frames, stars, speed)
SHELLS = [
    (24, (-1.5, 0, 3.0), -0.5, (1.0, 0.25, 0.1), 15, 260, 6.8),
    (38, (1.6, 0, 1.2), 0.8, (0.2, 0.55, 1.0), 15, 240, 6.2),
    (50, (-0.6, 0, -0.4), 0.2, (1.0, 0.72, 0.15), 14, 240, 6.0),
    (62, (0.7, 0, 3.6), 1.2, (0.95, 0.2, 0.75), 16, 300, 7.4),
]


def no_specks(sc):
    """Hundreds of trail tubes stack at a burst point: too few transparent bounces render them black. Filmic keeps the colours."""
    sc.cycles.transparent_max_bounces = 128
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"


def shells(sc, total, shells_def, scale=1.0, launch_z=-9.0):
    for i, (f, at, lx, rgb, rise, n, speed) in enumerate(shells_def):
        st.shell(sc, f"Shell{i}", f, tuple(c * scale for c in at), (lx * scale, 0, launch_z), max(1, f - rise), rgb, total,
                 count=n, speed=speed * scale, seed=11 + i, radius=0.017 * scale)


def build_show(sc, opts):
    stage.setup(sc, TOTAL, opts["samples"], world=0.0, lights=0.0, fog=(1.1, 8), streak=6.0)
    no_specks(sc)
    sc.cycles.transparent_max_bounces = 48
    shells(sc, TOTAL, SHELLS)
    sc.render.use_motion_blur = False   # the trails already are the motion


def build_icon(sc, opts):
    """Seamless: three bursts staggered across the 2 s loop; each trail set repeats exactly, so frame 30 == frame 0."""
    cam = stage.setup_icon(sc, opts["samples"], world=0.0, lights=0.0, fog=(1.1, 8), streak=6.0)
    no_specks(sc)
    sc.cycles.transparent_max_bounces = 48
    sc.render.use_motion_blur = False
    n = stage.ICON_N
    sh_def = [(4, (-1.0, 0, 1.2), (1.0, 0.3, 0.1)), (14, (1.2, 0, 0.3), (0.25, 0.55, 1.0)), (24, (0.0, 0, -1.1), (1.0, 0.72, 0.15))]
    # one extra period in time: each burst is also placed one loop earlier, wrapping its tail into the first frames
    for i, (f, at, rgb) in enumerate(sh_def):
        for shift in (0, -n):
            rnd = stage.seeded(40 + i)
            tracks = []
            for _ in range(130):
                d = stage.Vector((rnd.gauss(0, 1), rnd.gauss(0, 1), rnd.gauss(0, 1))).normalized()
                sp = 5.0 * rnd.uniform(0.75, 1.0)
                tracks.append((f + shift, st.simulate(stage.Vector(at), d * sp, 26, gravity=6.0, turbulence=1.2, rnd=rnd), rnd.random()))
            mat = st.material(f"IconMat{i}{shift}", rgb, 8.0, 8, n, life=14, twinkle=2.4)
            stage.link(sc, f"Icon{i}{shift}", st.tube_mesh(f"Icon{i}{shift}", tracks, 0.03), mat, shadow=False)
    half = 4.2
    cam.data.lens = stage.gc.CAM_DIST * 18.0 / half
    _ = sh


stage.run(ID, build_show, build_icon)
