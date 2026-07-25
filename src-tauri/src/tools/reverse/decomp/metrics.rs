use super::types::{
    FunctionMatch, Ledger, MatchStatus, MetricsSnapshot, ScanConfig,
};

pub struct MetricsCollector {
    total_functions: usize,
    exact_matches: usize,
    functional_matches: usize,
    unmatched_functions: usize,
    total_cost_ms: u64,
    total_nodes: usize,
    covered_nodes: usize,
}

impl MetricsCollector {
    pub fn new() -> Self {
        MetricsCollector {
            total_functions: 0,
            exact_matches: 0,
            functional_matches: 0,
            unmatched_functions: 0,
            total_cost_ms: 0,
            total_nodes: 0,
            covered_nodes: 0,
        }
    }

    pub fn record_cost(&mut self, cost_ms: u64) {
        self.total_cost_ms += cost_ms;
    }

    pub fn record_match(&mut self, m: &FunctionMatch) {
        self.total_functions += 1;
        match m.status {
            MatchStatus::Exact => self.exact_matches += 1,
            MatchStatus::Functional => self.functional_matches += 1,
            MatchStatus::Partial => {
                self.functional_matches += 1;
            }
            MatchStatus::Unmatched => self.unmatched_functions += 1,
        }
    }

    pub fn record_node_coverage(&mut self, covered: usize, total: usize) {
        self.total_nodes = total;
        self.covered_nodes = covered;
    }

    pub fn one_shot_rate(&self) -> f64 {
        if self.total_functions == 0 {
            return 1.0;
        }
        (self.exact_matches + self.functional_matches) as f64 / self.total_functions as f64
    }

    pub fn avg_cost_per_function(&self) -> f64 {
        if self.total_functions == 0 {
            return 0.0;
        }
        self.total_cost_ms as f64 / self.total_functions as f64
    }

    pub fn runtime_match_rate(&self) -> f64 {
        if self.total_functions == 0 {
            return 1.0;
        }
        (self.exact_matches + self.functional_matches) as f64 / self.total_functions as f64
    }

    pub fn node_coverage(&self) -> f64 {
        if self.total_nodes == 0 {
            return 1.0;
        }
        self.covered_nodes as f64 / self.total_nodes as f64
    }

    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            one_shot_rate: self.one_shot_rate(),
            avg_cost_per_function: self.avg_cost_per_function(),
            runtime_match_rate: self.runtime_match_rate(),
            node_coverage: self.node_coverage(),
            total_functions: self.total_functions,
            exact_matches: self.exact_matches,
            functional_matches: self.functional_matches,
            unmatched_functions: self.unmatched_functions,
            total_cost_ms: self.total_cost_ms,
            total_nodes: self.total_nodes,
            covered_nodes: self.covered_nodes,
        }
    }
}

pub fn compute_ledger_metrics(ledger: &Ledger) -> MetricsSnapshot {
    let mut collector = MetricsCollector::new();

    for rom in &ledger.roms {
        for m in &rom.function_matches {
            collector.record_match(m);
        }

        if let Some(ref ghidra) = rom.ghidra {
            if let Some(func_count) = ghidra.functions_count {
                let covered = rom
                    .function_matches
                    .iter()
                    .filter(|m| !matches!(m.status, MatchStatus::Unmatched))
                    .count();
                collector.record_node_coverage(covered, func_count);
            }
        }
    }

    collector.snapshot()
}

pub fn save_metrics_report(config: &ScanConfig, snapshot: &MetricsSnapshot) -> Result<(), String> {
    let path = config.work_dir.join("metrics.json");
    let json = serde_json::to_string_pretty(snapshot)
        .map_err(|e| format!("serialize metrics: {}", e))?;
    std::fs::write(&path, &json)
        .map_err(|e| format!("write metrics: {}", e))?;
    Ok(())
}

pub fn load_metrics(config: &ScanConfig) -> Option<MetricsSnapshot> {
    let path = config.work_dir.join("metrics.json");
    if !path.exists() {
        return None;
    }
    let data = std::fs::read_to_string(&path).ok()?;
    serde_json::from_str(&data).ok()
}
