use super::types::{RomEntry, RomHeader, Tier};

const COMMERCIAL_KEYWORDS: &[&str] = &[
    "(c)", "(p)", "all rights reserved",
    "electronic arts", "capcom", "konami", "square", "enix", "namco",
    "bandai", "snk", "treasure", "technosoft",
    "sonic", "streets of rage", "mortal kombat", "street fighter", "golden axe",
];

const CLEAN_ROOM_KEYWORDS: &[&str] = &[
    "sgdk", "genesis", "gcc", "sgl", "libmd", "mars", "sGDK", "SGDK",
];

fn rom_header_bytes(data: &[u8]) -> RomHeader {
    let offset = 0x100;
    let read_str = |start: usize, len: usize| -> Option<String> {
        if start + len > data.len() {
            return None;
        }
        let bytes = &data[start..start + len];
        let s = String::from_utf8_lossy(bytes);
        let trimmed = s.trim_matches('\0').trim().to_string();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    };

    RomHeader {
        console_name: read_str(offset, 16),
        copyright: read_str(offset + 0x10, 16),
        domestic_name: read_str(offset + 0x20, 48),
        overseas_name: read_str(offset + 0x50, 48),
        rom_type: read_str(offset + 0x80, 16),
        rom_size: read_str(offset + 0xA0, 8),
        sram_info: read_str(offset + 0xB0, 12),
        checksum_f0: Some(format!("{:04X}", u16::from_be_bytes(
            data.get(offset + 0xE0..=offset + 0xE1).map(|b| [b[0], b[1]]).unwrap_or([0, 0])
        ))),
    }
}

fn check_commercial(entry: &RomEntry) -> bool {
    if entry.filename.to_lowercase().contains("hack by") {
        return false;
    }

    if let Some(ref header) = entry.header {
        for field in [&header.console_name, &header.copyright, &header.domestic_name, &header.overseas_name] {
            if let Some(s) = field {
                let lower = s.to_lowercase();
                if COMMERCIAL_KEYWORDS.iter().any(|kw| lower.contains(kw)) {
                    return true;
                }
            }
        }
    }
    false
}

fn check_clean_room(entry: &RomEntry) -> bool {
    let lower = entry.filename.to_lowercase();
    for kw in CLEAN_ROOM_KEYWORDS {
        if lower.contains(kw.to_lowercase().as_str()) {
            return true;
        }
    }
    false
}

fn assign_tier(entry: &mut RomEntry) {
    if entry.tier != Tier::Unknown.as_str()
        && entry.tier != Tier::Nodes.as_str()
        && entry.tier != Tier::Bridge.as_str()
    {
        return;
    }

    if entry.sdk_fingerprint.is_some() {
        return;
    }

    let is_commercial = check_commercial(entry);

    if is_commercial {
        entry.is_commercial = true;
        entry.tier = Tier::Commercial.as_str().to_string();
        return;
    }

    if check_clean_room(entry) {
        entry.tier = Tier::MatchFunctional.as_str().to_string();
        return;
    }

    let has_header = entry.header.is_some()
        && (entry.header.as_ref().unwrap().console_name.is_some()
            || entry.header.as_ref().unwrap().domestic_name.is_some());

    if has_header {
        if entry.size < 1024 * 512 {
            entry.tier = Tier::MatchFunctional.as_str().to_string();
        } else {
            entry.tier = Tier::Bridge.as_str().to_string();
        }
    } else {
        entry.tier = Tier::Unknown.as_str().to_string();
    }
}

fn read_rom_data(path: &str) -> Vec<u8> {
    std::fs::read(path).unwrap_or_default()
}

pub fn triage(config: &super::types::ScanConfig) -> std::collections::HashMap<String, usize> {
    let ledger_path = config.work_dir.join("ledger.json");
    if !ledger_path.exists() {
        return std::collections::HashMap::new();
    }

    let data = std::fs::read_to_string(&ledger_path).unwrap_or_default();
    let mut ledger: super::types::Ledger = serde_json::from_str(&data).unwrap_or_else(|_| {
        super::types::Ledger {
            version: String::new(),
            scanned_at: String::new(),
            total_roms: 0,
            dirs_scanned: vec![],
            tier_counts: std::collections::HashMap::new(),
            roms: vec![],
        }
    });

    let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

    for rom in &mut ledger.roms {
        if rom.header.is_none() {
            let data = read_rom_data(&rom.path);
            if !data.is_empty() {
                rom.header = Some(rom_header_bytes(&data));
            }
        }

        assign_tier(rom);
        *counts.entry(rom.tier.clone()).or_insert(0) += 1;
    }

    ledger.tier_counts = counts.clone();
    ledger.total_roms = ledger.roms.len();

    let json = serde_json::to_string_pretty(&ledger).unwrap_or_default();
    let _ = std::fs::write(&ledger_path, json);

    counts
}
