XBSV
====


XBSV provides a hardware-software interface for applications split
between user mode code and custom hardware in an FPGA.  Portal can
automatically build the software and hardware glue for a message based
interface and also provides for configuring and using shared memory
between applications and hardware. Communications between hardware and
software are provided by a bidirectional flow of events and regions of
memory shared between hardware and software.  Events from software to
hardware are called requests and events from hardware to software are
called indications, but in fact they are symmetric.

A logical request/indication pair is referred to as a portal".  An
application can make use of multiple portals, which may be specified
independently. A portal is specified by a BSV interface declaration,
from which `genxpsprojfrombsv` generates BSV and C++ wrappers and
proxies.

Supported Platforms
-------------------

XBSV supports Android on Zynq platforms, including zedboard and zc702.

XBSV supports Linux on x86 with PCIe-attached Virtex and Kintex boards (vc707, kc705).

XBSV supports bluesim as a simulated hardware platform. 

genxpsprojfrombsv
-----------------

The script genxpsprojfrombsv enables you to take a Bluespec System
Verilog (BSV) file and generate a bitstream for a Xilinx Zynq FPGA. 

It generates C++ and BSV stubs so that you can write code that runs on
the Zynq's ARM CPUs to interact with your BSV componet.

See [doc/genxpsprojfrombsv.md](doc/genxpsprojfrombsv.md) for a description of its options.

Preparation
-----------

1. Get Vivado 2013.2

Preparation for Zynq
--------------------

1. Download ndk toolchain from: 
     http://developer.android.com/tools/sdk/ndk/index.html
     (actual file might be:
         http://dl.google.com/android/ndk/android-ndk-r8e-linux-x86_64.tar.bz2
     )
2. git clone git://github.com/cambridgehackers/zynq-boot.git

The boot.bin is board-specific, because the first stage boot loader
(fsbl) and the devicetree are both board-specific.

To build a boot.bin for a zedboard:

    make BOARD=zedboard all

To build a boot.bin for a zc702:

   make BOARD=zc702 all

Setting up the SD Card
----------------------

1. Download http://xbsv.googlecode.com/files/sdcard-130611.tar.bz
2. tar -jxvf sdcard-130611.tar.bz

Currently, all files must be in the first partition of an SD card.

3. Copy files
   cd sdcard-130611
   cp boot.bin devicetree.dtb ramdisk8M.image.gz zImage system.img /media/zynq
   cp empty.img /media/zynq/userdata.img

Eject the card and plug it into the zc702 and boot.

After Android is running on the ac702, follow the instructions below to build and install the zynq portal driver.

Preparation for PCIe
--------------------

1. Build the drivers

    cd drivers/pcieportal; make && sudo make install

2. Load the drivers

    cd drivers/pcieportal; make insmod

3. Install the Digilent cable driver

    cd /scratch/Xilinx/Vivado/2013.2/data/xicom/cable_drivers/lin64/digilent
    sudo ./install_digilent.sh


4. Get fpgajtag

    git clone git://github.com/cambridgehackers/fpgajtag
    cd fpgajtag
    make all && sudo make install

Echo Example
------------

    ## this has only been tested with the Vivado 2013.2 release
    . Xilinx/Vivado/2013.2/settings64.sh

    make echo.zedboard
or
    make echo.zc702
or
    make echo.kc705
or
    make echo.vc707

To run on a zedboard with IP address aa.bb.cc.dd:
    RUNPARAM=aa.bb.cc.dd make echo.zedrun

Memcpy Example
--------------

    BOARD=vc707 make -C examples/memcpy

HDMI Example
------------

For example, to create an HDMI frame buffer from the example code:

To generate code for Zedboard:
    make hdmidisplay.zedboard

To generate code for a ZC702 board:
    make hdmidisplay.zc702

The result .bit file for this example will be:

    examples/hdmi/zedboard/hw/mkHdmiZynqTop.bit.bin.gz

Sending the bitfile:
    adb push mkHdmiZynqTop.bit.bin.gz /mnt/sdcard

Loading the bitfile on the device:
    mknod /dev/xdevcfg c 259 0
    cat /sys/devices/amba.0/f8007000.devcfg/prog_done
    zcat /mnt/sdcard/mkHdmiZynqTop.bit.bin.gz > /dev/xdevcfg
    cat /sys/devices/amba.0/f8007000.devcfg/prog_done
    chmod agu+rwx /dev/fpga0

On the zedboard, configure the adv7511:
   echo RGB > /sys/bus/i2c/devices/1-0039/format
On the zc702, configure the adv7511:
   echo RGB > /sys/bus/i2c/devices/0-0039/format

Restart surfaceflinger:
   stop surfaceflinger; start surfaceflinger

Sometimes multiple restarts are required.

Imageon Example
---------------

This is an example using the Avnet Imageon board and ZC702 (not tested with Zedboard yet):

To generate code for a ZC702 board:
    make imageon.zc702

Installation
------------

Install the bluespec compiler. Make sure the BLUESPECDIR environment
variable is set:
    export BLUESPECDIR=~/bluespec/Bluespec-2012.10.beta2/lib
	
Install the python-ply package, e.g.,

    sudo apt-get install python-ply

PLY's home is http://www.dabeaz.com/ply/

Zynq Portal Driver
-------------

Get the kernel source tree and build it:

    git clone git://github.com/cambridgehackers/device_xilinx_kernel
    git checkout origin/december -b december
    cd device_xilinx_kernel
    make ARCH=arm xilinx_zynq_portal_defconfig 
    make ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabi- -j20 zImage modules

To Build the zynq portal driver, Makefile needs to be pointed to the root of the kernel source tree:

    export DEVICE_XILINX_KERNEL=/path/to/device_xilinx_kernel/

The driver sources are located in the xbsv project:

    cd xbsv
    (cd drivers/zynqportal/; DEVICE_XILINX_KERNEL=`pwd`/../../../device_xilinx_kernel/ make zynqportal.ko)
    (cd drivers/portalmem/;  DEVICE_XILINX_KERNEL=`pwd`/../../../device_xilinx_kernel/ make portalmem.ko)
    adb push drivers/zynqportal/zynqportal.ko /mnt/sdcard
    adb push drivers/portalmem/portalmem.ko /mnt/sdcard

To update the zynq portal driver running on the Zync platform, set ADB_PORT appropriately and run the following commands:

    adb -s $ADB_PORT push zynqportal.ko /mnt/sdcard/
    adb -s $ADB_PORT shell "cd /mnt/sdcard/ && uname -r | xargs rm -rf"
    adb -s $ADB_PORT shell "cd /mnt/sdcard/ && uname -r | xargs mkdir"
    adb -s $ADB_PORT shell "cd /mnt/sdcard/ && uname -r | xargs mv zynqportal.ko"
    adb -s $ADB_PORT shell "modprobe -r zynqportal"
    adb -s $ADB_PORT shell "modprobe zynqportal"

Zynq Hints
-------------

To remount /system read/write:

    mount -o rw,remount /dev/block/mmcblk0p1 /system


