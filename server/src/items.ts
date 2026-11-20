// Items of the second brain: tasks, reminders, shopping, ideas, notes, events.
import type { Db } from './db.js';
import { newId } from './crypto.js';
import { type Draft, ITEM_TYPES, type ItemType, type Understanding } from './brain/capture.js';

export interface Item {
  id: string; type: ItemType; title: string; notes: string | null;
  dueAt: string | null; allDay: boolean; people: string[]; place: string | null;
  done: boolean; doneAt: string | null; createdAt: string; updatedAt: string; captureId: string | null;
  /** When Loomi reminds: the snoozed time, else dueAt. Null for done items. */
  remindAt: string | null;
}

type Row = {
  id: string; type: ItemType; title: string; notes: string | null; due_at: Date | string | null; all_day: boolean;
  people: string[] | string; place: string | null; done_at: Date | string | null; created_at: Date | string; updated_at: Date | string; capture_id: string | null;
  remind_at: Date | string | null;
};
const iso = (d: Date | string | null) => (d ? new Date(d).toISOString() : null);
const toItem = (r: Row): Item => ({
  id: r.id, type: r.type, title: r.title, notes: r.notes, dueAt: iso(r.due_at), allDay: r.all_day,
  people: typeof r.people === 'string' ? JSON.parse(r.people) : r.people ?? [], place: r.place,
  done: !!r.done_at, doneAt: iso(r.done_at), createdAt: iso(r.created_at)!, updatedAt: iso(r.updated_at)!, captureId: r.capture_id,
  remindAt: r.done_at ? null : iso(r.remind_at ?? r.due_at),
});
const COLS = 'id, type, title, notes, due_at, all_day, people, place, done_at, created_at, updated_at, capture_id, remind_at';

/** Save a capture and its items. Same clientId twice (an app retrying offline captures) → same result. */
export async function saveCapture(db: Db, userId: number, deviceId: string | null, text: string, clientId: string | null, u: Understanding): Promise<{ captureId: string; items: Item[]; duplicate: boolean }> {
  if (clientId) {
    const prev = await db.query<{ id: string }>(`SELECT id FROM captures WHERE user_id = $1 AND client_id = $2`, [userId, clientId]);
    if (prev.length) return { captureId: prev[0].id, items: await itemsOfCapture(db, userId, prev[0].id), duplicate: true };
  }
  const captureId = newId();
  await db.query(`INSERT INTO captures (id, user_id, device_id, client_id, text, via, model) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [captureId, userId, deviceId, clientId, text.slice(0, 4000), u.via, u.model]);
  const items: Item[] = [];
  for (const d of u.items) items.push(await insertItem(db, userId, d, captureId));
  return { captureId, items, duplicate: false };
}

async function insertItem(db: Db, userId: number, d: Draft, captureId: string | null): Promise<Item> {
  const rows = await db.query<Row>(
    `INSERT INTO items (id, user_id, capture_id, type, title, notes, due_at, all_day, people, place)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING ${COLS}`,
    [newId(), userId, captureId, d.type, d.title, d.notes, d.dueAt?.toISOString() ?? null, d.allDay, JSON.stringify(d.people), d.place]);
  return toItem(rows[0]);
}

async function itemsOfCapture(db: Db, userId: number, captureId: string): Promise<Item[]> {
  return (await db.query<Row>(`SELECT ${COLS} FROM items WHERE user_id = $1 AND capture_id = $2 AND deleted_at IS NULL ORDER BY created_at, id`, [userId, captureId])).map(toItem);
}

export async function listItems(db: Db, userId: number, f: { status?: 'open' | 'done' | 'all'; type?: string; q?: string; limit?: number }): Promise<Item[]> {
  const where = ['user_id = $1', 'deleted_at IS NULL'];
  const args: unknown[] = [userId];
  if (f.status === 'open') where.push('done_at IS NULL');
  if (f.status === 'done') where.push('done_at IS NOT NULL');
  if (f.type && (ITEM_TYPES as readonly string[]).includes(f.type)) { args.push(f.type); where.push(`type = $${args.length}`); }
  if (f.q?.trim()) {
    args.push(`%${f.q.trim().replace(/[%_\\]/g, m => '\\' + m)}%`);
    where.push(`(title ILIKE $${args.length} OR coalesce(notes, '') ILIKE $${args.length} OR coalesce(place, '') ILIKE $${args.length} OR people::text ILIKE $${args.length})`);
  }
  args.push(Math.min(Math.max(f.limit ?? 500, 1), 1000));
  return (await db.query<Row>(
    `SELECT ${COLS} FROM items WHERE ${where.join(' AND ')}
     ORDER BY done_at IS NOT NULL, due_at IS NULL, due_at, created_at DESC LIMIT $${args.length}`, args)).map(toItem);
}

export interface ItemPatch { title?: string; notes?: string | null; type?: string; dueAt?: string | null; allDay?: boolean; done?: boolean }

export class ItemError extends Error {}

export async function updateItem(db: Db, userId: number, id: string, p: ItemPatch): Promise<Item | null> {
  const sets: string[] = [], args: unknown[] = [id, userId];
  const set = (col: string, v: unknown) => { args.push(v); sets.push(`${col} = $${args.length}`); };
  if (p.title !== undefined) { const t = p.title.trim(); if (!t) throw new ItemError('عنوان خالی است.'); set('title', t.slice(0, 200)); }
  if (p.notes !== undefined) set('notes', p.notes?.trim() ? p.notes.trim().slice(0, 2000) : null);
  if (p.type !== undefined) { if (!(ITEM_TYPES as readonly string[]).includes(p.type)) throw new ItemError('نوع ناشناخته.'); set('type', p.type); }
  if (p.dueAt !== undefined) {
    const v = p.dueAt === '' ? null : p.dueAt; // the HTTP layer may turn null into ''
    if (v !== null && Number.isNaN(Date.parse(v))) throw new ItemError('زمان نامعتبر است.');
    set('due_at', v);
    sets.push('remind_at = NULL', 'reminded_at = NULL'); // a new time means a fresh reminder
  }
  if (p.allDay !== undefined) set('all_day', p.allDay);
  if (p.done !== undefined) sets.push(p.done ? 'done_at = coalesce(done_at, now())' : 'done_at = NULL');
  if (!sets.length) throw new ItemError('چیزی برای تغییر نیست.');
  sets.push('updated_at = now()');
  const rows = await db.query<Row>(`UPDATE items SET ${sets.join(', ')} WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL RETURNING ${COLS}`, args);
  return rows.length ? toItem(rows[0]) : null;
}

export async function deleteItem(db: Db, userId: number, id: string): Promise<boolean> {
  return (await db.query(`UPDATE items SET deleted_at = now(), updated_at = now() WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL RETURNING id`, [id, userId])).length > 0;
}

/** «Remind me later»: move this item's reminder `minutes` from now (its due time stays). */
export async function snoozeItem(db: Db, userId: number, id: string, minutes: number): Promise<Item | null> {
  const rows = await db.query<Row>(
    `UPDATE items SET remind_at = now() + ($3::int * interval '1 minute'), reminded_at = NULL, updated_at = now()
     WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL RETURNING ${COLS}`, [id, userId, minutes]);
  return rows.length ? toItem(rows[0]) : null;
}

/**
 * Reminders that are due at `now` and not yet sent; marks them sent. Skips anything more than
 * `graceMin` late (a server that was down all night shouldn't fire yesterday's reminders) and
 * items saved after their own time («I had a meeting this morning»).
 */
export async function takeDueReminders(db: Db, now: Date, graceMin = 360): Promise<{ userId: number; item: Item }[]> {
  const rows = await db.query<Row & { user_id: number | string }>(
    `UPDATE items SET reminded_at = $1
     WHERE done_at IS NULL AND deleted_at IS NULL
       AND coalesce(remind_at, due_at) <= $1
       AND coalesce(remind_at, due_at) > $1::timestamptz - ($2::int * interval '1 minute')
       AND coalesce(remind_at, due_at) >= created_at - interval '1 minute'
       AND (reminded_at IS NULL OR reminded_at < coalesce(remind_at, due_at))
     RETURNING user_id, ${COLS}`, [now.toISOString(), graceMin]);
  return rows.map(r => ({ userId: Number(r.user_id), item: toItem(r) }));
}
