# rtl8139-fcode

More details in my [blog post](https://na.thanreed.com/2025/12/07/open-firmware-rtl8139.html) about this.

This is an FCode driver to allow a PowerPC Mac with Open Firmware to boot over the network (NetBoot) from an RTL8139-based Ethernet card. This is interesting because 3rd party network cards were historically not able to be used for NetBoot since no FCode drivers were available.

While I tested this on my hardware (Power Mac G4 - AGP Graphics aka Sawtooth) and it's working, it likely won't work out of the box on other hardware. The driver in general is "hackathon-quality" and contains some assumptions specific to my hardware setup (such as hardcoding the device path `/pci@f2000000/@d/@4` to the RTL8139 in several places).

License is MIT for the parts I own (Forth and Python code, Makefile). I do not own the macos_driver or the rtl8139.kext files (or the rtl8139.mkext, which is a derivative of the kext). These are only included for convenience.