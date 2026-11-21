# Sign-in and first run

**Welcome to Rui** asks you to choose **ChatGPT** or **API key**. ChatGPT offers browser and device-code methods. API key opens editable **Base URL**, masked **API key** and **Model ID** fields.

## Sub-features

- **Continue in your browser** shows a link preview, **Paste callback**, **Open browser**, **Copy URL**, **Change method** and **Back**. **Copy URL** copies the complete sign-in URL.
- **Use a device code** shows the address and code, with **Copy code**, **Open browser**, **Change method** and **Back**. C copies the code.
- **Connect with an API key** has **Connect** and **Back** controls. Typing a key shows mask characters.
- Tab/Shift-Tab move between controls; Enter or a click activates one. **Close** leaves the account chooser.

## How to get to it (user POV)

Run `rui` without local credentials, or open **Settings**, select **Sign-in** and press Enter. Choose the account and method, then follow the words shown in the dialog.

## Driving it with verify-rui

Run `$V frames FULLSHA --only first-run,first-run-browser,first-run-codex,first-run-key`.

Frame states: `first-run`, `first-run-browser`, `first-run-codex`, `first-run-key`, `signin-paste-refused-night`, `settings-signin`

These recipes open a separate terminal without local credentials. `RUI_TEST_LOGIN=waiting` keeps browser sign-in on the loopback fixture and device sign-in waiting for cancellation. Check the explicit browser/copy controls and the masked API key at both sizes. The API recipe types a key without connecting. `signin-paste-refused-night` opens first-run Sign-in, chooses API key and sends an over-limit bracketed paste: the key field locks, Status names **API key** and Connect stays blocked.

## Gotchas

These states show the dialog, not a completed sign-in. Drawing the device code must not copy it automatically. They do not prove clipboard delivery, real browser login or the active Host's configuration.

Source: [Sign-in screen](../../../../src/SignIn.zig), [controls and transitions](../../../../src/sign_in.zig), [frame limits](./frames.md).
