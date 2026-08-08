// Thin typed wrappers over the Tauri backend commands (src-tauri/src/lib.rs).
import { invoke } from '@tauri-apps/api/core';
import type { Server, ShieldState, ActionName } from './types';

export const listServers = () => invoke<Server[]>('list_servers');

export const addServer = (server: Server) => invoke<Server[]>('add_server', { server });

export const removeServer = (name: string) => invoke<Server[]>('remove_server', { name });

export const fetchState = (name: string) => invoke<ShieldState>('fetch_state', { name });

export const runAction = (name: string, action: ActionName, apply: boolean) =>
	invoke<Record<string, unknown>>('run_action', { name, action, apply });
