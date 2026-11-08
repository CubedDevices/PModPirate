#!/usr/bin/env python3
"""Apply -Os and newlib nano, then rebuild the platform and application."""

import os
import vitis

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WORKSPACE = os.path.join(ROOT, "vitis_ws")
PLATFORM = "pmodpirate_platform"
DOMAIN = "standalone_microblaze_riscv_0"
APP = "pmodpirate"

FLAGS = (
    " -Os -g -ffunction-sections -fdata-sections -Wall -Wextra "
    "-fno-tree-loop-distribute-patterns -specs=nano.specs"
)


def main():
    client = vitis.create_client()
    client.set_workspace(WORKSPACE)
    platform = client.get_component(PLATFORM)
    domain = platform.get_domain(DOMAIN)
    domain.set_config(option="proc", param="proc_extra_compiler_flags", value=FLAGS)
    print("domain flags:", domain.get_config("proc", "proc_extra_compiler_flags"))
    platform.build()

    app = client.get_component(APP)
    app.set_app_config(key="USER_COMPILE_OPTIMIZATION_LEVEL", values="-Os")
    app.build()
    vitis.dispose()


if __name__ == "__main__":
    main()
