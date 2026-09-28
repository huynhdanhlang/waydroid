#!/usr/bin/env python3
"""Guard GPU selection when render node numbers change across host boots."""

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import tools.config
from tools.helpers import images, lxc


class DynamicGpuTest(unittest.TestCase):
    def test_startup_regenerates_gpu_property_and_lxc_node(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "waydroid_base.prop").write_text(
                "ro.hardware.gralloc=gbm\n"
                "gralloc.gbm.device=/dev/dri/renderD129\n"
                "ro.hardware.egl=mesa\n"
            )
            args = SimpleNamespace(
                work=directory,
                config=str(work / "waydroid.cfg"),
                BINDER_DRIVER="binder",
                VNDBINDER_DRIVER="vndbinder",
                HWBINDER_DRIVER="hwbinder",
            )
            session = {
                "user_name": "test", "user_id": "1000", "group_id": "1000",
                "waydroid_data": "/tmp/test-data", "background_start": "true",
                "lcd_density": "0",
            }
            lxc_dir = work / "lxc"
            (lxc_dir / "waydroid").mkdir(parents=True)
            (lxc_dir / "waydroid" / "config_nodes").write_text(
                "lxc.mount.entry = /dev/dri/renderD129 dev/dri/renderD129 none bind,create=file,optional 0 0\n"
            )
            with patch("tools.helpers.gpu.getDriNode", return_value=("/dev/dri/renderD128", "/dev/dri/card1")), \
                    patch.dict(tools.config.defaults, {"lxc": str(lxc_dir)}):
                images.make_prop(args, session, str(work / "waydroid.prop"))
                lxc.refresh_nodes_lxc_config(args)

            props = (work / "waydroid.prop").read_text()
            nodes = (lxc_dir / "waydroid" / "config_nodes").read_text()
            self.assertIn("gralloc.gbm.device=/dev/dri/renderD128\n", props)
            self.assertNotIn("gralloc.gbm.device=/dev/dri/renderD129", props)
            self.assertIn("/dev/dri/renderD128", nodes)
            self.assertNotIn("/dev/dri/renderD129", nodes)


if __name__ == "__main__":
    unittest.main()
