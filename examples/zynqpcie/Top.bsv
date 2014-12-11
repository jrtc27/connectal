/* Copyright (c) 2014 Quanta Research Cambridge, Inc
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
import Clocks::*;
import Vector::*;
import FIFO::*;
import Connectable::*;
import GetPutWithClocks::*;
import CtrlMux::*;
import Portal::*;
import HostInterface::*;
import MemTypes::*;
import Leds::*;
import MemPortal::*;
import PcieHost ::*;
`ifndef BSIM
import PCIEWRAPPER          ::*;
import PcieEndpointX7       ::*;
import ConnectalXilinxCells ::*;
`endif

// generated by tool
import Simple::*;
import ZynqPcieTestRequest::*;
import ZynqPcieTestIndication::*;
import ZynqPcieTestIF::*;

// defined by user
import SimpleIF::*;

typedef enum {SimpleRequest, SimpleIndication, ZynqPcieTestRequest, ZynqPcieTestIndication} IfcNames deriving (Eq,Bits);

interface ZynqPcie;
   (* prefix="PCIE" *)
   interface PciewrapPci_exp#(PcieLanes) pcie;
   method Action pcie_sys_clk(Bit#(1) p, Bit#(1) n);
   method Action sys_clk(Bit#(1) p, Bit#(1) n);
   method Action pcie_sys_reset(Bit#(1) n);
   interface Clock deleteme_unused_clockFoo;
   interface Clock deleteme_unused_clockPortal;
   interface Clock deleteme_unused_clock100mhz;
endinterface

(* synthesize *)
module mkPcieHostTopSynth#(Clock pcie_sys_clk_p, Clock pcie_sys_clk_n, Clock sys_clk_p, Clock sys_clk_n, Reset pcie_sys_reset_n)(PcieHostTop);
   (*hide*) let host <- mkPcieHostTop(pcie_sys_clk_p, pcie_sys_clk_n, sys_clk_p, sys_clk_n, pcie_sys_reset_n);
   return host;
endmodule

module mkConnectalTop(ConnectalTop#(PhysAddrWidth,64,ZynqPcie,0));

   Clock defaultClock <- exposeCurrentClock();
   Reset defaultReset <- exposeCurrentReset();

   B2C1 b2c_pcie_sys_clk_p <- mkB2C1();
   B2C1 b2c_pcie_sys_clk_n <- mkB2C1();
   B2C b2c_pcie_sys_reset_n <- mkB2C();
   B2C1 b2c_sys_clk_p <- mkB2C1();
   B2C1 b2c_sys_clk_n <- mkB2C1();

   PcieHostTop host <- mkPcieHostTopSynth(b2c_pcie_sys_clk_p.c, b2c_pcie_sys_clk_n.c, b2c_sys_clk_p.c, b2c_sys_clk_n.c, b2c_pcie_sys_reset_n.r);

   // instantiate user portals
   SyncBitIfc#(Bit#(1)) resetBit <- mkSyncBit(b2c_pcie_sys_reset_n.c, b2c_pcie_sys_reset_n.r, defaultClock);
   SyncBitIfc#(Bit#(1)) linkUpBit <- mkSyncBit(host.portalClock, host.portalReset, defaultClock);
   ZynqPcieTestIndicationProxy zynqPcieTestIndicationProxy <- mkZynqPcieTestIndicationProxy(ZynqPcieTestIndication);
   ZynqPcieTest zynqPcieTest <- mkZynqPcieTest(linkUpBit, resetBit, zynqPcieTestIndicationProxy.ifc);
   ZynqPcieTestRequestWrapper zynqPcieTestRequestWrapper <- mkZynqPcieTestRequestWrapper(ZynqPcieTestRequest,zynqPcieTest.request);

   mkConnectionWithClocks(zynqPcieTest.traceBramClient, host.tpciehost.traceBramServer, defaultClock, defaultReset, host.portalClock, host.portalReset);

   Vector#(2,StdPortal) portals;
   portals[0] = zynqPcieTestIndicationProxy.portalIfc;
   portals[1] = zynqPcieTestRequestWrapper.portalIfc;
   let ctrl_mux <- mkSlaveMux(portals);
   
   Reg#(Bit#(8)) ledsValue <- mkReg(5);
   Reg#(Bit#(32)) remainingDuration <- mkReg(100000000);

   rule updateLeds;
      let duration = remainingDuration;
      if (duration == 0) begin
	 ledsValue <= ~ledsValue;
	 duration = 100000000;
      end
      else begin
	 duration = duration - 1;
      end
      remainingDuration <= duration;
   endrule

   rule updateLinkBit;
      linkUpBit.send(host.tep7.user.lnk_up());
   endrule
   SimpleProxy simpleIndicationProxy <- mkSimpleProxy(SimpleIndication, clocked_by host.portalClock, reset_by host.portalReset);
   Simple simpleRequest <- mkSimple(simpleIndicationProxy.ifc, clocked_by host.portalClock, reset_by host.portalReset);
   SimpleWrapper simpleRequestWrapper <- mkSimpleWrapper(SimpleRequest,simpleRequest, clocked_by host.portalClock, reset_by host.portalReset);
   
   Vector#(2,StdPortal) pcieportals;
   pcieportals[0] = simpleIndicationProxy.portalIfc;
   pcieportals[1] = simpleRequestWrapper.portalIfc;
   PhysMemSlave#(32,32) pcie_ctrl_mux <- mkSlaveMux(pcieportals, clocked_by host.portalClock, reset_by host.portalReset);
   mkConnection(host.tpciehost.master, pcie_ctrl_mux, clocked_by host.portalClock, reset_by host.portalReset);

   ZynqPcie zpcie = (interface ZynqPcie;
		     method Action pcie_sys_clk(Bit#(1) p, Bit#(1) n);
			b2c_pcie_sys_clk_p.inputclock(p);
			b2c_pcie_sys_clk_n.inputclock(n);
		     endmethod
		     method Action sys_clk(Bit#(1) p, Bit#(1) n);
			b2c_sys_clk_p.inputclock(p);
			b2c_sys_clk_n.inputclock(n);
		     endmethod
		     method Action pcie_sys_reset(Bit#(1) n);
			resetBit.send(n);
			b2c_pcie_sys_reset_n.inputreset(n);
		     endmethod
		     interface pcie = host.tep7.pcie;
		     interface Clock deleteme_unused_clockFoo = b2c_pcie_sys_reset_n.c;
		     interface Clock deleteme_unused_clockPortal = host.portalClock;
		     interface Clock deleteme_unused_clock100mhz = host.tpci_clk_100mhz_buf;
		     endinterface);

   LEDS ledsIF = (interface LEDS; method Bit#(LedsWidth) leds(); return truncate(ledsValue); endmethod endinterface);

   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = nil;
   interface leds = ledsIF;
   interface pins = zpcie;

endmodule : mkConnectalTop


