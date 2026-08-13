<script lang="ts">
	import { onMount } from 'svelte';
	import {
		listServers,
		addServer,
		removeServer,
		fetchState,
		runAction,
		acknowledgeDrift
	} from '$lib/api';
	import type { Server, ShieldState, ActionName, DriftItem } from '$lib/types';

	let servers = $state<Server[]>([]);
	let selected = $state<string | null>(null);
	let snap = $state<ShieldState | null>(null);
	let error = $state<string | null>(null);
	let inFlight = false;

	let showAdd = $state(false);
	let form = $state<Server>({ name: '', host: '', user: '', port: 22 });
	let addError = $state<string | null>(null);

	// confirm modal for heavier actions (preview -> apply)
	let pending = $state<{ action: ActionName; label: string; preview: unknown } | null>(null);
	let actionBusy = $state(false);
	let actionResult = $state<string | null>(null);
	let modalError = $state<string | null>(null);
	let busyFp = $state<string | null>(null); // drift item currently being acknowledged

	onMount(loadServers);

	async function loadServers() {
		try {
			servers = await listServers();
		} catch (e) {
			error = String(e);
		}
	}

	async function select(name: string) {
		if (inFlight) return;
		inFlight = true;
		selected = name;
		snap = null;
		error = null;
		actionResult = null;
		try {
			snap = await fetchState(name);
		} catch (e) {
			error = String(e);
		} finally {
			inFlight = false;
		}
	}

	async function submitAdd(e: Event) {
		e.preventDefault();
		addError = null;
		try {
			servers = await addServer({ ...form, port: Number(form.port) || 22 });
			showAdd = false;
			form = { name: '', host: '', user: '', port: 22 };
		} catch (err) {
			addError = String(err);
		}
	}

	async function remove(name: string) {
		servers = await removeServer(name);
		if (selected === name) {
			selected = null;
			snap = null;
		}
	}

	// ---- helpers -----------------------------------------------------------
	function ageMin(iso?: string): number | null {
		if (!iso) return null;
		const t = Date.parse(iso);
		if (Number.isNaN(t)) return null;
		return Math.max(0, Math.round((Date.now() - t) / 60000));
	}
	function freshText(m: number | null): string {
		if (m === null) return 'unknown';
		if (m < 1) return 'just now';
		if (m < 60) return `${m} min ago`;
		const h = Math.round(m / 60);
		if (h < 48) return `${h} h ago`;
		return `${Math.round(h / 24)} d ago`;
	}
	function uptime(s?: number): string {
		if (!s) return '—';
		const d = Math.floor(s / 86400);
		const h = Math.floor((s % 86400) / 3600);
		return d > 0 ? `${d}d ${h}h` : `${h}h`;
	}

	// posture: one honest verdict + how many items need the user
	const posture = $derived.by(() => {
		const s = snap;
		if (!s) return { state: 'good', verdict: '', sub: '', count: 0 };
		const driftNew = (s.drift?.added_items ?? []).filter((d) => d.status === 'new').length;
		const flagged = s.drift?.flagged_count ?? 0;
		const lynisMissing = s.lynis?.installed === false ? 1 : 0;
		const webHigh = s.webshell?.high_count ?? 0;
		const fileHits = s.file_events?.webshell_suspect ?? 0;
		const failed = s.services?.failed_count ?? 0;
		const netHigh = (s.exposure?.risky ?? []).filter(
			(r) => r.reach === 'internet' && r.risk === 'high'
		).length;

		const critN = flagged + webHigh + netHigh + (fileHits > 0 ? 1 : 0);
		if (critN > 0)
			return {
				state: 'crit',
				verdict: 'Something needs your attention now',
				sub: 'A flagged change or a live threat signal is open. Handle the red items below first.',
				count: critN
			};
		const needs = driftNew + lynisMissing + (failed > 0 ? 1 : 0);
		if (needs === 0)
			return {
				state: 'good',
				verdict: 'Protected — nothing needs you',
				sub: 'Everything is checked, current, and confirmed. We’ll alert you the moment that changes.',
				count: 0
			};
		return {
			state: 'watch',
			verdict: needs === 1 ? 'One thing needs your review' : `${needs} things need your review`,
			sub: 'No sign of a break-in — but there are changes you haven’t confirmed yet. Review them and you’re done.',
			count: needs
		};
	});

	const fresh = $derived.by(() => {
		const m = ageMin(snap?.meta?.collected_at);
		const stale = m !== null && m > 20; // agent runs every 5 min; >20 → likely down
		return { m, stale, text: freshText(m) };
	});

	// plain-language for a drift item
	function driftTitle(d: DriftItem): string {
		switch (d.kind) {
			case 'authkey':
				return 'A new SSH login key was added';
			case 'cron':
			case 'usercron':
				return 'A new scheduled task (cron) appeared';
			case 'unit':
				return 'A new service now starts on boot';
			case 'suid':
				return 'A new privileged (SUID) program appeared';
			default:
				return 'A start-up / access change';
		}
	}

	// ---- drift acknowledge (direct, informed, reversible) ------------------
	async function ack(fp: string, verdict: 'mine' | 'suspicious') {
		if (!selected || busyFp) return;
		busyFp = fp;
		try {
			await acknowledgeDrift(selected, fp, verdict, true);
			await select(selected); // refresh so the item reflects its new state
		} catch (e) {
			error = String(e);
		} finally {
			busyFp = null;
		}
	}

	// ---- heavier confirmed actions (preview -> confirm -> apply) ------------
	const ACTIONS: { action: ActionName; label: string }[] = [
		{ action: 'apply-security-updates.sh', label: 'Install security updates' },
		{ action: 'run-webshell-scan.sh', label: 'Scan for web shells now' },
		{ action: 'run-lynis-audit.sh', label: 'Run hardening audit' }
	];
	async function openAction(action: ActionName, label: string) {
		modalError = null;
		actionResult = null;
		try {
			const preview = await runAction(selected!, action, false);
			pending = { action, label, preview };
		} catch (e) {
			modalError = String(e);
			pending = { action, label, preview: null };
		}
	}
	function closeModal() {
		pending = null;
		actionBusy = false;
		modalError = null;
	}
	async function confirmAction() {
		if (!pending || !selected) return;
		actionBusy = true;
		modalError = null;
		try {
			const res = (await runAction(selected, pending.action, true)) as Record<string, unknown>;
			actionResult = `${pending.label}: ${res.note ?? 'done'}`;
			pending = null;
			await select(selected);
		} catch (e) {
			modalError = String(e);
		} finally {
			actionBusy = false;
		}
	}
</script>

{#snippet tick()}
	<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M5 12.5l4.2 4.2L19 7" /></svg>
{/snippet}

<div class="app">
	<aside class="rail">
		<div class="brandrow">
			<svg width="19" height="19" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"
				><path d="M12 2l8 3v6c0 5-3.4 8.5-8 11-4.6-2.5-8-6-8-11V5l8-3z" /></svg
			>
			Public Shield
		</div>
		<button class="addbtn" onclick={() => (showAdd = !showAdd)}>+ Add server</button>

		{#if showAdd}
			<form class="add-form" onsubmit={submitAdd}>
				<input placeholder="name" bind:value={form.name} required />
				<input placeholder="host / IP" bind:value={form.host} required />
				<input placeholder="ssh user" bind:value={form.user} required />
				<input type="number" placeholder="port" bind:value={form.port} />
				<button type="submit">Save</button>
				{#if addError}<p class="err">{addError}</p>{/if}
			</form>
		{/if}

		<ul class="fleet">
			{#each servers as s (s.name)}
				<li class:active={selected === s.name}>
					<button class="server" onclick={() => select(s.name)}>
						<span class="nm">{s.name}</span>
						<span class="ad mono">{s.user}@{s.host}</span>
					</button>
					<button class="rm" aria-label="Remove {s.name}" onclick={() => remove(s.name)}>×</button>
				</li>
			{:else}
				<li class="empty">No servers yet.</li>
			{/each}
		</ul>
	</aside>

	<main class="main">
		{#if !selected}
			<div class="placeholder">
				<h1>Select a server</h1>
				<p>Install the agent with <code>sudo bash install.sh</code>, then add it here.</p>
			</div>
		{:else}
			<div class="wrap">
				<!-- Topbar -->
				<div class="topbar">
					<div>
						<h1>{selected}</h1>
						{#if snap?.system}
							<div class="sub mono">
								{snap.system.os ?? ''} · {snap.system.arch ?? ''} · agent {snap.meta?.agent_version ??
									'?'}
							</div>
						{/if}
						{#if snap}
							<div class="freshness" class:stale={fresh.stale}>
								<span class="dot"></span>
								{#if fresh.stale}Agent may be down — no data for {fresh.text}{:else}Agent healthy ·
									checked {fresh.text}{/if}
							</div>
						{/if}
					</div>
					<button class="refresh" onclick={() => selected && select(selected)}>↻ Refresh</button>
				</div>

				{#if error}
					<div class="card errbox">
						<strong>Could not reach the agent.</strong>
						<pre>{error}</pre>
					</div>
				{/if}

				{#if snap && !error}
					<svelte:boundary>
					<!-- Posture banner -->
					<section class="posture" data-state={posture.state}>
						<svg class="shield" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
							<path d="M12 2.5l7.5 2.8v5.7c0 4.7-3.2 8-7.5 10.3C7.7 19 4.5 15.7 4.5 11V5.3L12 2.5z" fill="color-mix(in srgb, currentColor 12%, transparent)" />
							{#if posture.state === 'crit'}<path d="M9 9l6 6M15 9l-6 6" />{:else}<path d="M8.6 12.2l2.2 2.2 4.6-4.8" />{/if}
						</svg>
						<div>
							<div class="verdict">{posture.verdict}</div>
							<div class="vsub">{posture.sub}</div>
						</div>
						{#if posture.count > 0}
							<div class="count"><b>{posture.count}</b><span>need you</span></div>
						{:else}
							<div class="count ok"><b>✓</b><span>all clear</span></div>
						{/if}
					</section>

					<!-- NEEDS YOUR REVIEW -->
					{#if (snap.drift?.added_items?.length ?? 0) > 0 || snap.lynis?.installed === false}
						<section class="block">
							<div class="bh"><span class="eyebrow">Needs your review</span></div>

							{#each snap.drift?.added_items ?? [] as d (d.fp)}
								<div class="card finding" data-sev={d.status === 'flagged' ? 'crit' : 'watch'}>
									<div class="stripe"></div>
									<div class="fbody">
										<div class="ftitle">
											{driftTitle(d)}
											<span class="chip" data-sev={d.status === 'flagged' ? 'crit' : 'watch'}>
												{d.status === 'flagged' ? 'you flagged this' : 'new'}
											</span>
										</div>
										<div class="fwhy">
											New scheduled tasks, services, or SSH keys are how an intruder stays in after a
											break-in. Confirm this is something <b>you</b> did — nothing is silenced until you do.
										</div>
										<div class="ftarget mono">{d.target}</div>
									</div>
									<div class="faside">
										{#if busyFp === d.fp}
											<span class="chip">saving…</span>
										{:else}
											<button class="btn primary" onclick={() => ack(d.fp, 'mine')}>Yes, that’s me</button>
											<button class="btn danger" onclick={() => ack(d.fp, 'suspicious')}>I didn’t do this</button>
										{/if}
									</div>
								</div>
							{/each}

							{#if snap.lynis?.installed === false}
								<div class="card finding" data-sev="none">
									<div class="stripe"></div>
									<div class="fbody">
										<div class="ftitle">Hardening audit isn’t set up <span class="chip" data-sev="none">not measured</span></div>
										<div class="fwhy">
											Lynis checks 200+ hardening settings and gives a score. It isn’t installed, so this
											is a blind spot — not a problem we found, just one we can’t see yet.
										</div>
									</div>
									<div class="faside">
										<button class="btn primary" onclick={() => openAction('run-lynis-audit.sh', 'Set up hardening audit')}>Set up now</button>
									</div>
								</div>
							{/if}
						</section>
					{/if}

					<!-- GOOD TO KNOW: vulnerabilities -->
					{#if (snap.vulns?.vulnerable_count ?? 0) > 0}
						<section class="block">
							<div class="bh"><span class="eyebrow">Good to know</span><span class="hint">tracked — nothing to do unless a fix is available</span></div>
							{#each snap.vulns?.vulnerable ?? [] as v (v.package)}
								<div class="card finding" data-sev={v.status === 'fix_available' ? 'crit' : 'watch'}>
									<div class="stripe"></div>
									<div class="fbody">
										<div class="ftitle">
											<span class="mono">{v.package}</span> has {v.cve_count ?? v.cves?.length ?? 0} known {(v.cve_count ?? 1) === 1 ? 'vulnerability' : 'vulnerabilities'}
											<span class="chip" data-sev={v.status === 'fix_available' ? 'crit' : 'watch'}>
												{v.status === 'fix_available' ? 'update available' : 'fix pending'}
											</span>
										</div>
										<div class="fwhy">
											{#if v.status === 'fix_available'}
												A fix is in your repositories — installing updates clears it.
											{:else}
												The fix (<span class="mono">{v.fixed}</span>) isn’t in your repositories yet, so
												there’s nothing to install. We’ll alert you when it ships.
											{/if}
											<span class="mono faint"> installed {v.installed}{v.candidate ? ` · repo ${v.candidate}` : ''}</span>
										</div>
									</div>
									<div class="faside">
										{#if v.status === 'fix_available'}
											<button class="btn primary" onclick={() => openAction('apply-security-updates.sh', 'Install security updates')}>Fix now</button>
										{:else}
											<span class="chip">low priority</span>
										{/if}
									</div>
								</div>
							{/each}
						</section>
					{/if}

					<!-- EXPOSURE -->
					{#if snap.exposure}
						<section class="block">
							<div class="bh"><span class="eyebrow">Exposure</span><span class="hint">what the outside world can reach</span></div>
							<div class="card">
								<div class="exp-lead">
									<svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" class="exp-ic" data-ok={snap.exposure.host_exposure === 'nat'}>
										{#if snap.exposure.host_exposure === 'nat'}<path d="M8.6 12.2l2.2 2.2 4.6-4.8" /><circle cx="12" cy="12" r="9.2" />{:else}<path d="M12 9v4M12 16h.01" /><circle cx="12" cy="12" r="9.2" />{/if}
									</svg>
									<div>
										{#if snap.exposure.host_exposure === 'nat'}
											<b>You’re behind your router (NAT).</b> Nothing is directly reachable from the internet
											unless you’ve set up port-forwarding. Below is what other devices on your network can reach.
										{:else if snap.exposure.host_exposure === 'public'}
											<b>This host has a public IP — {snap.exposure.internet_reachable_count} service(s) are reachable from the internet.</b>
											Treat anything below as internet-facing.
										{:else}
											Exposure could not be determined.
										{/if}
									</div>
								</div>
								{#each snap.exposure.risky ?? [] as r, i (i)}
									<div class="portrow">
										<span class="mono">{r.process || 'service'} <span class="pport">:{r.port}</span></span>
										<span class="pdesc">{r.risk_note}</span>
										<span class="chip" data-sev={r.risk === 'high' ? 'crit' : 'watch'}>{r.reach === 'internet' ? 'internet' : 'LAN'} · {r.risk}</span>
									</div>
								{/each}
								{#if (snap.exposure.risky?.length ?? 0) === 0}
									<div class="portrow"><span class="pdesc">No risky services exposed. {snap.ports_public_count ?? 0} ports listen on all interfaces (routine local/DNS services).</span></div>
								{/if}
							</div>
						</section>
					{/if}

					<!-- ALL CLEAR -->
					<section class="block">
						<div class="bh"><span class="eyebrow">All clear</span><span class="hint">checked and healthy</span></div>
						<div class="clear-grid">
							<div class="clear-cell" data-ok={(snap.updates?.security ?? 0) === 0}>
								{@render tick()}
								<div><div class="t">{(snap.updates?.security ?? 0) === 0 ? 'Up to date' : `${snap.updates?.security} security updates`}</div><div class="d">{snap.updates?.total ?? 0} total pending</div></div>
							</div>
							<div class="clear-cell" data-ok={(snap.webshell?.finding_count ?? 0) === 0}>
								{@render tick()}
								<div><div class="t">{(snap.webshell?.finding_count ?? 0) === 0 ? 'No web shells' : `${snap.webshell?.finding_count} web-shell hits`}</div><div class="d">{snap.webshell?.scanned ?? 0} files scanned</div></div>
							</div>
							<div class="clear-cell" data-ok={(snap.threat_intel?.match_count ?? 0) === 0}>
								{@render tick()}
								<div><div class="t">{(snap.threat_intel?.match_count ?? 0) === 0 ? 'No calls to bad IPs' : `${snap.threat_intel?.match_count} bad-IP calls`}</div><div class="d">{snap.threat_intel?.feed_present ? 'feed current' : 'no feed'}</div></div>
							</div>
							<div class="clear-cell" data-ok={(snap.services?.failed_count ?? 0) === 0}>
								{@render tick()}
								<div><div class="t">{(snap.services?.failed_count ?? 0) === 0 ? 'All services running' : `${snap.services?.failed_count} failed services`}</div><div class="d">{snap.services?.running_count ?? 0} active</div></div>
							</div>
							<div class="clear-cell" data-ok={(snap.file_events?.webshell_suspect ?? 0) === 0}>
								{@render tick()}
								<div><div class="t">Real-time file watch {snap.file_events?.watching ? 'on' : 'off'}</div><div class="d">{snap.file_events?.webshell_suspect ?? 0} noteworthy events</div></div>
							</div>
						</div>
					</section>

					<!-- HEALTH -->
					{#if snap.system}
						<section class="block">
							<div class="bh"><span class="eyebrow">System health</span></div>
							<div class="health">
								<div class="stat"><div class="l">Disk /</div><div class="v mono">{snap.system.disk_root_pct ?? '—'}<small>%</small></div><div class="bar"><i style="width:{snap.system.disk_root_pct ?? 0}%; background:{(snap.system.disk_root_pct ?? 0) > 85 ? 'var(--crit)' : (snap.system.disk_root_pct ?? 0) > 70 ? 'var(--watch)' : 'var(--good)'}"></i></div></div>
								<div class="stat"><div class="l">Load (1m)</div><div class="v mono">{snap.system.load1 ?? '—'}</div></div>
								<div class="stat"><div class="l">Memory</div><div class="v mono">{snap.system.mem_used_pct ?? '—'}<small>%</small></div><div class="bar"><i style="width:{snap.system.mem_used_pct ?? 0}%"></i></div></div>
								<div class="stat"><div class="l">Uptime</div><div class="v mono">{uptime(snap.system.uptime_s)}</div></div>
							</div>
						</section>
					{/if}

					<!-- secondary actions -->
					<section class="block">
						<div class="bh"><span class="eyebrow">Run a check</span></div>
						<div class="actrow">
							{#each ACTIONS as a (a.action)}
								<button class="btn" disabled={actionBusy} onclick={() => openAction(a.action, a.label)}>{a.label}</button>
							{/each}
						</div>
						{#if actionResult}<p class="okmsg">{actionResult}</p>{/if}
					</section>

					{#snippet failed(err)}
						<div class="card errbox">
							<strong>Couldn’t render the dashboard from this server’s data.</strong>
							<pre>{err instanceof Error ? err.message : String(err)}</pre>
						</div>
					{/snippet}
					</svelte:boundary>
				{:else if !error}
					<p class="loading">Connecting over SSH…</p>
				{/if}
			</div>
		{/if}
	</main>
</div>

<!-- confirm modal for heavier actions -->
{#if pending}
	<div class="modal-backdrop" role="button" tabindex="-1" onclick={closeModal} onkeydown={(e) => e.key === 'Escape' && closeModal()}>
		<div class="modal" role="dialog" aria-modal="true" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
			<h2>{pending.label}</h2>
			{#if modalError}
				<div class="errbox"><pre>{modalError}</pre></div>
			{:else}
				<p class="muted">Preview — nothing has changed yet:</p>
				<pre class="preview">{JSON.stringify(pending.preview, null, 2)}</pre>
			{/if}
			<div class="modal-actions">
				<button class="btn" onclick={closeModal}>Cancel</button>
				<button class="btn primary" disabled={actionBusy || !!modalError} onclick={confirmAction}>
					{actionBusy ? 'Working…' : 'Confirm & apply'}
				</button>
			</div>
		</div>
	</div>
{/if}

<style>
	:root {
		--bg: #e9edf1; --surface: #fff; --surface-2: #f5f7f9;
		--ink: #141c24; --muted: #5a6672; --faint: #8b96a1; --line: #dbe1e7;
		--brand: #0e7c86;
		--good: #1a7f5a; --good-bg: #e4f3ec; --good-line: #bfe3d1;
		--watch: #9a6410; --watch-bg: #fbf0dc; --watch-line: #f0d9a8;
		--crit: #b5342a; --crit-bg: #fbe7e4; --crit-line: #f2c4bd;
		--none: #6a7783; --none-bg: #eef1f4; --none-line: #d7dde3;
		--shadow: 0 1px 2px rgba(20, 28, 36, 0.06), 0 6px 20px rgba(20, 28, 36, 0.05);
		--radius: 13px;
		--mono: ui-monospace, 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
	}
	:root:not([data-theme='light']) {
		@media (prefers-color-scheme: dark) {
			--bg: #0b0f14; --surface: #141b22; --surface-2: #1a222b;
			--ink: #e7eef4; --muted: #93a0ad; --faint: #6b7783; --line: #253039; --brand: #3bb3bd;
			--good: #52c493; --good-bg: #102c20; --good-line: #1f4d38;
			--watch: #e6b45c; --watch-bg: #2c2211; --watch-line: #4a3a1a;
			--crit: #f28b7f; --crit-bg: #301410; --crit-line: #5a2820;
			--none: #8b97a5; --none-bg: #1a222b; --none-line: #2b3641;
			--shadow: 0 1px 2px rgba(0, 0, 0, 0.3), 0 8px 24px rgba(0, 0, 0, 0.35);
		}
	}
	:root[data-theme='dark'] {
		--bg: #0b0f14; --surface: #141b22; --surface-2: #1a222b;
		--ink: #e7eef4; --muted: #93a0ad; --faint: #6b7783; --line: #253039; --brand: #3bb3bd;
		--good: #52c493; --good-bg: #102c20; --good-line: #1f4d38;
		--watch: #e6b45c; --watch-bg: #2c2211; --watch-line: #4a3a1a;
		--crit: #f28b7f; --crit-bg: #301410; --crit-line: #5a2820;
		--none: #8b97a5; --none-bg: #1a222b; --none-line: #2b3641;
		--shadow: 0 1px 2px rgba(0, 0, 0, 0.3), 0 8px 24px rgba(0, 0, 0, 0.35);
	}

	:global(body) { margin: 0; background: var(--bg); color: var(--ink); font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif; }
	.mono { font-family: var(--mono); font-variant-numeric: tabular-nums; }
	.faint { color: var(--faint); }
	.eyebrow { font-size: 11px; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint); }
	h1, h2 { margin: 0; text-wrap: balance; }
	button { font: inherit; cursor: pointer; }
	:focus-visible { outline: 2px solid var(--brand); outline-offset: 2px; border-radius: 6px; }

	.app { display: grid; grid-template-columns: 232px 1fr; min-height: 100vh; }
	.rail { background: var(--surface); border-right: 1px solid var(--line); padding: 16px 13px; display: flex; flex-direction: column; gap: 12px; }
	.brandrow { display: flex; align-items: center; gap: 8px; font-weight: 700; }
	.brandrow svg { color: var(--brand); }
	.addbtn { padding: 9px; border: 1px solid var(--line); border-radius: 10px; background: var(--surface-2); color: var(--ink); font-weight: 600; font-size: 13px; }
	.add-form { display: flex; flex-direction: column; gap: 6px; }
	.add-form input { padding: 7px 9px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-2); color: var(--ink); font-size: 13px; }
	.add-form button { padding: 7px; border-radius: 8px; border: 1px solid var(--brand); background: var(--brand); color: #fff; font-weight: 600; }
	.fleet { list-style: none; margin: 4px 0 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
	.fleet li { display: flex; align-items: center; border-radius: 10px; }
	.fleet li.active { background: color-mix(in srgb, var(--brand) 13%, transparent); }
	.server { flex: 1; text-align: left; background: none; border: 0; color: var(--ink); padding: 9px 11px; display: flex; flex-direction: column; gap: 2px; }
	.server .nm { font-weight: 650; font-size: 14px; }
	.server .ad { font-size: 11.5px; color: var(--muted); }
	.rm { background: none; border: 0; color: var(--faint); font-size: 18px; padding: 0 10px; }
	.empty { color: var(--muted); font-size: 13px; padding: 8px 11px; }
	.err { color: var(--crit); font-size: 12px; }

	.main { min-width: 0; padding: 22px clamp(16px, 3vw, 32px) 60px; }
	.wrap { max-width: 1000px; margin: 0 auto; display: flex; flex-direction: column; gap: 20px; }
	.placeholder { max-width: 460px; margin: 15vh auto; text-align: center; color: var(--muted); }
	.placeholder h1 { color: var(--ink); }
	code { font-family: var(--mono); background: var(--surface-2); padding: 1px 5px; border-radius: 5px; }

	.topbar { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
	.topbar h1 { font-size: 25px; letter-spacing: -0.02em; }
	.sub { color: var(--muted); font-size: 12.5px; margin-top: 3px; }
	.freshness { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; color: var(--good); font-weight: 600; margin-top: 5px; }
	.freshness .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--good); }
	.freshness.stale { color: var(--crit); }
	.freshness.stale .dot { background: var(--crit); }
	.refresh { padding: 8px 13px; border: 1px solid var(--line); background: var(--surface); color: var(--ink); border-radius: 10px; font-weight: 600; font-size: 13px; }

	.card { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow); }
	.errbox { padding: 14px 16px; color: var(--crit); }
	.errbox pre { white-space: pre-wrap; font-size: 12.5px; }
	.loading { color: var(--muted); }

	.posture { display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 22px; padding: 21px 24px; border-radius: var(--radius); box-shadow: var(--shadow); background: var(--surface); border: 1px solid var(--line); position: relative; overflow: hidden; }
	.posture::before { content: ''; position: absolute; inset: 0 auto 0 0; width: 5px; background: var(--st); }
	.posture[data-state='good'] { --st: var(--good); }
	.posture[data-state='watch'] { --st: var(--watch); }
	.posture[data-state='crit'] { --st: var(--crit); }
	.shield { width: 56px; height: 56px; color: var(--st); flex: none; }
	.verdict { font-size: 21px; font-weight: 750; letter-spacing: -0.02em; }
	.vsub { color: var(--muted); font-size: 13.5px; margin-top: 3px; max-width: 62ch; }
	.count { text-align: center; padding: 10px 18px; border-radius: 12px; background: var(--surface-2); border: 1px solid var(--line); min-width: 92px; }
	.count b { display: block; font-size: 28px; font-weight: 780; line-height: 1; color: var(--st); }
	.count.ok b { color: var(--good); }
	.count span { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }

	.block { display: flex; flex-direction: column; gap: 11px; }
	.bh { display: flex; align-items: baseline; gap: 10px; }
	.bh .hint { font-size: 12.5px; color: var(--faint); }

	.finding { display: grid; grid-template-columns: 4px 1fr auto; overflow: hidden; }
	.finding[data-sev='crit'] { --st: var(--crit); --st-bg: var(--crit-bg); --st-line: var(--crit-line); }
	.finding[data-sev='watch'] { --st: var(--watch); --st-bg: var(--watch-bg); --st-line: var(--watch-line); }
	.finding[data-sev='none'] { --st: var(--none); --st-bg: var(--none-bg); --st-line: var(--none-line); }
	.finding .stripe { background: var(--st); }
	.fbody { padding: 15px 16px; min-width: 0; }
	.ftitle { font-weight: 650; font-size: 15px; letter-spacing: -0.01em; display: flex; align-items: center; gap: 9px; flex-wrap: wrap; }
	.fwhy { color: var(--muted); font-size: 13.5px; margin-top: 4px; max-width: 70ch; }
	.ftarget { font-size: 12px; color: var(--faint); margin-top: 7px; word-break: break-all; }
	.faside { padding: 14px 16px; display: flex; flex-direction: column; gap: 7px; align-items: flex-end; justify-content: center; }

	.chip { font-size: 10.5px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; padding: 3px 8px; border-radius: 999px; white-space: nowrap; border: 1px solid var(--none-line); background: var(--none-bg); color: var(--none); }
	.chip[data-sev='crit'] { border-color: var(--crit-line); background: var(--crit-bg); color: var(--crit); }
	.chip[data-sev='watch'] { border-color: var(--watch-line); background: var(--watch-bg); color: var(--watch); }
	.chip[data-sev='none'] { border-color: var(--none-line); background: var(--none-bg); color: var(--none); }

	.btn { padding: 8px 13px; border-radius: 9px; font-size: 13px; font-weight: 650; border: 1px solid var(--line); background: var(--surface-2); color: var(--ink); white-space: nowrap; }
	.btn:disabled { opacity: 0.5; }
	.btn.primary { background: var(--brand); border-color: var(--brand); color: #fff; }
	.btn.danger { color: var(--crit); border-color: var(--crit-line); background: var(--crit-bg); }

	.exp-lead { display: flex; align-items: flex-start; gap: 11px; padding: 15px 16px; font-size: 14px; }
	.exp-ic { flex: none; margin-top: 1px; color: var(--watch); }
	.exp-ic[data-ok='true'] { color: var(--good); }
	.portrow { display: grid; grid-template-columns: 190px 1fr auto; gap: 12px; align-items: center; padding: 12px 16px; border-top: 1px solid var(--line); font-size: 13.5px; }
	.pport { color: var(--muted); }
	.pdesc { color: var(--muted); font-size: 13px; }

	.clear-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(215px, 1fr)); gap: 1px; background: var(--line); border: 1px solid var(--line); border-radius: var(--radius); overflow: hidden; }
	.clear-cell { background: var(--surface); padding: 13px 15px; display: flex; align-items: center; gap: 11px; color: var(--good); }
	.clear-cell[data-ok='false'] { color: var(--crit); }
	.clear-cell .t { font-weight: 600; font-size: 13.5px; color: var(--ink); }
	.clear-cell .d { color: var(--muted); font-size: 12px; }

	.health { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; }
	.stat { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; }
	.stat .l { font-size: 11px; color: var(--faint); text-transform: uppercase; letter-spacing: 0.05em; }
	.stat .v { font-size: 20px; font-weight: 720; margin-top: 4px; letter-spacing: -0.02em; }
	.stat .v small { font-size: 12px; color: var(--muted); font-weight: 500; }
	.bar { height: 5px; border-radius: 4px; background: var(--surface-2); margin-top: 8px; overflow: hidden; }
	.bar > i { display: block; height: 100%; background: var(--good); }

	.actrow { display: flex; gap: 8px; flex-wrap: wrap; }
	.okmsg { color: var(--good); font-size: 13px; }

	.modal-backdrop { position: fixed; inset: 0; background: rgba(10, 14, 20, 0.55); display: flex; align-items: center; justify-content: center; padding: 20px; z-index: 50; }
	.modal { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow); max-width: 560px; width: 100%; max-height: 82vh; overflow: auto; padding: 20px 22px; }
	.modal h2 { font-size: 18px; }
	.modal .muted { color: var(--muted); font-size: 13px; }
	.preview { background: var(--surface-2); border: 1px solid var(--line); border-radius: 9px; padding: 12px; font-family: var(--mono); font-size: 12px; white-space: pre-wrap; overflow: auto; }
	.modal-actions { display: flex; justify-content: flex-end; gap: 9px; margin-top: 14px; }

	@media (max-width: 760px) {
		.app { grid-template-columns: 1fr; }
		.rail { flex-direction: row; align-items: center; overflow-x: auto; }
		.posture { grid-template-columns: auto 1fr; }
		.posture .count { grid-column: 1 / -1; }
		.finding { grid-template-columns: 4px 1fr; }
		.faside { flex-direction: row; }
		.health { grid-template-columns: repeat(2, 1fr); }
		.portrow { grid-template-columns: 1fr; gap: 4px; }
	}
	@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
</style>
