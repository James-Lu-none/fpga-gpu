import sys
import re

# ISA Opcodes (Hex)
OPCODES = {
    "ADD":  0x01,
    "SUB":  0x02,
    "MUL":  0x03,
    "CMP":  0x04,
    "ADDI": 0x81,
    "LDR":  0xA0,
    "STR":  0xA1,
    "S2R":  0xB0,
    "BR":   0xC0,
    "SYNC": 0xE0,
    "EXIT": 0xFF
}

# System Registers for S2R
SYS_REGS = {
    "SR_TID.X": 0,
    "SR_TID.Y": 1,
    "SR_BID.X": 2,
    "SR_BID.Y": 3
}

def reg_to_int(reg_str):
    if not reg_str.upper().startswith('R'):
        raise ValueError(f"Invalid register {reg_str}")
    return int(reg_str[1:])

def parse_line(line):
    # Remove comments and strip
    line = line.split(';')[0].strip()
    if not line:
        return None
    
    # Split into mnemonic and operands
    parts = re.split(r'\s+|,|\s+', line)
    parts = [p for p in parts if p]
    
    mnemonic = parts[0].upper()
    if mnemonic not in OPCODES:
        raise ValueError(f"Unknown opcode: {mnemonic}")
        
    opcode = OPCODES[mnemonic]
    
    # R-Type: OP rd, rs, rt
    if mnemonic in ["ADD", "SUB", "MUL"]:
        rd = reg_to_int(parts[1])
        rs = reg_to_int(parts[2])
        rt = reg_to_int(parts[3])
        return (opcode << 24) | (rd << 19) | (rs << 14) | (rt << 9)
        
    # CMP: OP rs, rt
    elif mnemonic == "CMP":
        rs = reg_to_int(parts[1])
        rt = reg_to_int(parts[2])
        return (opcode << 24) | (rs << 14) | (rt << 9)
        
    # I-Type: ADDI rd, rs, imm
    elif mnemonic == "ADDI":
        rd = reg_to_int(parts[1])
        rs = reg_to_int(parts[2])
        imm = int(parts[3], 0) & 0x3FFF # 14-bit imm
        return (opcode << 24) | (rd << 19) | (rs << 14) | imm
        
    # Load/Store: LDR rd, [rs]
    elif mnemonic in ["LDR", "STR"]:
        # Parse [rs]
        r1 = reg_to_int(parts[1])
        mem_op = parts[2].replace('[', '').replace(']', '')
        r2 = reg_to_int(mem_op)
        if mnemonic == "LDR":
            rd = r1
            rs = r2
            return (opcode << 24) | (rd << 19) | (rs << 14)
        else: # STR rt, [rs]
            rt = r1
            rs = r2
            return (opcode << 24) | (rs << 14) | (rt << 9)
            
    # Branch: BR nzp, imm
    elif mnemonic == "BR":
        nzp_str = parts[1].upper()
        cond = 0
        if 'N' in nzp_str: cond |= 0x4
        if 'Z' in nzp_str: cond |= 0x2
        if 'P' in nzp_str: cond |= 0x1
        imm = int(parts[2], 0) & 0x7FFFF # 19-bit offset
        return (opcode << 24) | (cond << 19) | imm
        
    elif mnemonic == "S2R":
        rd = reg_to_int(parts[1])
        sr_name = parts[2].upper()
        if sr_name not in SYS_REGS:
            raise ValueError(f"Unknown system register: {sr_name}")
        imm = SYS_REGS[sr_name]
        return (opcode << 24) | (rd << 19) | imm
        
    elif mnemonic in ["EXIT", "SYNC"]:
        return opcode << 24
        
    raise ValueError(f"Unhandled mnemonic: {mnemonic}")

def assemble(input_file, output_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()
        
    machine_code = []
    for i, line in enumerate(lines):
        try:
            code = parse_line(line)
            if code is not None:
                machine_code.append(code)
        except Exception as e:
            print(f"Error on line {i+1}: {line.strip()}")
            print(e)
            sys.exit(1)
            
    with open(output_file, 'w') as f:
        for i, code in enumerate(machine_code):
            # Output in Hex format suitable for Verilog $readmemh or C array
            f.write(f"{code:08X}\n")
            
    print(f"Successfully assembled {len(machine_code)} instructions to {output_file}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python gpu_assembler.py <input.s> <output.hex>")
        sys.exit(1)
    assemble(sys.argv[1], sys.argv[2])
