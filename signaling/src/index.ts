/**
 * RemoteDesktop signaling Worker.
 *
 * One Durable Object per 6-digit pairing code. Each room holds at most
 * two peers: the host (which created the room) and one client. Messages
 * pushed by one side are long-polled by the other.
 *
 * The Worker never inspects SDP or ICE payloads — it's a typed relay.
 * Rooms self-expire after 5 minutes of inactivity.
 */

export interface Env {
	ROOMS: DurableObjectNamespace;
}

const MAX_BODY_BYTES = 16 * 1024;
const POLL_TIMEOUT_MS = 25_000;
const ROOM_TTL_MS = 5 * 60 * 1000;

type Role = "host" | "client";

interface Envelope {
	role: Role;
	kind: "offer" | "answer" | "ice" | "bye";
	payload: unknown;
	ts: number;
}

interface RoomState {
	createdAt: number;
	lastActivity: number;
	hostPresent: boolean;
	clientPresent: boolean;
	queues: { host: Envelope[]; client: Envelope[] };
}

/* ------------------------------------------------------------------ */
/* Worker entrypoint                                                  */
/* ------------------------------------------------------------------ */

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const parts = url.pathname.split("/").filter(Boolean);

		// Routes: /rooms/{code}/{action}
		if (parts[0] !== "rooms" || parts.length < 3) {
			return json({ error: "not_found" }, 404);
		}

		const code = parts[1];
		if (!/^[0-9]{6}$/.test(code)) {
			return json({ error: "bad_code" }, 400);
		}

		const id = env.ROOMS.idFromName(code);
		const stub = env.ROOMS.get(id);
		return stub.fetch(request);
	},
};

/* ------------------------------------------------------------------ */
/* Durable Object — one instance per pairing code                     */
/* ------------------------------------------------------------------ */

export class SignalingRoom implements DurableObject {
	private state: DurableObjectState;
	private room: RoomState;
	private waiters: Map<Role, Array<(v: Envelope[]) => void>> = new Map([
		["host", []],
		["client", []],
	]);

	constructor(state: DurableObjectState) {
		this.state = state;
		this.room = {
			createdAt: Date.now(),
			lastActivity: Date.now(),
			hostPresent: false,
			clientPresent: false,
			queues: { host: [], client: [] },
		};
	}

	async fetch(request: Request): Promise<Response> {
		if (Date.now() - this.room.lastActivity > ROOM_TTL_MS) {
			this.resetRoom();
		}
		this.room.lastActivity = Date.now();

		const url = new URL(request.url);
		const parts = url.pathname.split("/").filter(Boolean);
		const action = parts[2];

		try {
			switch (action) {
				case "claim":
					return await this.handleClaim(request);
				case "send":
					return await this.handleSend(request);
				case "poll":
					return await this.handlePoll(request);
				case "status":
					return this.handleStatus();
				default:
					return json({ error: "unknown_action" }, 404);
			}
		} catch (err) {
			return json(
				{ error: "internal", message: (err as Error).message },
				500,
			);
		}
	}

	/* POST /rooms/{code}/claim  body: { role }
	 * Claims the host or client slot. Fails if already claimed. */
	private async handleClaim(request: Request): Promise<Response> {
		const body = await readJson<{ role: Role }>(request);
		if (body.role !== "host" && body.role !== "client") {
			return json({ error: "bad_role" }, 400);
		}
		if (body.role === "host") {
			if (this.room.hostPresent) {
				return json({ error: "host_taken" }, 409);
			}
			this.room.hostPresent = true;
		} else {
			if (this.room.clientPresent) {
				return json({ error: "client_taken" }, 409);
			}
			if (!this.room.hostPresent) {
				return json({ error: "no_host" }, 404);
			}
			this.room.clientPresent = true;
		}
		return json({ ok: true });
	}

	/* POST /rooms/{code}/send  body: Envelope
	 * Queues a message for the *other* side to pick up. */
	private async handleSend(request: Request): Promise<Response> {
		const env = await readJson<Envelope>(request);
		if (!validEnvelope(env)) {
			return json({ error: "bad_envelope" }, 400);
		}
		const target: Role = env.role === "host" ? "client" : "host";
		this.room.queues[target].push(env);

		// Wake any long-pollers on the target side.
		const ws = this.waiters.get(target)!;
		if (ws.length > 0) {
			const drained = this.room.queues[target];
			this.room.queues[target] = [];
			while (ws.length > 0) ws.shift()!(drained);
		}
		return json({ ok: true });
	}

	/* GET /rooms/{code}/poll?role=host|client
	 * Long-poll up to POLL_TIMEOUT_MS, returns queued envelopes. */
	private async handlePoll(request: Request): Promise<Response> {
		const url = new URL(request.url);
		const role = url.searchParams.get("role") as Role | null;
		if (role !== "host" && role !== "client") {
			return json({ error: "bad_role" }, 400);
		}

		const queue = this.room.queues[role];
		if (queue.length > 0) {
			const drained = queue.slice();
			this.room.queues[role] = [];
			return json({ envelopes: drained });
		}

		// No data yet — park until send() wakes us or the timeout fires.
		return new Promise<Response>((resolve) => {
			const ws = this.waiters.get(role)!;
			const timer = setTimeout(() => {
				const i = ws.indexOf(deliver);
				if (i >= 0) ws.splice(i, 1);
				resolve(json({ envelopes: [] }));
			}, POLL_TIMEOUT_MS);

			const deliver = (envelopes: Envelope[]) => {
				clearTimeout(timer);
				resolve(json({ envelopes }));
			};
			ws.push(deliver);
		});
	}

	private handleStatus(): Response {
		return json({
			hostPresent: this.room.hostPresent,
			clientPresent: this.room.clientPresent,
			ageMs: Date.now() - this.room.createdAt,
		});
	}

	private resetRoom(): void {
		this.room = {
			createdAt: Date.now(),
			lastActivity: Date.now(),
			hostPresent: false,
			clientPresent: false,
			queues: { host: [], client: [] },
		};
		for (const ws of this.waiters.values()) {
			while (ws.length > 0) ws.shift()!([]);
		}
	}
}

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: {
			"content-type": "application/json",
			"access-control-allow-origin": "*",
		},
	});
}

async function readJson<T>(request: Request): Promise<T> {
	const raw = await request.text();
	if (raw.length > MAX_BODY_BYTES) {
		throw new Error("body_too_large");
	}
	return JSON.parse(raw) as T;
}

function validEnvelope(e: unknown): e is Envelope {
	if (!e || typeof e !== "object") return false;
	const env = e as Envelope;
	return (
		(env.role === "host" || env.role === "client") &&
		["offer", "answer", "ice", "bye"].includes(env.kind) &&
		typeof env.ts === "number"
	);
}
