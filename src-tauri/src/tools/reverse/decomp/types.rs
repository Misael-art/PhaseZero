use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Tier {
    MatchExact,
    MatchFunctional,
    Bridge,
    Nodes,
    Unknown,
    Commercial,
}

impl Tier {
    pub fn as_str(&self) -> &'static str {
        match self {
            Tier::MatchExact => "MatchExact",
            Tier::MatchFunctional => "MatchFunctional",
            Tier::Bridge => "Bridge",
            Tier::Nodes => "Nodes",
            Tier::Unknown => "Unknown",
            Tier::Commercial => "Commercial",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "MatchExact" => Tier::MatchExact,
            "MatchFunctional" => Tier::MatchFunctional,
            "Bridge" => Tier::Bridge,
            "Nodes" => Tier::Nodes,
            "Commercial" => Tier::Commercial,
            _ => Tier::Unknown,
        }
    }

    pub fn priority(&self) -> u8 {
        match self {
            Tier::MatchExact => 0,
            Tier::MatchFunctional => 1,
            Tier::Bridge => 2,
            Tier::Nodes => 3,
            Tier::Unknown => 4,
            Tier::Commercial => 5,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RomHashes {
    pub crc32: String,
    pub md5: String,
    pub sha1: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RomHeader {
    pub console_name: Option<String>,
    pub copyright: Option<String>,
    pub domestic_name: Option<String>,
    pub overseas_name: Option<String>,
    pub rom_type: Option<String>,
    pub rom_size: Option<String>,
    pub sram_info: Option<String>,
    pub checksum_f0: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SgdkFingerprint {
    pub detected: bool,
    pub confidence: f64,
    pub sig_version: Option<String>,
    pub crt_patterns_found: Vec<String>,
    pub lib_calls_found: Vec<String>,
    pub heap_location: Option<u32>,
    pub stack_location: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhidraMetadata {
    pub exported: bool,
    pub export_path: Option<String>,
    pub functions_count: Option<usize>,
    pub decompiled_bytes: Option<u64>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionMatch {
    pub name: String,
    pub address: u32,
    pub size: usize,
    pub similarity: f64,
    pub matched_bytes: usize,
    pub total_bytes: usize,
    pub status: MatchStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum MatchStatus {
    Exact,
    Functional,
    Partial,
    Unmatched,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RomEntry {
    pub path: String,
    pub filename: String,
    pub size: u64,
    pub extension: String,
    pub hashes: RomHashes,
    pub tier: String,
    pub is_commercial: bool,
    pub is_compressed: bool,
    pub header: Option<RomHeader>,
    pub sdk_fingerprint: Option<SgdkFingerprint>,
    pub ghidra: Option<GhidraMetadata>,
    pub function_matches: Vec<FunctionMatch>,
    pub scanned_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Ledger {
    pub version: String,
    pub scanned_at: String,
    pub total_roms: usize,
    pub dirs_scanned: Vec<String>,
    pub tier_counts: std::collections::HashMap<String, usize>,
    pub roms: Vec<RomEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsSnapshot {
    pub one_shot_rate: f64,
    pub avg_cost_per_function: f64,
    pub runtime_match_rate: f64,
    pub node_coverage: f64,
    pub total_functions: usize,
    pub exact_matches: usize,
    pub functional_matches: usize,
    pub unmatched_functions: usize,
    pub total_cost_ms: u64,
    pub total_nodes: usize,
    pub covered_nodes: usize,
}

pub struct ScanConfig {
    pub rom_dirs: Vec<PathBuf>,
    pub work_dir: PathBuf,
    pub skip_compressed: bool,
    pub max_depth: usize,
    pub compute_fingerprint: bool,
    pub ghidra_enabled: bool,
}

impl Default for ScanConfig {
    fn default() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "~".to_string());
        let default_work = PathBuf::from(&home).join(".retrodev").join("decomp_work");

        let rom_dirs_env = std::env::var("RDS_ROM_LIBRARY_DIRS").unwrap_or_default();
        let rom_dirs: Vec<PathBuf> = if rom_dirs_env.is_empty() {
            vec![]
        } else {
            rom_dirs_env
                .split(':')
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
                .collect()
        };

        ScanConfig {
            rom_dirs,
            work_dir: default_work,
            skip_compressed: false,
            max_depth: 3,
            compute_fingerprint: true,
            ghidra_enabled: false,
        }
    }
}

impl RomEntry {
    pub fn new(path: &std::path::Path, hashes: RomHashes, is_compressed: bool) -> Self {
        let filename = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);

        RomEntry {
            path: path.to_string_lossy().to_string(),
            filename,
            size,
            extension: ext,
            hashes,
            tier: Tier::Unknown.as_str().to_string(),
            is_commercial: false,
            is_compressed,
            header: None,
            sdk_fingerprint: None,
            ghidra: None,
            function_matches: vec![],
            scanned_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}
