##
## Copyright (C) 2013 Nokia, Inc
## Copyright (c) 2013-2014 Quanta Research Cambridge, Inc.

## Permission is hereby granted, free of charge, to any person
## obtaining a copy of this software and associated documentation
## files (the "Software"), to deal in the Software without
## restriction, including without limitation the rights to use, copy,
## modify, merge, publish, distribute, sublicense, and/or sell copies
## of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:

## The above copyright notice and this permission notice shall be
## included in all copies or substantial portions of the Software.

## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
## EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
## MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
## NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
## BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
## ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
## CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.

import os
import sys
import traceback
import globalv
import AST
import util
import functools
import math

proxyClassPrefixTemplate='''
class %(namespace)s%(className)s : public %(parentClass)s {
public:
    %(className)s(int id, PortalPoller *poller = 0) : Portal(id, %(namespace)s%(className)s_reqsize, NULL, poller) {
        pint.parent = static_cast<void *>(this);
    };
'''

wrapperClassPrefixTemplate='''
class %(namespace)s%(className)s : public %(parentClass)s {
public:
    %(className)s(int id, PortalPoller *poller = 0) : Portal(id, %(namespace)s%(className)s_reqsize, %(namespace)s%(className)s_handleMessage, poller) {
        pint.parent = static_cast<void *>(this);
    };
'''

handleMessageTemplateDecl='''
int %(namespace)s%(className)s_handleMessage(struct PortalInternal *p, unsigned int channel);
'''

handleMessageTemplate1='''
int %(namespace)s%(className)s_handleMessage(PortalInternal *p, unsigned int channel)
{    
    static int runaway = 0;
    unsigned int tmp;
    volatile unsigned int* temp_working_addr = &(p->map_base[PORTAL_IND_FIFO(channel)]);
    switch (channel) {'''

handleMessageTemplate2='''
    default:
        PORTAL_PRINTF("%(namespace)s%(className)s_handleMessage: unknown channel 0x%%x\\n", channel);
        if (runaway++ > 10) {
            PORTAL_PRINTF("%(namespace)s%(className)s_handleMessage: too many bogus indications, exiting\\n");
#ifndef __KERNEL__
            exit(-1);
#endif
        }
        return 0;
    }
    return 0;
}
'''

proxyMethodTemplateDecl='''
void %(namespace)s%(className)s_%(methodName)s (struct PortalInternal *p %(paramSeparator)s %(paramDeclarations)s );'''

proxyMethodTemplate='''
void %(namespace)s%(className)s_%(methodName)s (PortalInternal *p %(paramSeparator)s %(paramDeclarations)s )
{
    volatile unsigned int* temp_working_addr = &(p->map_base[PORTAL_REQ_FIFO(%(methodChannelOffset)s)]);
    BUSY_WAIT(p, temp_working_addr, "%(namespace)s%(className)s_%(methodName)s");
    %(paramStructMarshall)s
};
'''

proxyMethodTemplateSW='''
void %(namespace)s%(className)s_%(methodName)s (PortalInternal *p %(paramSeparator)s %(paramDeclarations)s )
{
    volatile unsigned int* temp_working_addr = p->map_base+1;
    %(paramStructMarshall)s
    SSWRITE(p, %(methodChannelOffset)s << 16 | %(wordLen)s, %(fdName)s);
};
'''

proxyMethodTemplateCpp='''
void %(namespace)s%(className)s::%(methodName)s ( %(paramDeclarations)s )
{
    %(namespace)s%(className)s_%(methodName)s (&pint %(paramSeparator)s %(paramReferences)s );
};
'''

msgDemarshallTemplate='''
    case %(channelNumber)s: 
        {
        %(paramStructDeclarations)s
        %(paramStructDemarshall)s
        %(responseCase)s
        }
        break;'''

msgDemarshallTemplateSW='''
    case %(channelNumber)s: 
        {
        int tmpfd;
        unsigned int tmp;
        volatile unsigned int* temp_working_addr = p->map_base+1;
        portalRecvFd(p->fpga_fd, (void *)temp_working_addr, (%(wordLen)s) * sizeof(uint32_t), &tmpfd);
        %(paramStructDeclarations)s
        %(paramStructDemarshall)s
        %(responseCase)s
        }
        break;'''

def indent(f, indentation):
    for i in xrange(indentation):
        f.write(' ')

def capitalize(s):
    return '%s%s' % (s[0].upper(), s[1:])

class NoCMixin:
    def emitCDeclaration(self, f, indentation, namespace):
        pass
    def emitCImplementation(self, f):
        return -1

class MethodMixin:
    def collectTypes(self):
        result = [self.return_type]
        result.append(AST.Type('Tuple', self.params))
        return result
    def resultTypeName(self):
        if (self.return_type):
            return self.return_type.cName()
        else:
            return int
    def formalParameters(self, params):
        return [ 'const %s%s %s' % (p.type.cName(), p.type.refParam(), p.name) for p in params]
    def emitMethodDeclaration(self, f, proxy, indentation, namespace, className):
        indent(f, indentation)
        resultTypeName = self.resultTypeName()
        paramValues = [p.name for p in self.params]
        paramValues.insert(0, '&pint')
        methodName = cName(self.name)
        if not proxy:
            f.write('virtual ')
        f.write('void %s ( ' % methodName)
        f.write(', '.join(self.formalParameters(self.params)))
        f.write(' ) ')
        if not proxy:
            f.write('= 0;\n')
        else:
            f.write('{ %s_%s (' % (className, methodName))
            f.write(', '.join(paramValues) + '); };\n')
    def emitCStructDeclaration(self, f, of, namespace, className):
        paramValues = ', '.join([p.name for p in self.params])
        formalParams = self.formalParameters(self.params)
        formalParams.insert(0, ' struct PortalInternal *p')
        methodName = cName(self.name)
        of.write('void %s%s_cb ( ' % (className, methodName))
        of.write(', '.join(formalParams))
        of.write(' );\n')
        f.write('void %s%s_cb ( ' % (className, methodName))
        f.write(', '.join(formalParams))
        f.write(' ) {\n')
        indent(f, 4)
        f.write(('(static_cast<%s *>(p->parent))->%s ( ' % (className, methodName)) + paramValues + ');\n')
        f.write('};\n')
    def emitCImplementation(self, f, hpp, className, namespace, proxy, doCpp, swInterface):

        # resurse interface types and flattening all structs into a list of types
        def collectMembers(scope, member):
            t = member.type
            tn = member.type.name
            while 1:
                if tn == 'Bit':
                    return [('%s%s'%(scope,member.name),t)]
                elif tn == 'Int' or tn == 'UInt':
                    return [('%s%s'%(scope,member.name),t)]
                elif tn == 'Float':
                    return [('%s%s'%(scope,member.name),t)]
                elif tn == 'Vector':
                    return [('%s%s'%(scope,member.name),t)]
                else:
                    td = globalv.globalvars[tn]
                    #print 'instantiate', t.params
                    tdtype = td.tdtype.instantiate(dict(zip(td.params, t.params)))
                    #print '           ', tdtype
                    if tdtype.type == 'Struct':
                        ns = '%s%s.' % (scope,member.name)
                        rv = map(functools.partial(collectMembers, ns), tdtype.elements)
                        return sum(rv,[])
                    elif tdtype.type == 'Enum':
                        return [('%s%s'%(scope,member.name),tdtype)]
                    elif tn == 'SpecialTypeForSendingFd':
                        return [('%s%s'%(scope,member.name),tdtype)]
                    else:
                        #print 'resolved to type', tdtype.type, tdtype.name, tdtype
                        t = tdtype
                        tn = tdtype.name

        class paramInfo:
            def __init__(self, name, width, shifted, datatype, assignOp):
                self.name = name
                self.width = width
                self.shifted = shifted
                self.datatype = datatype
                self.assignOp = assignOp
        # pack flattened struct-member list into 32-bit wide bins.  If a type is wider than 32-bits or 
        # crosses a 32-bit boundary, it will appear in more than one bin (though with different ranges).  
        # This is intended to mimick exactly Bluespec struct packing.  The padding must match the code 
        # in Adapter.bsv.  the argument s is a list of bins, atoms is the flattened list, and pro represents
        # the number of bits already consumed from atoms[0].
        def accumWords(s, pro, atoms):
            if len(atoms) == 0:
                if len(s) == 0:
                     return []
                else:
                     return [s]
            w = sum([x.width-x.shifted for x in s])
            a = atoms[0]
            thisType = a[1]
            aw = thisType.bitWidth();
            #print '%d %d %d' %(aw, pro, w)
            if (aw-pro+w == 32):
                s.append(paramInfo(a[0],aw,pro,thisType,'='))
                #print '%s (0)'% (a[0])
                return [s]+accumWords([],0,atoms[1:])
            if (aw-pro+w < 32):
                s.append(paramInfo(a[0],aw,pro,thisType,'='))
                #print '%s (1)'% (a[0])
                return accumWords(s,0,atoms[1:])
            else:
                s.append(paramInfo(a[0],pro+(32-w),pro,thisType,'|='))
                #print '%s (2)'% (a[0])
                return [s]+accumWords([],pro+(32-w), atoms)

        params = self.params
        paramDeclarations = self.formalParameters(params)
        paramStructDeclarations = [ '%s %s;' % (p.type.cName(), p.name) for p in params]
        
        argAtoms = sum(map(functools.partial(collectMembers, ''), params), [])

        # for a in argAtoms:
        #     print a[0]
        # print ''

        argAtoms.reverse();
        argWords  = accumWords([], 0, argAtoms)

        # for a in argWords:
        #     for b in a:
        #         print '%s[%d:%d]' % (b[0], b[1], b[2])
        # print ''
        fdName = '-1'

        def generate_marshall(w):
            global fdName
            off = 0
            word = []
            fmt = paramStructMarshallStr
            for e in w:
                field = e.name;
		if e.datatype.cName() == 'float':
		    return paramStructMarshallStr % ('*(int*)&' + e.name)
                if e.shifted:
                    field = '(%s>>%s)' % (field, e.shifted)
                if off:
                    field = '(%s<<%s)' % (field, off)
                if e.datatype.bitWidth() > 64:
                    field = '(const %s & std::bitset<%d>(0xFFFFFFFF)).to_ulong()' % (field, e.datatype.bitWidth())
                word.append(field)
                off = off+e.width-e.shifted
		if e.datatype.cName() == 'SpecialTypeForSendingFdL_32_P':
                    fdname = field
                    fmt = 'WRITEFD(p, temp_working_addr, %s);'
            return fmt % (''.join(util.intersperse('|', word)))

        def generate_demarshall(w):
            off = 0
            word = []
            word.append(paramStructDemarshallStr)
            for e in w:
                # print e.name+' (d)'
                field = 'tmp'
		if e.datatype.cName() == 'float':
		    word.append('%s = *(float*)&(%s);'%(e.name,field))
		    continue
                if off:
                    field = '%s>>%s' % (field, off)
                #print 'JJJ', e.name, '{{'+field+'}}', e.datatype.bitWidth(), e.shifted, e.assignOp, off
                #if e.datatype.bitWidth() < 32:
                field = '((%s)&0x%xul)' % (field, ((1 << (e.datatype.bitWidth()-e.shifted))-1))
                if e.shifted:
                    field = '((%s)(%s)<<%s)' % (e.datatype.cName(),field, e.shifted)
		word.append('%s %s (%s)(%s);'%(e.name, e.assignOp, e.datatype.cName(), field))
                off = off+e.width-e.shifted
            # print ''
            return '\n        '.join(word)

        if swInterface:
            paramStructDemarshallStr = 'tmp = *temp_working_addr++;'
            paramStructMarshallStr = '*temp_working_addr++ = %s;'
        else:
            paramStructDemarshallStr = 'tmp = READL(p, temp_working_addr);'
            paramStructMarshallStr = 'WRITEL(p, temp_working_addr, %s);'
        if argWords == []:
            paramStructMarshall = [paramStructMarshallStr % '0']
            paramStructDemarshall = [paramStructDemarshallStr]
        else:
            paramStructMarshall = map(generate_marshall, argWords)
            paramStructMarshall.reverse();
            paramStructDemarshall = map(generate_demarshall, argWords)
            paramStructDemarshall.reverse();

        if not params:
            paramStructDeclarations = ['        int padding;\n']
        resultTypeName = self.resultTypeName()
        substs = {
            'namespace': namespace,
            'className': className,
            'methodName': cName(self.name),
            'channelNumber': 'CHAN_NUM_%s_%s' % (className, cName(self.name)),
            'MethodName': capitalize(cName(self.name)),
            'paramDeclarations': ', '.join(paramDeclarations),
            'paramReferences': ', '.join([p.name for p in params]),
            'paramStructDeclarations': '\n        '.join(paramStructDeclarations),
            'paramStructMarshall': '\n    '.join(paramStructMarshall),
            'paramSeparator': ',' if params != [] else '',
            'paramStructDemarshall': '\n        '.join(paramStructDemarshall),
            'paramNames': ', '.join(['msg->%s' % p.name for p in params]),
            'resultType': resultTypeName,
            'methodChannelOffset': 'CHAN_NUM_%s_%s' % (className, cName(self.name)),
            'wordLen': len(argWords),
            'fdName': fdName,
            # if message is empty, we still send an int of padding
            'payloadSize' : max(4, 4*((sum([p.numBitsBSV() for p in self.params])+31)/32)) 
            }
        if (doCpp):
            f.write(proxyMethodTemplateCpp % substs)
        elif (not proxy):
            respParams = [p.name for p in self.params]
            respParams.insert(0, 'p')
            substs['responseCase'] = ('%(className)s%(name)s_cb(%(params)s);'
                                      % { 'name': self.name,
                                          'className' : className,
                                          'params': ', '.join(respParams)})
            if swInterface:
                f.write(msgDemarshallTemplateSW % substs)
            else:
                f.write(msgDemarshallTemplate % substs)
        else:
            substs['responseCase'] = ''
            if swInterface:
                f.write(proxyMethodTemplateSW % substs)
            else:
                f.write(proxyMethodTemplate % substs)
            hpp.write(proxyMethodTemplateDecl % substs)
        return len(argWords)


class StructMemberMixin:
    def emitCDeclaration(self, f, indentation, namespace):
        indent(f, indentation)
        f.write('%s %s' % (self.type.cName(), self.name))
        if self.type.isBitField():
            f.write(' : %d' % self.type.bitWidth())
        f.write(';\n')

class TypeDefMixin:
    def emitCDeclaration(self,f,indentation, namespace):
        #print 'TypeDefMixin.emitCdeclaration', self.tdtype.type, self.name, self.tdtype
        if self.tdtype.type == 'Struct' or self.tdtype.type == 'Enum':
            self.tdtype.emitCDeclaration(self.name,f,indentation,namespace)
        elif False and self.tdtype.type == 'Type':
            tdtype = self.tdtype
            #print 'resolving', tdtype.type, tdtype
            while tdtype.type == 'Type' and globalv.globalvars.has_key(tdtype.name):
                td = globalv.globalvars[tdtype.name]
                tdtype = td.tdtype.instantiate(dict(zip(td.params, tdtype.params)))
                #print 'resolved to', tdtype.type, tdtype
            if tdtype.type != 'Type':
                #print 'emitting declaration'
                tdtype.emitCDeclaration(self.name,f,indentation,namespace)
            
class StructMixin:
    def collectTypes(self):
        result = [self]
        result.append(self.elements)
        return result
    def emitCDeclaration(self, name, f, indentation, namespace):
        indent(f, indentation)
        if (indentation == 0):
            f.write('typedef ')
        f.write('struct %s {\n' % name)
        for e in self.elements:
            e.emitCDeclaration(f, indentation+4, namespace)
        indent(f, indentation)
        f.write('}')
        if (indentation == 0):
            f.write(' %s;' % name)
        f.write('\n')
    def emitCImplementation(self, f, hpp, className, namespace, doCpp, swInterface):
        return -1

class EnumElementMixin:
    def cName(self):
        return self.name

class EnumMixin:
    def cName(self):
        return self.name
    def collectTypes(self):
        result = [self]
        return result
    def emitCDeclaration(self, name, f, indentation, namespace):
        indent(f, indentation)
        if (indentation == 0):
            f.write('typedef ')
        f.write('enum %s { ' % name)
        indent(f, indentation)
        f.write(', '.join(['%s_%s' % (name, e) for e in self.elements]))
        indent(f, indentation)
        f.write(' }')
        if (indentation == 0):
            f.write(' %s;' % name)
        f.write('\n')
    def emitCImplementation(self, f, hpp, className, namespace, doCpp, swInterface):
        return -1
    def bitWidth(self):
        return int(math.ceil(math.log(len(self.elements))))

class InterfaceMixin:
    def collectTypes(self):
        result = [d.collectTypes() for d in self.decls]
        return result
    def getSubinterface(self, name):
        subinterfaceName = name
        if not globalv.globalvars.has_key(subinterfaceName):
            return None
        subinterface = globalv.globalvars[subinterfaceName]
        #print 'subinterface', subinterface, subinterface
        return subinterface
    def assignRequestResponseChannels(self, channelNumber=0):
        for d in self.decls:
            if d.__class__ == AST.Method:
                d.channelNumber = channelNumber
                channelNumber = channelNumber + 1
        self.channelCount = channelNumber
    def parentClass(self, default):
        rv = default if (len(self.typeClassInstances)==0) else (self.typeClassInstances[0])
        return rv
    def global_name(self, s, suffix):
        return '%s%s_%s' % (cName(self.name), suffix, s)
    def emitCProxyDeclaration(self, f, of, indentation, namespace, maxSize, swInterface):
        className = "%s%sProxy" % (swInterface, cName(self.name))
	reqChanNums = []
        for d in self.decls:
            reqChanNums.append('CHAN_NUM_%s%s' % (swInterface, self.global_name(d.name, "Proxy")))
        subs = {'className': className,
                'namespace': namespace,
                'maxSize': maxSize,
                'parentClass': self.parentClass('Portal')}
        f.write(proxyClassPrefixTemplate % subs)
        for d in self.decls:
            d.emitMethodDeclaration(f, True, indentation + 4, namespace, className)
        f.write('};\n')
	of.write('enum { ' + ','.join(reqChanNums) + '};\n')
        of.write('#define %(namespace)s%(className)s_reqsize (%(maxSize)s * sizeof(uint32_t))\n' % subs)
    def emitCWrapperDeclaration(self, f, of, cppf, indentation, namespace, maxSize, swInterface):
        className = "%s%sWrapper" % (swInterface, cName(self.name))
        indent(f, indentation)
	indChanNums = []
	for d in self.decls:
            indChanNums.append('CHAN_NUM_%s%s' % (swInterface, self.global_name(cName(d.name), "Wrapper")))
        subs = {'className': className,
                'namespace': namespace,
                'maxSize': maxSize,
                'parentClass': self.parentClass('Portal')}
        f.write(wrapperClassPrefixTemplate % subs)
        for d in self.decls:
            d.emitMethodDeclaration(f, False, indentation + 4, namespace, className)
        f.write('};\n')
        for d in self.decls:
            d.emitCStructDeclaration(cppf, of, namespace, className)
	of.write('enum { ' + ','.join(indChanNums) + '};\n')
        of.write('#define %(namespace)s%(className)s_reqsize (%(maxSize)s * sizeof(uint32_t))\n' % subs)
    def emitCProxyImplementation(self, f, hpp, namespace, swInterface):
        maxSize = 0;
        className = "%s%sProxy" % (swInterface, cName(self.name))
        substitutions = {'namespace': namespace,
                         'className': className,
                         'parentClass': self.parentClass('Portal')}
        for d in self.decls:
            t = d.emitCImplementation(f, hpp, className, namespace,True, False, swInterface)
            if t > maxSize:
                maxSize = t
        hpp.write('\n')
        return maxSize
    def emitCWrapperImplementation (self, f, hpp, namespace, swInterface):
        maxSize = 0;
        className = "%s%sWrapper" % (swInterface, cName(self.name))
        substitutions = {'namespace': namespace,
                         'className': className,
                         'parentClass': self.parentClass('Portal')}
        f.write(handleMessageTemplate1 % substitutions)
        for d in self.decls:
            t = d.emitCImplementation(f, hpp, className, namespace, False, False, swInterface)
            if t > maxSize:
                maxSize = t
        f.write(handleMessageTemplate2 % substitutions)
        hpp.write(handleMessageTemplateDecl % substitutions)
        return maxSize

class ParamMixin:
    def cName(self):
        return self.name
    def emitCDeclaration(self, f, indentation, namespace):
        indent(f, indentation)
        f.write('s %s' % (self.type, self.name))

class TypeMixin:
    def refParam(self):
        if (self.isBitField() and self.bitWidth() <= 64):
            return ''
        else:
            return ''
    def cName(self):
        cid = self.name
        cid = cid.replace(' ', '')
        if cid == 'Bit':
            if self.params[0].numeric() <= 32:
                return 'uint32_t'
            elif self.params[0].numeric() <= 64:
                return 'uint64_t'
            else:
                return 'std::bitset<%d>' % (self.params[0].numeric())
        elif cid == 'Int':
            if self.params[0].numeric() == 32:
                return 'int'
            else:
                assert(False)
        elif cid == 'UInt':
            if self.params[0].numeric() == 32:
                return 'unsigned int'
            else:
                assert(False)
        elif cid == 'Float':
	    return 'float'
        elif cid == 'Vector':
            return 'bsvvector<%d,%s>' % (self.params[0].numeric(), self.params[1].cName())
        elif cid == 'Action':
            return 'int'
        elif cid == 'ActionValue':
            return self.params[0].cName()
        if self.params:
            name = '%sL_%s_P' % (cid, '_'.join([cName(t) for t in self.params if t]))
        else:
            name = cid
        return name
    def isBitField(self):
        return self.name == 'Bit' or self.name == 'Int' or self.name == 'UInt'
    def bitWidth(self):
        if self.name == 'Bit' or self.name == 'Int' or self.name == 'UInt':
            width = self.params[0].name
            while globalv.globalvars.has_key(width):
                decl = globalv.globalvars[width]
                if decl.type != 'TypeDef':
                    break
                print 'Resolving width', width, decl.tdtype
                width = decl.tdtype.name
            return int(width)
        if self.name == 'Float':
            return 32
        else:
            return 0

def cName(x):
    if type(x) == str:
        x = x.replace(' ', '')
        x = x.replace('.', '$')
        return x
    else:
        return x.cName()

def generateProxy(create_cpp_file, generated_hpp, generated_cpp, generatedCFiles, i, swInterfacez):
    #myname = swInterface + i.name
    myname = i.name
    cppname = '%s.c' % myname
    hppname = '%s.h' % myname
    hpp = create_cpp_file(hppname)
    cpp = create_cpp_file(cppname)
    hpp.write('#ifndef _%(name)s_H_\n#define _%(name)s_H_\n' % {'name': myname.upper()})
    hpp.write('#include "%s.h"\n' % i.parentClass("portal"))
    generated_cpp.write('\n/************** Start of %sWrapper CPP ***********/\n' % myname)
    generated_cpp.write('#include "%s"\n' % hppname)
    for swInterface in ['', 'SS_']:
        maxSize = i.emitCProxyImplementation(cpp, generated_hpp, "", swInterface)
        if not swInterface:
            maxSize = 0
        i.emitCProxyDeclaration(hpp, generated_hpp, 0, '', maxSize, swInterface)
        maxSize = i.emitCWrapperImplementation(cpp, generated_hpp, '', swInterface)
        if not swInterface:
            maxSize = 0
        i.emitCWrapperDeclaration(hpp, generated_hpp, generated_cpp, 0, '', maxSize, swInterface)
    hpp.write('#endif // _%(name)s_H_\n' % {'name': myname.upper()})
    hpp.close();
    cpp.close();
    generatedCFiles.append(cppname)

def generate_cpp(globaldecls, project_dir, noisyFlag, swProxies, swWrappers, swInterface):
    def create_cpp_file(name):
        fname = os.path.join(project_dir, 'jni', name)
        f = util.createDirAndOpen(fname, 'w')
        if noisyFlag:
            print "Writing file ",fname
        f.write('#include "GeneratedTypes.h"\n');
        return f

    generatedCFiles = []
    hname = os.path.join(project_dir, 'jni', 'GeneratedTypes.h')
    generated_hpp = util.createDirAndOpen(hname, 'w')
    generated_hpp.write('#ifndef __GENERATED_TYPES__\n');
    generated_hpp.write('#define __GENERATED_TYPES__\n');
    generated_hpp.write('#include "portal.h"\n')
    generated_hpp.write('#ifdef __cplusplus\n')
    generated_hpp.write('extern "C" {\n')
    generated_hpp.write('#endif\n')
    # global type declarations used by interface mthods
    for v in globaldecls:
        if (v.type == 'TypeDef'):
            if v.params:
                print 'Skipping C++ declaration for parameterized type', v.name
                continue
            try:
                v.emitCDeclaration(generated_hpp, 0, '')
            except:
                print 'Skipping typedef', v.name
                traceback.print_exc()
    generated_hpp.write('\n');
    cppname = 'GeneratedCppCallbacks.cpp'
    generated_cpp = create_cpp_file(cppname)
    generatedCFiles.append(cppname)
    generated_cpp.write('\n#ifndef NO_CPP_PORTAL_CODE\n')

    for i in swProxies + swWrappers+swInterface:
        generateProxy(create_cpp_file, generated_hpp, generated_cpp, generatedCFiles, i, '')
#
#    for i in swInterface:
#        generateProxy(create_cpp_file, generated_hpp, generated_cpp, generatedCFiles, i, 'SS_')
    
    generated_cpp.write('#endif //NO_CPP_PORTAL_CODE\n')
    generated_cpp.close();
    generated_hpp.write('#ifdef __cplusplus\n')
    generated_hpp.write('}\n')
    generated_hpp.write('#endif\n')
    generated_hpp.write('#endif //__GENERATED_TYPES__\n');
    generated_hpp.close();
    gen_makefile = util.createDirAndOpen(os.path.join(project_dir, 'jni', 'Makefile.generated_files'), 'w')
    gen_makefile.write('\nGENERATED_CPP=' + ' '.join(generatedCFiles)+'\n');
    gen_makefile.close();
    return generatedCFiles
