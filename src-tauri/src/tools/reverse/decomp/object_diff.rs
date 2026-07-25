use std::collections::HashMap;
use std::process::Command;

use super::types::{FunctionMatch, MatchStatus};

pub struct DisassemblyLine {
    pub address: u32,
    pub bytes: Vec<u8>,
    pub mnemonic: String,
    pub operands: String,
}

pub struct FunctionBlock {
    pub name: String,
    pub start_addr: u32,
    pub end_addr: u32,
    pub lines: Vec<DisassemblyLine>,
}

fn objdump_disassemble(path: &str) -> Result<Vec<FunctionBlock>, String> {
    let output = Command::new("m68k-elf-objdump")
        .arg("-d")
        .arg("-M")
        .arg("68000")
        .arg("-b")
        .arg("binary")
        .arg("-m")
        .arg("m68k:68000")
        .arg(path)
        .output()
        .map_err(|e| format!("objdump failed: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "objdump error: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_objdump_output(&stdout)
}

fn disassemble_raw(data: &[u8], base_addr: u32) -> Result<Vec<FunctionBlock>, String> {
    let which = which("m68k-elf-objdump").unwrap_or_default();

    if which.is_empty() {
        return diassembler_stub(data, base_addr);
    }

    let temp_dir = std::env::temp_dir();
    let temp_bin = temp_dir.join("_rds_disasm.bin");
    std::fs::write(&temp_bin, data)
        .map_err(|e| format!("write temp binary: {}", e))?;

    let result = objdump_disassemble(temp_bin.to_string_lossy().as_ref());
    std::fs::remove_file(&temp_bin).ok();
    result
}

fn which(name: &str) -> Option<String> {
    let path_var = std::env::var("PATH").unwrap_or_default();
    for dir in path_var.split(':') {
        let full = format!("{}/{}", dir, name);
        if std::path::Path::new(&full).exists() {
            return Some(full);
        }
    }
    None
}

fn parse_objdump_output(output: &str) -> Result<Vec<FunctionBlock>, String> {
    let mut blocks = Vec::new();
    let mut current_block: Option<FunctionBlock> = None;

    for line in output.lines() {
        if line.trim().is_empty() {
            continue;
        }

        if line.starts_with("Disassembly of section") {
            continue;
        }

        if !line.starts_with(' ') && !line.starts_with('\t') {
            if let Some(block) = current_block.take() {
                blocks.push(block);
            }

            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() >= 2 {
                let name = parts[0].trim().to_string();
                current_block = Some(FunctionBlock {
                    name,
                    start_addr: 0,
                    end_addr: 0,
                    lines: vec![],
                });
            }
            continue;
        }

        if let Some(ref mut block) = current_block {
            let trimmed = line.trim();
            let parts: Vec<&str> = trimmed.splitn(3, |c: char| c == ':' || c == '\t').collect();
            if parts.len() >= 2 {
                if let Ok(addr) = u32::from_str_radix(parts[0].trim(), 16) {
                    if block.start_addr == 0 {
                        block.start_addr = addr;
                    }
                    block.end_addr = addr + 2;

                    let mnemonic = if parts.len() >= 3 {
                        parts[2].trim().to_string()
                    } else {
                        parts[1].trim().to_string()
                    };

                    block.lines.push(DisassemblyLine {
                        address: addr,
                        bytes: vec![],
                        mnemonic,
                        operands: String::new(),
                    });
                }
            }
        }
    }

    if let Some(block) = current_block.take() {
        blocks.push(block);
    }

    Ok(blocks)
}

fn diassembler_stub(data: &[u8], base_addr: u32) -> Result<Vec<FunctionBlock>, String> {
    let mut blocks = Vec::new();
    let mut lines = Vec::new();
    let mut addr = base_addr;

    let chunk_size = 64;
    let mut i = 0;

    while i < data.len().min(4096) {
        let end = (i + chunk_size).min(data.len());
        let chunk = &data[i..end];

        let opcode = if chunk.len() >= 2 {
            u16::from_be_bytes([chunk[0], chunk[1]])
        } else {
            0
        };

        let mnemonic = match opcode >> 12 {
            0x0 => match opcode {
                0x4E71 => "NOP",
                0x4E75 => "RTS",
                0x4E56 => "LINK",
                0x4E5E => "UNLK",
                0x4E90..=0x4E9F => "JSR",
                _ => "ORI",
            },
            0x4 => match opcode >> 8 {
                0x40 => "MOVEP",
                0x41 => "LEA",
                _ => "CHK",
            },
            0x6 => "BCLR",
            0xD => "ADD",
            0xE => {
                if opcode & 0xFE00 == 0xE000 {
                    if opcode & 0x01C0 == 0x0000 { "ASR" }
                    else if opcode & 0x01C0 == 0x0040 { "ASL" }
                    else if opcode & 0x01C0 == 0x0080 { "LSR" }
                    else if opcode & 0x01C0 == 0x00C0 { "LSL" }
                    else if opcode & 0x01C0 == 0x0100 { "ROXR" }
                    else if opcode & 0x01C0 == 0x0140 { "ROXL" }
                    else if opcode & 0x01C0 == 0x0180 { "ROR" }
                    else { "ROL" }
                } else {
                    "MOVE"
                }
            }
            0xF => "SBCD",
            _ => "MOVE",
        };

        lines.push(DisassemblyLine {
            address: addr,
            bytes: chunk.to_vec(),
            mnemonic: mnemonic.to_string(),
            operands: String::new(),
        });

        i += chunk_size;
        addr += chunk_size as u32;
    }

    blocks.push(FunctionBlock {
        name: "stub_main".to_string(),
        start_addr: base_addr,
        end_addr: addr,
        lines,
    });

    Ok(blocks)
}

pub fn compare_functions(
    source_blocks: &[FunctionBlock],
    target_blocks: &[FunctionBlock],
) -> Vec<FunctionMatch> {
    let source_map: HashMap<&str, &FunctionBlock> = source_blocks
        .iter()
        .map(|b| (b.name.as_str(), b))
        .collect();

    let mut matches = Vec::new();

    for target in target_blocks {
        let best_match = source_map.iter()
            .max_by(|(_, a), (_, b)| {
                let sim_a = compute_similarity(a, target);
                let sim_b = compute_similarity(b, target);
                sim_a.partial_cmp(&sim_b).unwrap_or(std::cmp::Ordering::Equal)
            })
            .map(|(name, block)| (*name, compute_similarity(block, target)));

        match best_match {
            Some((_, sim)) if sim >= 0.95 => {
                let matched = target.lines.iter().filter(|l| {
                    source_map.values().any(|s| s.lines.iter().any(|sl| sl.mnemonic == l.mnemonic))
                }).count();

                matches.push(FunctionMatch {
                    name: target.name.clone(),
                    address: target.start_addr,
                    size: (target.end_addr - target.start_addr) as usize,
                    similarity: sim,
                    matched_bytes: matched * 2,
                    total_bytes: target.lines.len() * 2,
                    status: if sim >= 0.99 {
                        MatchStatus::Exact
                    } else {
                        MatchStatus::Functional
                    },
                });
            }
            Some((_, sim)) if sim >= 0.7 => {
                matches.push(FunctionMatch {
                    name: target.name.clone(),
                    address: target.start_addr,
                    size: (target.end_addr - target.start_addr) as usize,
                    similarity: sim,
                    matched_bytes: 0,
                    total_bytes: target.lines.len() * 2,
                    status: MatchStatus::Partial,
                });
            }
            _ => {
                matches.push(FunctionMatch {
                    name: target.name.clone(),
                    address: target.start_addr,
                    size: (target.end_addr - target.start_addr) as usize,
                    similarity: 0.0,
                    matched_bytes: 0,
                    total_bytes: target.lines.len() * 2,
                    status: MatchStatus::Unmatched,
                });
            }
        }
    }

    matches
}

fn compute_similarity(a: &FunctionBlock, b: &FunctionBlock) -> f64 {
    if a.lines.is_empty() && b.lines.is_empty() {
        return 1.0;
    }
    if a.lines.is_empty() || b.lines.is_empty() {
        return 0.0;
    }

    let mut matched = 0;
    let total = a.lines.len().max(b.lines.len());

    for (i, a_line) in a.lines.iter().enumerate() {
        if i >= b.lines.len() {
            break;
        }
        if a_line.mnemonic == b.lines[i].mnemonic {
            matched += 1;
            if a_line.operands == b.lines[i].operands {
                matched += 1;
            }
        }
    }

    matched as f64 / (total * 2) as f64
}

pub fn diff_roms(
    source_path: &str,
    target_data: &[u8],
    target_base_addr: u32,
) -> Result<Vec<FunctionMatch>, String> {
    let source_blocks = objdump_disassemble(source_path).unwrap_or_default();
    let target_blocks = disassemble_raw(target_data, target_base_addr)?;

    Ok(compare_functions(&source_blocks, &target_blocks))
}

pub fn objdump_available() -> bool {
    which("m68k-elf-objdump").is_some()
}
