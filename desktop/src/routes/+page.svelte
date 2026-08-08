<script lang="ts">
	import { onMount } from 'svelte';
	import { listServers, addServer, removeServer, fetchState, runAction } from '$lib/api';
	import type { Server, ShieldState, ActionName } from '$lib/types';

	let servers = $state<Server[]>([]);
	let selected = $state<string | null>(null);
	let snap = $state<ShieldState | null>(null);
	let loading = $state(false);
	let error = $state<string | null>(null);

	let showAdd = $state(false);
	let form = $state<Server>({ name: '', host: '', user: '', port: 22 });
	let addError = $state<string | null>(null);

	// action confirmation modal
	let pending = $state<{ action: ActionName; label: string; preview: unknown } | null>(null);
	let actionBusy = $state(false);
	let actionResult = $state<string | null>(null);

	const ACTIONS: { action: ActionName; label: string }[] = [
		{ action: 'apply-security-updates.sh', label: 'Apply security updates' },
		{ action: 'run-webshell-scan.sh', label: 'Run webshell scan' },
		{ action: 'run-lynis-audit.sh', label: 'Run Lynis audit' },
		{ action: 'rebaseline-drift.sh', label: 'Accept current drift as baseline' }
	];

	onMount(loadServers);

	async function loadServers() {
		try {
			servers = await listServers();
		} catch (e) {
			error = String(e);
		}
	}

	async function select(name: string) {
		selected = name;
		snap = null;
		error = null;
		actionResult = null;
		loading = true;
		try {
			snap = await fetchState(name);
		} catch (e) {
			error = String(e);
		} finally {
			loading = false;
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
		try {
			servers = await removeServer(name);
			if (selected === name) {
				selected = null;
				snap = null;
			}
		} catch (e) {
			error = String(e);
		}
	}

	async function openAction(action: ActionName, label: string) {
		if (!selected) return;
		actionBusy = true;
		actionResult = null;
		try {
			const preview = await runAction(selected, action, false);
			pending = { action, label, preview };
		} catch (e) {
			error = String(e);
		} finally {
			actionBusy = false;
		}
	}

	async function confirmAction() {
		if (!selected || !pending) return;
		actionBusy = true;
		try {
			const res = await runAction(selected, pending.action, true);
			actionResult = `${pending.label}: ${JSON.stringify(res)}`;
			pending = null;
			await select(selected); // refresh snap after applying
		} catch (e) {
			error = String(e);
		} finally {
			actionBusy = false;
		}
	}

	function sev(bad: boolean, warn = false): string {
		return bad ? 'bad' : warn ? 'warn' : 'ok';
	}

	function uptime(s?: number): string {
		if (!s) return '—';
		const d = Math.floor(s / 86400);
		const h = Math.floor((s % 86400) / 3600);
		return d > 0 ? `${d}d ${h}h` : `${h}h`;
	}
</script>

<div class="app">
	<aside class="sidebar">
		<div class="brand">🛡️ <span>Ubuntu Public Shield</span></div>

		<button class="add-btn" onclick={() => (showAdd = !showAdd)}>
			{showAdd ? '× Cancel' : '+ Add server'}
		</button>

		{#if showAdd}
			<form class="add-form" onsubmit={submitAdd}>
				<input placeholder="name (e.g. web01)" bind:value={form.name} />
				<input placeholder="host / IP" bind:value={form.host} />
				<input placeholder="ssh user" bind:value={form.user} />
				<input type="number" placeholder="port" bind:value={form.port} />
				<button type="submit">Save</button>
				{#if addError}<p class="err">{addError}</p>{/if}
			</form>
		{/if}

		<ul class="fleet">
			{#each servers as s (s.name)}
				<li class:active={selected === s.name}>
					<button class="server" onclick={() => select(s.name)}>
						<strong>{s.name}</strong>
						<span>{s.user}@{s.host}</span>
					</button>
					<button class="rm" title="Remove" onclick={() => remove(s.name)}>×</button>
				</li>
			{:else}
				<li class="empty">No servers yet. Add one above.</li>
			{/each}
		</ul>
	</aside>

	<main class="detail">
		{#if !selected}
			<div class="placeholder">
				<h1>Select a server</h1>
				<p>Install the agent on a server with <code>sudo bash install.sh</code>, then add it here.</p>
			</div>
		{:else}
			<header class="detail-head">
				<div>
					<h1>{selected}</h1>
					{#if snap?.meta}
						<p class="sub">
							{snap.system?.os ?? ''} · agent {snap.meta.agent_version ?? '?'} · collected
							{snap.meta.collected_at ?? '?'}
						</p>
					{/if}
				</div>
				<button onclick={() => selected && select(selected)}>↻ Refresh</button>
			</header>

			{#if loading}
				<p class="loading">Connecting over SSH…</p>
			{:else if error}
				<div class="error-box">
					<strong>Could not reach the agent.</strong>
					<pre>{error}</pre>
				</div>
			{:else if snap}
				<section class="tiles">
					<div class="tile {sev((snap.updates?.security ?? 0) > 0, (snap.updates?.total ?? 0) > 0)}">
						<span class="n">{snap.updates?.security ?? 0}</span>
						<span class="l">security updates</span>
						<span class="s">{snap.updates?.total ?? 0} total pending</span>
					</div>

					<div class="tile {sev((snap.ports_public_count ?? 0) > 0, false)}">
						<span class="n">{snap.ports_public_count ?? 0}</span>
						<span class="l">public ports</span>
						<span class="s">{snap.ports?.length ?? 0} listening</span>
					</div>

					<div
						class="tile {sev(
							(snap.lynis?.hardening_index ?? 100) < 60,
							(snap.lynis?.hardening_index ?? 100) < 75
						)}"
					>
						<span class="n">{snap.lynis?.hardening_index ?? '—'}</span>
						<span class="l">Lynis hardening</span>
						<span class="s">{snap.lynis?.installed ? 'index / 100' : 'not installed'}</span>
					</div>

					<div class="tile {sev((snap.drift?.added_count ?? 0) > 0)}">
						<span class="n">{snap.drift?.added_count ?? 0}</span>
						<span class="l">persistence drift</span>
						<span class="s">{snap.drift?.baseline_created ? 'baseline set' : 'since baseline'}</span>
					</div>

					<div class="tile {sev((snap.webshell?.finding_count ?? 0) > 0)}">
						<span class="n">{snap.webshell?.finding_count ?? 0}</span>
						<span class="l">webshell findings</span>
						<span class="s">
							{snap.webshell?.high_count ?? 0} high · {snap.webshell?.scanned ?? 0} scanned
						</span>
					</div>

					<div class="tile {sev((snap.threat_intel?.match_count ?? 0) > 0)}">
						<span class="n">{snap.threat_intel?.match_count ?? 0}</span>
						<span class="l">C2 / bad-IP hits</span>
						<span class="s">{snap.threat_intel?.feed_present ? 'feed active' : 'no feed'}</span>
					</div>

					<div class="tile {sev((snap.vulns?.vulnerable_count ?? 0) > 0)}">
						<span class="n">{snap.vulns?.vulnerable_count ?? 0}</span>
						<span class="l">vulnerable packages</span>
						<span class="s">{snap.vulns?.feed_present ? 'feed active' : 'no feed'}</span>
					</div>

					<div class="tile {sev((snap.services?.failed_count ?? 0) > 0)}">
						<span class="n">{snap.services?.failed_count ?? 0}</span>
						<span class="l">failed services</span>
						<span class="s">{snap.services?.running_count ?? 0} running</span>
					</div>

					<div class="tile ok">
						<span class="n">{snap.system?.disk_root_pct ?? '—'}%</span>
						<span class="l">disk /</span>
						<span class="s">
							load {snap.system?.load1 ?? '—'} · mem {snap.system?.mem_used_pct ?? '—'}% · up
							{uptime(snap.system?.uptime_s)}
						</span>
					</div>
				</section>

				<section class="actions">
					<h2>Actions</h2>
					<div class="action-row">
						{#each ACTIONS as a (a.action)}
							<button disabled={actionBusy} onclick={() => openAction(a.action, a.label)}>
								{a.label}
							</button>
						{/each}
					</div>
					{#if actionResult}<p class="ok-msg">{actionResult}</p>{/if}
				</section>

				{#if (snap.ports_public_count ?? 0) > 0}
					<section class="list">
						<h2>Public listening ports</h2>
						<ul>
							{#each (snap.ports ?? []).filter((p) => p.public) as p (p.proto + p.address + p.port)}
								<li><code>{p.proto} {p.address}:{p.port}</code> {p.process ?? ''}</li>
							{/each}
						</ul>
					</section>
				{/if}

				{#if (snap.webshell?.finding_count ?? 0) > 0}
					<section class="list">
						<h2>Webshell findings</h2>
						<ul>
							{#each snap.webshell?.findings ?? [] as f (f.file)}
								<li>
									<span class="badge {f.level === 'high' ? 'bad' : 'warn'}">{f.level}</span>
									<code>{f.file}</code> — score {f.score} ({f.signals.join(', ')})
								</li>
							{/each}
						</ul>
					</section>
				{/if}

				{#if (snap.vulns?.vulnerable_count ?? 0) > 0}
					<section class="list">
						<h2>Vulnerable packages</h2>
						<ul>
							{#each snap.vulns?.vulnerable ?? [] as v (v.package + v.cve)}
								<li>
									<span class="badge warn">{v.priority}</span>
									<code>{v.package}</code> {v.installed} → {v.fixed}
									<span class="cve">{v.cve}</span>
								</li>
							{/each}
						</ul>
					</section>
				{/if}

				{#if (snap.drift?.added_count ?? 0) > 0}
					<section class="list">
						<h2>Persistence changes since baseline</h2>
						<ul>
							{#each snap.drift?.added ?? [] as d (d)}
								<li><span class="badge bad">added</span> <code>{d}</code></li>
							{/each}
						</ul>
					</section>
				{/if}
			{/if}
		{/if}
	</main>
</div>

{#if pending}
	<div class="modal-backdrop">
		<div class="modal">
			<h2>{pending.label}</h2>
			<p>Preview of what will happen (nothing has changed yet):</p>
			<pre>{JSON.stringify(pending.preview, null, 2)}</pre>
			<div class="modal-actions">
				<button class="ghost" onclick={() => (pending = null)}>Cancel</button>
				<button class="danger" disabled={actionBusy} onclick={confirmAction}>
					{actionBusy ? 'Applying…' : 'Confirm & apply'}
				</button>
			</div>
		</div>
	</div>
{/if}

<style>
	:global(body) {
		margin: 0;
		font-family: system-ui, sans-serif;
	}
	.app {
		display: grid;
		grid-template-columns: 280px 1fr;
		height: 100vh;
		color: #1a1a1a;
		background: #f6f7f9;
	}
	.sidebar {
		background: #14181f;
		color: #e6e8ec;
		padding: 16px;
		overflow-y: auto;
	}
	.brand {
		font-size: 16px;
		font-weight: 700;
		margin-bottom: 16px;
	}
	.brand span {
		vertical-align: middle;
	}
	.add-btn {
		width: 100%;
		padding: 8px;
		margin-bottom: 10px;
		cursor: pointer;
		border: 1px solid #2b3240;
		background: #1d232d;
		color: #e6e8ec;
		border-radius: 6px;
	}
	.add-form {
		display: flex;
		flex-direction: column;
		gap: 6px;
		margin-bottom: 12px;
	}
	.add-form input {
		padding: 7px;
		border-radius: 5px;
		border: 1px solid #2b3240;
		background: #0f1319;
		color: #e6e8ec;
	}
	.add-form button {
		padding: 7px;
		cursor: pointer;
		border-radius: 5px;
		border: none;
		background: #3b82f6;
		color: white;
	}
	.fleet {
		list-style: none;
		padding: 0;
		margin: 8px 0 0;
	}
	.fleet li {
		display: flex;
		align-items: center;
		border-radius: 6px;
		margin-bottom: 4px;
	}
	.fleet li.active {
		background: #1d232d;
	}
	.fleet .server {
		flex: 1;
		text-align: left;
		background: none;
		border: none;
		color: #e6e8ec;
		padding: 8px;
		cursor: pointer;
		display: flex;
		flex-direction: column;
	}
	.fleet .server span {
		font-size: 12px;
		color: #9aa4b2;
	}
	.fleet .rm {
		background: none;
		border: none;
		color: #6b7280;
		cursor: pointer;
		font-size: 18px;
		padding: 0 8px;
	}
	.fleet .empty {
		color: #6b7280;
		font-size: 13px;
		padding: 8px;
	}
	.detail {
		padding: 24px;
		overflow-y: auto;
	}
	.placeholder {
		color: #6b7280;
		margin-top: 15vh;
		text-align: center;
	}
	.detail-head {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
	}
	.detail-head h1 {
		margin: 0;
	}
	.detail-head .sub {
		color: #6b7280;
		font-size: 13px;
		margin: 4px 0 0;
	}
	.detail-head button,
	.actions button {
		cursor: pointer;
		border: 1px solid #d1d5db;
		background: white;
		padding: 8px 12px;
		border-radius: 6px;
	}
	.tiles {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
		gap: 12px;
		margin: 20px 0;
	}
	.tile {
		background: white;
		border-radius: 10px;
		padding: 14px;
		display: flex;
		flex-direction: column;
		gap: 2px;
		border-left: 4px solid #d1d5db;
	}
	.tile .n {
		font-size: 26px;
		font-weight: 700;
	}
	.tile .l {
		font-size: 13px;
		color: #374151;
	}
	.tile .s {
		font-size: 11px;
		color: #9ca3af;
	}
	.tile.ok {
		border-left-color: #22c55e;
	}
	.tile.warn {
		border-left-color: #f59e0b;
	}
	.tile.bad {
		border-left-color: #ef4444;
		background: #fef2f2;
	}
	.actions {
		margin: 12px 0;
	}
	.action-row {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
	}
	.list {
		background: white;
		border-radius: 10px;
		padding: 8px 16px;
		margin-top: 14px;
	}
	.list ul {
		list-style: none;
		padding: 0;
	}
	.list li {
		padding: 6px 0;
		border-bottom: 1px solid #f0f0f0;
		font-size: 14px;
	}
	.badge {
		display: inline-block;
		font-size: 11px;
		padding: 1px 6px;
		border-radius: 4px;
		color: white;
		margin-right: 6px;
	}
	.badge.bad {
		background: #ef4444;
	}
	.badge.warn {
		background: #f59e0b;
	}
	.cve {
		color: #6b7280;
		font-size: 12px;
	}
	code {
		background: #f0f2f4;
		padding: 1px 4px;
		border-radius: 3px;
		font-size: 13px;
	}
	.error-box {
		background: #fef2f2;
		border: 1px solid #fecaca;
		border-radius: 8px;
		padding: 14px;
		margin-top: 16px;
	}
	.error-box pre {
		white-space: pre-wrap;
		color: #b91c1c;
		font-size: 12px;
	}
	.err {
		color: #fca5a5;
		font-size: 12px;
	}
	.ok-msg {
		color: #15803d;
		font-size: 13px;
	}
	.loading {
		color: #6b7280;
	}
	.modal-backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.5);
		display: flex;
		align-items: center;
		justify-content: center;
	}
	.modal {
		background: white;
		border-radius: 12px;
		padding: 20px;
		width: min(600px, 90vw);
		max-height: 80vh;
		overflow-y: auto;
	}
	.modal pre {
		background: #f6f7f9;
		padding: 12px;
		border-radius: 8px;
		font-size: 12px;
		white-space: pre-wrap;
	}
	.modal-actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}
	.modal-actions button {
		padding: 8px 14px;
		border-radius: 6px;
		cursor: pointer;
		border: none;
	}
	.modal-actions .ghost {
		background: #e5e7eb;
	}
	.modal-actions .danger {
		background: #ef4444;
		color: white;
	}
</style>
