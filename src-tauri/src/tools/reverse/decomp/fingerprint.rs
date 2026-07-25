use super::types::{SgdkFingerprint, Tier};

const SGDK_LIB_CALLS: &[&[u8]] = &[
    &[0x4E, 0xB9, 0x00, 0x00, 0x00, 0x00], // JSR absolute
    &[0x4E, 0x75], // RTS
    &[0x4E, 0x56], // LINK
    &[0x4E, 0x5E], // UNLK
];

const SGDK_RESET_VECTOR_ADDR: usize = 0x004;
const SGDK_HEADER_OFFSET: usize = 0x100;
const SGDK_CRT_START: usize = 0x200;

fn scan_pattern(data: &[u8], pattern: &[u8], offset: usize) -> Vec<usize> {
    let mut matches = Vec::new();
    if pattern.is_empty() || offset >= data.len() {
        return matches;
    }

    let search_start = offset.min(data.len().saturating_sub(pattern.len()));
    let search_end = data.len().saturating_sub(pattern.len());

    for i in (search_start..=search_end).step_by(2) {
        if i + pattern.len() > data.len() {
            break;
        }
        if &data[i..i + pattern.len()] == pattern {
            matches.push(i);
        }
    }
    matches
}

fn has_relaxed_pattern(data: &[u8], pattern: &[u8], range_start: usize, range_end: usize) -> bool {
    if range_end > data.len() || range_start >= range_end {
        return false;
    }
    for i in (range_start..range_end).step_by(2) {
        if i + pattern.len() > data.len() {
            break;
        }
        if &data[i..i + pattern.len()] == pattern {
            return true;
        }
    }
    false
}

fn detect_sgdk_crt(data: &[u8]) -> (Vec<String>, f64) {
    let mut patterns_found = Vec::new();
    let mut confidence: f64 = 0.0;

    let reset_vec = u32::from_be_bytes(
        data.get(SGDK_RESET_VECTOR_ADDR..SGDK_RESET_VECTOR_ADDR + 4)
            .map(|b| [b[0], b[1], b[2], b[3]])
            .unwrap_or([0; 4]),
    );

    let reset_addr = reset_vec as usize;

    if reset_addr >= SGDK_CRT_START && reset_addr < data.len() {
        patterns_found.push(format!("reset-vector=0x{:08X}", reset_vec));
        confidence += 0.2;

        if data.len() > SGDK_HEADER_OFFSET {
            let header_end = SGDK_HEADER_OFFSET + 0x100;
            if header_end <= data.len() {
                confidence += 0.1;
            }
        }

        let crt_region = if reset_addr + 0x200 <= data.len() {
            &data[reset_addr..reset_addr + 0x200]
        } else {
            &data[reset_addr..]
        };

        if has_relaxed_pattern(crt_region, &[0x4E, 0x71], 0, crt_region.len()) {
            patterns_found.push("nop-padding".to_string());
            confidence += 0.1;
        }

        if crt_region.len() > 4 {
            let first_word = u16::from_be_bytes(
                [crt_region[0], crt_region[1]]
            );
            if first_word == 0x4EF9 || first_word == 0x4EB9 || first_word == 0x4E75 {
                patterns_found.push(format!("crt-entry-jmp=0x{:04X}", first_word));
                confidence += 0.1;
            }
        }
    }

    if confidence > 0.0 {
        if has_relaxed_pattern(data, &[0x00, 0x00, 0xBF, 0xFF], 0, 0x400) {
            patterns_found.push("stack-ptr-0xBFFF".to_string());
            confidence += 0.15;
        }
    }

    (patterns_found, confidence.min(1.0))
}

fn detect_sgdk_lib_calls(data: &[u8]) -> Vec<String> {
    let mut calls = Vec::new();
    let search_start = 0x200;

    for pattern in SGDK_LIB_CALLS {
        let matches = scan_pattern(data, pattern, search_start);
        if !matches.is_empty() {
            calls.push(format!("lib-call x{}", matches.len()));
        }
    }

    calls
}

pub fn fingerprint_rom(data: &[u8], filename: &str) -> SgdkFingerprint {
    let (crt_patterns, base_conf) = detect_sgdk_crt(data);
    let lib_calls = detect_sgdk_lib_calls(data);

    let mut confidence = base_conf;

    if !lib_calls.is_empty() {
        confidence += 0.15;
    }

    let lower_name = filename.to_lowercase();
    if lower_name.contains("sgdk") || lower_name.contains("rocketpanda") {
        confidence += 0.2;
    }

    let detected = confidence >= 0.3;

    SgdkFingerprint {
        detected,
        confidence: confidence.min(1.0),
        sig_version: if detected { Some("sgdk-crt-v1".to_string()) } else { None },
        crt_patterns_found: crt_patterns,
        lib_calls_found: lib_calls,
        heap_location: None,
        stack_location: Some(0x00BFFF00),
    }
}

pub fn tier_from_fingerprint(fp: &SgdkFingerprint, filename: &str, is_commercial: bool) -> Tier {
    if is_commercial {
        return Tier::Commercial;
    }
    let lower = filename.to_lowercase();
    if lower.contains("sgdk") || lower.contains("clean") || lower.contains("recompile") {
        if fp.detected && fp.confidence >= 0.8 {
            return Tier::MatchExact;
        }
        return Tier::MatchFunctional;
    }
    if fp.detected && fp.confidence >= 0.7 {
        return Tier::MatchExact;
    }
    if fp.detected && fp.confidence >= 0.4 {
        return Tier::MatchFunctional;
    }
    if fp.confidence >= 0.2 {
        return Tier::Bridge;
    }
    Tier::Nodes
}
