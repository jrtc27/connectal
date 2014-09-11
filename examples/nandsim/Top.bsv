// bsv libraries
import SpecialFIFOs::*;
import Vector::*;
import StmtFSM::*;
import FIFO::*;
import BRAM::*;
import DefaultValue::*;
import Connectable::*;

// portz libraries
import Leds::*;
import Directory::*;
import CtrlMux::*;
import Portal::*;
import PortalMemory::*;
import MemTypes::*;
import MemServer::*;
import MemUtils::*;
import SGList::*;

// generated by tool
import NandSimRequestWrapper::*;
import DmaDebugRequestWrapper::*;
import SGListConfigRequestWrapper::*;
import NandSimIndicationProxy::*;
import DmaDebugIndicationProxy::*;
import SGListConfigIndicationProxy::*;

// defined by user
import NandSim::*;
import NandSimNames::*;

module mkPortalTop(StdPortalDmaTop#(PhysAddrWidth));
   
   NandSimIndicationProxy nandSimIndicationProxy <- mkNandSimIndicationProxy(NandSimIndication);   
   NandSim nandSim <- mkNandSim(nandSimIndicationProxy.ifc);
   NandSimRequestWrapper nandSimRequestWrapper <- mkNandSimRequestWrapper(NandSimRequest,nandSim.request);
   
   SGListConfigIndicationProxy backingStoreSGListConfigIndicationProxy <- mkSGListConfigIndicationProxy(BackingStoreSGListConfigIndication);
   SGListMMU#(PhysAddrWidth) backingStoreSGList <- mkSGListMMU(0, True, backingStoreSGListConfigIndicationProxy.ifc);
   SGListConfigRequestWrapper backingStoreSGListConfigRequestWrapper <- mkSGListConfigRequestWrapper(BackingStoreSGListConfigRequest, backingStoreSGList.request);

   DmaDebugIndicationProxy hostmemDmaDebugIndicationProxy <- mkDmaDebugIndicationProxy(HostmemDmaDebugIndication);
   MemServer#(PhysAddrWidth,64,1) hostmemDma <- mkMemServerRW(hostmemDmaDebugIndicationProxy.ifc, cons(nandSim.readClient, nil), cons(nandSim.writeClient, nil), cons(backingStoreSGList, nil));
   DmaDebugRequestWrapper hostmemDmaDebugRequestWrapper <- mkDmaDebugRequestWrapper(HostmemDmaDebugRequest, hostmemDma.request);
   
   
   Vector#(6,StdPortal) portals;
   portals[0] = nandSimRequestWrapper.portalIfc;
   portals[1] = nandSimIndicationProxy.portalIfc; 
   portals[2] = hostmemDmaDebugRequestWrapper.portalIfc;
   portals[3] = hostmemDmaDebugIndicationProxy.portalIfc; 
   portals[4] = backingStoreSGListConfigRequestWrapper.portalIfc;
   portals[5] = backingStoreSGListConfigIndicationProxy.portalIfc;
   
   StdDirectory dir <- mkStdDirectory(portals);
   let ctrl_mux <- mkSlaveMux(dir,portals);
   
   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = hostmemDma.masters;
   interface leds = default_leds;
      
endmodule : mkPortalTop
