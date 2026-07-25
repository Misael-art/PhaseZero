use clap::{Parser, Subcommand};
use rds_decomp::types::ScanConfig;
use rds_decomp::DecompPipeline;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "rds-decomp", version, about = "RetroDev Studio - Paired Decompilation Pipeline")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Scan {
        #[arg(short, long, help = "ROM library directories (colon-separated, overrides RDS_ROM_LIBRARY_DIRS)")]
        dirs: Option<String>,

        #[arg(short, long, help = "Work directory (default ~/.retrodev/decomp_work/)")]
        work_dir: Option<PathBuf>,

        #[arg(long, help = "Enable Ghidra headless export (requires Ghidra installed)")]
        ghidra: bool,

        #[arg(long, help = "Max directory scan depth")]
        max_depth: Option<usize>,
    },
    Status {
        #[arg(short, long)]
        work_dir: Option<PathBuf>,
    },
    Diff {
        #[arg(help = "ROM to analyze")]
        rom: String,

        #[arg(help = "Reference binary (known clean recompile)")]
        reference: String,

        #[arg(short, long)]
        work_dir: Option<PathBuf>,
    },
    Triage {
        #[arg(short, long)]
        work_dir: Option<PathBuf>,
    },
    Fprint {
        #[arg(help = "ROM file to fingerprint")]
        rom: String,
    },
    Metrics {
        #[arg(short, long)]
        work_dir: Option<PathBuf>,
    },
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Command::Scan {
            dirs,
            work_dir,
            ghidra,
            max_depth,
        } => cmd_scan(dirs, work_dir, ghidra, max_depth),
        Command::Status { work_dir } => cmd_status(work_dir),
        Command::Diff {
            rom,
            reference,
            work_dir,
        } => cmd_diff(&rom, &reference, work_dir),
        Command::Triage { work_dir } => cmd_triage(work_dir),
        Command::Fprint { rom } => cmd_fprint(&rom),
        Command::Metrics { work_dir } => cmd_metrics(work_dir),
    }
}

fn build_config(
    dirs: Option<String>,
    work_dir: Option<PathBuf>,
    ghidra: bool,
    max_depth: Option<usize>,
) -> ScanConfig {
    let mut config = ScanConfig::default();

    if let Some(d) = dirs {
        config.rom_dirs = d.split(':').filter(|s| !s.is_empty()).map(PathBuf::from).collect();
    }

    if let Some(w) = work_dir {
        config.work_dir = w;
    }

    config.ghidra_enabled = ghidra;

    if let Some(d) = max_depth {
        config.max_depth = d;
    }

    config
}

fn cmd_scan(dirs: Option<String>, work_dir: Option<PathBuf>, ghidra: bool, max_depth: Option<usize>) {
    let config = build_config(dirs, work_dir, ghidra, max_depth);
    let pipeline = DecompPipeline::with_config(config);

    match pipeline.scan() {
        Ok((roms, metrics)) => {
            println!("Scan complete.");
            println!("  ROMs found: {}", roms.len());
            println!("  One-shot rate: {:.2}%", metrics.one_shot_rate * 100.0);
            println!("  Avg cost/function: {:.2}ms", metrics.avg_cost_per_function);
            println!("  Runtime match rate: {:.2}%", metrics.runtime_match_rate * 100.0);
            println!("  Node coverage: {:.2}%", metrics.node_coverage * 100.0);

            for rom in &roms {
                println!(
                    "  [{}] {} ({})",
                    rom.tier, rom.filename, rom.hashes.crc32
                );
            }
        }
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

fn cmd_status(work_dir: Option<PathBuf>) {
    let mut config = ScanConfig::default();
    if let Some(w) = work_dir {
        config.work_dir = w;
    }
    let pipeline = DecompPipeline::with_config(config);

    match pipeline.status() {
        Ok((count, metrics)) => {
            println!("Decomp work dir: {:?}", pipeline.config.work_dir);
            println!("ROMs in ledger: {}", count);
            if let Some(m) = metrics {
                println!();
                println!("Metrics:");
                println!("  one_shot_rate: {:.2}%", m.one_shot_rate * 100.0);
                println!("  avg_cost_per_function: {:.2}ms", m.avg_cost_per_function);
                println!("  runtime_match_rate: {:.2}%", m.runtime_match_rate * 100.0);
                println!("  node_coverage: {:.2}%", m.node_coverage * 100.0);
                println!("  total_functions: {}", m.total_functions);
                println!("  exact_matches: {}", m.exact_matches);
                println!("  functional_matches: {}", m.functional_matches);
                println!("  unmatched_functions: {}", m.unmatched_functions);
            } else {
                println!("No metrics yet. Run `scan` first.");
            }
        }
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

fn cmd_diff(rom: &str, reference: &str, work_dir: Option<PathBuf>) {
    let mut config = ScanConfig::default();
    if let Some(w) = work_dir {
        config.work_dir = w;
    }
    let pipeline = DecompPipeline::with_config(config);

    match pipeline.diff_rom(rom, reference) {
        Ok(matches) => {
            let exact = matches.iter().filter(|m| matches!(m.status, rds_decomp::types::MatchStatus::Exact)).count();
            let functional = matches.iter().filter(|m| matches!(m.status, rds_decomp::types::MatchStatus::Functional)).count();
            let partial = matches.iter().filter(|m| matches!(m.status, rds_decomp::types::MatchStatus::Partial)).count();
            let unmatched = matches.iter().filter(|m| matches!(m.status, rds_decomp::types::MatchStatus::Unmatched)).count();

            println!("Diff complete: {} functions", matches.len());
            println!("  Exact:      {}", exact);
            println!("  Functional: {}", functional);
            println!("  Partial:    {}", partial);
            println!("  Unmatched:  {}", unmatched);

            for m in &matches {
                if !matches!(m.status, rds_decomp::types::MatchStatus::Unmatched) {
                    println!(
                        "  [{:?}] {} @ 0x{:08X} (sim: {:.2}%)",
                        m.status, m.name, m.address, m.similarity * 100.0
                    );
                }
            }
        }
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

fn cmd_triage(work_dir: Option<PathBuf>) {
    let mut config = ScanConfig::default();
    if let Some(w) = work_dir {
        config.work_dir = w;
    }
    let counts = rds_decomp::triage::triage(&config);

    println!("Tier distribution:");
    for (tier, count) in &counts {
        println!("  {}: {}", tier, count);
    }
}

fn cmd_fprint(rom: &str) {
    let data = match std::fs::read(rom) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("Error reading {}: {}", rom, e);
            std::process::exit(1);
        }
    };

    let filename = std::path::Path::new(rom)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| rom.to_string());

    let fp = rds_decomp::fingerprint::fingerprint_rom(&data, &filename);

    println!("SGDK Fingerprint for {}", filename);
    println!("  Detected:    {}", fp.detected);
    println!("  Confidence:  {:.2}%", fp.confidence * 100.0);
    println!("  Signature:   {:?}", fp.sig_version);
    println!("  CRT patterns:");
    for p in &fp.crt_patterns_found {
        println!("    - {}", p);
    }
    println!("  Lib calls:");
    for c in &fp.lib_calls_found {
        println!("    - {}", c);
    }
}

fn cmd_metrics(work_dir: Option<PathBuf>) {
    let mut config = ScanConfig::default();
    if let Some(w) = work_dir {
        config.work_dir = w;
    }

    match rds_decomp::metrics::load_metrics(&config) {
        Some(m) => {
            println!("Metrics snapshot:");
            println!("  one_shot_rate: {:.2}%", m.one_shot_rate * 100.0);
            println!("  avg_cost_per_function: {:.2}ms", m.avg_cost_per_function);
            println!("  runtime_match_rate: {:.2}%", m.runtime_match_rate * 100.0);
            println!("  node_coverage: {:.2}%", m.node_coverage * 100.0);
            println!("  total_functions: {}", m.total_functions);
            println!("  exact_matches: {}", m.exact_matches);
            println!("  functional_matches: {}", m.functional_matches);
            println!("  unmatched_functions: {}", m.unmatched_functions);
            println!("  total_cost_ms: {}", m.total_cost_ms);
            println!("  total_nodes: {}", m.total_nodes);
            println!("  covered_nodes: {}", m.covered_nodes);
        }
        None => {
            println!("No metrics found at {:?}", config.work_dir.join("metrics.json"));
            println!("Run `rds-decomp scan` first.");
        }
    }
}
