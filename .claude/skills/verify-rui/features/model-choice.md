# Model choice and Effort

**Model** opens an editable value with matching models below it. Typing filters the matches, arrows select and Enter saves. **Effort** offers the levels supported by that model. These choices appear in App settings, Chat info or above a chat's input.

## Sub-features

- The current model has a **✓**. Matching names are indented beneath the value; **↓ N more** appears when more matches remain below.
- Filtering shortens the list without a separate **Filter:** row.
- A chat's model and effort words are clickable. Tab focuses Model; another Tab focuses Effort; Enter opens the focused choice.
- `/model` opens the same chat choice. Empty chats can choose model and effort before sending.
- App settings changes defaults; chat choices change that Session. Esc closes the topmost choice.

## How to get to it (user POV)

Click the model or effort below a chat's input, use Tab and Enter, or send `/model`. In Chat info use Up/Down then Enter on **Model** or **Effort**. In App settings choose those fields the same way. Click a matching model or effort to save it.

## Driving it with verify-rui

Run `$V frames FULLSHA --only appcmds-model,settings-model,settings-model-filter,start-model,start-effort,start-picked,chat-effort,model-picker,model-filter`.

Frame states: `appcmds-model`, `settings-model`, `settings-model-filter`, `start-model`, `start-effort`, `start-picked`, `chat-effort`, `model-picker`, `model-filter`

Check **✓**, indented matches and the typed **sol** or **ter** query in the Model value row. **start-picked** checks **xhigh** in the empty chat; **chat-effort** saves **low** in an existing chat. [Chat info](./status-navigation.md) owns its nested Model layout frames.

## Gotchas

Available models depend on the provider; effort levels depend on the model. Use fixture names from the scenario, not assumptions about a live account. `model-picker` and `model-filter` open App settings from Overview.

Source: [shared model choice](../../../../src/model_choice.zig), [chat fields](../../../../src/chat_info.zig), [app defaults](../../../../src/app_settings.zig).
