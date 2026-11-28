# App settings and Keys

The pinned **Settings** row opens the **Rui** panel. It shows defaults for new chats, sign-in, the installed version and **Keys**. Keys shows the shared keyboard reference in two columns when space allows and one column in a narrow terminal.

## Sub-features

- **Model**, **Effort**, **Permissions** and **Notifications** edit app settings. Permissions offers **run without asking** and **ask first**.
- **Sign-in** opens the account dialog. **Version** starts Upgrade.
- **Memory**, when available, shows Rui and tool memory use. It is read only.
- **Keys** is the second last selectable row, before **Connections**. It includes **enter**, **esc**, **⇧enter**, **tab**, **⇧tab**, **ctrl+x**, **↑↓**, **←→**, **ctrl+o**, **ctrl+p**, **ctrl+r**, **/**, **alt+↑↓**, **alt+a** and **ctrl+c**.

## How to get to it (user POV)

On Overview press End then Enter, or click **Settings** in the list beside a wide chat. Use Up/Down and Enter, or click a field and its choice. From the first field, press Down six times then Enter for Keys. Esc returns from Keys to Settings; another Esc returns to the screen you came from.

## Driving it with verify-rui

Run `$V frames FULLSHA --only settings,settings-field-hover,mouse-settings,keys,settings-connections`.

Frame states: `settings`, `settings-field-hover`, `mouse-settings`, `keys`, `settings-connections`, `panels-settings`

Check both sizes. Hovering Notifications must leave the selection unchanged. Compare keyboard and mouse entry into Settings. Keys must show aligned pairs at 140 columns and one column at 46, without a title, footer or command list. Model captures belong to [Model choice](./model-choice.md).

## Gotchas

App defaults and an existing chat's settings have different scopes. Use [Chat info](./status-navigation.md) to change the open chat. `/setup` shows defaults as command output; it does not open this panel.

Source: [App settings](../../../../src/app_settings.zig), [Keys](../../../../src/keys_panel.zig), [key names and meanings](../../../../src/keymap.zig).
