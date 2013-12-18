// bsv libraries
import SpecialFIFOs::*;
import Vector::*;
import StmtFSM::*;
import FIFO::*;

// portz libraries
import AxiMasterSlave::*;
import Directory::*;
import CtrlMux::*;
import Portal::*;
import Leds::*;


// generated by tool
import SayWrapper::*;
import SayProxy::*;

// defined by user
import Say::*;

interface Top;
   interface StdAxi3Slave     ctrl;
   interface StdAxi3Master    m_axi;
   interface ReadOnly#(Bool)  interrupt;
   interface LEDS             leds;
endinterface

module mkZynqTop(Top);

   // instantiate user portals
   SayProxy sayProxy <- mkSayProxy(7);
   Say say <- mkSay(sayProxy.ifc);
   SayWrapper sayWrapper <- mkSayWrapper(1008,say);
   Vector#(2,StdPortal) portals;
   portals[0] = sayWrapper.portalIfc;
   portals[1] = sayProxy.portalIfc; 
   
   // instantiate system directory
   Directory dir <- mkDirectory(portals);
   Vector#(1,StdPortal) directories;
   directories[0] = dir.portalIfc;
   
   // when constructing ctrl and interrupt muxes, directories must be the first argument
   let ctrl_mux <- mkAxiSlaveMux(directories,portals);
   let interrupt_mux <- mkInterruptMux(directories,portals);
   
   interface ReadOnly interrupt = interrupt_mux;
   interface StdAxi3Slave ctrl = ctrl_mux;
   interface Axi3Master m_axi = ?;
   interface LEDS leds = ?;

endmodule


import "BDPI" function Action      initPortal(Bit#(32) d);
import "BDPI" function Bool                    writeReq();
import "BDPI" function ActionValue#(Bit#(32)) writeAddr();
import "BDPI" function ActionValue#(Bit#(32)) writeData();
import "BDPI" function Bool                     readReq();
import "BDPI" function ActionValue#(Bit#(32))  readAddr();
import "BDPI" function Action        readData(Bit#(32) d);


module mkBsimTop();
   Top top <- mkZynqTop;
   let wf <- mkPipelineFIFO;
   let init_seq = (action 
		      initPortal(0);
		      initPortal(1);
		      initPortal(2);
                   endaction);
   let init_fsm <- mkOnce(init_seq);
   rule init_rule;
      init_fsm.start;
   endrule
   rule wrReq (writeReq());
      let wa <- writeAddr;
      let wd <- writeData;
      top.ctrl.write.writeAddr(wa,0,0,0,0,0,0);
      wf.enq(wd);
      $display("mkBsimTop::wrReq %h", wa);
   endrule
   rule wrData;
      wf.deq;
      top.ctrl.write.writeData(wf.first,0,0,0);
   endrule
   rule rdReq (readReq());
      let ra <- readAddr;
      top.ctrl.read.readAddr(ra,0,0,0,0,0,0);
      //$display("mkBsimTop::rdReq %h", ra);
   endrule
   rule rdResp;
      let rd <- top.ctrl.read.readData;
      readData(rd);
   endrule
endmodule
