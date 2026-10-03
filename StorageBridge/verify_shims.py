"""Executes the production Thumb shims with mocked XNU buf/physio APIs.

python -m pip install unicorn
python StorageBridge/verify_shims.py [--kernel /path/to/decompressed/kernel.macho]
No firmware is distributed with this project.
"""
import hashlib, json, struct, unittest, argparse
from pathlib import Path
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE
from unicorn.arm_const import *

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / 'StorageBridge/shims.json').read_text())
SHIMS = {name: (addr, bytes.fromhex(code)) for name, addr, code in MANIFEST['blobs']}
API = {'count': 0x8009cdf8, 'resid': 0x8009ce0c, 'map': 0x8009d1e8,
       'device': 0x8009d1a0, 'flags': 0x8009cdcc, 'blkno': 0x8009d178,
       'unmap': 0x8009d230, 'error': 0x8009cd90, 'done': 0x8009d5d4,
       'rw': 0x801e2a3c, 'physio': 0x801d9a48}
# Verified exported symbol values from the reference kernel.
REG = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]

class Shims(unittest.TestCase):
    def machine(self):
        uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
        uc.mem_map(0x80000000, 0x300000)
        uc.mem_map(0x100000, 0x40000)
        for addr, code in SHIMS.values(): uc.mem_write(addr, code)
        uc.mem_write(0x80097918, b'\x70\x47')
        for address in API.values(): uc.mem_write(address, b'\x70\x47')
        uc.reg_write(UC_ARM_REG_SP, 0x120000)
        uc.reg_write(UC_ARM_REG_LR, 0x110001)
        for index, reg in enumerate((UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7, UC_ARM_REG_R8)):
            uc.reg_write(reg, 0x100 + index)
        return uc

    def strategy(self, block, error=0, processed=1024, map_error=0, read=True):
        uc = self.machine(); calls=[]; resid=[]; errors=[]
        def hook(uc, address, size, user):
            if address == 0x110000: uc.emu_stop(); return
            args=[uc.reg_read(r) for r in REG]
            sp=uc.reg_read(UC_ARM_REG_SP)
            name=next((n for n,a in API.items() if a == address), None)
            if name:
                calls.append(name)
                if name == 'count': uc.reg_write(REG[0],1024)
                elif name == 'resid': resid.append(args[1])
                elif name == 'map':
                    uc.mem_write(args[1], struct.pack('<I',0x130080)); uc.reg_write(REG[0],map_error)
                elif name == 'device': uc.reg_write(REG[0],0x02000000)
                elif name == 'flags': uc.reg_write(REG[0],int(read))
                elif name == 'blkno':
                    uc.reg_write(REG[0],block & 0xffffffff); uc.reg_write(REG[1],block >> 32)
                elif name == 'error': errors.append(args[1])
                elif name == 'done': self.assertEqual(args[0],0x120100)
            elif address == 0x80097918:
                calls.append('host')
                self.assertEqual(args,[0x130080,1024,block&0xffffffff,block>>32])
                self.assertEqual(struct.unpack('<II',uc.mem_read(sp,8)),(int(read),0x02000000))
                uc.reg_write(REG[0],error);uc.reg_write(REG[1],processed)
        uc.hook_add(UC_HOOK_CODE,hook)
        uc.reg_write(REG[0],0x120100)
        uc.emu_start(SHIMS['strategy'][0]|1,0,count=2000)
        self.assertEqual(uc.reg_read(UC_ARM_REG_PC),0x110000)
        self.assertEqual(uc.reg_read(UC_ARM_REG_SP),0x120000)
        for index,reg in enumerate((UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R6,UC_ARM_REG_R7,UC_ARM_REG_R8)):
            self.assertEqual(uc.reg_read(reg),0x100+index)
        self.assertEqual(calls.count('done'),1)
        if map_error:
            self.assertNotIn('host',calls);self.assertNotIn('unmap',calls)
            self.assertEqual(errors,[14]);self.assertEqual(resid,[1024])
        else:
            self.assertEqual(resid,[1024,1024-processed])
            self.assertEqual(errors,[error] if error else [])
            self.assertEqual(calls[-2:],['resid','done'] if not error else ['error','done'])

    def test_high_offset_read(self): self.strategy((5<<30)//512)
    def test_high_offset_write(self): self.strategy((7<<30)//512,read=False)
    def test_64_bit_block_number(self): self.strategy((1<<32)+17)
    def test_partial_io(self): self.strategy((8<<30)//512-1,processed=512)
    def test_eof(self): self.strategy((8<<30)//512,processed=0)
    def test_host_error(self): self.strategy(0,error=28,processed=0)
    def test_map_failure(self): self.strategy(0,map_error=14)

    def test_raw_device_uses_physio(self):
        for reading in (True,False):
            uc=self.machine()
            uc.mem_map(0x8032b000,4096)
            uc.mem_write(0x8032b018,struct.pack('<I',512))
            seen=[]
            def hook(uc,address,size,user):
                if address==0x110000:uc.emu_stop()
                elif address==API['rw']:
                    self.assertEqual(uc.reg_read(REG[0]),0x130000)
                    uc.reg_write(REG[0],0 if reading else 1)
                elif address==API['physio']:
                    seen.append(address)
                    self.assertEqual([uc.reg_read(r) for r in REG],[0x800976bd,0,0x02000000,int(reading)])
                    args=struct.unpack('<III',uc.mem_read(uc.reg_read(UC_ARM_REG_SP),12))
                    self.assertEqual(args,(0x801d9c15,0x130000,512))
                    uc.reg_write(REG[0],17)
            uc.hook_add(UC_HOOK_CODE,hook)
            uc.reg_write(REG[0],0x02000000);uc.reg_write(REG[1],0x130000)
            uc.emu_start(SHIMS['raw'][0]|1,0,count=1000)
            self.assertEqual(len(seen),1)
            self.assertEqual(uc.reg_read(REG[0]),17)
            self.assertEqual(uc.reg_read(UC_ARM_REG_SP),0x120000)

    def test_swift_uses_manifest_bytes(self):
        source=(ROOT/'Podium/Emulator/Storage/GuestDiskBridge.swift').read_text()
        for _,_,code in MANIFEST['blobs']:self.assertIn('"'+code+'"',source)
        self.assertIn(MANIFEST['kernelSHA256'],source)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--kernel');args,rest=parser.parse_known_args()
    if args.kernel:
        kernel=Path(args.kernel).read_bytes()
        assert hashlib.sha256(kernel).hexdigest()==MANIFEST['kernelSHA256']
        # Check reference Mach-O address/file-offset equivalence and functions.
        p=28;segments=[]
        for _ in range(struct.unpack_from('<I',kernel,16)[0]):
            cmd,size=struct.unpack_from('<II',kernel,p)
            if cmd==1:
                base,length,offset,filesize=struct.unpack_from('<IIII',kernel,p+24)
                segments.append((base,length,offset,filesize))
            p+=size
        for addr,_ in SHIMS.values():
            assert any(base<=addr<base+filesize and offset+addr-base==addr-0x80001000 for base,length,offset,filesize in segments)
        print('Reference kernel SHA-256 and shim load addresses verified')
    unittest.main(argv=['verify_shims.py']+rest)
