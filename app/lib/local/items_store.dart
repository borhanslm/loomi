// Items on this device: a cache of the last list (so the app opens instantly and works offline)
// and an outbox of captures typed while offline — sent as soon as the server is reachable.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/loomi_api.dart';
import 'reminders.dart';
import 'session.dart';

class PendingCapture {
  PendingCapture(this.clientId, this.text, this.at);
  factory PendingCapture.fromJson(Map<String, dynamic> j) => PendingCapture(j['id'] as String, j['text'] as String, DateTime.parse(j['at'] as String));
  Map<String, dynamic> toJson() => {'id': clientId, 'text': text, 'at': at.toIso8601String()};
  final String clientId, text;
  final DateTime at;
}

class ItemsState {
  const ItemsState({this.items = const [], this.pending = const [], this.loaded = false, this.error});
  final List<Item> items;
  final List<PendingCapture> pending;
  final bool loaded;
  final String? error;
  ItemsState copy({List<Item>? items, List<PendingCapture>? pending, bool? loaded, String? error, bool clearError = false}) =>
      ItemsState(items: items ?? this.items, pending: pending ?? this.pending, loaded: loaded ?? this.loaded, error: clearError ? null : error ?? this.error);
}

String newClientId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class ItemsController extends Notifier<ItemsState> {
  static const _kItems = 'loomi.items.v1', _kOutbox = 'loomi.outbox.v1';
  bool _flushing = false;

  LoomiApi? get _api => ref.read(sessionProvider).value?.api;

  @override
  ItemsState build() {
    _restore();
    return const ItemsState();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final items = (jsonDecode(p.getString(_kItems) ?? '[]') as List).map((e) => Item.fromJson(e as Map<String, dynamic>)).toList();
    final pending = (jsonDecode(p.getString(_kOutbox) ?? '[]') as List).map((e) => PendingCapture.fromJson(e as Map<String, dynamic>)).toList();
    if (state.loaded) return; // a fresher server list already arrived
    state = state.copy(items: items, pending: pending);
    unawaited(Reminders.instance.sync(items));
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kItems, jsonEncode(state.items.map((e) => e.toJson()).toList()));
    await p.setString(_kOutbox, jsonEncode(state.pending.map((e) => e.toJson()).toList()));
    unawaited(Reminders.instance.sync(state.items));
  }

  /// Fetch everything from the server (open + recently done), then send any queued captures.
  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    try {
      // buttons pressed in notifications while offline
      for (final a in await takeQueuedActions()) {
        try {
          await applyAction(api, a.itemId, a.action);
        } on LoomiApiError catch (e) {
          if (e.status == null) await queueAction(a.itemId, a.action); // still offline
        }
      }
      final items = await api.items(status: 'all');
      state = state.copy(items: items, loaded: true, clearError: true);
      await _save();
      await flush();
    } on LoomiApiError catch (e) {
      if (e.unauthorized) {
        // this device was removed on the server → back to pairing
        await clearLocal();
        await ref.read(sessionProvider.notifier).signOut();
        return;
      }
      state = state.copy(error: e.message);
    }
  }

  /// Capture text. Returns the server's understanding, or null if it was queued offline.
  Future<CaptureResult?> capture(String text) async {
    final pc = PendingCapture(newClientId(), text.trim(), DateTime.now());
    state = state.copy(pending: [...state.pending, pc]);
    await _save();
    return _send(pc);
  }

  Future<CaptureResult?> _send(PendingCapture pc) async {
    final api = _api;
    if (api == null) return null;
    try {
      final r = await api.capture(pc.text, clientId: pc.clientId);
      state = state.copy(
        pending: state.pending.where((p) => p.clientId != pc.clientId).toList(),
        items: [...r.items, ...state.items.where((i) => !r.items.any((n) => n.id == i.id))],
      );
      await _save();
      return r;
    } on LoomiApiError catch (e) {
      if (e.status != null && e.status! >= 400 && e.status! < 500 && e.status != 429 && e.status != 401) {
        // the server refused it for good — drop it rather than retrying forever
        state = state.copy(pending: state.pending.where((p) => p.clientId != pc.clientId).toList(), error: e.message);
        await _save();
      }
      return null;
    }
  }

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      for (final pc in [...state.pending]) {
        await _send(pc);
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> setDone(Item it, bool done) => _patch(it, {'done': done}, (i) => _with(i, done: done));

  Future<void> edit(Item it, {String? title, ItemType? type, DateTime? dueAt, bool clearDue = false, bool? allDay}) => _patch(it, {
        'title': ?title,
        if (type != null) 'type': type.name,
        if (clearDue) 'dueAt': null else if (dueAt != null) 'dueAt': dueAt.toUtc().toIso8601String(),
        'allDay': ?allDay,
      }, (i) => _with(i, title: title, type: type, dueAt: dueAt, clearDue: clearDue, allDay: allDay));

  /// Items the server made elsewhere (e.g. from a voice note) — show them right away.
  Future<void> absorb(List<Item> fresh) async {
    if (fresh.isEmpty) return;
    state = state.copy(items: [...fresh, ...state.items.where((i) => !fresh.any((n) => n.id == i.id))]);
    await _save();
  }

  /// «Remind me later».
  Future<void> snooze(Item it, [int minutes = snoozeMinutes]) async {
    final before = state.items;
    final at = DateTime.now().add(Duration(minutes: minutes));
    state = state.copy(items: before.map((i) => i.id == it.id ? _with(i, remindAt: at) : i).toList());
    try {
      final fresh = await _api?.snooze(it.id, minutes);
      if (fresh != null) state = state.copy(items: state.items.map((i) => i.id == it.id ? fresh : i).toList());
      await _save();
    } on LoomiApiError catch (e) {
      state = state.copy(items: before, error: e.message);
    }
  }

  /// A notification button: done / later / open.
  Future<void> onNotice(String? itemId, String action) async {
    if (itemId == null) return;
    final it = state.items.where((i) => i.id == itemId).firstOrNull;
    if (it == null) {
      if (action != 'open') await queueAction(itemId, action);
      return refresh();
    }
    if (action == 'done') return setDone(it, true);
    if (action == 'later') return snooze(it);
  }

  Future<void> remove(Item it) async {
    final before = state.items;
    state = state.copy(items: before.where((i) => i.id != it.id).toList());
    try {
      await _api?.deleteItem(it.id);
      await _save();
    } on LoomiApiError catch (e) {
      state = state.copy(items: before, error: e.message);
    }
  }

  Future<void> _patch(Item it, Map<String, dynamic> body, Item Function(Item) optimistic) async {
    final before = state.items;
    state = state.copy(items: before.map((i) => i.id == it.id ? optimistic(i) : i).toList());
    try {
      final fresh = await _api?.updateItem(it.id, body);
      if (fresh != null) state = state.copy(items: state.items.map((i) => i.id == it.id ? fresh : i).toList());
      await _save();
    } on LoomiApiError catch (e) {
      state = state.copy(items: before, error: e.message);
    }
  }

  static Item _with(Item i, {String? title, ItemType? type, DateTime? dueAt, bool clearDue = false, bool? allDay, bool? done, DateTime? remindAt}) {
    final isDone = done ?? i.done;
    final due = clearDue ? null : dueAt ?? i.dueAt;
    // a new time means a fresh reminder; done items never remind
    final remind = isDone ? null : remindAt ?? (clearDue || dueAt != null ? due : i.remindAt ?? due);
    return Item(
      id: i.id, type: type ?? i.type, title: title ?? i.title, notes: i.notes,
      dueAt: due, allDay: allDay ?? i.allDay,
      people: i.people, place: i.place, done: isDone, createdAt: i.createdAt, remindAt: remind,
    );
  }

  Future<void> clearLocal() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kItems);
    await p.remove(_kOutbox);
    state = const ItemsState();
    await Reminders.instance.sync(const []); // no reminders for a removed device
  }
}

final itemsProvider = NotifierProvider<ItemsController, ItemsState>(ItemsController.new);
