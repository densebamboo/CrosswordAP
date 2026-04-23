# CrosswordAP AP Debug Test Prep

This checklist is for reproducing clue delivery and large-room connection bugs with useful logs.

## Log Capture

Debug logs are written as JSON lines under:

`user://logs/crossword_ap_<session>.log`

Every line includes `source`, `event`, `t_msec`, and structured `data`.

Useful event groups:

- `APClient`: WebSocket open/close, AP packets, item indexes, sent checks, errors.
- `GridManager`: mode changes, slot data apply, save/restore, clue reveals, location processing.
- `APHarness`: fake packet sequences and unsent solved-entry audits.

Console-only debug spam is quiet by default. Re-enable these only for focused UI/cell-state debugging:

- `DEBUG_COLOR_INDICATOR` in `grid_manager.gd`
- `DEBUG_AP_LAYOUT` in `grid_manager.gd`
- `DEBUG_AP_SAVE` in `grid_manager.gd`
- `DEBUG_AP_PROCESS` in `grid_manager.gd`
- `DEBUG_CLUE_DUMP` in `grid_manager.gd`
- `DEBUG_SETUP` in `grid_manager.gd`
- `ENABLED` in `debug_cell_locking.gd`

AP `Sync` packets are deduped within a short window so connect-time `PrintJSON` bursts do not produce several identical sync logs.

`save_progress` is logged only when AP-relevant save state changes. Typed letter saves still happen normally, but they do not produce repeated log rows unless `DEBUG_AP_SAVE` is enabled.

## Manual Large Multiworld Matrix

Run the same CrosswordAP slot through these room sizes:

- 1 player
- 10 players
- 50 players
- 100 players
- 200 players

For each run, record whether the log reaches these events:

- `websocket_open`
- `data_package`
- `send_connect`
- `connected`
- `slot_data_received`
- `slot_layout_applied`
- `puzzle_ready`

If it drops back to the menu, inspect the nearest `websocket_closed`, `connection_refused`, `json_parse_failed`, `slot_layout_invalid`, or `ap_client_failed` event.

## Clue Delivery Tests

Fresh receive:

1. Start connected in AP mode.
2. Send one `Clue` to the CrosswordAP player.
3. Confirm `received_items_processed` shows one clue.
4. Confirm `entry_revealed` and `save_progress` follow it.

Reconnect receive:

1. Receive at least one clue.
2. Close and reopen the game.
3. Reconnect to the same room.
4. Confirm `restore_complete` appears.
5. Confirm duplicate `ReceivedItems` packets do not reveal duplicate clues.

Disconnected solve audit:

1. Connect and reach `puzzle_ready`.
2. Press `Shift+7` to simulate a dropped AP connection without clearing the puzzle.
3. Solve a revealed word.
4. Press `Shift+0` to audit solved entries that do not have sent AP checks.
5. Confirm `unsent_solved_entries_audit` reports whether solved entries lack sent checks.
6. Press the normal Connect button to reconnect.
7. Confirm `resend_unsent_checks_start`, `location_check_send`, and `resend_unsent_checks_done` appear.
8. Press `Shift+0` again and confirm `unsent_count` is `0`.

Out-of-logic solve:

1. Connect and reach `puzzle_ready`.
2. Solve a word whose clue is still locked, usually by filling it from crossing letters or known answer text.
3. Confirm `out_of_logic_clue_unveiled` appears.
4. Confirm `location_check_send` appears for the next `Solved N Words` location.
5. Confirm the hidden queue count decreases so a future `Clue` item cannot be spent on that already-solved word.
6. Press `Shift+0` and confirm `unsent_count` is `0` while connected.

Two Crossword slots in one app session:

1. Complete or partially solve `Crossword001`.
2. Disconnect back to offline mode.
3. Connect as `Crossword002` in the same room without restarting Godot.
4. Confirm the new slot starts with its own `restore_skip` or `restore_complete` path.
5. Confirm `puzzle_ready` and the first `direct_clues_process_start` for the new slot do not inherit `total_direct_clues_received` from the previous slot.
6. If the server sends all 15 clue items, confirm `revealed_count` reaches `20` and `total_direct_clues_received` ends at `15`, not `30`.

## Harness Calls

Debug hotkeys are disabled by default for release builds. Enable `enable_ap_debug_hotkeys` on the GridManager node before using this section.

While the game is running, press these keys:

- `Shift+6`: manually resend solved AP checks that were saved locally but never sent.
- `Shift+7`: simulate AP connection drop while keeping the puzzle loaded.
- `Shift+8`: run fake received-items sequence.
- `Shift+9`: run fake retroactive-items sequence.
- `Shift+0`: audit solved entries that do not have sent AP checks.

If you prefer the Godot remote inspector, call these on the GridManager node:

- `debug_run_received_items_sequence()`
- `debug_run_retroactive_items_sequence()`
- `debug_audit_unsent_solved_entries()`
- `debug_simulate_ap_connection_drop()`
- `debug_resend_unsent_solved_entries()`

The harness forces the AP client into a packet-test connected state and injects fake `ReceivedItems` packets. It is intended for diagnostics only, not normal play.

## What To Attach To Bug Reports

- The newest `crossword_ap_*.log`.
- Room size and AP server version.
- Player name and slot number.
- Whether the game reached `puzzle_ready`.
- The last 30 log events before failure.
