#!/usr/bin/env python3
"""Create the PModPirate Vitis platform and empty MicroBlaze application."""

import os
import sys

import vitis

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WORKSPACE = os.path.join(ROOT, "vitis_ws")
XSA = os.path.join(ROOT, "hw", "pmodpirate.xsa")
PLATFORM = "pmodpirate_platform"
DOMAIN = "standalone_microblaze_riscv_0"
APP = "pmodpirate"


def set_domain_flags(platform):
    domain = platform.get_domain(DOMAIN)
    flags = (
        " -Os -g -ffunction-sections -fdata-sections -Wall -Wextra "
        "-fno-tree-loop-distribute-patterns -specs=nano.specs"
    )
    # The BSP is compiled with -specs=nano.specs. The application is not:
    # this multilib's nano.specs asks for libc_nano, which the toolchain
    # does not ship, so the ELF links the toolchain newlib instead.
    domain.set_config(option="proc", param="proc_extra_compiler_flags", value=flags)
    print("domain extra flags set")


def set_app_flags(app):
    app.set_app_config(key="USER_COMPILE_OPTIMIZATION_LEVEL", values="-Os")


def main():
    os.makedirs(WORKSPACE, exist_ok=True)
    client = vitis.create_client()
    client.set_workspace(WORKSPACE)

    platform = client.create_platform_component(
        name=PLATFORM,
        hw_design=XSA,
        os="standalone",
        cpu="microblaze_riscv_0",
        domain_name=DOMAIN,
        no_boot_bsp=True,
    )
    try:
        set_domain_flags(platform)
    except Exception as exc:
        print(f"domain flags not applied: {exc}")

    print("building platform")
    platform.build()

    xpfm = client.find_platform_in_repos(PLATFORM)
    app = client.create_app_component(
        name=APP,
        platform=xpfm,
        domain=DOMAIN,
        template="empty_application",
    )
    src = os.path.join(ROOT, "fw", "src")
    inc = os.path.join(ROOT, "fw", "include")
    app.import_files(from_loc=src, files=None, dest_dir_in_cmp="src")
    app.import_files(from_loc=inc, files=None, dest_dir_in_cmp="src")
    print(f"application {APP} created")
    set_app_flags(app)
    print("building application")
    app.build()
    print("vitis application built")
    vitis.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(main())
