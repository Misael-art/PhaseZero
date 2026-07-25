use std::fs;
use std::io::Read;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::sync::atomic::AtomicUsize;

use sha1::Digest as Sha1Digest;
use walkdir::WalkDir;

use super::types::{RomEntry, RomHashes, ScanConfig};

const ROM_EXTS: &[&str] = &["bin", "md", "smd", "gen", "sgd"];
const MAX_ROM_BYTES: u64 = 8 * 1024 * 1024;

pub struct ScanResult {
    pub entries: Vec<RomEntry>,
    pub skipped: usize,
    pub errors: Vec<String>,
    pub dirs_scanned: Vec<String>,
}

fn compute_hashes(data: &[u8]) -> RomHashes {
    let crc32 = crc32fast::hash(data);
    let md5 = md5_compute(data);
    let sha1 = sha1_compute(data);

    RomHashes {
        crc32: format!("{:08x}", crc32),
        md5,
        sha1,
    }
}

fn md5_compute(data: &[u8]) -> String {
    let hash = md5::Md5::digest(data);
    format!("{:x}", hash)
}

fn sha1_compute(data: &[u8]) -> String {
    let hash = sha1::Sha1::digest(data);
    format!("{:x}", hash)
}

fn read_rom_bytes(path: &Path) -> Result<Vec<u8>, String> {
    let mut f = fs::File::open(path).map_err(|e| format!("open {}: {}", path.display(), e))?;
    let mut buf = Vec::with_capacity(MAX_ROM_BYTES as usize);
    f.read_to_end(&mut buf)
        .map_err(|e| format!("read {}: {}", path.display(), e))?;
    Ok(buf)
}

fn is_rom_file(entry: &walkdir::DirEntry) -> bool {
    if !entry.file_type().is_file() {
        return false;
    }
    let name = entry.file_name().to_string_lossy().to_lowercase();
    ROM_EXTS.iter().any(|ext| name.ends_with(&format!(".{}", ext)) || name.ends_with(&format!(".{}", ext.to_uppercase())))
}

fn scan_rom_file(path: &Path) -> Result<RomEntry, String> {
    let data = read_rom_bytes(path)?;
    let hashes = compute_hashes(&data);
    Ok(RomEntry::new(path, hashes, false))
}

fn scan_zip_file(path: &Path, config: &ScanConfig, progress: Arc<AtomicUsize>) -> Result<Vec<RomEntry>, String> {
    let f = fs::File::open(path).map_err(|e| format!("open zip {}: {}", path.display(), e))?;
    let mut archive = zip::ZipArchive::new(f)
        .map_err(|e| format!("read zip {}: {}", path.display(), e))?;

    let extract_dir = config.work_dir.join("extracted");
    fs::create_dir_all(&extract_dir)
        .map_err(|e| format!("create extract dir: {}", e))?;

    let mut entries = Vec::new();

    for i in 0..archive.len() {
        let mut file = archive
            .by_index(i)
            .map_err(|e| format!("zip entry {} in {}: {}", i, path.display(), e))?;

        let name = file.name().to_lowercase();
        let is_rom = ROM_EXTS.iter().any(|ext| name.ends_with(&format!(".{}", ext)));
        if !is_rom || file.is_dir() {
            continue;
        }

        let mut data = Vec::new();
        file.read_to_end(&mut data)
            .map_err(|e| format!("read zip entry {} in {}: {}", i, path.display(), e))?;

        let file_stem = Path::new(file.name())
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("rom_{}", i));

        let zip_stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "unknown".to_string());

        let extract_name = format!("{}_{}.bin", zip_stem, file_stem);
        let extract_path = extract_dir.join(&extract_name);

        fs::write(&extract_path, &data)
            .map_err(|e| format!("extract {}: {}", extract_name, e))?;

        let hashes = compute_hashes(&data);
        let mut entry = RomEntry::new(&extract_path, hashes, true);
        entry.size = data.len() as u64;
        entries.push(entry);
        progress.fetch_add(1, Ordering::Relaxed);
    }

    Ok(entries)
}

pub fn scan(config: &ScanConfig) -> ScanResult {
    let mut entries = Vec::new();
    let mut skipped = 0;
    let mut errors = Vec::new();
    let mut dirs_scanned = Vec::new();

    for dir in &config.rom_dirs {
        if !dir.exists() {
            errors.push(format!("Directory not found: {}", dir.display()));
            continue;
        }
        dirs_scanned.push(dir.to_string_lossy().to_string());

        let walker = WalkDir::new(dir).max_depth(config.max_depth);
        for result in walker {
            let entry = match result {
                Ok(e) => e,
                Err(e) => {
                    errors.push(format!("walk error: {}", e));
                    continue;
                }
            };

            if entry.file_type().is_dir() {
                continue;
            }

            let path = entry.path();
            let ext = path
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();

            if ext == "zip" && !config.skip_compressed {
                match scan_zip_file(path, config, Arc::new(AtomicUsize::new(0))) {
                    Ok(mut zip_entries) => entries.append(&mut zip_entries),
                    Err(e) => {
                        errors.push(format!("{}", e));
                        skipped += 1;
                    }
                }
            } else if is_rom_file(&entry) {
                if entry.metadata().map(|m| m.len()).unwrap_or(0) > MAX_ROM_BYTES {
                    errors.push(format!(
                        "Skipped oversized: {} (>{})",
                        path.display(),
                        MAX_ROM_BYTES
                    ));
                    skipped += 1;
                    continue;
                }
                match scan_rom_file(path) {
                    Ok(rom) => entries.push(rom),
                    Err(e) => {
                        errors.push(format!("{}", e));
                        skipped += 1;
                    }
                }
            }
        }
    }

    ScanResult {
        entries,
        skipped,
        errors,
        dirs_scanned,
    }
}
