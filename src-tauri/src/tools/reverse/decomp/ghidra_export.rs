use std::process::Command;

use super::types::GhidraMetadata;

const GHIDRA_HEADLESS: &str = "ghidraHeadless";

fn find_ghidra() -> Option<String> {
    if let Some(path) = which(GHIDRA_HEADLESS) {
        return Some(path);
    }

    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = vec![
        format!("{}/ghidra/support/analyzeHeadless", home),
        format!("/opt/ghidra/support/analyzeHeadless"),
        format!("/usr/local/ghidra/support/analyzeHeadless"),
    ];

    for candidate in &candidates {
        if std::path::Path::new(candidate).exists() {
            return Some(candidate.clone());
        }
    }

    glob()
}

fn which(name: &str) -> Option<String> {
    let path_var = std::env::var("PATH").unwrap_or_default();
    for dir in path_var.split(':') {
        let full = format!("{}/{}", dir, name);
        if std::path::Path::new(&full).exists() || std::path::Path::new(&format!("{}.exe", full)).exists() {
            return Some(full);
        }
    }
    None
}

fn glob() -> Option<String> {
    if let Ok(entries) = std::fs::read_dir("/opt") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("ghidra") {
                let analyze = entry.path().join("support").join("analyzeHeadless");
                if analyze.exists() {
                    return Some(analyze.to_string_lossy().to_string());
                }
            }
        }
    }
    if let Ok(entries) = std::fs::read_dir("/usr/local") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("ghidra") {
                let analyze = entry.path().join("support").join("analyzeHeadless");
                if analyze.exists() {
                    return Some(analyze.to_string_lossy().to_string());
                }
            }
        }
    }
    None
}

pub fn try_export(
    rom_path: &str,
    work_dir: &std::path::Path,
) -> GhidraMetadata {
    let ghidra_path = match find_ghidra() {
        Some(p) => p,
        None => {
            return GhidraMetadata {
                exported: false,
                export_path: None,
                functions_count: None,
                decompiled_bytes: None,
                error: Some("Ghidra not installed or not in PATH".to_string()),
            };
        }
    };

    let rom_stem = std::path::Path::new(rom_path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "rom".to_string());

    let project_dir = work_dir.join("ghidra_projects");
    let export_dir = work_dir.join("ghidra_exports").join(&rom_stem);

    std::fs::create_dir_all(&project_dir).ok();
    std::fs::create_dir_all(&export_dir).ok();

    let project_name = format!("rds_{}", rom_stem.replace('-', "_").replace('.', "_"));

    let output = Command::new(&ghidra_path)
        .arg(project_dir.to_string_lossy().to_string())
        .arg(&project_name)
        .arg("-import")
        .arg(rom_path)
        .arg("-postScript")
        .arg("ExportProgram.java")
        .arg(export_dir.to_string_lossy().to_string())
        .arg("-analysisTimeoutPerFile")
        .arg("120")
        .arg("-deleteProject")
        .output();

    match output {
        Ok(out) => {
            let _stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();

            if out.status.success() {
                let func_count = count_exported_functions(&export_dir);
                let decompiled_bytes = estimate_export_size(&export_dir);

                GhidraMetadata {
                    exported: true,
                    export_path: Some(export_dir.to_string_lossy().to_string()),
                    functions_count: func_count,
                    decompiled_bytes,
                    error: None,
                }
            } else {
                GhidraMetadata {
                    exported: false,
                    export_path: None,
                    functions_count: None,
                    decompiled_bytes: None,
                    error: Some(format!("Ghidra export failed: {}", stderr)),
                }
            }
        }
        Err(e) => GhidraMetadata {
            exported: false,
            export_path: None,
            functions_count: None,
            decompiled_bytes: None,
            error: Some(format!("Ghidra launch failed: {}", e)),
        },
    }
}

fn count_exported_functions(dir: &std::path::Path) -> Option<usize> {
    let count = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .filter(|e| {
                    e.file_type().map(|t| t.is_file()).unwrap_or(false)
                })
                .count()
        })
        .ok()?;

    if count > 0 {
        Some(count)
    } else {
        None
    }
}

fn estimate_export_size(dir: &std::path::Path) -> Option<u64> {
    let total: u64 = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .filter_map(|e| e.metadata().ok())
                .map(|m| m.len())
                .sum()
        })
        .ok()?;

    if total > 0 {
        Some(total)
    } else {
        None
    }
}

pub fn ghidra_available() -> bool {
    find_ghidra().is_some()
}
