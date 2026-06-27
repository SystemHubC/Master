# Privacy Policy — Pulse Intelligence Autopilot

Pulse Intelligence Autopilot is a FunPay Pulse plugin that helps a seller answer buyer messages with deterministic rules and, if enabled, an external OpenAI-compatible AI provider.

## What data may be processed

The plugin may process:

- buyer message text;
- FunPay chat/order identifiers;
- buyer username available in events;
- lot/category/order context available in Pulse events;
- seller-provided knowledge base, lot knowledge, style settings and quick templates;
- short dialog memory stored in the plugin state;
- Telegram admin commands and test-chat messages if Telegram control is enabled.

## External AI providers

If `use_llm` is enabled, the plugin sends selected buyer text, dialog context, seller instructions, lot knowledge and style settings to the configured OpenAI-compatible endpoint. The endpoint is configured by the seller in `llm_base_url` and `llm_model`.

The plugin does not send data to an AI provider when a quick template, silence rule, blacklist, stop-word rule, schedule rule or smart-noise filter is matched before AI generation.

## Telegram control

Telegram control is disabled by default. If enabled, the plugin uses a Telegram bot token stored in Pulse secrets. Telegram may receive admin notifications, Suggest drafts, stop-word alerts, test-chat messages and command responses. Only Telegram IDs listed in `telegram_admin_ids` are allowed to control the plugin.

## Storage

The plugin stores its own configuration and state in Pulse storage. This can include statistics, short dialog memory, pending Suggest drafts, mute/blacklist state and test-chat state. Secrets are stored separately through Pulse `secrets:own`.

## Retention

The seller can clear memory, reset statistics and export backups from the plugin UI or Telegram commands. Backups may contain operational settings and dialog snippets and should not be published.

## Contact

Support: https://t.me/AndreyCatser
