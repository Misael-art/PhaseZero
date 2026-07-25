pub mod tools;

pub use tools::reverse::decomp::types;
pub use tools::reverse::decomp::scanner;
pub use tools::reverse::decomp::triage;
pub use tools::reverse::decomp::ledger;
pub use tools::reverse::decomp::fingerprint;
pub use tools::reverse::decomp::ghidra_export;
pub use tools::reverse::decomp::object_diff;
pub use tools::reverse::decomp::metrics;

use types::{MetricsSnapshot, RomEntry, ScanConfig};

pub struct DecompPipeline {
    pub config: ScanConfig,
}

impl DecompPipeline {
    pub fn new() -> Self {
        DecompPipeline {
            config: ScanConfig::default(),
        }
    }

    pub fn with_config(config: ScanConfig) -> Self {
        DecompPipeline { config }
    }

    pub fn scan(&self) -> Result<(Vec<RomEntry>, MetricsSnapshot), String> {
        ledger::scan_and_merge(&self.config)?;

        let mut ledger = ledger::load_ledger(&self.config);

        for rom in &mut ledger.roms {
            if self.config.compute_fingerprint && rom.sdk_fingerprint.is_none() {
                let data = std::fs::read(&rom.path).unwrap_or_default();
                if !data.is_empty() {
                    let fp = fingerprint::fingerprint_rom(&data, &rom.filename);
                    rom.tier = fingerprint::tier_from_fingerprint(
                        &fp,
                        &rom.filename,
                        rom.is_commercial,
                    )
                    .as_str()
                    .to_string();
                    rom.sdk_fingerprint = Some(fp);
                }
            }

            if self.config.ghidra_enabled && rom.ghidra.is_none() {
                let ghidra_result =
                    ghidra_export::try_export(&rom.path, &self.config.work_dir);
                rom.ghidra = Some(ghidra_result);
            }
        }

        ledger::save_ledger(&ledger, &self.config)?;

        triage::triage(&self.config);

        let final_ledger = ledger::load_ledger(&self.config);
        let roms = final_ledger.roms.clone();
        let metrics = metrics::compute_ledger_metrics(&final_ledger);
        metrics::save_metrics_report(&self.config, &metrics)?;

        Ok((roms, metrics))
    }

    pub fn diff_rom(&self, rom_path: &str, reference_path: &str) -> Result<Vec<types::FunctionMatch>, String> {
        let data = std::fs::read(rom_path)
            .map_err(|e| format!("read {}: {}", rom_path, e))?;
        object_diff::diff_roms(reference_path, &data, 0x00000000)
    }

    pub fn status(&self) -> Result<(usize, Option<MetricsSnapshot>), String> {
        let ledger = ledger::load_ledger(&self.config);
        let metrics = metrics::load_metrics(&self.config);
        Ok((ledger.total_roms, metrics))
    }
}

impl Default for DecompPipeline {
    fn default() -> Self {
        Self::new()
    }
}
