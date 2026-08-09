// Shape of the agent's state document (agent/shield-agent -> latest.json) and
// the desktop's own types. All fields optional — a collector may be absent.

export interface Server {
	name: string;
	host: string;
	user: string;
	port: number;
}

export interface PortEntry {
	proto: string;
	address: string;
	port: number | string;
	process?: string;
	public: boolean;
}

export interface WebshellFinding {
	file: string;
	score: number;
	level: string;
	signals: string[];
}

export interface VulnEntry {
	package: string;
	installed: string;
	fixed: string;
	candidate?: string;
	status?: 'fix_available' | 'fix_pending';
	cves?: string[];
	cve_count?: number;
	binaries?: string[];
}

export interface ShieldState {
	meta?: { agent_version?: string; collected_at?: string; host?: string };
	system?: {
		hostname?: string;
		os?: string;
		kernel?: string;
		arch?: string;
		load1?: number;
		mem_used_pct?: number;
		uptime_s?: number;
		disk_root_pct?: number;
	};
	ports?: PortEntry[];
	ports_public_count?: number;
	updates?: { total: number; security: number; source: string };
	services?: {
		running_count?: number;
		enabled_count?: number;
		failed_count?: number;
		failed?: string[];
	};
	lynis?: { installed?: boolean; hardening_index?: number | null; last_run?: string };
	drift?: {
		baseline_created?: boolean;
		added?: string[];
		removed?: string[];
		added_count?: number;
		removed_count?: number;
	};
	webshell?: {
		scanned?: number;
		finding_count?: number;
		high_count?: number;
		findings?: WebshellFinding[];
	};
	threat_intel?: { feed_present?: boolean; match_count?: number; matches?: { ip: string }[] };
	vulns?: {
		feed_present?: boolean;
		checked?: number;
		vulnerable_count?: number;
		cve_count?: number;
		fix_available_count?: number;
		fix_pending_count?: number;
		vulnerable?: VulnEntry[];
	};
	file_events?: {
		watching?: boolean;
		total?: number;
		webshell_suspect?: number;
		persistence?: number;
		recent?: { ts: string; type: string; path: string; event: string }[];
	};
}

export type ActionName =
	| 'apply-security-updates.sh'
	| 'rebaseline-drift.sh'
	| 'run-webshell-scan.sh'
	| 'run-lynis-audit.sh';
