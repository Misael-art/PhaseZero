use std::collections::HashMap;
use std::fs;


use super::scanner;
use super::types::{Ledger, RomEntry, ScanConfig};

pub fn load_ledger(config: &ScanConfig) -> Ledger {
    let path = config.work_dir.join("ledger.json");
    if !path.exists() {
        return Ledger {
            version: "rds-decomp-v1".to_string(),
            scanned_at: String::new(),
            total_roms: 0,
            dirs_scanned: vec![],
            tier_counts: HashMap::new(),
            roms: vec![],
        };
    }

    let data = fs::read_to_string(&path).unwrap_or_default();
    serde_json::from_str(&data).unwrap_or_else(|_| Ledger {
        version: "rds-decomp-v1".to_string(),
        scanned_at: String::new(),
        total_roms: 0,
        dirs_scanned: vec![],
        tier_counts: HashMap::new(),
        roms: vec![],
    })
}

pub fn save_ledger(ledger: &Ledger, config: &ScanConfig) -> Result<(), String> {
    fs::create_dir_all(&config.work_dir)
        .map_err(|e| format!("create work dir: {}", e))?;

    let path = config.work_dir.join("ledger.json");
    let json = serde_json::to_string_pretty(ledger)
        .map_err(|e| format!("serialize ledger: {}", e))?;
    fs::write(&path, json).map_err(|e| format!("write ledger: {}", e))?;
    Ok(())
}

pub fn scan_and_merge(config: &ScanConfig) -> Result<(), String> {
    let mut ledger = load_ledger(config);

    let existing_paths: std::collections::HashSet<String> = ledger
        .roms
        .iter()
        .map(|r| r.path.clone())
        .collect();

    let scan_result = scanner::scan(config);

    for new_rom in scan_result.entries {
        if !existing_paths.contains(&new_rom.path) {
            ledger.roms.push(new_rom);
        }
    }

    let mut tier_counts: HashMap<String, usize> = HashMap::new();
    for rom in &ledger.roms {
        *tier_counts.entry(rom.tier.clone()).or_insert(0) += 1;
    }

    ledger.total_roms = ledger.roms.len();
    ledger.tier_counts = tier_counts;
    ledger.dirs_scanned = scan_result.dirs_scanned;
    ledger.scanned_at = chrono::Utc::now().to_rfc3339();

    save_ledger(&ledger, config)?;

    if !scan_result.errors.is_empty() {
        let err_path = config.work_dir.join("scan_errors.log");
        let err_text = scan_result.errors.join("\n");
        fs::write(&err_path, &err_text)
            .map_err(|e| format!("write errors log: {}", e))?;
    }

    Ok(())
}

pub fn get_roms_by_tier(config: &ScanConfig, tier: &str) -> Vec<RomEntry> {
    let ledger = load_ledger(config);
    ledger
        .roms
        .into_iter()
        .filter(|r| r.tier == tier)
        .collect()
}
