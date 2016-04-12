// Copyright (c) 2014 Quanta Research Cambridge, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import BuildVector::*;
import ClientServer::*;
import Connectable::*;
import DefaultValue::*;
import FIFOF::*;
import Gearbox::*;
import GetPut::*;
import MIMO::*;
import Vector::*;

import Pipe::*;
import Portal::*;
import MemTypes::*;
import ConnectalMemory::*;
import SharedMemoryFifo::*;

module mkSharedMemoryRequestPortal#(PipePortal#(numRequests, numIndications, 32) portal,
   function Bit#(16) messageSize(Bit#(16) methodNumber),
   Vector#(2, MemReadEngineServer#(64)) readEngine, Vector#(2, MemWriteEngineServer#(64)) writeEngine)(SharedMemoryPortal#(64));
   SharedMemoryPipeOut#(64,numRequests) pipeOut <- mkSharedMemoryPipeOut(readEngine, writeEngine);
   mapM_(uncurry(mkConnection), zip(pipeOut.data, portal.requests));

   interface SharedMemoryPortalConfig cfg = pipeOut.cfg;
endmodule

// adds a header word to each message out of an indication pipe
module mkFramedIndicationPipe#(PipePortal#(numRequests,numIndications,32) pipePortal,
			       function Bit#(16) messageSize(Bit#(16) methodNumber),
			       Integer i)(PipeOut#(Bit#(32)));

   let pipeOut = pipePortal.indications[i];
   Bit#(16) messageBits = messageSize(fromInteger(i));
   Bit#(16) roundup = messageBits[4:0] == 0 ? 0 : 1;
   Bit#(16) numWords = (messageBits >> 5) + roundup;
   Bit#(16) totalWords = numWords + 1;
   Bit#(32) hdr = fromInteger(i) << 16 | extend(numWords + 1);
   let sendHeader <- mkReg(True);
   Reg#(Bit#(16)) burstLenReg <- mkReg(0);
   return (interface PipeOut;
	      method Bit#(32) first() if (pipeOut.notEmpty());
	         if (sendHeader)
		    return hdr;
		 else
		    return pipeOut.first();
	      endmethod
	      method Action deq() if (pipeOut.notEmpty());
	         if (sendHeader) begin
		    sendHeader <= False;
		    burstLenReg <= numWords;
		 end
		 else begin
		    pipeOut.deq();
		    burstLenReg <= burstLenReg - 1;
		    if (burstLenReg == 1)
		       sendHeader <= True;
		 end
	      endmethod
	      method Bool notEmpty(); return pipeOut.notEmpty(); endmethod
	   endinterface);
endmodule

module mkSharedMemoryIndicationPortal#(PipePortal#(numRequests,numIndications,32) pipePortal,
				       function Bit#(16) messageSize(Bit#(16) methodNumber),
				       Vector#(2, MemReadEngineServer#(64)) readEngines, Vector#(2, MemWriteEngineServer#(64)) writeEngines)
   (SharedMemoryPortal#(64));

   Vector#(numIndications, PipeOut#(Bit#(32))) indicationPipes <- genWithM(mkFramedIndicationPipe(pipePortal,messageSize));

   SharedMemoryPipeIn#(64) pipeIn <- mkSharedMemoryPipeIn(indicationPipes, readEngines, writeEngines);
   interface SharedMemoryPortalConfig cfg = pipeIn.cfg;
endmodule

interface SerialPortalPipeOut#(numeric type pipeCount);
   interface Vector#(pipeCount, PipeOut#(Bit#(32))) data;
   interface PipeIn#(Bit#(8))                       inputPipe;
endinterface
interface SerialPortalPipeIn#(numeric type dataBusWidth);
endinterface


typedef enum {
   Idle,
   MessageHeader,
   MessageBody,
   Stop
   } SerialPortalState deriving (Bits,Eq);

module mkSerialPortalPipeOut(SerialPortalPipeOut#(pipeCount));
   let clock <- exposeCurrentClock();
   let reset <- exposeCurrentReset();
   Reg#(Bit#(16)) messageWordsReg <- mkReg(0);
   Reg#(Bit#(16)) methodIdReg <- mkReg(0);
   Reg#(SerialPortalState) state <- mkReg(Idle);
   FIFOF#(Bit#(8)) inputFifo <- mkFIFOF();
   Gearbox#(1,4,Bit#(8)) gearbox <- mk1toNGearbox(clock,reset,clock,reset);
   Vector#(pipeCount, FIFOF#(Bit#(32))) dataFifo <- replicateM(mkFIFOF);

   let verbose = False;

   rule rx;
      let char <- toGet(inputFifo).get();
      gearbox.enq(vec(char));
   endrule

   rule idle if (state == Idle);
      state <= MessageHeader;
   endrule

   rule receiveMessageHeader if (state == MessageHeader);
      let bytevec = gearbox.first(); gearbox.deq();
      let hdr = pack(bytevec);
      let methodId = hdr[31:16];
      let messageWords = hdr[15:0];
      methodIdReg <= methodId;
      if (verbose)
         $display("receiveMessageHeader hdr=%x methodId=%x messageWords=%d", hdr, methodId, messageWords);
      messageWordsReg <= messageWords - 1;
      if (messageWords == 1)
         state <= MessageHeader;
      else
         state <= MessageBody;
   endrule

   rule receiveMessage if (state == MessageBody);
      let vec = gearbox.first(); gearbox.deq();
      let data = pack(vec);
      if (verbose)
         $display("receiveMessage data=%x messageWords=%d", data, messageWordsReg);
      if (methodIdReg != 16'hFFFF)
         dataFifo[methodIdReg].enq(data);
      messageWordsReg <= messageWordsReg - 1;
      if (messageWordsReg == 1)
         state <= MessageHeader;
   endrule

   interface data      = map(toPipeOut, dataFifo);
   interface inputPipe = toPipeIn(inputFifo);
endmodule

module mkSerialPortalPipeIn#(Vector#(numIndications, PipeOut#(Bit#(32))) pipes)(PipeOut#(Bit#(8)));
   let clock <- exposeCurrentClock;
   let reset <- exposeCurrentReset;
   Reg#(Bit#(16)) messageWordsReg <- mkReg(0);
   Reg#(Bit#(16)) methodIdReg <- mkReg(0);
   Reg#(Bool) paddingReg <- mkReg(False);
   Reg#(SerialPortalState) state <- mkReg(Idle);
   Reg#(Bit#(32)) sglIdReg <- mkReg(0);
   function Bool pipeOutNotEmpty(PipeOut#(a) po); return po.notEmpty(); endfunction
   Vector#(numIndications, Bool) readyBits = map(pipeOutNotEmpty, pipes);
   Bool      interruptStatus = False;
   Bit#(16)  readyChannel = -1;
   FIFOF#(Bit#(8)) outputFifo <- mkFIFOF();
   Gearbox#(4,1,Bit#(8)) gb <- mkNto1Gearbox(clock,reset,clock,reset);

   let verbose = True;

   for (Integer i = valueOf(numIndications) - 1; i >= 0; i = i - 1) begin
      if (readyBits[i]) begin
         interruptStatus = True;
         readyChannel = fromInteger(i);
      end
   end

   rule send8bits;
      let v = gb.first();
      gb.deq();
      if (verbose) $display("send8bits v=%h", v);
      outputFifo.enq(v[0]);
   endrule

   rule idle if (state == Idle);
      state <= MessageHeader;
   endrule

   rule sendHeader if (state == MessageHeader && interruptStatus);
      Bit#(32) hdr <- toGet(pipes[readyChannel]).get();
      Bit#(16) totalWords = hdr[15:0];
      let messageWords = totalWords-1;

      messageWordsReg <= messageWords;
      methodIdReg <= readyChannel;
      gb.enq(unpack(hdr));
      state <= MessageBody;
   endrule

   rule sendMessage if (state == MessageBody);
      messageWordsReg <= messageWordsReg - 1;
      let v <- toGet(pipes[methodIdReg]).get();
      gb.enq(unpack(v));
      $display("sendMessage v=%h messageWords=%d paddingReg=%d", v, messageWordsReg, paddingReg);
      if (messageWordsReg == 1) begin
         state <= MessageHeader;
      end
   endrule

   return toPipeOut(outputFifo);
endmodule
